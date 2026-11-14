/**
 * The decisions behind courier automation (functions/src/shipping/pure.ts).
 *
 *   npx tsx scripts/tests/shipping.test.ts
 */
import assert from "node:assert/strict";
import {
  DEFAULT_CONFIG as C, canCancelAt, courierBlocker, delhiveryStage, nextPickupDate, orderStatusFor, packKg,
  parcelKg, parseConfig, parseCustomerAddress, rankQuotes, readSellerPlace, shiprocketStage, shouldApply,
  withinReassignCap, shouldSimulate, orderDropPlace, sellerCourierShare, type Quote,
} from "../../functions/src/shipping/pure";

// A config that isn't there, or is mistyped, must never mean live or on.
assert.equal(parseConfig(undefined).enabled, false);
assert.equal(parseConfig({ enabled: "true" }).enabled, false);
assert.equal(parseConfig({ enabled: true, mode: "LIVE" }).mode, "simulate");
assert.equal(parseConfig({ mode: "live" }).mode, "live");

// Live mode can be limited to named sellers, so a normal test order never books for real
assert.equal(shouldSimulate(parseConfig({ mode: "simulate", liveSellers: ["9011842378"] }), "+919011842378"), true);
assert.equal(shouldSimulate(parseConfig({ mode: "live" }), "+919011842378"), false);                          // no list: everyone real
assert.equal(shouldSimulate(parseConfig({ mode: "live", liveSellers: ["+91 90118 42378"] }), "+919011842378"), false);
assert.equal(shouldSimulate(parseConfig({ mode: "live", liveSellers: ["9011842378"] }), "+918899556633"), true); // not listed: simulated
assert.equal(shouldSimulate(parseConfig({ mode: "live", liveSellers: ["9011842378"] }), undefined), true);
assert.equal(shouldSimulate(parseConfig({ mode: "LIVE", liveSellers: ["9011842378"] }), "+919011842378"), true);  // exact word only
assert.deepEqual(parseConfig({ liveSellers: ["123", "x", "9011842378"] }).liveSellers, ["9011842378"]);

// Weight
assert.equal(packKg("500 ml"), 0.5);
assert.equal(packKg("5 Ltr"), 5);
assert.equal(packKg("250gm"), 0.25);
assert.equal(packKg("1"), 0);
assert.deepEqual(parcelKg([{ variantUnit: "1L", qty: 2 }], C), { kg: 2.2, guessed: false });
assert.deepEqual(parcelKg([{ variantUnit: "100ml" }], C), { kg: 0.5, guessed: false }); // minimum
assert.deepEqual(parcelKg([{ unit: "1", quantity: 3 }], C), { kg: 3.3, guessed: true }); // unreadable size flagged

// Addresses: both shapes that really exist on orders
const web = parseCustomerAddress("Plot 4, Nandgaon, Ahmednagar, Maharashtra, 414402", "Maharashtra");
assert.equal(web.pincode, "414402");
assert.equal(web.city, "Nandgaon");
assert.equal(web.state, "Maharashtra");
assert.equal(parseCustomerAddress({ address: "Road 1", city: "Pune", state: "MH", pincode: "411001" }).pincode, "411001");
assert.equal(parseCustomerAddress({ address: "near 411001 stop", pincode: "" }).pincode, "411001");
assert.equal(parseCustomerAddress("no pin here").pincode, "");
assert.equal(readSellerPlace({ address: { line1: "A", pincode: "413213", city: "Mohol" } }).pincode, "413213");
assert.equal(readSellerPlace({ address: "Shop 1, Pune 411001" }).pincode, "411001");
assert.equal(readSellerPlace({ pincode: "000000" }).pincode, "");

// Choosing a courier
const q = (carrier: Quote["carrier"], cost: number, service = "S", etaDays?: number): Quote => ({ carrier, service, cost, etaDays });
assert.equal(rankQuotes([q("shiprocket", 179), q("delhivery", 124)])[0]!.carrier, "delhivery");
assert.equal(rankQuotes([q("delhivery", 100, "S", 5), q("shiprocket", 100, "X", 2)])[0]!.carrier, "shiprocket"); // tie: faster
assert.equal(rankQuotes([q("delhivery", 0), q("shiprocket", NaN)]).length, 0); // a ₹0 quote is a failure, not a bargain
const block = (o: Partial<Parameters<typeof courierBlocker>[0]>) => courierBlocker({ pickupPin: "414402", dropPin: "411001", declaredValue: 1000, categories: [], cfg: C, ...o });
assert.equal(block({}), null);
assert.equal(block({ pickupPin: "" }), "no_pickup_address");
assert.equal(block({ dropPin: "12" }), "no_delivery_pincode");
assert.equal(block({ declaredValue: 50000 }), "over_value_limit");
assert.equal(block({ categories: ["Pesticide"], cfg: { ...C, blockedCategories: ["pesticide"] } }), "blocked_category");

// Reassignment limit
assert.equal(withinReassignCap(400, 1000, 50), true);
assert.equal(withinReassignCap(501, 1000, 50), false);
assert.equal(withinReassignCap(null, 1000, 50), true); // no courier: seller delivers
assert.equal(withinReassignCap(9999, 1000, 0), true); // 0 = no limit

// Couriers repeat events and send them out of order
assert.equal(shouldApply("delivered", "in_transit"), false);
assert.equal(shouldApply("in_transit", "in_transit"), false);
assert.equal(shouldApply("in_transit", "picked_up"), false);
assert.equal(shouldApply("booked", "in_transit"), true); // missed events are fine
assert.equal(shouldApply("out_for_delivery", "returning"), true);
assert.equal(shouldApply("returning", "delivered"), false);
assert.equal(shouldApply("returning", "returned"), true);
assert.equal(shouldApply("self", "delivered"), false);
assert.equal(shouldApply("cancelling", "picked_up"), false);

// Status moves
assert.equal(orderStatusFor("picked_up", "accepted"), "dispatched");
assert.equal(orderStatusFor("in_transit", "dispatched"), null);
assert.equal(orderStatusFor("delivered", "accepted"), "delivered");
assert.equal(orderStatusFor("delivered", "cancelled"), null); // a refunded order is never reopened
assert.equal(orderStatusFor("delivered", "reassigning"), null);
assert.equal(orderStatusFor("returning", "dispatched"), null);
assert.equal(orderStatusFor("out_for_delivery", "delivered"), null);
assert.equal(canCancelAt("pickup_requested"), true);
assert.equal(canCancelAt("picked_up"), false);

// Courier status words
assert.equal(delhiveryStage("Manifested", "UD"), null);
assert.equal(delhiveryStage("In Transit", "UD"), "in_transit");
assert.equal(delhiveryStage("Dispatched", "UD"), "out_for_delivery");
assert.equal(delhiveryStage("Delivered", "DL"), "delivered");
assert.equal(delhiveryStage("RTO", "DL"), "returned");
assert.equal(delhiveryStage("In Transit", "RT"), "returning");
assert.equal(shiprocketStage("RTO DELIVERED"), "returned");
assert.equal(shiprocketStage("RTO_INITIATED"), "returning");
assert.equal(shiprocketStage("OUT FOR DELIVERY"), "out_for_delivery");
assert.equal(shiprocketStage("PICKUP SCHEDULED"), null);

// Pickups skip Sunday. 2026-11-07 is a Saturday.
assert.equal(nextPickupDate(new Date("2026-11-07T06:00:00Z")), "2026-11-09");
assert.equal(nextPickupDate(new Date("2026-11-05T06:00:00Z")), "2026-11-06");


// Structured delivery address (web/app checkout) wins over the old string
{
  const p = orderDropPlace({
    deliveryAddress: { house: "Flat 4, Sai Heights", area: "Kharadi", landmark: "EON IT Park", city: "Pune", state: "Maharashtra", pincode: "411014" },
    customerAddress: "old text, 999999",
    customerDeliveryState: "Maharashtra",
  });
  assert.equal(p.pincode, "411014");
  assert.equal(p.line, "Flat 4, Sai Heights, Kharadi, Near EON IT Park");
  assert.equal(p.city, "Pune");
  assert.equal(p.state, "Maharashtra");
  // No usable pincode in it: fall back to customerAddress
  assert.equal(orderDropPlace({ deliveryAddress: { pincode: "12" }, customerAddress: "Kharadi, Pune, Pune, Maharashtra, 411014" }).pincode, "411014");
  assert.equal(orderDropPlace({ customerAddress: { address: "Plot 9", pincode: "414402" } }).pincode, "414402");
}

// Free Delivery: seller pays the courier, never more than the courier charged
assert.equal(sellerCourierShare({}, 120), 0);
assert.equal(sellerCourierShare({ deliveryBreakdown: { sellerPaysCourier: 127 } }, 110.4), 111);
assert.equal(sellerCourierShare({ deliveryBreakdown: { sellerPaysCourier: 127 } }, 160), 127);   // excess: platform
assert.equal(sellerCourierShare({ deliveryBreakdown: { sellerPaysCourier: 127 } }, null), 127);
assert.equal(sellerCourierShare({ deliveryBreakdown: { sellerPaysCourier: 127 }, reassignment: { status: "accepted" } }, 100), 0);
assert.equal(sellerCourierShare({ deliveryBreakdown: { sellerPaysCourier: 127 }, adminReassignment: { at: "x" } }, 100), 0);
// Share offer: customer paid 135 of a 269 quote, seller agreed 134
assert.equal(sellerCourierShare({ deliveryCharge: 135, deliveryBreakdown: { sellerPaysCourier: 134 } }, 269), 134);
assert.equal(sellerCourierShare({ deliveryCharge: 135, deliveryBreakdown: { sellerPaysCourier: 134 } }, 200), 65);   // courier cheaper: seller pays only the gap
assert.equal(sellerCourierShare({ deliveryCharge: 135, deliveryBreakdown: { sellerPaysCourier: 134 } }, 120), 0);    // customer's part already covers it
assert.equal(sellerCourierShare({ deliveryCharge: 135, deliveryBreakdown: { sellerPaysCourier: 134 } }, 400), 134);  // dearer: platform pays the excess

console.log("shipping: all passed");
