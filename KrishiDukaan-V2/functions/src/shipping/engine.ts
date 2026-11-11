import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions/v2";
import { notify } from "../notify";
import { queueWaNotification } from "../wa-notify";
import {
  bookShipment, cancelShipment, getQuotes, requestPickup, trackingUrlFor,
  type ActiveShipment, type Pickup,
} from "./carriers";
import {
  SELF_REASON_TEXT, canCancelAt, courierBlocker, hasLeftSeller, needsAttentionFor, orderStatusFor,
  parcelKg, parseConfig, parseCustomerAddress, rankQuotes, readSellerPlace, shouldApply,
  validPin, withinReassignCap,
  type OrderItemLike, type Quote, type SelfReason, type ShippingConfig, type Stage,
} from "./pure";

/**
 * Who ships an order, and keeping the order in step with the parcel.
 *
 * THE ORDER DOCUMENT IS THE SOURCE OF TRUTH. `order.shipment` is written only
 * here (firestore.rules forbids clients). A cancelled booking moves to
 * `order.shipmentHistory`, so a reassigned order keeps the record of what it
 * cost even though the customer sees only the live shipment.
 *
 * MONEY RULES
 *   - order.deliveryCharge is what the customer paid. Nothing here changes it:
 *     a reassignment to a far seller costs the platform, never the customer.
 *   - The courier is paid by the platform, so on a courier order the platform
 *     keeps the delivery fee (keepDeliveryFee). Self-delivery leaves it with
 *     the seller, as it always was.
 *   - "delivered" comes only from the courier. It releases the seller's money
 *     (route-release.ts), so a seller must not be able to set it.
 */

export const RAZORPAY_KEY_ID = defineSecret("RAZORPAY_KEY_ID");
export const RAZORPAY_KEY_SECRET = defineSecret("RAZORPAY_KEY_SECRET");

const db = () => admin.firestore();
const orderRef = (id: string) => db().collection("orders").doc(id);
const key10 = (v: unknown) => String(v ?? "").replace(/\D/g, "").slice(-10);
const nowIso = () => new Date().toISOString();
const LOCK_STALE_MS = 10 * 60 * 1000;
const MAX_EVENTS = 40;

export async function loadConfig(): Promise<ShippingConfig> {
  const snap = await db().collection("_serverConfig").doc("shipping").get();
  return parseConfig(snap.data());
}

/** The seller's address: first document holding a valid pincode wins. */
export async function resolvePickup(sellerPhone: string): Promise<Pickup | null> {
  const k = key10(sellerPhone);
  if (k.length !== 10) return null;
  for (const col of ["manufacturers", "retailers", "profiles", "users"]) {
    for (const id of [`+91${k}`, k]) {
      const snap = await db().collection(col).doc(id).get();
      if (!snap.exists) continue;
      const d = snap.data() ?? {};
      const place = readSellerPlace(d);
      if (!validPin(place.pincode)) continue;
      return {
        ...place,
        name: String(d.businessName ?? d.shopName ?? d.name ?? "KrishiDukan Seller"),
        phone: k,
        phoneKey: k,
        gstin: d.gstin ? String(d.gstin) : undefined,
      };
    }
  }
  return null;
}

const orderValue = (o: FirebaseFirestore.DocumentData) => Number(o.grandTotal ?? o.total ?? o.subtotal ?? 0);
const itemsOf = (o: FirebaseFirestore.DocumentData) => (Array.isArray(o.items) ? o.items : []) as OrderItemLike[];

function isPaid(o: FirebaseFirestore.DocumentData) {
  return o.payment?.status === "paid" && !o.payment?.refundId;
}

async function categoriesOf(items: OrderItemLike[]): Promise<string[]> {
  const out = new Set<string>();
  for (const i of items as Array<OrderItemLike & { productId?: unknown; catalogId?: unknown }>) {
    if (i.category) out.add(String(i.category));
    const id = String(i.catalogId ?? i.productId ?? "");
    if (!id) continue;
    const d = await db().collection("products").doc(id).get().catch(() => null);
    if (d?.get("category")) out.add(String(d.get("category")));
  }
  return [...out];
}

// ─── Book ────────────────────────────────────────────────────────────────

/**
 * Takes the booking lock. A trigger can fire twice and two can run together;
 * only the holder calls a courier, so one order cannot be booked twice.
 */
async function claim(orderId: string): Promise<{ order: FirebaseFirestore.DocumentData; attempt: number } | null> {
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(orderRef(orderId));
    const o = snap.data();
    if (!o || o.status !== "accepted" || !isPaid(o)) return null;
    const s = (o.shipment ?? {}) as Record<string, any>;
    if (s.stage) {
      const stale = s.stage === "booking" && Date.now() - Date.parse(String(s.lockedAt ?? 0)) > LOCK_STALE_MS;
      if (!stale) return null;
    }
    const attempt = Number(o.shipmentAttempts ?? 0) + 1;
    tx.update(orderRef(orderId), {
      shipmentAttempts: attempt,
      shipment: {
        mode: "courier", stage: "booking", active: true, lockedAt: nowIso(), sellerKey: key10(o.sellerPhone ?? o.sellerId),
      },
    });
    return { order: o, attempt };
  });
}

async function fallBackToSelf(orderId: string, o: FirebaseFirestore.DocumentData, reason: SelfReason, quotesTried: Quote[], errors: string[]) {
  const attention = needsAttentionFor(reason);
  await orderRef(orderId).update({
    shipment: {
      mode: "self", stage: "self", active: false, reason, reasonText: SELF_REASON_TEXT[reason],
      sellerKey: key10(o.sellerPhone ?? o.sellerId), quotes: quotesTried, errors,
      needsAttention: attention, decidedAt: nowIso(),
    },
    updatedAt: nowIso(),
  });
  await notify(String(o.sellerPhone ?? ""), "order", "Please deliver this order yourself",
    `${SELF_REASON_TEXT[reason]}. Deliver it as usual and update the status.`, { orderId }).catch(() => undefined);
  logger.info("[shipping] self delivery", { orderId, reason });
}

/** Cheapest courier that actually accepts the booking; seller delivers if none do. */
export async function bookForOrder(orderId: string): Promise<void> {
  const cfg = await loadConfig();
  if (!cfg.enabled) return;

  // A shipment left from a previous seller goes first (reassignment accepted
  // before the cancel finished).
  const peek = (await orderRef(orderId).get()).data();
  const old = peek?.shipment as Record<string, any> | undefined;
  if (old?.stage && old.sellerKey && old.sellerKey !== key10(peek?.sellerPhone ?? peek?.sellerId)) {
    await cancelForOrder(orderId, "seller_changed");
  }

  const claimed = await claim(orderId);
  if (!claimed) return;
  const { order: o, attempt } = claimed;

  const items = itemsOf(o);
  const value = orderValue(o);
  const drop = parseCustomerAddress(o.customerAddress, o.customerDeliveryState);
  const pickup = await resolvePickup(String(o.sellerPhone ?? o.sellerId ?? ""));
  const blocker = courierBlocker({
    pickupPin: pickup?.pincode ?? "", dropPin: drop.pincode, declaredValue: value,
    categories: await categoriesOf(items), cfg,
  });
  if (blocker) return fallBackToSelf(orderId, o, blocker, [], []);

  const { kg, guessed } = parcelKg(items, cfg);
  const { quotes, errors } = await getQuotes(cfg.carriers, pickup!.pincode, drop.pincode, kg, value);
  const ranked = rankQuotes(quotes);
  if (ranked.length === 0) {
    // Both couriers erroring is not the same as "no service here".
    return fallBackToSelf(orderId, o, errors.length === cfg.carriers.length ? "booking_failed" : "not_serviceable", [], errors);
  }

  const simulate = cfg.mode !== "live";
  const reference = `${orderId}-${attempt}`;
  const failures: string[] = [...errors];
  for (const quote of ranked) {
    try {
      const b = await bookShipment({
        reference, orderId, quote, pickup: pickup!, weightKg: kg, declaredValue: value, items,
        drop: { ...drop, name: String(o.customerName ?? "Customer"), phone: key10(o.customerPhone) },
      }, simulate);
      const trackingUrl = trackingUrlFor(quote.carrier, b.awb);
      const customerPaid = Number(o.deliveryCharge ?? 0);
      const at = nowIso();
      await orderRef(orderId).update({
        shipment: {
          mode: "courier", stage: "booked", active: true, simulated: simulate,
          carrier: quote.carrier, service: quote.service, courierId: quote.courierId ?? null,
          awb: b.awb, trackingUrl, labelUrl: b.labelUrl ?? null,
          carrierShipmentId: b.carrierShipmentId ?? null, carrierOrderId: b.carrierOrderId ?? null,
          reference, sellerKey: key10(o.sellerPhone ?? o.sellerId),
          weightKg: kg, weightGuessed: guessed, cost: quote.cost, etaDays: quote.etaDays ?? null,
          customerPaid, platformGap: Math.round((quote.cost - customerPaid) * 100) / 100,
          quotes: ranked.slice(0, 8), errors: failures,
          needsAttention: false, bookedAt: at,
          events: [{ stage: "booked", at, source: "system" }],
        },
        // Same field the manual flow writes, so every existing screen shows it.
        "tracking.url": trackingUrl,
        "tracking.idType": "awb",
        "tracking.id": b.awb,
        "tracking.addedAt": at,
        "tracking.addedBy": "courier-automation",
        "tracking.updatedAt": at,
        updatedAt: at,
      });
      // The seller may have rejected while the courier was answering. The
      // reject trigger found nothing to cancel then, so it is cancelled here.
      const latest = (await orderRef(orderId).get()).data();
      if (latest?.status !== "accepted") {
        logger.warn("[shipping] order moved during booking, cancelling", { orderId, status: latest?.status });
        await cancelForOrder(orderId, "order_changed_during_booking");
        return;
      }
      await keepDeliveryFee(orderId, cfg);
      await tellCustomer(orderId, o, trackingUrl, b.awb);
      await notify(String(o.sellerPhone ?? ""), "order", "Courier booked",
        `Print the label, pack the order, then tap Ready for pickup. Tracking ID ${b.awb}.`, { orderId }).catch(() => undefined);
      logger.info("[shipping] booked", { orderId, carrier: quote.carrier, service: quote.service, cost: quote.cost, simulate });
      return;
    } catch (e) {
      failures.push(`${quote.carrier}/${quote.service}: ${String(e).slice(0, 200)}`);
      logger.warn("[shipping] booking failed, trying next", { orderId, carrier: quote.carrier, e: String(e) });
    }
  }
  await fallBackToSelf(orderId, o, "booking_failed", ranked.slice(0, 8), failures);
}

async function tellCustomer(orderId: string, o: FirebaseFirestore.DocumentData, url: string, awb: string) {
  const phone = String(o.customerPhone ?? "").replace(/\D/g, "");
  if (!phone) return;
  await queueWaNotification(phone.startsWith("91") ? phone : `91${phone}`,
    `Your order is booked with the courier. Track: ${url} (AWB Number: ${awb})`, {
      template: "order_tracking_link",
      payload: {
        customerName: String(o.customerName ?? ""), trackingUrl: url,
        trackingIdTypeLabel: "AWB Number", trackingId: awb, orderId,
      },
      source: { event: "order_tracking_link", entityType: "order", entityId: orderId },
      type: "order",
    }).catch((e) => logger.warn("[shipping] tracking message not queued", { orderId, e: String(e) }));
}

// ─── Delivery fee ────────────────────────────────────────────────────────

/**
 * The customer's delivery fee sits in the seller's held transfer. Once the
 * platform is paying the courier it must come back, or the fee is paid twice.
 * Sets platformKeptDelivery first: the manual payout run reads that, so a
 * seller with no Route transfer is covered too.
 */
async function keepDeliveryFee(orderId: string, cfg: ShippingConfig): Promise<void> {
  if (!cfg.platformKeepsDeliveryFee) return;
  await orderRef(orderId).update({ "shipment.platformKeptDelivery": true });
  const o = (await orderRef(orderId).get()).data();
  // The customer's delivery fee, plus the courier cost a seller agreed to bear
  // by marking every item Free Delivery (lib/cart-pricing courierDelivery).
  const sellerPays = Number(o?.deliveryBreakdown?.sellerPaysCourier ?? 0);
  const fee = Math.round((Number(o?.deliveryCharge ?? 0) + (sellerPays > 0 ? sellerPays : 0)) * 100);
  const paymentId = String(o?.payment?.razorpayPaymentId ?? "");
  if (!o || fee <= 0 || !paymentId || o.shipment?.feeReversal) return;
  try {
    const auth = "Basic " + Buffer.from(`${RAZORPAY_KEY_ID.value()}:${RAZORPAY_KEY_SECRET.value()}`).toString("base64");
    const res = await fetch(`https://api.razorpay.com/v1/payments/${paymentId}/transfers`, { headers: { Authorization: auth } });
    if (!res.ok) throw new Error(`transfers ${res.status}`);
    const items = ((await res.json()) as { items?: any[] }).items ?? [];
    const recorded = String(o.routeTransfer?.id ?? "");
    const seller = key10(o.sellerPhone ?? o.sellerId);
    const t = recorded
      ? items.find((x) => x.id === recorded)
      : items.find((x) => key10(x.notes?.sellerKey) === seller);
    if (!t) return; // no Route transfer: the payout run deducts it instead
    const left = Number(t.amount) - Number(t.amount_reversed ?? 0);
    const amount = Math.min(fee, left);
    if (amount <= 0) return;
    const rev = await fetch(`https://api.razorpay.com/v1/transfers/${t.id}/reversals`, {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ amount }),
    });
    if (!rev.ok) throw new Error(`reversal ${rev.status}: ${(await rev.text()).slice(0, 200)}`);
    const r = (await rev.json()) as { id: string };
    await orderRef(orderId).update({ "shipment.feeReversal": { id: r.id, transferId: t.id, paise: amount, at: nowIso() } });
  } catch (e) {
    logger.error("[shipping] delivery fee not reversed", { orderId, e: String(e) });
    await orderRef(orderId).update({
      "shipment.needsAttention": true,
      "shipment.attentionNote": `Delivery fee still with the seller: ${String(e).slice(0, 160)}`,
    });
  }
}

// ─── Cancel ──────────────────────────────────────────────────────────────

/**
 * Cancels the live booking before anything else happens to the order. If the
 * parcel has already left, it can't be cancelled: that goes to an admin rather
 * than pretending, because the goods are physically on the road.
 */
export async function cancelForOrder(orderId: string, why: string): Promise<boolean> {
  const taken = await db().runTransaction(async (tx) => {
    const snap = await tx.get(orderRef(orderId));
    const s = snap.data()?.shipment as Record<string, any> | undefined;
    if (!s?.stage || s.mode === "self") return s?.stage ? ("self" as const) : null;
    if (s.stage === "cancelling") {
      if (Date.now() - Date.parse(String(s.cancelAt ?? 0)) < LOCK_STALE_MS) return null;
    } else if (!canCancelAt(s.stage)) {
      tx.update(orderRef(orderId), {
        "shipment.needsAttention": true,
        "shipment.attentionNote": `Order moved (${why}) after the parcel left the seller.`,
      });
      return null;
    }
    tx.update(orderRef(orderId), {
      "shipment.previousStage": s.stage === "cancelling" ? (s.previousStage ?? "booked") : s.stage,
      "shipment.stage": "cancelling",
      "shipment.cancelAt": nowIso(),
    });
    return s;
  });
  if (!taken) return false;
  if (taken === "self") {
    await orderRef(orderId).update({ shipment: FieldValue.delete() });
    return true;
  }
  try {
    if (taken.awb) await cancelShipment(taken as unknown as ActiveShipment);
  } catch (e) {
    logger.error("[shipping] courier cancel failed, sweep will retry", { orderId, e: String(e) });
    await orderRef(orderId).update({
      "shipment.cancelError": String(e).slice(0, 240),
      "shipment.needsAttention": true,
      "shipment.attentionNote": "The courier booking could not be cancelled yet.",
    });
    return false;
  }
  await orderRef(orderId).update({
    shipment: FieldValue.delete(),
    tracking: FieldValue.delete(),
    shipmentHistory: FieldValue.arrayUnion({
      carrier: taken.carrier ?? null, service: taken.service ?? null, awb: taken.awb ?? null,
      cost: taken.cost ?? null, simulated: taken.simulated === true, sellerKey: taken.sellerKey ?? null,
      platformKeptDelivery: taken.platformKeptDelivery === true,
      cancelledAt: nowIso(), reason: why,
    }),
    updatedAt: nowIso(),
  });
  logger.info("[shipping] cancelled", { orderId, why });
  return true;
}

// ─── Pickup + tracking events ────────────────────────────────────────────

export async function requestPickupFor(orderId: string): Promise<void> {
  const o = (await orderRef(orderId).get()).data();
  const s = o?.shipment as Record<string, any> | undefined;
  if (!o || !s || s.mode !== "courier" || s.stage !== "booked") return;
  try {
    const warehouse = String((await db().collection("courierPickups").doc(s.sellerKey).get()).get("delhiveryName") ?? "");
    const date = await requestPickup(s as unknown as ActiveShipment, warehouse);
    await applyEvent(orderId, "pickup_requested", "seller", `Pickup on ${date}`);
    await orderRef(orderId).update({ "shipment.pickupDate": date });
  } catch (e) {
    await orderRef(orderId).update({
      "shipment.needsAttention": true,
      "shipment.attentionNote": `Pickup request failed: ${String(e).slice(0, 180)}`,
    });
  }
}

/** Every courier update comes through here: webhook, poll or simulator alike. */
export async function applyEvent(orderId: string, stage: Stage, source: string, detail = ""): Promise<boolean> {
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(orderRef(orderId));
    const o = snap.data();
    const s = o?.shipment as Record<string, any> | undefined;
    if (!o || !s || s.mode !== "courier" || !shouldApply(s.stage as Stage, stage)) return false;

    const at = nowIso();
    const events = [...(Array.isArray(s.events) ? s.events : []), { stage, at, source, ...(detail ? { detail } : {}) }].slice(-MAX_EVENTS);
    const update: Record<string, unknown> = {
      "shipment.stage": stage, "shipment.events": events, "shipment.lastEventAt": at, updatedAt: at,
    };
    if (stage === "delivered" || stage === "returned" || stage === "lost") update["shipment.active"] = false;
    if (stage === "returning" || stage === "returned" || stage === "lost") {
      update["shipment.needsAttention"] = true;
      update["shipment.attentionNote"] = stage === "lost"
        ? "The courier reports this parcel lost. Decide the refund."
        : "The parcel is coming back to the seller. Decide the refund.";
    }
    const next = orderStatusFor(stage, String(o.status));
    if (next) {
      update.status = next;
      update.statusHistory = FieldValue.arrayUnion({ status: next, at, by: "courier" });
    } else if (hasLeftSeller(stage) && (o.status === "cancelled" || o.status === "rejected")) {
      update["shipment.needsAttention"] = true;
      update["shipment.attentionNote"] = `Courier reports ${stage} on a ${o.status} order.`;
    }
    tx.update(orderRef(orderId), update);
    return true;
  });
}

// ─── Reassignment ────────────────────────────────────────────────────────

/**
 * A rejected order is offered to other sellers. The customer's delivery charge
 * is frozen, so a far seller costs the platform: price each seller, tell them,
 * and withdraw offers over the limit. If nobody is left the window is closed
 * at once, so the customer is refunded by the next sweep, not after 24h.
 */
export async function priceReassignmentOffers(orderId: string): Promise<void> {
  const cfg = await loadConfig();
  if (!cfg.enabled) return;
  const o = (await orderRef(orderId).get()).data();
  const candidates = (o?.reassignment?.candidatePhones ?? []) as string[];
  if (!o || candidates.length === 0) return;
  const drop = parseCustomerAddress(o.customerAddress, o.customerDeliveryState);
  const { kg } = parcelKg(itemsOf(o), cfg);
  const value = orderValue(o);

  let open = 0;
  for (const phone of candidates) {
    const ref = db().collection("sellerOffers").doc(key10(phone)).collection("offers").doc(orderId);
    const offer = await ref.get();
    if (!offer.exists || offer.get("status") !== "open") continue;
    let best: Quote | null = null;
    const pickup = await resolvePickup(phone);
    if (pickup && validPin(drop.pincode)) {
      const { quotes } = await getQuotes(cfg.carriers, pickup.pincode, drop.pincode, kg, value);
      best = rankQuotes(quotes)[0] ?? null;
    }
    const cost = best?.cost ?? null;
    if (!withinReassignCap(cost, value, cfg.reassignMaxCostPercent)) {
      await ref.update({ status: "too_far", estimatedShipping: cost, updatedAt: nowIso() });
      logger.info("[shipping] offer withdrawn, shipping over the limit", { orderId, seller: key10(phone).slice(-4), cost, value });
      continue;
    }
    open++;
    await ref.update({
      estimatedShipping: cost, shippingBy: best ? "courier" : "seller", updatedAt: nowIso(),
    });
  }
  if (open === 0) {
    await orderRef(orderId).update({
      "reassignment.expiresAt": Timestamp.now(),
      "reassignment.noViableSeller": true,
      updatedAt: nowIso(),
    });
  }
}

// ─── Webhook lookup + sweep ──────────────────────────────────────────────

export async function orderIdForAwb(awb: string): Promise<string | null> {
  const q = await db().collection("orders").where("shipment.awb", "==", awb).limit(1).get();
  return q.docs[0]?.id ?? null;
}
