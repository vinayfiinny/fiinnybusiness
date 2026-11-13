/**
 * Who has made delivery free. Pure, shared by checkout and the delivery estimate.
 *
 *   - the product itself is Free Delivery (existing per-product flag), or
 *   - the selling store offers free delivery on everything
 *     (deliverySettings/{seller}.storeFreeDelivery — not `freeDelivery`, which old
 *     app builds delete on every save), or
 *   - the product belongs to a manufacturer who offers free delivery across
 *     its retailer network (deliverySettings/{manufacturer}.networkFreeDelivery).
 *
 * Free for the customer is not free for us: the courier cost is taken from the
 * SELLER's payout after booking (they have priced it into the product), never
 * absorbed by the platform. See functions/src/shipping/engine.ts keepDeliveryFee.
 */

export type FreeDeliverySettings = { storeFreeDelivery?: unknown; networkFreeDelivery?: unknown } | null | undefined;

export function isFreeDelivery(input: {
  productFree?: boolean;
  seller?: FreeDeliverySettings;
  manufacturer?: FreeDeliverySettings;
}): boolean {
  if (input.productFree === true) return true;
  if (input.seller?.storeFreeDelivery === true) return true;
  if (input.manufacturer?.networkFreeDelivery === true) return true;
  return false;
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
