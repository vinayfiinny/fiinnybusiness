/**
 * "Delivery by <date>" — the date a customer sees on the product page, cart and
 * checkout. Pure (no Firebase), shared by every route, unit-tested.
 *
 *   order now → seller accepts and the courier picks up on the next working
 *   day (handlingDays, default 1) → the courier's transit days → delivered.
 *
 * Working days skip Sunday (couriers don't pick up or deliver then). Dates are
 * Indian time. It is an estimate: the seller still has to accept the order.
 */

const IST_OFFSET_MS = 5.5 * 3600 * 1000;

/** Today's date in India as a UTC-midnight Date (so day maths ignores timezones). */
function istDay(now: Date): Date {
  const ist = new Date(now.getTime() + IST_OFFSET_MS);
  return new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate()));
}

function addWorkingDays(day: Date, n: number): Date {
  const d = new Date(day.getTime());
  let left = Math.max(0, Math.floor(n));
  while (left > 0) {
    d.setUTCDate(d.getUTCDate() + 1);
    if (d.getUTCDay() !== 0) left--;
  }
  return d;
}

/** YYYY-MM-DD of the estimated delivery, or null without a transit time. */
export function deliveryByDate(etaDays: number | null | undefined, now: Date = new Date(), handlingDays = 1): string | null {
  if (etaDays == null || !Number.isFinite(etaDays) || etaDays <= 0) return null;
  const pickup = addWorkingDays(istDay(now), Math.max(1, handlingDays));
  return addWorkingDays(pickup, Math.ceil(etaDays)).toISOString().slice(0, 10);
}

/** The courier pickup date used for the estimate (Delhivery's TAT API asks for it). */
export function expectedPickupDate(now: Date = new Date(), handlingDays = 1): string {
  return addWorkingDays(istDay(now), Math.max(1, handlingDays)).toISOString().slice(0, 10);
}

/** "Wed, 19 Nov" for display. */
export function formatDeliveryDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  return d.toLocaleDateString("en-IN", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}
