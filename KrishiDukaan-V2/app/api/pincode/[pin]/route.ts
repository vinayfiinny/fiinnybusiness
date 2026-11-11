import { NextRequest, NextResponse } from "next/server";
import { getAdminDb } from "../../../lib/firebase-admin";

/**
 * GET /api/pincode/{pin} → { pincode, city, district, state, areas[] }
 *
 * Fills the checkout address from the pincode (web cart and app checkout), so
 * the customer types only their area/locality. Source: India Post's public
 * pincode directory. A pincode's district/state never change, so each answer is
 * kept in Firestore (pincodes/{pin}) and every later lookup is one read.
 * 404 when the pincode doesn't exist; the form then stays editable as before.
 */

type PinInfo = { pincode: string; city: string; district: string; taluka: string; state: string; areas: string[] };
const mem = new Map<string, PinInfo>();
// "Not found" is remembered briefly only: India Post can fail for a moment, and a
// real pincode must not stay "not found" until the server restarts.
const missUntil = new Map<string, number>();

const tidy = (v: unknown) => {
  const s = String(v ?? "").trim();
  return s && s.toUpperCase() !== "NA" ? s : "";
};

async function fromIndiaPost(pin: string): Promise<PinInfo | null> {
  const res = await fetch(`https://api.postalpincode.in/pincode/${pin}`, {
    signal: AbortSignal.timeout(5000),
    cache: "no-store",
  });
  const body = (await res.json()) as Array<{ Status?: string; PostOffice?: Array<Record<string, unknown>> | null }>;
  const offices = body?.[0]?.Status === "Success" ? body[0].PostOffice ?? [] : [];
  if (!offices.length) return null;
  const first = offices[0]!;
  const district = tidy(first.District);
  // India Post has no "city". Its Block is the taluka/mandal, which is wrong for
  // towns (Gurugram → "Sector -45", Hyderabad → "Asifnagar"), so the city is the
  // district and the taluka is returned on its own.
  const taluka = offices.map((o) => tidy(o.Block)).find(Boolean) ?? "";
  return {
    pincode: pin,
    city: district,
    district,
    taluka,
    state: tidy(first.State),
    areas: Array.from(new Set(offices.map((o) => tidy(o.Name)).filter(Boolean))).slice(0, 25),
  };
}

export async function GET(_req: NextRequest, { params }: { params: { pin: string } }) {
  const pin = String(params.pin ?? "").trim();
  if (!/^[1-9]\d{5}$/.test(pin)) {
    return NextResponse.json({ error: "Enter a valid 6-digit pincode." }, { status: 400 });
  }
  const headers = { "Cache-Control": "public, max-age=86400, s-maxage=604800" };
  const hit = mem.get(pin);
  if (hit) return NextResponse.json(hit, { headers });
  if ((missUntil.get(pin) ?? 0) > Date.now()) {
    return NextResponse.json({ error: "Pincode not found." }, { status: 404 });
  }
  const ref = getAdminDb().collection("pincodes").doc(pin);
  try {
    const saved = (await ref.get()).data() as PinInfo | undefined;
    if (saved?.state && saved.taluka !== undefined) {
      mem.set(pin, saved);
      return NextResponse.json(saved, { headers });
    }
  } catch { /* fall through to India Post */ }
  try {
    const info = await fromIndiaPost(pin);
    if (!info) {
      missUntil.set(pin, Date.now() + 10 * 60 * 1000);
      return NextResponse.json({ error: "Pincode not found." }, { status: 404 });
    }
    mem.set(pin, info);
    ref.set({ ...info, fetchedAt: new Date().toISOString() }).catch(() => undefined);
    return NextResponse.json(info, { headers });
  } catch (e) {
    console.warn("[pincode] lookup failed", pin, e);
    return NextResponse.json({ error: "Pincode lookup is unavailable. Please type the address." }, { status: 503 });
  }
}
