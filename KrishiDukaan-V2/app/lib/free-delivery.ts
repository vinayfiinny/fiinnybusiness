/**
 * Delivery offers: how much of a line's delivery the SELLER pays. Pure, shared
 * by checkout (create-cart-order), the product-page estimate, the admin manual
 * order and the unit tests.
 *
 * A line's seller share (0 = customer pays all, 1 = free for the customer) is
 * the most generous of:
 *   - the product itself: Free Delivery (`freeDelivery: true`, existing flag)
 *     or a part of it (`sellerDeliveryPct`, 1–99) — set per product in the
 *     product edit form (web) / product screens (app);
 *   - the store, on everything it sells: deliverySettings/{seller}
 *     `storeFreeDelivery` (not `freeDelivery`, which old app builds delete on
 *     every save) or `storeDeliveryPct` (1–99);
 *   - the product's manufacturer, across its retailer network:
 *     deliverySettings/{manufacturer}.networkFreeDelivery.
 * On top of that the store can make a whole order free above a value:
 * deliverySettings/{seller}.freeDeliveryAbove (₹, the store's part of the
 * order), applied in lib/cart-pricing computeSellerPricing.
 *
 * Free for the customer is not free for us: on a courier order the seller's
 * part of the courier cost is taken from the SELLER's payout after booking
 * (never more than the courier actually charged), never absorbed by the
 * platform. See functions/src/shipping/pure.ts sellerCourierShare.
 */

export type FreeDeliverySettings = {
  storeFreeDelivery?: unknown;
  storeDeliveryPct?: unknown;
  networkFreeDelivery?: unknown;
  freeDeliveryAbove?: unknown;
} | null | undefined;

/** A partial-offer percentage: a whole number 1–99, else 0 (100 is "free", a separate flag). */
export function offerPct(v: unknown): number {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() ? Number(v) : NaN;
  if (!Number.isFinite(n)) return 0;
  const r = Math.round(n);
  return r >= 1 && r <= 99 ? r : 0;
}

/** The order value (₹) above which this store delivers free; 0 = no such offer. */
export function freeDeliveryAbove(settings: FreeDeliverySettings): number {
  const n = Number(settings?.freeDeliveryAbove);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** The seller's share of this line's delivery, 0..1. */
export function lineDeliveryShare(input: {
  productFree?: boolean;
  productPct?: unknown;
  seller?: FreeDeliverySettings;
  manufacturer?: FreeDeliverySettings;
}): number {
  if (input.productFree === true) return 1;
  if (input.seller?.storeFreeDelivery === true) return 1;
  if (input.manufacturer?.networkFreeDelivery === true) return 1;
  return Math.max(offerPct(input.productPct), offerPct(input.seller?.storeDeliveryPct)) / 100;
}

/** Whether the customer pays nothing for this line's delivery. */
export function isFreeDelivery(input: Parameters<typeof lineDeliveryShare>[0]): boolean {
  return lineDeliveryShare(input) >= 1;
}

/** The manufacturer a product line belongs to: the copy's maker, else the canonical's. */
export function manufacturerPhoneOf(
  copy: Record<string, unknown> | null | undefined,
  canonical: Record<string, unknown> | null | undefined,
): string {
  const pick = (d: Record<string, unknown> | null | undefined) => {
    if (!d) return "";
    const m = String(d.manufacturerPhone ?? "").trim();
    if (m) return m;
    return d.ownerType === "manufacturer" ? String(d.ownerPhone ?? "").trim() : "";
  };
  return pick(copy) || pick(canonical);
}
