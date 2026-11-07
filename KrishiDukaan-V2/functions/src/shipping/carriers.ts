import * as admin from "firebase-admin";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions/v2";
import {
  delhiveryStage, nextPickupDate, shiprocketStage, trackingUrlFor,
  type CarrierId, type OrderItemLike, type Place, type Quote, type Stage, itemQty,
} from "./pure";

/**
 * Delhivery and Shiprocket behind one shape, so the engine never cares which
 * courier it is talking to.
 *
 * NOTHING HERE MAY RUN IN LIVE MODE BY ACCIDENT. Quotes are always real and
 * cost nothing. book / cancel / requestPickup take `simulate` from the engine,
 * which reads _serverConfig/shipping; in simulate mode they never touch the
 * network. Live booking creates a real shipment against a real wallet.
 */

export const DELHIVERY_API_TOKEN = defineSecret("DELHIVERY_API_TOKEN");
export const SHIPROCKET_API_EMAIL = defineSecret("SHIPROCKET_API_EMAIL");
export const SHIPROCKET_API_PASSWORD = defineSecret("SHIPROCKET_API_PASSWORD");

const DELHIVERY = "https://track.delhivery.com";
const SHIPROCKET = "https://apiv2.shiprocket.in/v1/external";
const TIMEOUT_MS = 20_000;

export interface Pickup extends Place {
  name: string;
  phone: string; // 10 digits
  phoneKey: string;
  gstin?: string;
}

export interface BookingInput {
  reference: string; // unique per order + attempt: a retry cannot book twice
  orderId: string;
  quote: Quote;
  pickup: Pickup;
  drop: Place & { name: string; phone: string };
  items: OrderItemLike[];
  weightKg: number;
  declaredValue: number;
}

export interface Booking {
  awb: string;
  carrierShipmentId?: string;
  carrierOrderId?: string;
  labelUrl?: string | null;
}

async function http(url: string, init: RequestInit = {}): Promise<{ status: number; body: any; text: string }> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  const text = await res.text();
  let body: any = null;
  try { body = JSON.parse(text); } catch { /* some endpoints answer in text */ }
  return { status: res.status, body, text };
}

// ─── Delhivery ───────────────────────────────────────────────────────────

const dlvHeaders = () => ({ Authorization: `Token ${DELHIVERY_API_TOKEN.value()}`, Accept: "application/json" });

async function delhiveryQuotes(pickupPin: string, dropPin: string, kg: number): Promise<Quote[]> {
  const pin = await http(`${DELHIVERY}/c/api/pin-codes/json/?filter_codes=${dropPin}`, { headers: dlvHeaders() });
  const code = pin.body?.delivery_codes?.[0]?.postal_code;
  if (!code || String(code.pre_paid).toUpperCase() !== "Y") return [];
  const grams = Math.ceil(kg * 1000);
  const out: Quote[] = [];
  for (const [md, service] of [["S", "Surface"], ["E", "Express"]] as const) {
    const url = `${DELHIVERY}/api/kinko/v1/invoice/charges/.json?md=${md}&ss=Delivered&d_pin=${dropPin}&o_pin=${pickupPin}&cgm=${grams}&pt=Pre-paid`;
    const r = await http(url, { headers: dlvHeaders() });
    const cost = Number((Array.isArray(r.body) ? r.body[0] : r.body)?.total_amount);
    if (Number.isFinite(cost) && cost > 0) out.push({ carrier: "delhivery", service, cost: Math.round(cost * 100) / 100 });
  }
  return out;
}

async function ensureDelhiveryWarehouse(p: Pickup): Promise<string> {
  const ref = admin.firestore().collection("courierPickups").doc(p.phoneKey);
  const name = String((await ref.get()).data()?.delhiveryName ?? "");
  if (name) return name;
  const created = `KD-${p.phoneKey}`;
  const r = await http(`${DELHIVERY}/api/backend/clientwarehouse/create/`, {
    method: "POST",
    headers: { ...dlvHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify({
      name: created, registered_name: p.name, phone: p.phone, email: "", address: p.line, city: p.city,
      pin: p.pincode, country: "India", return_address: p.line, return_city: p.city, return_pin: p.pincode,
      return_state: p.state, return_country: "India",
    }),
  });
  // "already exists" still means the name is usable.
  if (r.status >= 400 && !/already exist/i.test(r.text)) throw new Error(`Delhivery warehouse: ${r.text.slice(0, 200)}`);
  await ref.set({ delhiveryName: created, updatedAt: new Date().toISOString() }, { merge: true });
  return created;
}

async function delhiveryBook(b: BookingInput): Promise<Booking> {
  const warehouse = await ensureDelhiveryWarehouse(b.pickup);
  const data = {
    shipments: [{
      order: b.reference,
      name: b.drop.name, phone: b.drop.phone, add: b.drop.line, pin: b.drop.pincode,
      city: b.drop.city, state: b.drop.state, country: "India",
      payment_mode: "Prepaid", cod_amount: 0, total_amount: b.declaredValue,
      products_desc: b.items.map((i) => String(i.name ?? "Item")).join(", ").slice(0, 200),
      quantity: String(b.items.reduce((n, i) => n + itemQty(i), 0)),
      weight: Math.ceil(b.weightKg * 1000),
      shipping_mode: b.quote.service,
      seller_name: b.pickup.name, seller_gst_tin: b.pickup.gstin ?? "",
    }],
    pickup_location: { name: warehouse },
  };
  const r = await http(`${DELHIVERY}/api/cmu/create.json`, {
    method: "POST",
    headers: { ...dlvHeaders(), "Content-Type": "application/x-www-form-urlencoded" },
    body: `format=json&data=${encodeURIComponent(JSON.stringify(data))}`,
  });
  const pkg = r.body?.packages?.[0];
  if (!pkg?.waybill) throw new Error(`Delhivery booking: ${r.text.slice(0, 300)}`);
  const awb = String(pkg.waybill);
  let labelUrl: string | null = null;
  try {
    const l = await http(`${DELHIVERY}/api/p/packing_slip?wbns=${awb}&pdf=true`, { headers: dlvHeaders() });
    labelUrl = l.body?.packages?.[0]?.pdf_download_link ?? null;
  } catch (e) { logger.warn("[shipping] Delhivery label failed", { awb, e: String(e) }); }
  return { awb, labelUrl };
}

// ─── Shiprocket ──────────────────────────────────────────────────────────

/** A login lasts days and logging in repeatedly gets rate-limited, so it is cached. */
async function shiprocketToken(): Promise<string> {
  const ref = admin.firestore().collection("_serverConfig").doc("shiprocketToken");
  const cached = (await ref.get()).data();
  if (cached?.token && Number(cached.expiresAt) > Date.now()) return String(cached.token);
  const r = await http(`${SHIPROCKET}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: SHIPROCKET_API_EMAIL.value(), password: SHIPROCKET_API_PASSWORD.value() }),
  });
  if (!r.body?.token) throw new Error(`Shiprocket login failed (${r.status})`);
  await ref.set({ token: r.body.token, expiresAt: Date.now() + 8 * 24 * 3600 * 1000 });
  return String(r.body.token);
}

const srHeaders = async () => ({ Authorization: `Bearer ${await shiprocketToken()}`, "Content-Type": "application/json" });

async function shiprocketQuotes(pickupPin: string, dropPin: string, kg: number, value: number): Promise<Quote[]> {
  const url = `${SHIPROCKET}/courier/serviceability/?pickup_postcode=${pickupPin}&delivery_postcode=${dropPin}&weight=${kg}&cod=0&declared_value=${Math.ceil(value)}`;
  const r = await http(url, { headers: await srHeaders() });
  const list = r.body?.data?.available_courier_companies;
  if (!Array.isArray(list)) return [];
  return list
    .map((c: any): Quote => ({
      carrier: "shiprocket",
      service: String(c.courier_name ?? "Shiprocket"),
      courierId: Number(c.courier_company_id),
      cost: Math.round(Number(c.rate ?? c.freight_charge) * 100) / 100,
      etaDays: Number(c.estimated_delivery_days) || null,
    }))
    .filter((q: Quote) => Number.isFinite(q.cost) && q.cost > 0);
}

async function ensureShiprocketPickup(p: Pickup): Promise<string> {
  const ref = admin.firestore().collection("courierPickups").doc(p.phoneKey);
  const name = String((await ref.get()).data()?.shiprocketName ?? "");
  if (name) return name;
  const created = `KD${p.phoneKey}`;
  const r = await http(`${SHIPROCKET}/settings/company/addpickup`, {
    method: "POST",
    headers: await srHeaders(),
    body: JSON.stringify({
      pickup_location: created, name: p.name, email: "support@krishidukan.com", phone: p.phone,
      address: p.line.length >= 10 ? p.line : `${p.line}, ${p.city}`, city: p.city, state: p.state,
      country: "India", pin_code: p.pincode,
    }),
  });
  if (r.status >= 400 && !/already/i.test(r.text)) throw new Error(`Shiprocket pickup: ${r.text.slice(0, 200)}`);
  await ref.set({ shiprocketName: created, updatedAt: new Date().toISOString() }, { merge: true });
  return created;
}

async function shiprocketBook(b: BookingInput): Promise<Booking> {
  const pickupName = await ensureShiprocketPickup(b.pickup);
  const headers = await srHeaders();
  const [first, ...rest] = b.drop.name.trim().split(/\s+/);
  const created = await http(`${SHIPROCKET}/orders/create/adhoc`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      order_id: b.reference,
      order_date: new Date().toISOString().slice(0, 16).replace("T", " "),
      pickup_location: pickupName,
      billing_customer_name: first || "Customer", billing_last_name: rest.join(" "),
      billing_address: b.drop.line, billing_city: b.drop.city, billing_state: b.drop.state,
      billing_pincode: b.drop.pincode, billing_country: "India", billing_phone: b.drop.phone,
      shipping_is_billing: true,
      order_items: b.items.map((i, n) => ({
        name: String(i.name ?? "Item"), sku: `${b.orderId}-${n}`, units: itemQty(i), selling_price: Number(i.price ?? 0),
      })),
      payment_method: "Prepaid", sub_total: b.declaredValue,
      length: 20, breadth: 15, height: 10, weight: b.weightKg,
    }),
  });
  const shipmentId = created.body?.shipment_id;
  if (!shipmentId) throw new Error(`Shiprocket order: ${created.text.slice(0, 300)}`);
  const carrierOrderId = String(created.body.order_id ?? "");
  const assigned = await http(`${SHIPROCKET}/courier/assign/awb`, {
    method: "POST", headers,
    body: JSON.stringify({ shipment_id: shipmentId, courier_id: b.quote.courierId }),
  });
  const awb = assigned.body?.response?.data?.awb_code;
  if (!awb) {
    // Don't leave an unassigned order behind on the account.
    await http(`${SHIPROCKET}/orders/cancel`, { method: "POST", headers, body: JSON.stringify({ ids: [carrierOrderId] }) }).catch(() => undefined);
    throw new Error(`Shiprocket AWB: ${assigned.text.slice(0, 300)}`);
  }
  let labelUrl: string | null = null;
  try {
    const l = await http(`${SHIPROCKET}/courier/generate/label`, {
      method: "POST", headers, body: JSON.stringify({ shipment_id: [shipmentId] }),
    });
    labelUrl = l.body?.label_url ?? null;
  } catch (e) { logger.warn("[shipping] Shiprocket label failed", { awb, e: String(e) }); }
  return { awb: String(awb), carrierShipmentId: String(shipmentId), carrierOrderId, labelUrl };
}

// ─── One shape for the engine ────────────────────────────────────────────

export interface ActiveShipment {
  carrier: CarrierId; awb: string; carrierShipmentId?: string; carrierOrderId?: string; simulated?: boolean;
}

/** Real prices from every enabled courier. One being down never blocks the other. */
export async function getQuotes(
  carriers: CarrierId[], pickupPin: string, dropPin: string, kg: number, value: number,
): Promise<{ quotes: Quote[]; errors: string[] }> {
  const results = await Promise.allSettled(carriers.map((c) =>
    c === "delhivery" ? delhiveryQuotes(pickupPin, dropPin, kg) : shiprocketQuotes(pickupPin, dropPin, kg, value)));
  const quotes: Quote[] = [];
  const errors: string[] = [];
  results.forEach((r, i) => {
    if (r.status === "fulfilled") quotes.push(...r.value);
    else errors.push(`${carriers[i]}: ${String(r.reason).slice(0, 160)}`);
  });
  return { quotes, errors };
}

export async function bookShipment(input: BookingInput, simulate: boolean): Promise<Booking> {
  if (simulate) {
    const prefix = input.quote.carrier === "delhivery" ? "SIMD" : "SIMS";
    return { awb: `${prefix}${Date.now().toString().slice(-10)}`, labelUrl: null };
  }
  return input.quote.carrier === "delhivery" ? delhiveryBook(input) : shiprocketBook(input);
}

export async function cancelShipment(s: ActiveShipment): Promise<void> {
  if (s.simulated) return;
  if (s.carrier === "delhivery") {
    const r = await http(`${DELHIVERY}/api/p/edit`, {
      method: "POST",
      headers: { ...dlvHeaders(), "Content-Type": "application/json" },
      body: JSON.stringify({ waybill: s.awb, cancellation: "true" }),
    });
    if (r.status >= 400 || r.body?.status === false) throw new Error(`Delhivery cancel: ${r.text.slice(0, 200)}`);
    return;
  }
  const r = await http(`${SHIPROCKET}/orders/cancel`, {
    method: "POST", headers: await srHeaders(), body: JSON.stringify({ ids: [s.carrierOrderId] }),
  });
  if (r.status >= 400) throw new Error(`Shiprocket cancel: ${r.text.slice(0, 200)}`);
}

export async function requestPickup(s: ActiveShipment, warehouse: string): Promise<string> {
  const date = nextPickupDate(new Date());
  if (s.simulated) return date;
  if (s.carrier === "delhivery") {
    const r = await http(`${DELHIVERY}/fm/request/new/`, {
      method: "POST",
      headers: { ...dlvHeaders(), "Content-Type": "application/json" },
      body: JSON.stringify({ pickup_time: "11:00:00", pickup_date: date, pickup_location: warehouse, expected_package_count: 1 }),
    });
    if (r.status >= 400) throw new Error(`Delhivery pickup: ${r.text.slice(0, 200)}`);
    return date;
  }
  const r = await http(`${SHIPROCKET}/courier/generate/pickup`, {
    method: "POST", headers: await srHeaders(), body: JSON.stringify({ shipment_id: [s.carrierShipmentId] }),
  });
  if (r.status >= 400) throw new Error(`Shiprocket pickup: ${r.text.slice(0, 200)}`);
  return date;
}

/** Where the courier says the parcel is, for shipments whose webhook went quiet. */
export async function trackShipment(s: ActiveShipment): Promise<{ stage: Stage | null; detail: string }> {
  if (s.simulated) return { stage: null, detail: "" };
  if (s.carrier === "delhivery") {
    const r = await http(`${DELHIVERY}/api/v1/packages/json/?waybill=${encodeURIComponent(s.awb)}`, { headers: dlvHeaders() });
    const st = r.body?.ShipmentData?.[0]?.Shipment?.Status;
    return { stage: delhiveryStage(st?.Status, st?.StatusType), detail: String(st?.Instructions ?? st?.Status ?? "") };
  }
  const r = await http(`${SHIPROCKET}/courier/track/awb/${encodeURIComponent(s.awb)}`, { headers: await srHeaders() });
  const t = r.body?.tracking_data?.shipment_track?.[0];
  return { stage: shiprocketStage(t?.current_status), detail: String(t?.current_status ?? "") };
}

export { trackingUrlFor };
