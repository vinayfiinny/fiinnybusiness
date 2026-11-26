/**
 * Who gets which rupee: functions/src/payouts/settlement.ts
 * (docs/delivery-money-architecture.md).
 *
 *   npx tsx scripts/tests/settlement.test.ts
 *
 * Every number below is worked by hand from the owner's rules: commission 2%
 * of goods, gateway 2% + 18% GST, customer delivery always stays with the
 * platform, Option B for campaigns.
 */
import assert from "node:assert/strict";
import {
  activeCampaign, actualSellerCourierPaise, bookingSplit, courierShareRefund, customerPaidPaise, gatewayFeePaise, gatewayRate,
  grossUpForGateway, planForReassignedSeller, planSettlement, readAdjustments, readPlan, selfDeliveryAdjustment,
  settlementView, splitCourierCost, withAdjustment, type SplitRates,
  withoutUnpaidAdjustment,
} from "../../functions/src/payouts/settlement";

const R: SplitRates = { commissionPercent: 2, gatewayFeePercent: 2, gatewayFeeGstPercent: 18, feeBearer: "seller" };
const SELLER = "+918658031942";
const AT = "2026-11-16T10:00:00.000Z";

// ── Gateway maths ────────────────────────────────────────────────────────
assert.equal(gatewayRate(R), 0.0236);
assert.equal(gatewayFeePaise(100000, R), 2360);            // ₹1000 → ₹20 + ₹3.60
assert.equal(gatewayFeePaise(8200, R), 194);               // ₹82 → 164 + ceil(29.52)
assert.equal(grossUpForGateway(80, R), 82);                // 80 / 0.9764 = 81.93 → 82
assert.equal(grossUpForGateway(97.64, R), 100);            // exact, no float creep to 101
assert.equal(grossUpForGateway(0, R), 0);
assert.equal(grossUpForGateway(-5, R), 0);
// The platform nets at least the courier cost after Razorpay's fee.
for (const cost of [1, 37, 80, 99, 143, 250, 999]) {
  const charged = grossUpForGateway(cost, R);
  assert.ok(charged * 100 - gatewayFeePaise(charged * 100, R) >= cost * 100, `gross-up covers ₹${cost}`);
}

// ── Scenario 1: customer pays delivery ──────────────────────────────────
{
  const c = splitCourierCost({ cost: 80, sellerShare: 0, campaign: null, rates: R });
  assert.deepEqual(c, { sellerCourier: 0, campaign: 0, customerBase: 80, customerDelivery: 82 });
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82,
    sellerCourier: 0, campaign: 0, courierQuote: 80, sellerShare: 0, rates: R });
  assert.equal(p.sellerKey, "8658031942");
  assert.equal(p.commissionPaise, 2000);                   // 2% of goods only
  assert.equal(p.gatewayFeePaise, 2360);                   // on goods only
  assert.equal(p.keptDeliveryPaise, 0);                    // delivery never routed to the seller
  assert.equal(p.transferPaise, 95640);                    // ₹956.40
  assert.equal(customerPaidPaise(p), 108200);              // ₹1000 + ₹82
  // Booked at the quoted ₹80: the platform covers the courier from what the customer paid.
  const b = bookingSplit(p, 80);
  assert.equal(b.customerNetPaise, 8006);
  assert.equal(b.sellerPaise, 0);
  assert.equal(b.campaignPaise, 0);
  assert.equal(b.platformPaise, -6);                       // 6 paise to spare, never short
}

// ── Scenario 2: seller offers free delivery ─────────────────────────────
{
  const c = splitCourierCost({ cost: 80, sellerShare: 1, campaign: null, rates: R });
  assert.deepEqual(c, { sellerCourier: 80, campaign: 0, customerBase: 0, customerDelivery: 0 });
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  assert.equal(p.transferPaise, 87640);                    // 1000 − 20 − 23.60 − 80
  // Booked cheaper (₹70): the seller owes only ₹70, ₹10 comes back to them.
  assert.equal(actualSellerCourierPaise(p, 70), 7000);
  const refund = courierShareRefund(p, 70, SELLER, AT);
  assert.equal(refund?.netPaise, 1000);
  assert.equal(refund?.id, "courier_share_refund:8658031942");
  // Booked dearer (₹95): never more than they agreed; the platform pays the gap.
  assert.equal(courierShareRefund(p, 95, SELLER, AT), null);
  assert.equal(bookingSplit(p, 95).platformPaise, 1500);
  // A partial (50%) offer.
  const half = splitCourierCost({ cost: 80, sellerShare: 0.5, campaign: null, rates: R });
  assert.deepEqual(half, { sellerCourier: 40, campaign: 0, customerBase: 40, customerDelivery: 41 });
}

// ── Scenario 3: platform campaign ───────────────────────────────────────
{
  const c = splitCourierCost({ cost: 80, sellerShare: 0, campaign: { maxPerOrder: 0 }, rates: R });
  assert.deepEqual(c, { sellerCourier: 0, campaign: 80, customerBase: 0, customerDelivery: 0 });
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    campaign: 80, courierQuote: 80, sellerShare: 0, rates: R });
  assert.equal(p.transferPaise, 95640);                    // seller gets everything less commission + gateway
  assert.equal(p.campaignApplied, true);
  const b = bookingSplit(p, 80);
  assert.equal(b.campaignPaise, 8000);
  assert.equal(b.platformPaise, 0);
}

// ── Option B: campaign + seller's own offer ─────────────────────────────
{
  // Seller offers 50%: they pay half, the platform the other half, customer ₹0.
  const half = splitCourierCost({ cost: 80, sellerShare: 0.5, campaign: { maxPerOrder: 0 }, rates: R });
  assert.deepEqual(half, { sellerCourier: 40, campaign: 40, customerBase: 0, customerDelivery: 0 });
  // Seller offers 100%: they pay it all, the platform nothing.
  const full = splitCourierCost({ cost: 80, sellerShare: 1, campaign: { maxPerOrder: 0 }, rates: R });
  assert.deepEqual(full, { sellerCourier: 80, campaign: 0, customerBase: 0, customerDelivery: 0 });
  // Per-order cap ₹50: the customer pays the excess, grossed up.
  const capped = splitCourierCost({ cost: 80, sellerShare: 0, campaign: { maxPerOrder: 50 }, rates: R });
  assert.deepEqual(capped, { sellerCourier: 0, campaign: 50, customerBase: 30, customerDelivery: 31 });
}

// ── Seller delivers (no courier serves): delivery still stays with platform ─
{
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "seller", customerDelivery: 50,
    sellerCourier: 99, campaign: 99, rates: R });      // offer/campaign ignored when the seller delivers
  assert.equal(p.v, 2);
  assert.equal(p.keptDeliveryPaise, 0);
  assert.equal(p.sellerCourierPaise, 0);
  assert.equal(p.campaignPaise, 0);
  assert.equal(p.commissionPaise, 2000);                   // still 2% of goods only
  assert.equal(p.gatewayFeePaise, 2360);                   // on goods only
  assert.equal(p.transferPaise, 95640);                    // no delivery in Route
  assert.equal(selfDeliveryAdjustment(p, SELLER, AT), null);
}

// ── No courier booked → delivery stays with platform, unused offer returns ─
{
  const s1 = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82,
    courierQuote: 80, rates: R });
  assert.equal(selfDeliveryAdjustment(s1, SELLER, AT), null);
  // An already-paid v1 order retains its original delivery payout promise.
  assert.equal(selfDeliveryAdjustment({ ...s1, v: 1 }, SELLER, AT)?.netPaise, 8006);
  const s2 = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  assert.equal(selfDeliveryAdjustment(s2, SELLER, AT)?.netPaise, 8000);  // their ₹80 share back
  const camp = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    campaign: 80, courierQuote: 80, rates: R });
  assert.equal(selfDeliveryAdjustment(camp, SELLER, AT), null);         // campaign: nothing was paid for delivery
  // Another seller (reassigned) delivering never gets the first seller's share back.
  assert.equal(selfDeliveryAdjustment(s2, "9999999999", AT), null);
}

// ── Reassignment: the new seller pays no courier share ──────────────────
{
  const s2 = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  const n = planForReassignedSeller(s2, "+919011842378", R);
  assert.equal(n.sellerKey, "9011842378");
  assert.equal(n.sellerCourierPaise, 0);
  assert.equal(n.transferPaise, 95640);
  assert.equal(n.deliveryTo, "platform");
}

// ── Readers ─────────────────────────────────────────────────────────────
{
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 0,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  const adj = [courierShareRefund(p, 70, SELLER, AT)!];
  const v = settlementView(p, adj);
  assert.deepEqual(v, {
    grossPaise: 100000, commissionPaise: 2000, gatewayFeePaise: 2360, deliveryPaise: 8000,
    transferPaise: 87640, adjustmentsPaise: 1000, adjustmentsDuePaise: 1000, netPaise: 88640,
  });
  // Paid adjustments still count towards net, not towards due.
  const paid = [{ ...adj[0], paidTransferId: "trf_1", paidAt: AT, paidVia: "topup" as const }];
  assert.equal(settlementView(p, paid).adjustmentsDuePaise, 0);
  assert.equal(settlementView(p, paid).netPaise, 88640);
  // Another seller's adjustment is never counted for the current seller.
  assert.equal(settlementView(p, adj, { sellerKey: "9011842378" }).adjustmentsPaise, 0);
  // Partial refund of ₹100 comes off the goods; commission and fee follow.
  const s1 = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82, rates: R });
  const r = settlementView(s1, [], { refundedPaise: 10000 });
  assert.equal(r.commissionPaise, 1800);
  assert.equal(r.gatewayFeePaise, 2124);
  assert.equal(r.transferPaise, 86076);
  // Everything refunded: nothing owed, no courier share taken.
  assert.equal(settlementView(p, [], { refundedPaise: 100000 }).netPaise, 0);
  assert.equal(settlementView(p, [], { refundedPaise: 100000 }).deliveryPaise, 0);
}

// ── Fees larger than a tiny order: never a negative transfer ────────────
{
  const p = planSettlement({ sellerKey: SELLER, goods: 10, deliveryTo: "platform", customerDelivery: 0,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  assert.equal(p.transferPaise, 0);
}

// ── Stored documents are untrusted ──────────────────────────────────────
{
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82, rates: R });
  assert.deepEqual(readPlan(JSON.parse(JSON.stringify(p))), p);
  assert.equal(readPlan(null), null);
  assert.equal(readPlan({ ...p, v: 3 }), null);
  assert.equal(readPlan({ ...p, v: 1 })?.v, 1);            // historical orders remain readable
  assert.equal(readPlan({ ...p, goodsPaise: 10.5 }), null);
  assert.equal(readPlan({ ...p, deliveryTo: "customer" }), null);
  assert.deepEqual(readAdjustments([{ id: "x", kind: "self_delivery", netPaise: -5, sellerKey: SELLER }, null, "y"]), []);
  const a = selfDeliveryAdjustment({ ...p, v: 1 }, SELLER, AT)!;
  assert.equal(readAdjustments([a]).length, 1);
  // Adding the same adjustment twice (a trigger fired twice) changes nothing.
  const once = withAdjustment([], a);
  const twice = withAdjustment(once.list, a);
  assert.equal(once.added, true);
  assert.equal(twice.added, false);
  assert.equal(twice.list.length, 1);
}

console.log("settlement: all checks passed");

// ── Campaign switch ─────────────────────────────────────────────────────
{
  const now = Date.parse("2026-11-20T12:00:00Z");
  const base = { active: true, name: "Diwali", startsAt: "2026-11-15T00:00:00Z", endsAt: "2026-11-25T00:00:00Z" };
  assert.deepEqual(activeCampaign(base, now), { name: "Diwali", maxPerOrder: 0 });
  assert.equal(activeCampaign({ ...base, active: "true" }, now), null);             // exact boolean only
  assert.equal(activeCampaign({ ...base, active: false }, now), null);
  assert.equal(activeCampaign({ ...base, startsAt: undefined }, now), null);        // no dates → not running
  assert.equal(activeCampaign({ ...base, endsAt: "2026-11-20T12:00:00Z" }, now), null); // ended exactly now
  assert.equal(activeCampaign({ ...base, startsAt: "2026-11-21T00:00:00Z" }, now), null); // not started
  assert.equal(activeCampaign({ ...base, budget: 1000, spentPaise: 100000 }, now), null); // budget used up
  assert.deepEqual(activeCampaign({ ...base, budget: 1000, spentPaise: 99999, maxPerOrder: 60 }, now), { name: "Diwali", maxPerOrder: 60 });
  assert.deepEqual(activeCampaign({ ...base, name: "  " , startsAt: { seconds: 1763164800 } }, now), { name: "Free delivery", maxPerOrder: 0 });
  console.log("settlement campaign: all checks passed");
}

// ── Checkout pricing with the new courier options (lib/cart-pricing) ─────
{
  const { computeSellerPricing } = require("../../app/lib/cart-pricing") as typeof import("../../app/lib/cart-pricing");
  const courier = { charge: 80, carrier: "shiprocket" as const, service: "x", weightKg: 1 };
  const line = (extra: Record<string, unknown> = {}) => ({ sellerKey: SELLER, unitPrice: 1000, qty: 1, weightKg: 1, ...extra });
  // Scenario 1: ₹80 courier → customer pays ₹82 (gateway fee on delivery added).
  const s1 = computeSellerPricing(SELLER, [line()], null, "Maharashtra", courier, { rates: R });
  assert.equal(s1.deliveryCharge, 82);
  assert.equal(s1.delivery.gatewayGrossUp, 2);
  assert.equal(s1.total, 1082);
  // Scenario 2: seller's free delivery → customer ₹0, seller ₹80.
  const s2 = computeSellerPricing(SELLER, [line({ freeDelivery: true })], null, "Maharashtra", courier, { rates: R });
  assert.equal(s2.deliveryCharge, 0);
  assert.equal(s2.delivery.free, true);
  assert.equal(s2.delivery.sellerPaysCourier, 80);
  // Scenario 3: campaign → customer ₹0, platform ₹80.
  const camp = { name: "Diwali", maxPerOrder: 0 };
  const s3 = computeSellerPricing(SELLER, [line()], null, "Maharashtra", courier, { rates: R, campaign: camp });
  assert.equal(s3.deliveryCharge, 0);
  assert.deepEqual(s3.delivery.campaign, { name: "Diwali", platformPays: 80 });
  assert.equal(s3.delivery.sellerPaysCourier, undefined);
  // Option B: 50% offer during a campaign → seller ₹40, platform ₹40, customer ₹0.
  const b = computeSellerPricing(SELLER, [line({ deliveryShare: 0.5 })], null, "Maharashtra", courier, { rates: R, campaign: camp });
  assert.equal(b.deliveryCharge, 0);
  assert.equal(b.delivery.sellerPaysCourier, 40);
  assert.deepEqual(b.delivery.campaign, { name: "Diwali", platformPays: 40 });
  // Store's "free above ₹500" during a campaign: the store's offer is 100%, so the store pays.
  const above = computeSellerPricing(SELLER, [line()], { freeDeliveryAbove: 500 } as never, "Maharashtra", courier, { rates: R, campaign: camp });
  assert.equal(above.delivery.sellerPaysCourier, 80);
  assert.equal(above.delivery.campaign, undefined);
  // No courier (seller's slab): campaign does not apply, the seller's slab is charged as before.
  const slab = computeSellerPricing(SELLER, [line()], { deliverySlabs: [{ maxWeightKg: 5, charge: 50 }] } as never, "Maharashtra", null, { rates: R, campaign: camp });
  assert.equal(slab.delivery.mode, undefined);
  assert.equal(slab.delivery.campaign, undefined);
  console.log("settlement checkout pricing: all checks passed");
}

// ── Seller keys: phones in any form match, user ids are never read as phones ─
{
  const { key10 } = require("../../functions/src/payouts/settlement") as typeof import("../../functions/src/payouts/settlement");
  assert.equal(key10("+91 86580 31942"), "8658031942");
  assert.equal(key10("8658031942"), "8658031942");
  assert.equal(key10("dRv07eFd0wao2LhfnG9TPsVpkXC3"), "dRv07eFd0wao2LhfnG9TPsVpkXC3");
  assert.equal(key10(""), "");
  assert.equal(key10(undefined), "");
  console.log("settlement keys: all checks passed");
}

// ── Balance payouts (payout run, after-KYC): plan + adjustments in one go ─
{
  const { balancePayoutSplit, markAdjustmentsPaid } = require("../../functions/src/payouts/settlement") as typeof import("../../functions/src/payouts/settlement");
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  const adj = [selfDeliveryAdjustment(p, SELLER, AT)!];
  const split = balancePayoutSplit(p, adj, { sellerKey: SELLER });
  assert.equal(split.transferPaise, 87640 + 8000);
  assert.equal(split.adjustmentsPaise, 8000);
  const paid = markAdjustmentsPaid(adj, SELLER, "trf_9", AT, "payout_run");
  assert.equal(paid[0].paidTransferId, "trf_9");
  assert.equal(balancePayoutSplit(p, paid, { sellerKey: SELLER }).transferPaise, 87640);  // never paid twice
  console.log("settlement balance payouts: all checks passed");
}

// ── Top-ups for Route sellers (functions/src/payouts/settlement-topups.ts) ─
{
  const { decideTopUp } = require("../../functions/src/payouts/settlement-topups") as typeof import("../../functions/src/payouts/settlement-topups");
  const p = planSettlement({ sellerKey: SELLER, goods: 1000, deliveryTo: "platform", customerDelivery: 82,
    sellerCourier: 80, courierQuote: 80, sellerShare: 1, rates: R });
  const adj = selfDeliveryAdjustment(p, SELLER, AT)!;
  const day = 24 * 3600 * 1000;
  const deliveredAt = Date.parse("2026-11-01T10:00:00Z");
  const order = {
    status: "delivered", sellerPhone: SELLER,
    statusHistory: [{ status: "delivered", at: new Date(deliveredAt).toISOString() }],
    settlement: { ...p, routed: true, routedAccountId: "acc_ABCDEFGHIJKLMN" },
    settlementAdjustments: [adj],
  };
  assert.deepEqual(decideTopUp(order, deliveredAt + 8 * day),
    { action: "pay", amountPaise: 8000, accountId: "acc_ABCDEFGHIJKLMN", sellerKey: "8658031942" });
  assert.equal(decideTopUp(order, deliveredAt + 6 * day).action, "wait");                      // refund window
  assert.equal(decideTopUp({ ...order, status: "out_for_delivery" }, deliveredAt + 8 * day).action, "wait");
  assert.equal(decideTopUp({ ...order, settlement: { ...order.settlement, routed: false } }, deliveredAt + 8 * day).action, "skip");
  assert.equal(decideTopUp({ ...order, settlement: { ...order.settlement, routedAccountId: "" } }, deliveredAt + 8 * day).action, "skip");
  assert.equal(decideTopUp({ ...order, settlementTopUpClaim: { run: "x" } }, deliveredAt + 8 * day).action, "skip");
  assert.equal(decideTopUp({ ...order, status: "rejected" }, deliveredAt + 8 * day).action, "done");
  assert.equal(decideTopUp({ ...order, settlementAdjustments: [{ ...adj, paidTransferId: "trf_1" }] }, deliveredAt + 8 * day).action, "done");
  // An adjustment for a previous seller is never paid to the current one.
  assert.equal(decideTopUp({ ...order, sellerPhone: "+919011842378" }, deliveredAt + 8 * day).action, "done");
  // Retry waits 6 hours after a failure.
  assert.equal(decideTopUp({ ...order, settlementTopUpErrorAt: deliveredAt + 8 * day - 3600_000 }, deliveredAt + 8 * day).action, "wait");
  console.log("settlement top-ups: all checks passed");
}

// ── Admin: campaign form, ledger report, wallets ────────────────────────
{
  const m = require("../../functions/src/payouts/settlement") as typeof import("../../functions/src/payouts/settlement");
  const now = Date.parse("2026-11-16T10:00:00Z");
  const ok = m.validateCampaignInput({ active: true, name: " Diwali ", startsAt: "2026-11-17T00:00:00+05:30", endsAt: "2026-11-25T00:00:00+05:30", maxPerOrder: "60", budget: 5000 }, now);
  assert.equal(ok.ok, true);
  if (ok.ok) assert.deepEqual(ok.value, { active: true, name: "Diwali", startsAt: "2026-11-16T18:30:00.000Z", endsAt: "2026-11-24T18:30:00.000Z", maxPerOrder: 60, budget: 5000 });
  assert.equal(m.validateCampaignInput({ name: "", startsAt: "2026-11-17", endsAt: "2026-11-18" }, now).ok, false);
  assert.equal(m.validateCampaignInput({ name: "x", startsAt: "2026-11-18", endsAt: "2026-11-17" }, now).ok, false);
  assert.equal(m.validateCampaignInput({ name: "x", startsAt: "2026-11-01", endsAt: "2026-11-02" }, now).ok, false);   // already ended
  assert.equal(m.validateCampaignInput({ name: "x", startsAt: "2026-11-17", endsAt: "2026-11-18", budget: -1 }, now).ok, false);

  assert.equal(m.weekOfIst(Date.parse("2026-11-16T00:10:00+05:30")), "2026-11-16");     // Monday morning IST
  assert.equal(m.weekOfIst(Date.parse("2026-11-15T23:50:00+05:30")), "2026-11-09");     // Sunday night IST
  const entries = [
    { kind: "booked" as const, at: "2026-11-16T05:00:00Z", carrier: "shiprocket", costPaise: 8000, customerNetPaise: 8006, sellerPaise: 0, campaignPaise: 0, platformPaise: -6 },
    { kind: "booked" as const, at: "2026-11-17T05:00:00Z", carrier: "delhivery", costPaise: 9000, customerNetPaise: 0, sellerPaise: 0, campaignPaise: 9000, platformPaise: 0 },
    { kind: "cancelled" as const, at: "2026-11-17T06:00:00Z", carrier: "delhivery", costPaise: -9000, customerNetPaise: 0, sellerPaise: 0, campaignPaise: -9000, platformPaise: 0 },
    { kind: "self_delivery" as const, at: "2026-11-18T05:00:00Z", toSellerPaise: 8006 },
    { kind: "booked" as const, at: "2026-11-18T05:00:00Z", carrier: "shiprocket", simulated: true, costPaise: 7000 },
  ];
  assert.deepEqual(m.summariseLedger(entries), [{
    weekOf: "2026-11-16", parcels: 1, courierCostPaise: 8000, customerPaise: 8006, sellerPaise: 0,
    campaignPaise: 0, platformPaise: -6, toSellerPaise: 8006,
  }]);
  // Delhivery: ₹10,000 recorded on the 16th 00:00 IST, one booking + its cancellation since → still ₹10,000.
  assert.equal(m.estimateWalletPaise(1_000_000, Date.parse("2026-11-16T00:00:00+05:30"), entries, "delhivery"), 1_000_000);
  assert.equal(m.estimateWalletPaise(1_000_000, Date.parse("2026-11-16T00:00:00+05:30"), entries.slice(0, 2), "delhivery"), 991_000);
  // Alerts: below ₹5,000, not again within 12 hours.
  assert.equal(m.walletAlertDue(227_743, 5000, 0, now), true);
  assert.equal(m.walletAlertDue(227_743, 5000, now - 3600_000, now), false);
  assert.equal(m.walletAlertDue(227_743, 5000, now - 13 * 3600_000, now), true);
  assert.equal(m.walletAlertDue(600_000, 5000, 0, now), false);
  assert.equal(m.walletAlertDue(null, 5000, 0, now), false);       // unknown balance: no false alarm
  console.log("settlement admin helpers: all checks passed");
}

// Admin retry: the seller's self-delivery adjustment goes only while unpaid.
{
  const adj = (over: Record<string, unknown>) => ({ id: "x", sellerKey: "8658031942", kind: "self_delivery", netPaise: 18649, at: "t", ...over }) as never;
  const unpaid = withoutUnpaidAdjustment([adj({}), adj({ id: "y", kind: "booked_refund" })], "self_delivery" as never, "+918658031942");
  assert.equal(unpaid.removed.length, 1);
  assert.equal(unpaid.list.length, 1);
  assert.equal(unpaid.paid.length, 0);
  const paid = withoutUnpaidAdjustment([adj({ paidTransferId: "trf_1" })], "self_delivery" as never, "8658031942");
  assert.equal(paid.removed.length, 0);
  assert.equal(paid.paid.length, 1);
  assert.equal(paid.list.length, 1);
  console.log("settlement retry adjustment: passed");
}
