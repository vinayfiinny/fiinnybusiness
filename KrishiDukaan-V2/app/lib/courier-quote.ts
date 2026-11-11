import { getAdminDb } from "./firebase-admin";

/**
 * Checkout delivery priced from the couriers.
 *
 * THE BUSINESS RULE (owner, Nov 2026)
 *   - The customer pays what the courier charges: the cheaper of Delhivery and
 *     Shiprocket for this seller's shop → this pincode → this parcel weight.
 *     If only one serves the address, that one.
 *   - Neither serves it → the seller delivers, at the seller's own slab charge.
 *   - The price is fixed at payment. A later reassignment to a farther seller
 *     never charges the customer more; the platform pays the difference.
 *
 * SPEED
 *   Two couriers answer in ~1-2 s, so quotes are cached per
 *   (shop pincode, customer pincode, weight band) for 30 minutes, in memory and
 *   in Firestore (courierQuotes). The cart asks for the price as soon as the
 *   pincode is entered; the Pay request then hits the cache, so both show the
 *   same number and paying adds no wait.
 *
 * Weight bands: couriers bill in 0.5 kg steps, so the parcel weight is rounded
 * UP to the next 0.5 kg. Cart and checkout therefore always price the same band.
 */

export type CourierQuote = {
  carrier: "delhivery" | "shiprocket";
  service: string;
  courierId?: number;
  cost: number;
  etaDays?: number | null;
};

const TIMEOUT_MS = 6000;
const CACHE_MS = 30 * 60 * 1000;
const PIN = /^[1-9]\d{5}$/;
const memQuotes = new Map<string, { at: number; quote: CourierQuote | null }>();
const memPickup = new Map<string, { at: number; pin: string | null }>();
let memConfig: { at: number; on: boolean } | null = null;

/** Off unless _serverConfig/shipping has enabled AND checkoutPricing true. */
export async function courierCheckoutEnabled(): Promise<boolean> {
  if (memConfig && Date.now() - memConfig.at < 60_000) return memConfig.on;
  let on = false;
  try {
    const d = (await getAdminDb().collection("_serverConfig").doc("shipping").get()).data();
    on = d?.enabled === true && d?.checkoutPricing === true;
  } catch { on = false; }
  memConfig = { at: Date.now(), on };
  return on;
}

const k10 = (v: unknown) => String(v ?? "").replace(/\D/g, "").slice(-10);

/** A seller document's pincode, nested or flat; "" when unusable. */
function pinOf(d: Record<string, unknown>): string {
  const a = d.address && typeof d.address === "object" ? (d.address as Record<string, unknown>) : {};
  const flat = String(a.pincode ?? d.pincode ?? "").trim();
  if (PIN.test(flat)) return flat;
  const text = typeof d.address === "string" ? d.address : "";
  return text.match(/\b[1-9]\d{5}\b/)?.[0] ?? "";
}

/** The seller's shop pincode (same document order as the booking code). */
export async function pickupPincodeFor(sellerKey: string): Promise<string | null> {
  const k = k10(sellerKey);
  if (k.length !== 10) return null;
  const hit = memPickup.get(k);
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.pin;
  const db = getAdminDb();
  let pin: string | null = null;
  outer: for (const col of ["manufacturers", "retailers", "profiles", "users"]) {
    const snaps = await Promise.all([`+91${k}`, k].map((id) => db.collection(col).doc(id).get()));
    for (const s of snaps) {
      if (!s.exists) continue;
      const p = pinOf(s.data() ?? {});
      if (p) { pin = p; break outer; }
    }
  }
  memPickup.set(k, { at: Date.now(), pin });
  return pin;
}

/** The customer's pincode: the explicit field first, else from the address. */
export function dropPincodeFrom(address: unknown, explicit?: unknown): string {
  const e = String(explicit ?? "").trim();
  if (PIN.test(e)) return e;
  if (address && typeof address === "object") {
    const a = address as Record<string, unknown>;
    const p = String(a.pincode ?? a.addressPincode ?? "").trim();
    if (PIN.test(p)) return p;
  }
  return String(address ?? "").match(/\b[1-9]\d{5}\b/)?.[0] ?? "";
}

/**
 * Billable parcel weight: each line's pack weight (a size we can't read counts
 * 1 kg per unit), +10% packing, at least 0.5 kg, rounded UP to the 0.5 kg band.
 * Same rule as the booking code (functions/src/shipping/pure.ts parcelKg).
 */
export function parcelKgFor(lines: Array<{ qty: number; weightKg: number }>): number {
  const raw = lines.reduce((s, l) => s + (l.weightKg > 0 ? l.weightKg : Math.max(1, l.qty) * 1), 0);
  const kg = Math.max(0.5, raw * 1.1);
  return Math.ceil(kg * 2) / 2;
}

async function http(url: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS), cache: "no-store" });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return null; }
}

async function delhivery(pickup: string, drop: string, kg: number): Promise<CourierQuote[]> {
  const token = process.env.DELHIVERY_API_TOKEN;
  if (!token) return [];
  const h = { Authorization: `Token ${token}`, Accept: "application/json" };
  const pin = await http(`https://track.delhivery.com/c/api/pin-codes/json/?filter_codes=${drop}`, { headers: h });
  const code = pin?.delivery_codes?.[0]?.postal_code;
  if (!code || String(code.pre_paid).toUpperCase() !== "Y") return [];
  const grams = Math.ceil(kg * 1000);
  const rates = await Promise.all((["S", "E"] as const).map((md) =>
    http(`https://track.delhivery.com/api/kinko/v1/invoice/charges/.json?md=${md}&ss=Delivered&d_pin=${drop}&o_pin=${pickup}&cgm=${grams}&pt=Pre-paid`, { headers: h })
      .catch(() => null)));
  const out: CourierQuote[] = [];
  rates.forEach((r, i) => {
    const cost = Number((Array.isArray(r) ? r[0] : r)?.total_amount);
    if (Number.isFinite(cost) && cost > 0) out.push({ carrier: "delhivery", service: i === 0 ? "Surface" : "Express", cost });
  });
  return out;
}

async function shiprocketToken(): Promise<string | null> {
  const email = process.env.SHIPROCKET_API_EMAIL;
  const password = process.env.SHIPROCKET_API_PASSWORD;
  if (!email || !password) return null;
  // Shared with the booking functions (functions/src/shipping/carriers.ts).
  const ref = getAdminDb().collection("_serverConfig").doc("shiprocketToken");
  const cached = (await ref.get()).data();
  if (cached?.token && Number(cached.expiresAt) > Date.now()) return String(cached.token);
  const r = await http("https://apiv2.shiprocket.in/v1/external/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (!r?.token) return null;
  await ref.set({ token: r.token, expiresAt: Date.now() + 8 * 24 * 3600 * 1000 });
  return String(r.token);
}

async function shiprocket(pickup: string, drop: string, kg: number, value: number): Promise<CourierQuote[]> {
  const token = await shiprocketToken();
  if (!token) return [];
  const r = await http(
    `https://apiv2.shiprocket.in/v1/external/courier/serviceability/?pickup_postcode=${pickup}&delivery_postcode=${drop}&weight=${kg}&cod=0&declared_value=${Math.max(1, Math.ceil(value))}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  const list = r?.data?.available_courier_companies;
  if (!Array.isArray(list)) return [];
  return list
    .map((c: any): CourierQuote => ({
      carrier: "shiprocket",
      service: String(c.courier_name ?? "Shiprocket"),
      courierId: Number(c.courier_company_id) || undefined,
      cost: Number(c.rate ?? c.freight_charge),
      etaDays: Number(c.estimated_delivery_days) || null,
    }))
    .filter((q: CourierQuote) => Number.isFinite(q.cost) && q.cost > 0);
}

/** Cheapest first; ties go to the faster courier. */
export function cheapestOf(quotes: CourierQuote[]): CourierQuote | null {
  const ok = quotes.filter((q) => Number.isFinite(q.cost) && q.cost > 0);
  ok.sort((a, b) => a.cost - b.cost || (a.etaDays ?? 99) - (b.etaDays ?? 99));
  return ok[0] ?? null;
}

/**
 * The cheapest courier for this route and weight band, or null when no courier
 * serves it (or both are unreachable: then the seller's own charge applies, so
 * a courier outage never blocks checkout).
 */
export async function cheapestQuote(pickup: string, drop: string, kg: number, value: number): Promise<CourierQuote | null> {
  if (!PIN.test(pickup) || !PIN.test(drop) || !(kg > 0)) return null;
  const key = `${pickup}_${drop}_${kg.toFixed(1)}`;
  const mem = memQuotes.get(key);
  if (mem && Date.now() - mem.at < CACHE_MS) return mem.quote;
  const ref = getAdminDb().collection("courierQuotes").doc(key);
  try {
    const d = (await ref.get()).data();
    if (d && Date.now() - Number(d.at) < CACHE_MS) {
      const quote = (d.quote as CourierQuote | null) ?? null;
      memQuotes.set(key, { at: Number(d.at), quote });
      return quote;
    }
  } catch { /* cache miss */ }
  const [a, b] = await Promise.allSettled([delhivery(pickup, drop, kg), shiprocket(pickup, drop, kg, value)]);
  const all = [...(a.status === "fulfilled" ? a.value : []), ...(b.status === "fulfilled" ? b.value : [])];
  const quote = cheapestOf(all);
  const bothFailed = a.status === "rejected" && b.status === "rejected";
  // Don't cache an outage as "no courier": try again on the next request.
  if (!bothFailed) {
    const at = Date.now();
    memQuotes.set(key, { at, quote });
    ref.set({ at, quote, pickup, drop, kg }).catch(() => undefined);
  }
  return quote;
}
