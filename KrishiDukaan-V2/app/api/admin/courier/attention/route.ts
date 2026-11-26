import { NextResponse } from "next/server";
import { getAdminDb } from "../../../../lib/firebase-admin";
import { requireAdmin, requireSection } from "../../../../lib/admin-auth";
import {
  key10, readAdjustments, withoutUnpaidAdjustment,
} from "../../../../../functions/src/payouts/settlement";

/**
 * Admin → Courier delivery: orders whose courier booking needs a person.
 *
 * GET  (admin, or team with "orders"): orders with shipment.needsAttention —
 *      failed bookings, bookings waiting for an automatic retry, empty wallets.
 * POST { orderId } (admin): "Retry booking now". For an order that fell back
 *      to its seller (booking failed / no courier) or is waiting for a retry:
 *      the seller's unpaid self-delivery adjustment is removed (they will not
 *      deliver it after all), and a booking is started at once (the
 *      shipOrderOnChange trigger sees retryAt = now). Refused when that
 *      adjustment was already paid, so money already sent is never orphaned.
 */

const RETRYABLE_SELF = new Set(["booking_failed", "not_serviceable", "automation_off"]);

export async function GET(request: Request) {
  const caller = await requireSection(request, "orders");
  if (caller instanceof NextResponse) return caller;
  const snap = await getAdminDb().collection("orders").where("shipment.needsAttention", "==", true).limit(60).get();
  const orders = snap.docs.map((d) => {
    const o = d.data();
    const s = (o.shipment ?? {}) as Record<string, unknown>;
    return {
      id: d.id,
      number: String(o.invoiceNumber ?? o.orderNumber ?? d.id.slice(0, 8).toUpperCase()),
      status: String(o.status ?? ""),
      sellerName: String(o.sellerName ?? o.sellerPhone ?? ""),
      customerName: String(o.customerName ?? ""),
      total: Number(o.grandTotal ?? o.total ?? 0),
      stage: String(s.stage ?? ""),
      reason: String(s.reason ?? ""),
      note: String(s.attentionNote ?? s.reasonText ?? ""),
      errors: (Array.isArray(s.errors) ? s.errors : []).slice(0, 3).map((e) => String(e).slice(0, 300)),
      retryAt: s.retryAt ? String(s.retryAt) : null,
      canRetry: o.status === "accepted" &&
        ((s.stage === "self" && RETRYABLE_SELF.has(String(s.reason))) || s.stage === "booking"),
    };
  });
  return NextResponse.json({ orders });
}

export async function POST(request: Request) {
  const caller = await requireAdmin(request);
  if (caller instanceof NextResponse) return caller;
  const body = (await request.json().catch(() => null)) as { orderId?: unknown } | null;
  const orderId = String(body?.orderId ?? "").trim();
  if (!orderId || orderId.includes("/")) return NextResponse.json({ error: "orderId is required" }, { status: 400 });

  const db = getAdminDb();
  const ref = db.collection("orders").doc(orderId);
  const who = caller.phone ?? caller.uid;
  try {
    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const o = snap.data();
      if (!o) return { status: 404, error: "Order not found" };
      if (o.status !== "accepted") return { status: 409, error: `The order is ${o.status ?? "not accepted"}; only an accepted order can be booked.` };
      const s = (o.shipment ?? {}) as Record<string, unknown>;
      const allowed = (s.stage === "self" && RETRYABLE_SELF.has(String(s.reason))) || s.stage === "booking";
      if (!allowed) return { status: 409, error: `Nothing to retry: the shipment is "${String(s.stage ?? "none")}".` };

      const sellerKey = key10(o.sellerPhone ?? o.sellerId);
      const adj = withoutUnpaidAdjustment(readAdjustments(o.settlementAdjustments), "self_delivery", sellerKey);
      if (adj.paid.length > 0) {
        return { status: 409, error: "The seller was already paid for delivering this order. Settle that first; the retry was not started." };
      }
      const now = new Date().toISOString();
      const stillDue = adj.list.some((a) => !a.paidTransferId);
      tx.update(ref, {
        ...(adj.removed.length ? { settlementAdjustments: adj.list } : {}),
        ...(adj.removed.length && !stillDue && o.settlementTopUpDue === true ? { settlementTopUpDue: false } : {}),
        // Rounds of automatic retries count again from here.
        shipmentRetryFrom: Number(o.shipmentAttempts ?? 0),
        shipment: {
          mode: "courier", stage: "booking", active: true, lockedAt: now, retryAt: now,
          sellerKey, requestedBy: who, requestedAt: now,
          previous: {
            stage: String(s.stage ?? ""), reason: String(s.reason ?? ""),
            errors: (Array.isArray(s.errors) ? s.errors : []).slice(0, 3).map((e) => String(e).slice(0, 300)),
          },
        },
        updatedAt: now,
      });
      if (adj.removed.length) {
        tx.delete(db.collection("deliveryLedger").doc(`${orderId}_${sellerKey || "seller"}_self_delivery`.replace(/[/]/g, "_")));
      }
      return { status: 200, removedPaise: adj.removed.reduce((n, a) => n + a.netPaise, 0) };
    });
    if (result.status !== 200) return NextResponse.json({ error: result.error }, { status: result.status });
    return NextResponse.json({ ok: true, removedSelfDeliveryPaise: result.removedPaise });
  } catch (e) {
    console.error("[admin courier retry]", orderId, e);
    return NextResponse.json({ error: "Could not start the retry. Please try again." }, { status: 500 });
  }
}
