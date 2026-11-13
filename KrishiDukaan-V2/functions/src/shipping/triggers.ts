import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import * as admin from "firebase-admin";
import {
  DELHIVERY_API_TOKEN, SHIPROCKET_API_EMAIL, SHIPROCKET_API_PASSWORD, trackShipment, type ActiveShipment,
} from "./carriers";
import {
  RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, applyEvent, bookForOrder, cancelForOrder, loadConfig,
  orderIdForAwb, priceReassignmentOffers, releaseStuckBooking, requestPickupFor,
} from "./engine";
import { delhiveryStage, shiprocketStage, type Stage } from "./pure";

/**
 * Courier automation hangs off the order document, like route-release.ts: an
 * order is accepted from the web dashboard, both apps, WhatsApp and the
 * reassignment server code, and a trigger catches all of them, old app builds
 * included. Every step is idempotent, because triggers can fire twice and these
 * functions' own writes re-fire this one.
 */

const REGION = "asia-south1";
const SECRETS = [DELHIVERY_API_TOKEN, SHIPROCKET_API_EMAIL, SHIPROCKET_API_PASSWORD, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET];
const SIM_EVENTS: Stage[] = ["picked_up", "in_transit", "out_for_delivery", "delivered", "returning", "returned", "lost"];
const NOT_PICKED_UP_MS = 48 * 3600 * 1000;

export const shipOrderOnChange = onDocumentUpdated(
  { region: REGION, document: "orders/{orderId}", secrets: SECRETS, timeoutSeconds: 120 },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    const orderId = event.params.orderId;

    // Left the seller's hands before pickup: the booking must go first. A
    // refund from the admin tool leaves the status alone, so it counts too.
    const closing = after.status === "reassigning" || after.status === "rejected" || after.status === "cancelled";
    const refunded = !before.payment?.refundId && !!after.payment?.refundId;
    if ((closing && before.status !== after.status) || refunded) {
      if (after.shipment?.stage) await cancelForOrder(orderId, refunded ? "refunded" : `order_${after.status}`);
    }

    if (after.status === "reassigning" && before.status !== "reassigning") {
      await priceReassignmentOffers(orderId);
    }

    if (after.status === "accepted" && before.status !== "accepted") {
      await bookForOrder(orderId);
    }

    // The one thing a seller may ask for (firestore.rules allows only this field).
    const req = after.shipmentRequest as { id?: string; action?: string; event?: string } | undefined;
    if (req?.id && req.id !== before.shipmentRequest?.id) {
      if (req.action === "pickup") {
        await requestPickupFor(orderId);
      } else if (req.action === "simulate" && after.shipment?.simulated === true && SIM_EVENTS.includes(req.event as Stage)) {
        // Test bookings only: a real shipment can only be moved by its courier.
        await applyEvent(orderId, req.event as Stage, "simulator");
      } else {
        logger.warn("[shipping] request ignored", { orderId, action: req.action });
      }
    }
  },
);

/** Catches whatever the triggers and webhooks missed. */
export const shipmentSweep = onSchedule(
  { region: REGION, schedule: "every 30 minutes", timeZone: "Asia/Kolkata", secrets: SECRETS, timeoutSeconds: 300 },
  async () => {
    // Runs even when automation is switched off: parcels already booked must
    // still be tracked to delivery (that releases the seller's money) and
    // cancellations retried. Only new bookings stop.
    const cfg = await loadConfig();
    const snap = await admin.firestore().collection("orders").where("shipment.active", "==", true).limit(300).get();
    let moved = 0;
    for (const d of snap.docs) {
      const o = d.data();
      const s = o.shipment as Record<string, any>;
      try {
        if (s.stage === "booking") await (cfg.enabled ? bookForOrder(d.id) : releaseStuckBooking(d.id));
        else if (s.stage === "cancelling") await cancelForOrder(d.id, "retry");
        else if (!s.simulated && s.awb) {
          const t = await trackShipment(s as unknown as ActiveShipment);
          if (t.stage && (await applyEvent(d.id, t.stage, "poll", t.detail))) moved++;
        }
        const since = Date.parse(String(s.bookedAt ?? ""));
        if ((s.stage === "booked" || s.stage === "pickup_requested") && since && Date.now() - since > NOT_PICKED_UP_MS && !s.needsAttention) {
          await d.ref.update({
            "shipment.needsAttention": true,
            "shipment.attentionNote": "Not picked up 48 hours after booking.",
          });
        }
      } catch (e) {
        logger.warn("[shipping] sweep item failed", { orderId: d.id, e: String(e) });
      }
    }
    logger.info("[shipping] sweep", { active: snap.size, moved });
  },
);

/**
 * Status updates pushed by the couriers. Register
 *   …/courierWebhook?carrier=delhivery&token=<_serverConfig/shipping.webhookToken>
 * with each. An update we cannot place answers 200 so the courier stops
 * retrying it; the sweep is the safety net.
 */
export const courierWebhook = onRequest(
  { region: REGION, invoker: "public" },
  async (req, res) => {
    const cfg = await loadConfig();
    if (!cfg.webhookToken || req.query.token !== cfg.webhookToken) {
      res.status(401).send("no");
      return;
    }
    const carrier = String(req.query.carrier ?? "");
    const b = (req.body ?? {}) as Record<string, any>;
    let awb = "";
    let stage: Stage | null = null;
    let detail = "";
    if (carrier === "delhivery") {
      const s = b.Shipment ?? {};
      awb = String(s.AWB ?? s.Waybill ?? "");
      stage = delhiveryStage(s.Status?.Status, s.Status?.StatusType);
      detail = String(s.Status?.Instructions ?? s.Status?.Status ?? "");
    } else if (carrier === "shiprocket") {
      awb = String(b.awb ?? "");
      stage = shiprocketStage(b.current_status ?? b.shipment_status);
      detail = String(b.current_status ?? "");
    }
    if (awb && stage) {
      const orderId = await orderIdForAwb(awb);
      if (orderId) await applyEvent(orderId, stage, `webhook:${carrier}`, detail);
      else logger.warn("[shipping] webhook for unknown AWB", { carrier, awb });
    }
    res.status(200).send("ok");
  },
);
