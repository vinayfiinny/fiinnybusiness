/**
 * "Delivery by" date and free-delivery rules.
 *   npx tsx scripts/tests/delivery-eta.test.ts
 */
import assert from "node:assert/strict";
import { deliveryByDate, expectedPickupDate, formatDeliveryDate } from "../../app/lib/delivery-eta";
import { freeDeliveryAbove, isFreeDelivery, lineDeliveryShare, manufacturerPhoneOf, offerPct } from "../../app/lib/free-delivery";

// Friday 13 Nov 2026, 10:00 IST
const fri = new Date("2026-11-13T04:30:00Z");
assert.equal(expectedPickupDate(fri), "2026-11-14");              // Fri 13 → pickup Sat 14
assert.equal(deliveryByDate(4, fri), "2026-11-19");                // Sat 14 + 4 working days, Sunday skipped → Thu 19
assert.equal(deliveryByDate(1, fri), "2026-11-16");                // Sat 14 + 1 → Mon 16 (skips Sun 15)
assert.equal(deliveryByDate(null, fri), null);
assert.equal(deliveryByDate(0, fri), null);
// Saturday evening: pickup is Monday
const sat = new Date("2026-11-14T15:00:00Z");                      // 20:30 IST Sat
assert.equal(expectedPickupDate(sat), "2026-11-16");
assert.equal(deliveryByDate(3, sat), "2026-11-19");
// Late night UTC is already the next day in India
const lateUtc = new Date("2026-11-13T20:00:00Z");                  // 01:30 IST Sat 14
assert.equal(expectedPickupDate(lateUtc), "2026-11-16");           // Sat 14 in India → pickup Mon 16
assert.equal(formatDeliveryDate("2026-11-19"), "Thu, 19 Nov");
// Extra handling day
assert.equal(deliveryByDate(4, fri, 2), "2026-11-20");

// Free delivery
assert.equal(isFreeDelivery({}), false);
assert.equal(isFreeDelivery({ productFree: true }), true);
assert.equal(isFreeDelivery({ seller: { storeFreeDelivery: true } }), true);
assert.equal(isFreeDelivery({ seller: { freeDelivery: true } as never }), false);      // legacy field old app builds delete: ignored
assert.equal(isFreeDelivery({ manufacturer: { networkFreeDelivery: true } }), true);
assert.equal(isFreeDelivery({ seller: { storeFreeDelivery: "true" } }), false);            // only an explicit true
assert.equal(isFreeDelivery({ manufacturer: { storeFreeDelivery: true } }), false);         // a maker's own store setting isn't a network setting
// Share offers: the most generous applies
assert.equal(lineDeliveryShare({}), 0);
assert.equal(lineDeliveryShare({ productPct: 50 }), 0.5);
assert.equal(lineDeliveryShare({ seller: { storeDeliveryPct: 30 } }), 0.3);
assert.equal(lineDeliveryShare({ productPct: 20, seller: { storeDeliveryPct: 60 } }), 0.6);
assert.equal(lineDeliveryShare({ productPct: 20, seller: { storeFreeDelivery: true } }), 1);
assert.equal(lineDeliveryShare({ productPct: 20, manufacturer: { networkFreeDelivery: true } }), 1);
assert.equal(lineDeliveryShare({ manufacturer: { storeDeliveryPct: 50 } }), 0);          // a maker's store % isn't a network offer
assert.equal(offerPct(100), 0); assert.equal(offerPct(0), 0); assert.equal(offerPct("40"), 40); assert.equal(offerPct(-5), 0); assert.equal(offerPct(33.4), 33);
assert.equal(freeDeliveryAbove({ freeDeliveryAbove: 5000 }), 5000);
assert.equal(freeDeliveryAbove({ freeDeliveryAbove: "abc" }), 0);
assert.equal(freeDeliveryAbove(null), 0);
assert.equal(manufacturerPhoneOf({ manufacturerPhone: "+919000000003" }, { ownerPhone: "x" }), "+919000000003");
assert.equal(manufacturerPhoneOf(null, { ownerType: "manufacturer", ownerPhone: "+919000000004" }), "+919000000004");
assert.equal(manufacturerPhoneOf(null, { ownerType: "retailer", ownerPhone: "+919000000005" }), "");
console.log("delivery eta + free delivery: all passed");
