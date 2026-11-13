import { NextRequest, NextResponse } from "next/server";
import { getAdminDb } from "../../../lib/firebase-admin";
import { cheapestQuote, courierCheckoutEnabled, parcelKgFor, pickupPincodeFor } from "../../../lib/courier-quote";
import { deliveryByDate } from "../../../lib/delivery-eta";
import { isFreeDelivery, manufacturerPhoneOf } from "../../../lib/free-delivery";
import { parseVariantWeightKg } from "../../../utils/weight";

/**
 * GET /api/delivery/estimate?productId=…&pincode=…&seller=…&size=…
 *   → { enabled, available, free, charge, carrier, service, etaDays, deliveryBy }
 *
 * The "Deliver to 411062 — FREE delivery by Thu, 19 Nov" line on the product
 * page (web and app). Same rules as checkout (create-cart-order): the cheapest
 * courier for this seller's shop → this pincode → one pack of this size, and
 * free when the product, the store or its manufacturer's network offers it.
 * Courier answers are cached per route (lib/courier-quote), so most calls cost
 * no courier request. `enabled: false` when courier delivery is switched off.
 */

const PIN = /^[1-9]\d{5}$/;
const hits = new Map<string, { at: number; n: number }>();

function rateLimited(ip: string): boolean {
  const now = Date.now();
  const h = hits.get(ip);
  if (!h || now - h.at > 60_000) { hits.set(ip, { at: now, n: 1 }); return false; }
  h.n++;
  return h.n > 40;
}

export async function GET(req: NextRequest) {
  const q = req.nextUrl.searchParams;
  const productId = String(q.get("productId") ?? "").trim();
  const pincode = String(q.get("pincode") ?? "").trim();
  if (!productId || !PIN.test(pincode)) {
    return NextResponse.json({ error: "productId and a 6-digit pincode are required" }, { status: 400 });
  }
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0]!.trim() || "local";
  if (rateLimited(ip)) return NextResponse.json({ error: "Too many requests" }, { status: 429 });

  if (!(await courierCheckoutEnabled())) return NextResponse.json({ enabled: false });

  const db = getAdminDb();
  const snap = await db.collection("products").doc(productId).get();
  if (!snap.exists) return NextResponse.json({ error: "Product not found" }, { status: 404 });
  const product = snap.data() as Record<string, unknown>;

  const rawSeller = String(q.get("seller") ?? "").trim()
    || String(product.retailerPhone ?? product.ownerPhone ?? product.manufacturerPhone ?? "").trim();
  // Seller documents are keyed "+91XXXXXXXXXX".
  const digits = rawSeller.replace(/\D/g, "");
  const seller = digits.length >= 10 ? `+91${digits.slice(-10)}` : rawSeller;
  if (!seller) return NextResponse.json({ enabled: true, available: false });

  // This store's own copy, when it sells a copy (its free-delivery flag wins).
  let copy: Record<string, unknown> | null = null;
  for (const field of ["manufacturerProductId", "originalProductId"]) {
    if (copy) break;
    for (const owner of ["ownerPhone", "retailerPhone"]) {
      const c = await db.collection("products").where(field, "==", productId).where(owner, "==", seller).limit(1).get();
      if (!c.empty) { copy = c.docs[0]!.data(); break; }
    }
  }

  const maker = manufacturerPhoneOf(copy, product);
  const [pickup, sellerSettings, makerSettings] = await Promise.all([
    pickupPincodeFor(seller),
    db.collection("deliverySettings").doc(seller).get().then((d) => d.data() ?? null).catch(() => null),
    maker ? db.collection("deliverySettings").doc(maker).get().then((d) => d.data() ?? null).catch(() => null) : null,
  ]);
  if (!pickup) return NextResponse.json({ enabled: true, available: false });

  const variants = Array.isArray(product.variants) ? (product.variants as Array<Record<string, unknown>>) : [];
  const size = String(q.get("size") ?? "").trim() || String(product.unit ?? variants[0]?.unit ?? variants[0]?.label ?? "");
  const kg = parcelKgFor([{ qty: 1, weightKg: parseVariantWeightKg(size) }]);
  const price = Number(copy?.price ?? product.price ?? 0);
  const free = isFreeDelivery({
    productFree: (copy?.freeDelivery ?? product.freeDelivery) === true,
    seller: sellerSettings,
    manufacturer: makerSettings,
  });

  const quote = await cheapestQuote(pickup, pincode, kg, price);
  if (!quote) return NextResponse.json({ enabled: true, available: false, free });

  return NextResponse.json(
    {
      enabled: true,
      available: true,
      free,
      charge: free ? 0 : Math.ceil(quote.cost),
      carrier: quote.carrier,
      service: quote.service,
      etaDays: quote.etaDays ?? null,
      deliveryBy: deliveryByDate(quote.etaDays),
      pincode,
    },
    { headers: { "Cache-Control": "private, max-age=300" } },
  );
}
