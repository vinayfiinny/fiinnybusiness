"use client";

import { useEffect, useState } from "react";
import { RefreshCw, Truck } from "lucide-react";
import { auth } from "../../firebase";

type Config = {
  enabled: boolean;
  checkoutPricing: boolean;
  mode: "live" | "simulate";
  liveSellers: string[];
  updatedBy: string | null;
  updatedAt: number | null;
};

/**
 * Courier delivery on/off (api/admin/shipping-config → _serverConfig/shipping).
 * Off = no new Delhivery/Shiprocket bookings; sellers arrange delivery as
 * before and checkout uses their own delivery charges.
 */
export default function AdminCourierPage() {
  const [cfg, setCfg] = useState<Config | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  const call = async (init?: RequestInit): Promise<Config> => {
    const token = await auth.currentUser?.getIdToken();
    const res = await fetch("/api/admin/shipping-config", {
      ...init,
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token ?? ""}` },
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error || `Request failed (${res.status})`);
    return body as Config;
  };

  const load = async () => {
    setLoading(true);
    try {
      setCfg(await call());
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : "Could not load the settings." });
    } finally {
      setLoading(false);
    }
  };

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { void load(); }, []);

  const save = async (patch: Partial<Pick<Config, "enabled" | "checkoutPricing">>, confirmText: string) => {
    if (!window.confirm(confirmText)) return;
    setSaving(true);
    setMessage(null);
    try {
      setCfg(await call({ method: "POST", body: JSON.stringify(patch) }));
      setMessage({ ok: true, text: "Saved. Checkout picks this up within a minute." });
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : "Save failed." });
    } finally {
      setSaving(false);
    }
  };

  const on = cfg?.enabled === true;
  const pricingOn = on && cfg?.checkoutPricing === true;

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="flex items-center gap-2 text-2xl font-black text-on-surface">
            <Truck className="h-6 w-6 text-primary" /> Courier delivery
          </h1>
          <p className="mt-1 text-sm text-on-surface-variant">
            Automatic Delhivery / Shiprocket booking when a seller accepts an order.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          className="flex items-center gap-1.5 rounded-xl border border-outline-variant/40 bg-white px-3 py-2 text-sm font-semibold"
        >
          <RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} /> Refresh
        </button>
      </div>

      {cfg && (
        <div className="space-y-5 rounded-2xl border border-outline-variant/30 bg-white p-5">
          <div className="flex items-center justify-between gap-4">
            <span>
              <span className="block text-sm font-bold text-on-surface">
                Courier automation is {on ? <span className="text-green-700">ON</span> : <span className="text-red-700">OFF</span>}
              </span>
              <span className="block text-xs text-on-surface-variant">
                {on
                  ? "Accepted orders are booked with the cheaper courier; the seller prints the label and hands the parcel over."
                  : "Sellers arrange delivery themselves, as before. Shipments already booked keep being tracked."}
              </span>
            </span>
            <button
              type="button"
              disabled={saving}
              onClick={() => void save(
                { enabled: !on },
                on
                  ? "Turn courier automation OFF? New orders will not be booked with a courier and checkout goes back to sellers' own delivery charges."
                  : "Turn courier automation ON? Accepted orders will be booked with Delhivery/Shiprocket.",
              )}
              className={`shrink-0 rounded-xl px-4 py-2 text-sm font-bold text-white disabled:opacity-50 ${on ? "bg-red-600" : "bg-green-700"}`}
            >
              {on ? "Turn off" : "Turn on"}
            </button>
          </div>

          <div className="flex items-center justify-between gap-4 border-t border-outline-variant/30 pt-5">
            <span>
              <span className="block text-sm font-bold text-on-surface">
                Courier price at checkout: {pricingOn ? "ON" : "OFF"}
              </span>
              <span className="block text-xs text-on-surface-variant">
                The customer pays the courier&rsquo;s price and sees a delivery date. Off: each seller&rsquo;s own delivery slabs.
                {!on && " (Only works while courier automation is on.)"}
              </span>
            </span>
            <button
              type="button"
              disabled={saving || !on}
              onClick={() => void save(
                { checkoutPricing: !cfg.checkoutPricing },
                cfg.checkoutPricing ? "Stop charging courier prices at checkout?" : "Charge courier prices at checkout?",
              )}
              className="shrink-0 rounded-xl border border-outline-variant/40 bg-white px-4 py-2 text-sm font-bold disabled:opacity-50"
            >
              {cfg.checkoutPricing ? "Turn off" : "Turn on"}
            </button>
          </div>

          <div className="space-y-1 border-t border-outline-variant/30 pt-5 text-xs text-on-surface-variant">
            <p>
              Booking mode: <b>{cfg.mode === "live" ? "real bookings" : "simulated (no real courier)"}</b>
              {cfg.mode === "live" && cfg.liveSellers.length > 0 && <> — real only for {cfg.liveSellers.join(", ")}; others simulated</>}
            </p>
            {cfg.updatedBy && (
              <p>
                Last changed by {cfg.updatedBy}
                {cfg.updatedAt ? ` on ${new Date(cfg.updatedAt).toLocaleString("en-IN")}` : ""}
              </p>
            )}
          </div>
        </div>
      )}

      {message && (
        <p className={`rounded-xl px-4 py-3 text-sm ${message.ok ? "bg-green-50 text-green-800" : "bg-red-50 text-red-800"}`}>
          {message.text}
        </p>
      )}
    </div>
  );
}
