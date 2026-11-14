"use client";

import { useState } from "react";
import { ExternalLink, Package, Printer, Truck } from "lucide-react";
import { requestShipmentAction } from "../firebase";
import {
  COURIER_NAMES, SHIPMENT_LEFT_SELLER, SHIPMENT_STAGE_TEXT,
  type OrderDoc, type ShipmentStage,
} from "../../types/order";

const SIM_STEPS: { event: ShipmentStage; label: string }[] = [
  { event: "picked_up", label: "Picked up" },
  { event: "in_transit", label: "In transit" },
  { event: "out_for_delivery", label: "Out for delivery" },
  { event: "delivered", label: "Delivered" },
  { event: "returning", label: "Return" },
  { event: "returned", label: "Returned" },
  { event: "lost", label: "Lost" },
];

/** The courier parcel, for the customer (My Orders) and the seller (dashboard). */
export default function ShipmentCard({ order, sellerView = false }: { order: OrderDoc; sellerView?: boolean }) {
  const s = order.shipment;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!s) return null;

  const send = async (action: "pickup" | "simulate", event?: string) => {
    setBusy(true);
    setError(null);
    try {
      await requestShipmentAction(order.id, action, event);
    } catch {
      setError("Could not send that. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  if (s.mode === "self") {
    if (!sellerView) return null;
    return (
      <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-xs text-amber-900">
        <p className="font-black">Please deliver this order yourself</p>
        <p className="mt-1">{s.reasonText}. Update the status as usual.</p>
      </div>
    );
  }

  const name = s.carrier ? COURIER_NAMES[s.carrier] : "Courier";
  const trouble = s.stage === "returning" || s.stage === "returned" || s.stage === "lost";
  return (
    <div className="space-y-2.5 rounded-xl border border-surface-container p-4">
      <div className="flex items-center justify-between gap-2">
        <p className="flex items-center gap-1.5 text-[10px] font-black uppercase tracking-widest text-on-surface-variant">
          <Truck className="h-3.5 w-3.5" /> {name}{s.service ? ` · ${s.service}` : ""}
        </p>
        <span className={`rounded-full px-2 py-0.5 text-[10px] font-bold ${trouble ? "bg-red-100 text-red-700" : "bg-primary/10 text-primary"}`}>
          {SHIPMENT_STAGE_TEXT[s.stage]}
        </span>
      </div>

      {s.simulated && (
        <p className="rounded-lg bg-amber-50 px-2.5 py-1.5 text-[11px] font-semibold text-amber-800">
          Test booking. Nothing is really shipped and the tracking link will not work.
        </p>
      )}
      {s.stage === "pickup_requested" && s.pickupDate && (
        <p className="text-xs text-on-surface-variant">Pickup expected on {s.pickupDate}.</p>
      )}

      {s.awb && (
        <div className="text-xs">
          <span className="text-on-surface-variant">Tracking ID: </span>
          <span className="font-bold text-on-surface">{s.awb}</span>
        </div>
      )}
      {s.trackingUrl && (
        <a href={s.trackingUrl} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 text-xs font-bold text-primary hover:underline">
          <ExternalLink className="h-3.5 w-3.5" /> Track this parcel
        </a>
      )}

      {sellerView && (
        <>
          {s.cost != null && (s.sellerPaysCourier ?? 0) > 0 ? (
            <p className="text-[11px] font-semibold text-on-surface">
              Your delivery offer: ₹{s.sellerPaysCourier} of the courier cost is taken from your payout.
            </p>
          ) : s.cost != null && (
            <p className="text-[11px] text-on-surface-variant">
              KrishiDukan pays the courier, so the delivery charge is not part of your payout.
            </p>
          )}
          {s.weightGuessed && (
            <p className="text-[11px] font-semibold text-amber-800">
              Weight was estimated ({s.weightKg} kg). A wrong size on the product can change what the courier charges.
            </p>
          )}
          <div className="flex flex-wrap gap-2">
            {s.labelUrl && (
              <a href={s.labelUrl} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 rounded-lg border border-outline-variant/50 px-3 py-1.5 text-[11px] font-bold">
                <Printer className="h-3.5 w-3.5" /> Print label
              </a>
            )}
            {s.stage === "booked" && (
              <button type="button" disabled={busy} onClick={() => send("pickup")} className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-[11px] font-black text-white disabled:opacity-50">
                <Package className="h-3.5 w-3.5" /> Ready for pickup
              </button>
            )}
          </div>
          {s.simulated && !["delivered", "returned", "lost"].includes(s.stage) && (
            <div className="border-t border-surface-container pt-2">
              <p className="mb-1.5 text-[10px] font-black uppercase tracking-widest text-on-surface-variant">Test: act as the courier</p>
              <div className="flex flex-wrap gap-1.5">
                {SIM_STEPS.map((step) => (
                  <button key={step.event} type="button" disabled={busy} onClick={() => send("simulate", step.event)} className="rounded-md border border-outline-variant/50 px-2 py-1 text-[10px] font-bold disabled:opacity-50">
                    {step.label}
                  </button>
                ))}
              </div>
            </div>
          )}
          {SHIPMENT_LEFT_SELLER.includes(s.stage) && s.stage !== "delivered" && (
            <p className="text-[11px] text-on-surface-variant">The status updates by itself as the courier moves the parcel.</p>
          )}
          {error && <p className="text-[11px] font-semibold text-red-700">{error}</p>}
        </>
      )}
    </div>
  );
}
