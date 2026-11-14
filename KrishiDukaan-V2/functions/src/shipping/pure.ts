/**
 * Courier automation: the decisions, with no Firebase or network in here, so
 * every rule can be tested on its own (scripts/tests/shipping.test.ts).
 */

export type CarrierId = "delhivery" | "shiprocket";

export type Stage =
  | "booking" | "booked" | "pickup_requested" | "picked_up" | "in_transit"
  | "out_for_delivery" | "delivered" | "returning" | "returned" | "lost"
  | "cancelling" | "self";

export type SelfReason =
  | "no_pickup_address" | "no_delivery_pincode" | "blocked_category"
  | "over_value_limit" | "not_serviceable" | "booking_failed" | "automation_off";

export interface ShippingConfig {
  /** Off by default: code deployed anywhere does nothing until this is set. */
  enabled: boolean;
  /** simulate = real price quotes, invented bookings. live = real shipments. */
  mode: "simulate" | "live";
  carriers: CarrierId[];
  /**
   * With mode "live": only these sellers (10-digit phones) get REAL bookings;
   * every other seller is simulated, so an ordinary test order can't create a
   * real shipment. Empty = every seller (production). Ignored in simulate mode.
   */
  liveSellers: string[];
  /** On courier orders the platform pays the courier, so it keeps the fee. */
  platformKeepsDeliveryFee: boolean;
  /** Reassignment: skip a seller whose shipping exceeds this % of order value. 0 = no limit.
   *  Owner's rule: the order always goes ahead and the platform pays any extra,
   *  so the default is no limit. */
  reassignMaxCostPercent: number;
  /** Above this, an e-way bill is needed, so the order is handled by hand. */
  maxDeclaredValue: number;
  /** Lower-case product categories couriers will not carry. */
  blockedCategories: string[];
  minWeightKg: number;
  packingFactor: number;
  /** Weight assumed for a pack size that cannot be read ("1", "bottle"). */
  unknownItemKg: number;
  webhookToken: string;
}

export const DEFAULT_CONFIG: ShippingConfig = {
  enabled: false,
  mode: "simulate",
  carriers: ["delhivery", "shiprocket"],
  liveSellers: [],
  platformKeepsDeliveryFee: true,
  reassignMaxCostPercent: 0,
  maxDeclaredValue: 49999,
  blockedCategories: [],
  minWeightKg: 0.5,
  packingFactor: 1.1,
  unknownItemKg: 1,
  webhookToken: "",
};

export function parseConfig(raw: unknown): ShippingConfig {
  const d = (raw ?? {}) as Partial<ShippingConfig>;
  const num = (v: unknown, fallback: number) => {
    const n = Number(v);
    return v !== undefined && Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  const carriers = Array.isArray(d.carriers)
    ? d.carriers.filter((c): c is CarrierId => c === "delhivery" || c === "shiprocket")
    : DEFAULT_CONFIG.carriers;
  return {
    enabled: d.enabled === true,
    // Only the exact word turns on real bookings; anything else stays simulated.
    mode: d.mode === "live" ? "live" : "simulate",
    carriers,
    liveSellers: Array.isArray(d.liveSellers)
      ? d.liveSellers.map((p) => String(p).replace(/\D/g, "").slice(-10)).filter((p) => p.length === 10)
      : [],
    platformKeepsDeliveryFee: d.platformKeepsDeliveryFee !== false,
    reassignMaxCostPercent: num(d.reassignMaxCostPercent, DEFAULT_CONFIG.reassignMaxCostPercent),
    maxDeclaredValue: num(d.maxDeclaredValue, DEFAULT_CONFIG.maxDeclaredValue),
    blockedCategories: Array.isArray(d.blockedCategories)
      ? d.blockedCategories.map((c) => String(c).trim().toLowerCase()).filter(Boolean)
      : [],
    minWeightKg: num(d.minWeightKg, DEFAULT_CONFIG.minWeightKg) || DEFAULT_CONFIG.minWeightKg,
    packingFactor: num(d.packingFactor, DEFAULT_CONFIG.packingFactor) || DEFAULT_CONFIG.packingFactor,
    unknownItemKg: num(d.unknownItemKg, DEFAULT_CONFIG.unknownItemKg) || DEFAULT_CONFIG.unknownItemKg,
    webhookToken: String(d.webhookToken ?? ""),
  };
}

// ─── Weight ──────────────────────────────────────────────────────────────

/** Kg in a pack label, or 0 when it can't be read. Mirrors app/utils/weight.ts. */
export function packKg(label: unknown): number {
  const m = String(label ?? "").trim().toLowerCase().match(
    /^(\d+(?:\.\d+)?)\s*(kilograms?|kgs?|grams?|gms?|g|millilitres?|milliliters?|mls?|litres?|liters?|ltrs?|l)$/,
  );
  if (!m) return 0;
  const n = parseFloat(m[1]!);
  const u = m[2]!;
  if (u.startsWith("k")) return n;
  if (u.startsWith("g")) return n / 1000;
  if (u.startsWith("m")) return n / 1000;
  return n;
}

export interface OrderItemLike {
  name?: unknown; qty?: unknown; quantity?: unknown; variantUnit?: unknown;
  variantLabel?: unknown; unit?: unknown; price?: unknown; category?: unknown;
}

export const itemQty = (i: OrderItemLike) => Math.max(1, Math.floor(Number(i.quantity ?? i.qty ?? 1)) || 1);

/** Parcel weight: every line, plus packing, never below the courier minimum. */
export function parcelKg(items: OrderItemLike[], cfg: Pick<ShippingConfig, "minWeightKg" | "packingFactor" | "unknownItemKg">) {
  let kg = 0;
  let guessed = false;
  for (const it of items) {
    const pack = packKg(it.variantUnit ?? it.variantLabel ?? it.unit);
    if (pack <= 0) guessed = true;
    kg += itemQty(it) * (pack > 0 ? pack : cfg.unknownItemKg);
  }
  return {
    kg: Math.max(cfg.minWeightKg, Math.round(kg * cfg.packingFactor * 1000) / 1000),
    guessed,
  };
}

// ─── Addresses ───────────────────────────────────────────────────────────

const PIN = /\b[1-9]\d{5}\b/;

export const validPin = (v: unknown) => /^[1-9]\d{5}$/.test(String(v ?? "").trim());

export interface Place { line: string; city: string; state: string; pincode: string }

/** Orders store the address as a map (app) or joined text (website). */
export function parseCustomerAddress(raw: unknown, deliveryState?: unknown): Place {
  const state = String(deliveryState ?? "").trim();
  if (raw && typeof raw === "object") {
    const a = raw as Record<string, unknown>;
    const pin = String(a.pincode ?? a.addressPincode ?? "").trim();
    const line = String(a.address ?? a.line1 ?? a.area ?? a.addressArea ?? "").trim();
    return {
      line,
      city: String(a.city ?? a.addressCity ?? a.district ?? "").trim(),
      state: state || String(a.state ?? a.addressState ?? "").trim(),
      pincode: validPin(pin) ? pin : line.match(PIN)?.[0] ?? "",
    };
  }
  // Website order: "area, city, district, state, pincode".
  const text = String(raw ?? "").trim();
  const pincode = text.match(PIN)?.[0] ?? "";
  const parts = text.split(",").map((p) => p.trim()).filter((p) => p && p !== pincode);
  return {
    line: text,
    city: parts.length >= 3 ? parts[parts.length - 3]! : parts[1] ?? "",
    state: state || (parts.length >= 2 ? parts[parts.length - 1]! : ""),
    pincode,
  };
}

/**
 * Where an order goes. Newer orders carry a structured `deliveryAddress`
 * (house / area / landmark / city / state / pincode, written by web and app
 * checkout); older ones only the customerAddress string or map.
 */
export function orderDropPlace(o: Record<string, unknown>): Place {
  const d = o.deliveryAddress;
  if (d && typeof d === "object" && !Array.isArray(d)) {
    const a = d as Record<string, unknown>;
    const pin = String(a.pincode ?? "").trim();
    if (validPin(pin)) {
      const parts = [a.house, a.area, a.landmark ? `Near ${String(a.landmark).trim()}` : ""]
        .map((x) => String(x ?? "").trim()).filter(Boolean);
      return {
        line: parts.join(", "),
        city: String(a.city ?? a.district ?? "").trim(),
        state: String(o.customerDeliveryState ?? "").trim() || String(a.state ?? "").trim(),
        pincode: pin,
      };
    }
  }
  return parseCustomerAddress(o.customerAddress, o.customerDeliveryState);
}

/**
 * The courier cost the seller bears on a delivery-offer order: Free Delivery
 * (all of it) or a share offer (part of it) — the seller's, the store's or the
 * manufacturer network's, or the store's "free above ₹X" (lib/cart-pricing
 * records the checkout figure as deliveryBreakdown.sellerPaysCourier).
 *
 * The platform pays the courier and keeps what the customer paid, so the
 * seller covers only the gap: never more than they agreed at checkout, never
 * more than the courier actually charged minus what the customer paid. A
 * reassigned order's new seller never made the offer, so they pay nothing;
 * the platform covers it.
 */
export function sellerCourierShare(o: Record<string, unknown>, bookedCost: number | null | undefined): number {
  const breakdown = (o.deliveryBreakdown ?? {}) as Record<string, unknown>;
  const agreed = Number(breakdown.sellerPaysCourier ?? 0);
  if (!(agreed > 0)) return 0;
  const reassignment = (o.reassignment ?? {}) as Record<string, unknown>;
  if (reassignment.status === "accepted" || o.adminReassignment) return 0;
  const cost = Number(bookedCost ?? 0);
  if (!(cost > 0)) return agreed;
  const customerPaid = Math.max(0, Number(o.deliveryCharge ?? 0) || 0);
  return Math.max(0, Math.min(agreed, Math.ceil(cost) - customerPaid));
}

/** A seller document's address, nested or flat. Empty pincode when unusable. */
export function readSellerPlace(d: Record<string, unknown>): Place {
  const addr = d.address;
  const isMap = !!addr && typeof addr === "object" && !Array.isArray(addr);
  const a = (isMap ? addr : {}) as Record<string, unknown>;
  const text = isMap ? "" : String(addr ?? "");
  const pin = String(a.pincode ?? d.pincode ?? "").trim();
  return {
    line: String(a.line1 ?? a.address ?? text ?? "").trim(),
    city: String(a.city ?? d.city ?? "").trim(),
    state: String(a.state ?? d.state ?? "").trim(),
    pincode: validPin(pin) ? pin : text.match(PIN)?.[0] ?? "",
  };
}

// ─── Choosing a courier ──────────────────────────────────────────────────

export interface Quote {
  carrier: CarrierId;
  /** Service within the carrier: Surface / Express, or a Shiprocket courier name. */
  service: string;
  /** Shiprocket's courier_company_id, needed to book that exact courier. */
  courierId?: number;
  cost: number;
  etaDays?: number | null;
}

/** Cheapest first; on a tie the faster one, then a stable order. */
export function rankQuotes(quotes: Quote[]): Quote[] {
  return quotes
    .filter((q) => Number.isFinite(q.cost) && q.cost > 0)
    .slice()
    .sort((a, b) =>
      a.cost - b.cost ||
      (a.etaDays ?? 99) - (b.etaDays ?? 99) ||
      a.carrier.localeCompare(b.carrier) ||
      a.service.localeCompare(b.service));
}

/** Real booking or simulated, for this seller. Anything but exact "live" simulates. */
export function shouldSimulate(cfg: Pick<ShippingConfig, "mode" | "liveSellers">, sellerPhone: unknown): boolean {
  if (cfg.mode !== "live") return true;
  if (cfg.liveSellers.length === 0) return false;
  const key = String(sellerPhone ?? "").replace(/\D/g, "").slice(-10);
  return !cfg.liveSellers.includes(key);
}

/** Reasons an order can never go by courier, before asking for any price. */
export function courierBlocker(input: {
  pickupPin: string; dropPin: string; declaredValue: number; categories: string[]; cfg: ShippingConfig;
}): SelfReason | null {
  if (!validPin(input.pickupPin)) return "no_pickup_address";
  if (!validPin(input.dropPin)) return "no_delivery_pincode";
  if (input.cfg.maxDeclaredValue > 0 && input.declaredValue > input.cfg.maxDeclaredValue) return "over_value_limit";
  const blocked = new Set(input.cfg.blockedCategories);
  if (input.categories.some((c) => blocked.has(String(c).trim().toLowerCase()))) return "blocked_category";
  return null;
}

/** These need a person; the others are ordinary reasons for the seller to deliver. */
export const needsAttentionFor = (r: SelfReason) =>
  r === "over_value_limit" || r === "booking_failed" || r === "no_pickup_address";

export const SELF_REASON_TEXT: Record<SelfReason, string> = {
  no_pickup_address: "Your shop address has no valid pincode",
  no_delivery_pincode: "The customer's address has no valid pincode",
  blocked_category: "Couriers do not carry this product",
  over_value_limit: "Order value needs an e-way bill",
  not_serviceable: "No courier delivers to this address",
  booking_failed: "The courier booking failed",
  automation_off: "Courier booking is switched off",
};

/** Reassignment: may this seller be offered the order at this shipping cost? */
export function withinReassignCap(cost: number | null, orderValue: number, percent: number): boolean {
  if (cost === null) return true; // no courier here: the seller delivers at the platform charge
  if (percent <= 0 || orderValue <= 0) return true;
  return cost <= (orderValue * percent) / 100;
}

// ─── Tracking events ─────────────────────────────────────────────────────

const RANK: Record<Stage, number> = {
  booking: 0, cancelling: 0, self: 0, booked: 1, pickup_requested: 2, picked_up: 3, in_transit: 4,
  out_for_delivery: 5, delivered: 6, returning: 5, lost: 6, returned: 7,
};

/** Before the parcel leaves the seller, a booking can still be cancelled. */
export const canCancelAt = (s: unknown) => s === "booked" || s === "pickup_requested" || s === "booking";

export const hasLeftSeller = (s: unknown) =>
  ["picked_up", "in_transit", "out_for_delivery", "delivered", "returning", "returned", "lost"].includes(String(s));

/**
 * Whether an incoming event moves the shipment. Couriers repeat events and
 * deliver them out of order; a late "in transit" must never undo "delivered".
 */
export function shouldApply(current: Stage, next: Stage): boolean {
  if (current === next) return false;
  if (current === "delivered" || current === "returned" || current === "lost") return false;
  if (current === "self" || current === "cancelling" || current === "booking") return false;
  // Once returning, only the end of the return counts.
  if (current === "returning") return next === "returned" || next === "lost";
  if (next === "returning" || next === "lost") return true;
  return RANK[next] > RANK[current];
}

/** The order status an event leads to, or null to leave the order alone. */
export function orderStatusFor(stage: Stage, status: string): string | null {
  if (status === "cancelled" || status === "rejected" || status === "reassigning" || status === "delivered") return null;
  if (stage === "delivered") return "delivered";
  if (stage === "out_for_delivery") return status === "accepted" || status === "dispatched" ? "out_for_delivery" : null;
  if (stage === "picked_up" || stage === "in_transit") return status === "accepted" ? "dispatched" : null;
  return null;
}

export function delhiveryStage(status: unknown, statusType: unknown): Stage | null {
  const s = String(status ?? "").trim().toLowerCase();
  const t = String(statusType ?? "").trim().toUpperCase();
  if (t === "DL") return s === "rto" ? "returned" : "delivered";
  if (t === "RT") return "returning";
  if (t === "LT" || s === "lost") return "lost";
  if (s === "dispatched") return "out_for_delivery";
  if (s === "in transit" || s === "pending") return "in_transit";
  if (s === "picked up") return "picked_up";
  return null; // Manifested, Not Picked, Open: nothing has happened yet
}

export function shiprocketStage(status: unknown): Stage | null {
  const s = String(status ?? "").trim().toUpperCase().replace(/[_-]+/g, " ");
  if (!s) return null;
  if (s.includes("RTO")) return s.includes("DELIVERED") ? "returned" : "returning";
  if (s === "LOST") return "lost";
  if (s === "DELIVERED") return "delivered";
  if (s.includes("OUT FOR DELIVERY")) return "out_for_delivery";
  if (s === "PICKED UP") return "picked_up";
  if (s === "SHIPPED" || s.includes("IN TRANSIT") || s.includes("REACHED")) return "in_transit";
  return null;
}

export function trackingUrlFor(carrier: CarrierId, awb: string): string {
  const id = encodeURIComponent(awb);
  return carrier === "delhivery"
    ? `https://www.delhivery.com/track/package/${id}`
    : `https://shiprocket.co/tracking/${id}`;
}

/** Next working day after `from` (no Sunday pickups), as YYYY-MM-DD in IST. */
export function nextPickupDate(from: Date): string {
  const ist = new Date(from.getTime() + 5.5 * 3600 * 1000);
  ist.setUTCDate(ist.getUTCDate() + 1);
  if (ist.getUTCDay() === 0) ist.setUTCDate(ist.getUTCDate() + 1);
  return ist.toISOString().slice(0, 10);
}
