import { NextResponse } from "next/server";
import { FieldValue } from "firebase-admin/firestore";
import { getAdminDb } from "../../../lib/firebase-admin";
import { requireAdmin, requireSection } from "../../../lib/admin-auth";

/**
 * Admin switch for courier automation (_serverConfig/shipping, which clients
 * cannot read or write).
 *
 *   enabled          — Delhivery/Shiprocket are booked when a seller accepts.
 *                      Off: sellers arrange delivery themselves, as before.
 *                      Shipments already booked are still tracked/cancellable.
 *   checkoutPricing  — the customer pays the courier's price at checkout
 *                      (only while enabled). Off: each seller's own slabs.
 *
 * mode / liveSellers (simulated vs real bookings) are shown, not edited here.
 * GET: admin or team with "orders". POST: full admins only (it changes what
 * customers pay).
 */

const REF = () => getAdminDb().collection("_serverConfig").doc("shipping");

function view(d: Record<string, unknown> | undefined) {
  const x = d ?? {};
  return {
    enabled: x.enabled === true,
    checkoutPricing: x.checkoutPricing === true,
    mode: x.mode === "live" ? "live" : "simulate",
    liveSellers: Array.isArray(x.liveSellers) ? x.liveSellers.map(String) : [],
    updatedBy: typeof x.updatedBy === "string" ? x.updatedBy : null,
    updatedAt: x.updatedAt && typeof (x.updatedAt as { toMillis?: () => number }).toMillis === "function"
      ? (x.updatedAt as { toMillis: () => number }).toMillis()
      : null,
  };
}

export async function GET(request: Request) {
  const caller = await requireSection(request, "orders");
  if (caller instanceof NextResponse) return caller;
  const snap = await REF().get();
  return NextResponse.json(view(snap.data()));
}

export async function POST(request: Request) {
  const caller = await requireAdmin(request);
  if (caller instanceof NextResponse) return caller;
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body || (typeof body.enabled !== "boolean" && typeof body.checkoutPricing !== "boolean")) {
    return NextResponse.json({ error: "Send enabled and/or checkoutPricing as true/false." }, { status: 400 });
  }
  const patch: Record<string, unknown> = {
    updatedBy: caller.phone ?? caller.uid,
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (typeof body.enabled === "boolean") patch.enabled = body.enabled;
  if (typeof body.checkoutPricing === "boolean") patch.checkoutPricing = body.checkoutPricing;
  await REF().set(patch, { merge: true });
  const snap = await REF().get();
  return NextResponse.json(view(snap.data()));
}
