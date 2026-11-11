/**
 * End-to-end test of courier automation against the DEPLOYED UAT functions.
 * Creates test orders, walks them through each situation, checks the result,
 * deletes them. Bookings are simulated; prices are real. UAT only.
 *
 *   npx tsx scripts/test-shipping-uat.ts
 */
import * as admin from "firebase-admin";
import { randomBytes } from "crypto";

const PROJECT = "karan-arjun-uat";
admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();

const CUSTOMER = {
  customerId: "shiptest-customer", customerName: "Test Customer", customerPhone: "+919000000001",
  customerAddress: { address: "12 Test Road", city: "Pune", state: "Maharashtra", pincode: "411001" },
  customerDeliveryState: "Maharashtra",
};
const made: string[] = [];
const offers: FirebaseFirestore.DocumentReference[] = [];
let pass = 0;
let fail = 0;
const check = (name: string, ok: boolean, got?: unknown) => {
  if (ok) pass++; else fail++;
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : `   got: ${JSON.stringify(got)}`}`);
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until(id: string, test: (o: FirebaseFirestore.DocumentData) => boolean, ms = 45000) {
  const end = Date.now() + ms;
  let o: FirebaseFirestore.DocumentData = {};
  while (Date.now() < end) {
    o = (await db.collection("orders").doc(id).get()).data() ?? {};
    if (test(o)) return o;
    await sleep(1200);
  }
  return o;
}

async function newOrder(over: Record<string, unknown>) {
  const id = `shiptest-${randomBytes(5).toString("hex")}`;
  made.push(id);
  await db.collection("orders").doc(id).set({
    ...CUSTOMER, status: "placed", sellerType: "manufacturer", sellerName: "Test Seller",
    items: [{ productId: "shiptest-product", name: "Test Fertilizer", qty: 2, variantUnit: "1kg", price: 400 }],
    subtotal: 800, deliveryCharge: 40, totalGst: 0, grandTotal: 840,
    payment: { status: "paid", amount: 840 },
    statusHistory: [{ status: "placed", at: new Date().toISOString() }],
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...over,
  });
  return id;
}

const accept = (id: string) => db.collection("orders").doc(id).update({ status: "accepted" });
const ask = (id: string, action: string, event?: string) => db.collection("orders").doc(id).update({
  shipmentRequest: { id: randomBytes(4).toString("hex"), action, ...(event ? { event } : {}) },
});
const booked = (o: FirebaseFirestore.DocumentData) => !!o.shipment?.stage && o.shipment.stage !== "booking";

(async () => {
  const cfg = (await db.collection("_serverConfig").doc("shipping").get()).data();
  if (cfg?.enabled !== true || cfg?.mode === "live") throw new Error("Needs enabled + simulate mode");
  const near = process.env.SELLER_NEAR!;
  const far = process.env.SELLER_FAR!;
  const nopin = process.env.SELLER_NOPIN!;

  console.log("\n1. Accept → cheapest courier booked, tracking linked");
  const a = await newOrder({ sellerPhone: near, sellerId: near });
  await accept(a);
  let o = await until(a, booked);
  const s = o.shipment ?? {};
  console.log(`     ${s.carrier}/${s.service} ₹${s.cost} (customer paid ₹${s.customerPaid}, gap ₹${s.platformGap}), ${s.quotes?.length} quotes, ${s.weightKg} kg`);
  check("booked as courier", s.mode === "courier" && s.stage === "booked", s);
  check("is simulated", s.simulated === true && String(s.awb).startsWith("SIM"), s.awb);
  check("cheapest quote chosen", s.cost === Math.min(...(s.quotes ?? []).map((q: { cost: number }) => q.cost)), s.quotes);
  check("tracking link + id on the order", o.tracking?.url === s.trackingUrl && o.tracking?.id === s.awb, o.tracking);
  check("customer charge unchanged", o.deliveryCharge === 40 && o.grandTotal === 840);
  check("platform keeps the delivery fee", s.platformKeptDelivery === true, s);

  console.log("\n2. Pickup, then courier events, including repeated and late ones");
  await ask(a, "pickup");
  o = await until(a, (x) => x.shipment?.stage === "pickup_requested");
  check("pickup requested", o.shipment?.stage === "pickup_requested" && !!o.shipment?.pickupDate, o.shipment?.stage);
  await ask(a, "simulate", "picked_up");
  o = await until(a, (x) => x.status === "dispatched");
  check("picked up → order dispatched", o.status === "dispatched", o.status);
  await ask(a, "simulate", "out_for_delivery");
  o = await until(a, (x) => x.status === "out_for_delivery");
  check("→ out for delivery", o.status === "out_for_delivery", o.status);
  await ask(a, "simulate", "in_transit"); // a late event
  await sleep(5000);
  o = (await db.collection("orders").doc(a).get()).data()!;
  check("late event does not move it back", o.shipment?.stage === "out_for_delivery" && o.status === "out_for_delivery", o.shipment?.stage);
  await ask(a, "simulate", "delivered");
  o = await until(a, (x) => x.status === "delivered");
  check("delivered by the courier", o.status === "delivered" && o.shipment?.active === false, o.status);

  console.log("\n3. Seller rejects after booking → cancelled, far seller takes it, customer charge frozen");
  const b = await newOrder({ sellerPhone: near, sellerId: near });
  await accept(b);
  o = await until(b, booked);
  const firstAwb = o.shipment?.awb;
  const firstCost = o.shipment?.cost;
  const offerRef = db.collection("sellerOffers").doc(far.slice(-10)).collection("offers").doc(b);
  offers.push(offerRef);
  await offerRef.set({ orderId: b, status: "open", sellerPhone: far });
  await db.collection("orders").doc(b).update({
    status: "reassigning",
    reassignment: {
      status: "open", round: 1, candidatePhones: [far],
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 864e5),
    },
  });
  o = await until(b, (x) => !x.shipment && (x.shipmentHistory ?? []).length === 1);
  check("first booking cancelled and kept in history", o.shipmentHistory?.[0]?.awb === firstAwb && !o.shipment, o.shipmentHistory);
  check("old tracking removed", !o.tracking, o.tracking);
  await sleep(8000);
  const offer = (await offerRef.get()).data();
  console.log(`     offer: ${offer?.status}, estimated ₹${offer?.estimatedShipping} by ${offer?.shippingBy}`);
  check("offer priced for the far seller", offer?.estimatedShipping > 0, offer);
  await db.collection("orders").doc(b).update({
    status: "accepted", sellerPhone: far, sellerId: far, "reassignment.status": "accepted",
  });
  o = await until(b, booked);
  console.log(`     first ₹${firstCost} → new ₹${o.shipment?.cost}, customer still paid ₹${o.deliveryCharge}`);
  check("new booking from the new seller", o.shipment?.stage === "booked" && o.shipment?.awb !== firstAwb && o.shipment?.sellerKey === far.slice(-10), o.shipment);
  check("customer charge frozen", o.deliveryCharge === 40 && o.grandTotal === 840);

  console.log("\n4. Owner's rule: a far, costly seller is still offered; the platform pays the gap");
  const c = await newOrder({ sellerPhone: near, sellerId: near, grandTotal: 20, subtotal: 20, deliveryCharge: 0 });
  const offer2 = db.collection("sellerOffers").doc(far.slice(-10)).collection("offers").doc(c);
  offers.push(offer2);
  await offer2.set({ orderId: c, status: "open", sellerPhone: far });
  await db.collection("orders").doc(c).update({
    status: "reassigning",
    reassignment: {
      status: "open", round: 1, candidatePhones: [far],
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 864e5),
    },
  });
  let priced: FirebaseFirestore.DocumentData | undefined;
  for (let i = 0; i < 25 && !(priced?.estimatedShipping > 0); i++) { await sleep(1200); priced = (await offer2.get()).data(); }
  o = (await db.collection("orders").doc(c).get()).data()!;
  check("offer stays open even though shipping costs more than the order", priced?.status === "open" && priced?.estimatedShipping > 20, priced);
  check("window not closed (order goes ahead)", o.reassignment?.noViableSeller !== true, o.reassignment);

  console.log("\n5. Fallback to the seller");
  const d = await newOrder({ sellerPhone: near, sellerId: near, customerAddress: { address: "Nowhere", city: "X", state: "Maharashtra", pincode: "999999" } });
  await accept(d);
  o = await until(d, booked);
  check("no courier serves it → seller delivers", o.shipment?.mode === "self" && o.shipment?.reason === "not_serviceable", o.shipment);
  check("seller-delivered charge untouched", o.deliveryCharge === 40 && !o.shipment?.platformKeptDelivery);
  const e = await newOrder({ sellerPhone: nopin, sellerId: nopin });
  await accept(e);
  o = await until(e, booked);
  check("seller has no pincode → seller delivers, flagged", o.shipment?.reason === "no_pickup_address" && o.shipment?.needsAttention === true, o.shipment);
  const f = await newOrder({ sellerPhone: near, sellerId: near, grandTotal: 60000, subtotal: 60000 });
  await accept(f);
  o = await until(f, booked);
  check("₹60,000 order → manual, flagged", o.shipment?.reason === "over_value_limit" && o.shipment?.needsAttention === true, o.shipment);

  console.log("\n6. Unpaid order is never booked; a parcel can't be cancelled after pickup");
  const g = await newOrder({ sellerPhone: near, sellerId: near, payment: { status: "pending" } });
  await accept(g);
  await sleep(9000);
  o = (await db.collection("orders").doc(g).get()).data()!;
  check("unpaid → no booking", !o.shipment, o.shipment);
  const h = await newOrder({ sellerPhone: near, sellerId: near });
  await accept(h);
  await until(h, booked);
  await ask(h, "simulate", "picked_up");
  await until(h, (x) => x.status === "dispatched");
  await db.collection("orders").doc(h).update({ status: "cancelled" });
  o = await until(h, (x) => x.shipment?.needsAttention === true, 20000);
  check("cancelled after pickup → flagged, not faked", o.shipment?.needsAttention === true && o.shipment?.stage === "picked_up", o.shipment);
})()
  .catch((e) => { fail++; console.error("STOPPED:", e); })
  .finally(async () => {
    for (const id of made) await db.collection("orders").doc(id).delete().catch(() => undefined);
    for (const r of offers) await r.delete().catch(() => undefined);
    console.log(`\n${pass} passed, ${fail} failed. ${made.length} test orders removed.`);
    process.exit(fail ? 1 : 0);
  });
