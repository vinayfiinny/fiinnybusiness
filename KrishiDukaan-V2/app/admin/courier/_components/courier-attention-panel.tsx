"use client";

import { useEffect, useState } from "react";
import { AlertTriangle, RotateCw } from "lucide-react";
import { auth } from "../../../firebase";

/**
 * Orders whose courier booking needs a person: a failed booking, one waiting
 * for an automatic retry, or an empty courier wallet. "Retry booking now"
 * (app/api/admin/courier/attention) books again at once and removes the
 * seller's unpaid "delivered it themselves" adjustment.
 */

type Row = {
  id: string; number: string; status: string; sellerName: string; customerName: string; total: number;
  stage: string; reason: string; note: string; errors: string[]; retryAt: string | null; canRetry: boolean;
};

async function call(init?: RequestInit) {
  const token = await auth.currentUser?.getIdToken();
  const res = await fetch("/api/admin/courier/attention", {
    ...init,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token ?? ""}` },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body?.error || `Request failed (${res.status})`);
  return body;
}

export function CourierAttentionPanel() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  const load = async () => {
    try {
      setRows(((await call()) as { orders: Row[] }).orders);
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : String(e) });
    }
  };
  useEffect(() => { void load(); }, []);

  const retry = async (r: Row) => {
    setBusy(r.id);
    setMessage(null);
    try {
      const out = await call({ method: "POST", body: JSON.stringify({ orderId: r.id }) });
      const removed = Number(out.removedSelfDeliveryPaise ?? 0);
      setMessage({
        ok: true,
        text: `Booking started for ${r.number}.${removed > 0 ? ` Removed the seller's unpaid self-delivery adjustment (₹${(removed / 100).toFixed(2)}).` : ""} Refresh in a minute to see the result.`,
      });
      await load();
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="space-y-3 rounded-2xl border border-outline-variant/30 bg-white p-5">
      <div className="flex items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-base font-bold text-on-surface">
          <AlertTriangle className="h-5 w-5 text-amber-600" /> Bookings that need attention
        </h2>
        <button type="button" onClick={() => void load()} className="text-xs font-bold text-primary">Refresh</button>
      </div>
      {message && (
        <p className={`rounded-xl px-3 py-2 text-sm ${message.ok ? "bg-green-50 text-green-800" : "bg-red-50 text-red-800"}`}>{message.text}</p>
      )}
      {rows === null ? (
        <p className="text-sm text-on-surface-variant">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-on-surface-variant">Nothing needs attention.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li key={r.id} className="rounded-xl border border-outline-variant/30 p-3 text-sm">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-bold">{r.number} · ₹{r.total.toLocaleString("en-IN")} · {r.sellerName} → {r.customerName}</span>
                {r.canRetry && (
                  <button
                    type="button"
                    disabled={busy === r.id}
                    onClick={() => void retry(r)}
                    className="inline-flex items-center gap-1 rounded-lg bg-primary px-3 py-1.5 text-xs font-bold text-white disabled:opacity-50"
                  >
                    <RotateCw className="h-3.5 w-3.5" /> {busy === r.id ? "Starting…" : "Retry booking now"}
                  </button>
                )}
              </div>
              <p className="mt-1 text-xs text-on-surface-variant">
                {r.stage === "booking" && r.retryAt
                  ? `Retrying automatically at ${new Date(r.retryAt).toLocaleString("en-IN")}`
                  : r.stage === "self" ? "Handed to the seller" : r.stage}
                {r.note ? ` · ${r.note}` : ""}
              </p>
              {r.errors.length > 0 && (
                <ul className="mt-1 list-disc pl-5 text-xs text-red-700">
                  {r.errors.map((e, i) => <li key={i}>{e}</li>)}
                </ul>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
