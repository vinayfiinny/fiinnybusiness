"use client";

import { useEffect, useState } from "react";
import { formatDeliveryDate } from "../../lib/delivery-eta";

/**
 * "Deliver to 411062 — FREE delivery by Thu, 19 Nov · Change" on the product
 * page, like Amazon. Asks /api/delivery/estimate (same courier price and rules
 * as checkout) for the nearest store that delivers. The pincode is remembered
 * in this browser; nothing shows when courier delivery is switched off.
 */

type Estimate = {
  enabled: boolean;
  available?: boolean;
  free?: boolean;
  charge?: number;
  fullCharge?: number;
  /** The store pays this % of delivery (share offers). */
  sellerPct?: number;
  /** Free delivery on orders of at least this much from the store. */
  freeAbove?: number | null;
  deliveryBy?: string | null;
  etaDays?: number | null;
};

const PIN_KEY = "kd_delivery_pincode";
const PIN = /^[1-9]\d{5}$/;

function readPin(): string {
  try { return localStorage.getItem(PIN_KEY) ?? ""; } catch { return ""; }
}
function savePin(pin: string) {
  try { localStorage.setItem(PIN_KEY, pin); } catch { /* private window */ }
}

export function DeliveryEstimate({ productId, seller, size }: { productId: string; seller?: string; size?: string }) {
  const [pin, setPin] = useState("");
  const [draft, setDraft] = useState("");
  const [editing, setEditing] = useState(false);
  const [est, setEst] = useState<Estimate | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const saved = readPin();
    setPin(saved);
    setDraft(saved);
    setEditing(!PIN.test(saved));
  }, []);

  useEffect(() => {
    if (!PIN.test(pin) || !productId) { setEst(null); return; }
    let cancelled = false;
    setLoading(true);
    const qs = new URLSearchParams({ productId, pincode: pin });
    if (seller) qs.set("seller", seller);
    if (size) qs.set("size", size);
    fetch(`/api/delivery/estimate?${qs}`)
      .then((r) => (r.ok ? r.json() : null))
      .then((body) => { if (!cancelled) setEst(body); })
      .catch(() => { if (!cancelled) setEst(null); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [pin, productId, seller, size]);

  if (est && est.enabled === false) return null;

  const apply = () => {
    const p = draft.trim();
    if (!PIN.test(p)) return;
    savePin(p);
    setPin(p);
    setEditing(false);
  };

  return (
    <div className="rounded-2xl border border-surface-container bg-surface-container-low px-4 py-3 text-sm">
      {editing ? (
        <form
          className="flex items-center gap-2"
          onSubmit={(e) => { e.preventDefault(); apply(); }}
        >
          <label htmlFor="pdp-pin" className="shrink-0 font-semibold text-on-surface">Deliver to</label>
          <input
            id="pdp-pin"
            inputMode="numeric"
            maxLength={6}
            value={draft}
            onChange={(e) => setDraft(e.target.value.replace(/\D/g, "").slice(0, 6))}
            placeholder="Enter pincode"
            className="min-w-0 flex-1 rounded-xl border border-outline-variant bg-white px-3 py-1.5 text-sm"
          />
          <button
            type="submit"
            disabled={!PIN.test(draft.trim())}
            className="shrink-0 rounded-xl bg-primary px-3 py-1.5 text-xs font-bold text-white disabled:opacity-50"
          >
            Check
          </button>
        </form>
      ) : (
        <div className="flex flex-col gap-0.5">
          <div className="flex items-center justify-between gap-2">
            <span className="text-on-surface-variant">
              Deliver to <span className="font-bold text-on-surface">{pin}</span>
            </span>
            <button type="button" onClick={() => setEditing(true)} className="text-xs font-bold text-primary">
              Change
            </button>
          </div>
          {loading ? (
            <span className="text-xs text-on-surface-variant">Checking delivery…</span>
          ) : !est ? null : est.available ? (
            <>
              <span className="font-semibold text-on-surface">
                {est.free ? <span className="text-green-700">FREE delivery</span> : <>Delivery ₹{est.charge}</>}
                {!est.free && (est.sellerPct ?? 0) > 0 && est.fullCharge
                  ? <span className="ml-1 text-xs font-normal text-on-surface-variant line-through">₹{est.fullCharge}</span>
                  : null}
                {est.deliveryBy && <> by <span className="text-green-700">{formatDeliveryDate(est.deliveryBy)}</span></>}
              </span>
              {!est.free && (est.sellerPct ?? 0) > 0 && (
                <span className="text-xs text-green-700">The store pays {est.sellerPct}% of your delivery</span>
              )}
              {!est.free && est.freeAbove ? (
                <span className="text-xs text-on-surface-variant">
                  FREE delivery on orders of ₹{est.freeAbove.toLocaleString("en-IN")}+ from this store
                </span>
              ) : null}
            </>
          ) : (
            <span className="text-xs text-on-surface-variant">
              Courier delivery isn&apos;t available to this pincode; the store will tell you the delivery charge.
            </span>
          )}
        </div>
      )}
    </div>
  );
}
