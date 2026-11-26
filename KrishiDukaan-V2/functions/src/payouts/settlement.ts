/**
 * Who gets which rupee of an online order: the settlement plan.
 *
 * Design: docs/delivery-money-architecture.md. Pure: no Firebase, no network.
 * Imported by the website server (checkout, refunds, reassignment, payout run,
 * seller earnings) AND by Cloud Functions (courier engine, payout jobs, stats),
 * so there is exactly one copy of these rules. The Flutter app mirrors only the
 * reader (settlementNet) and its tests pin the same numbers.
 *
 * THE RULES (owner, updated 25 Nov 2026)
 *   - Commission is a % of the seller's GOODS (items + added GST), never of
 *     delivery.
 *   - The customer's delivery money stays with KrishiDukan regardless of who
 *     delivers. It never enters a new seller Route transfer. The seller's
 *     gateway fee is calculated only on goods.
 *   - A seller's free/partial delivery offer is their share of the courier
 *     cost, deducted from their transfer at checkout.
 *   - Platform campaign (Option B): the seller still pays what they offered;
 *     the platform pays the rest, up to a per-order cap.
 *
 * MONEY IS INTEGER PAISE. Deductions round UP (one paise at most against the
 * seller), so a transfer can never exceed what the platform holds.
 *
 * THE INVARIANT
 *   The checkout transfer is the least the seller is owed. Anything that
 *   happens later (no courier after all, a cheaper booking) only ADDS money for
 *   the seller, as an adjustment. The platform never has to claw back in the
 *   normal flow, so a failed step leaves a seller owed — visible and retried —
 *   never overpaid.
 */

/** settings/route rates: the same shape app/lib/route-split.ts reads. */
export interface SplitRates {
  /** Platform commission, % of goods. */
  commissionPercent: number;
  /** Razorpay fee %, before GST. */
  gatewayFeePercent: number;
  /** GST on the Razorpay fee, %. */
  gatewayFeeGstPercent: number;
  /** "seller" = the seller's transfer bears the fee on what they receive. */
  feeBearer: "seller" | "platform";
}

export const SETTLEMENT_VERSION = 2;

/** A percentage of a paise amount, rounded UP to a whole paise (route-split.ts pctOfPaise). */
export function pctOfPaise(paise: number, percent: number): number {
  if (!(percent > 0) || !(paise > 0)) return 0;
  return Math.ceil((paise * Math.round(percent * 100)) / 10_000);
}

/** Razorpay's fee on an amount, GST included, rounded up (the same two steps as route-split.ts). */
export function gatewayFeePaise(paise: number, rates: SplitRates): number {
  const base = pctOfPaise(paise, rates.gatewayFeePercent);
  return base + pctOfPaise(base, rates.gatewayFeeGstPercent);
}

/** The gateway fee as a fraction of the amount charged (2% × 1.18 = 0.0236). */
export function gatewayRate(rates: SplitRates): number {
  const r = (Math.max(0, rates.gatewayFeePercent) / 100) * (1 + Math.max(0, rates.gatewayFeeGstPercent) / 100);
  return Math.min(0.5, r);
}

/**
 * What to charge the customer so that, after Razorpay takes its fee on it, the
 * platform still has `baseRupees`. Whole rupees, rounded up; 0 stays 0.
 */
export function grossUpForGateway(baseRupees: number, rates: SplitRates): number {
  if (!(baseRupees > 0)) return 0;
  const r = gatewayRate(rates);
  // Rounded to 6 places first so 100 / (1 - 0.0236) never becomes 102.4170...01.
  return Math.ceil(Number((baseRupees / (1 - r)).toFixed(6)));
}

const toPaise = (rupees: number) => Math.round((Number(rupees) || 0) * 100);
const clampShare = (s: number) => (Number.isFinite(s) ? Math.min(1, Math.max(0, s)) : 0);
const r2 = (n: number) => Math.round(n * 100) / 100;

// ─── Courier cost split (checkout) ────────────────────────────────────────

export interface CampaignTerms {
  /** Most the platform covers on one parcel, ₹. 0 = no cap. */
  maxPerOrder: number;
}

export interface CourierSplit {
  /** The seller's share of the courier cost, ₹ (their offer). */
  sellerCourier: number;
  /** The platform's share under a campaign, ₹. */
  campaign: number;
  /** What the customer owes towards the courier, before the gateway gross-up, ₹. */
  customerBase: number;
  /** What the customer is charged for delivery, gross-up included, whole ₹. */
  customerDelivery: number;
}

/**
 * Divides one parcel's courier price between the seller (their offer), the
 * platform (a campaign) and the customer (the rest, plus the gateway fee on it).
 *
 *   cost         the courier quote, ₹ (already rounded up to a whole rupee)
 *   sellerShare  0..1, from the seller's offers (lib/cart-pricing parcelShare)
 *   campaign     the live campaign's terms, or null
 */
export function splitCourierCost(input: {
  cost: number;
  sellerShare: number;
  campaign?: CampaignTerms | null;
  rates: SplitRates;
}): CourierSplit {
  const cost = Math.max(0, Number(input.cost) || 0);
  const share = clampShare(input.sellerShare);
  const sellerCourier = r2(cost * share);
  const remaining = r2(cost - sellerCourier);
  let campaign = 0;
  if (input.campaign) {
    const cap = Number(input.campaign.maxPerOrder) > 0 ? Number(input.campaign.maxPerOrder) : Infinity;
    campaign = r2(Math.min(cap, remaining));
  }
  const customerBase = r2(Math.max(0, remaining - campaign));
  return {
    sellerCourier,
    campaign,
    customerBase,
    customerDelivery: grossUpForGateway(customerBase, input.rates),
  };
}

// ─── The plan ─────────────────────────────────────────────────────────────

export type DeliveryTo = "platform" | "seller";

export interface SettlementPlan {
  v: number;
  /** Whose plan this is: the seller's phone, last 10 digits. */
  sellerKey: string;
  /** Items + added GST: what the seller sold. */
  goodsPaise: number;
  /** "platform": a courier was priced at checkout and the platform ships. */
  deliveryTo: DeliveryTo;
  /** What the customer paid for delivery (gross-up included). */
  customerDeliveryPaise: number;
  /** Legacy v1 only: delivery money included in the seller transfer. Always 0 in v2. */
  keptDeliveryPaise: number;
  commissionPaise: number;
  gatewayFeePaise: number;
  /** The seller's share of the courier cost, from their offer. */
  sellerCourierPaise: number;
  /** The platform's planned campaign share (budget; actual is set at booking). */
  campaignPaise: number;
  /** The checkout quote the split was made on, paise (0 when the seller delivers). */
  courierQuotePaise: number;
  /** The seller's offer share 0..1, kept so a booking at a different price can be re-split. */
  sellerShare: number;
  /** Whether a campaign applied to this parcel. */
  campaignApplied: boolean;
  /** What the seller's Route transfer is for. 0 when fees eat it all. */
  transferPaise: number;
  /** The rates used, so later readers never re-derive with a changed rate. */
  rates: SplitRates;
}

export function planSettlement(input: {
  sellerKey: string;
  /** subtotal + gstAdded, ₹ */
  goods: number;
  deliveryTo: DeliveryTo;
  /** What the customer is charged for this seller's delivery, ₹. */
  customerDelivery: number;
  /** The seller's share of the courier cost, ₹ (0 when the seller delivers). */
  sellerCourier?: number;
  /** The platform's campaign share, ₹. */
  campaign?: number;
  courierQuote?: number;
  sellerShare?: number;
  rates: SplitRates;
}): SettlementPlan {
  const rates = normaliseRates(input.rates);
  const goodsPaise = Math.max(0, toPaise(input.goods));
  const customerDeliveryPaise = Math.max(0, toPaise(input.customerDelivery));
  const platformShips = input.deliveryTo === "platform";
  const keptDeliveryPaise = 0;
  const sellerCourierPaise = platformShips ? Math.max(0, toPaise(input.sellerCourier ?? 0)) : 0;
  const campaignPaise = platformShips ? Math.max(0, toPaise(input.campaign ?? 0)) : 0;
  const commissionPaise = pctOfPaise(goodsPaise, rates.commissionPercent);
  const gatewayFee = rates.feeBearer === "seller" ? gatewayFeePaise(goodsPaise, rates) : 0;
  const transferPaise = Math.max(
    0,
    goodsPaise + keptDeliveryPaise - commissionPaise - gatewayFee - sellerCourierPaise,
  );
  return {
    v: SETTLEMENT_VERSION,
    sellerKey: key10(input.sellerKey),
    goodsPaise,
    deliveryTo: platformShips ? "platform" : "seller",
    customerDeliveryPaise,
    keptDeliveryPaise,
    commissionPaise,
    gatewayFeePaise: gatewayFee,
    sellerCourierPaise,
    campaignPaise,
    courierQuotePaise: platformShips ? Math.max(0, toPaise(input.courierQuote ?? 0)) : 0,
    sellerShare: platformShips ? clampShare(input.sellerShare ?? 0) : 0,
    campaignApplied: platformShips && campaignPaise > 0,
    transferPaise,
    rates,
  };
}

/**
 * The plan for a NEW seller who takes over a reassigned order. They never made
 * the delivery offer, so they pay no courier share (the platform pays the
 * courier, as the reassignment rules already say). Goods and delivery mode are
 * the original order's; the rates are today's.
 */
export function planForReassignedSeller(plan: SettlementPlan, newSellerKey: string, rates: SplitRates): SettlementPlan {
  return planSettlement({
    sellerKey: newSellerKey,
    goods: plan.goodsPaise / 100,
    deliveryTo: plan.deliveryTo,
    customerDelivery: plan.customerDeliveryPaise / 100,
    sellerCourier: 0,
    campaign: plan.campaignPaise / 100,
    courierQuote: plan.courierQuotePaise / 100,
    sellerShare: 0,
    rates,
  });
}

// ─── After payment: adjustments (only ever in the seller's favour) ────────

export type AdjustmentKind = "self_delivery" | "courier_share_refund";

export interface SettlementAdjustment {
  /** Idempotency key: one adjustment of a kind per seller per order. */
  id: string;
  sellerKey: string;
  kind: AdjustmentKind;
  /** Net amount owed to the seller, paise, fees already taken. */
  netPaise: number;
  at: string;
  note?: string;
  /** Set once paid. */
  paidTransferId?: string;
  paidAt?: string;
  paidVia?: "topup" | "payout_run" | "after_kyc";
}

/**
 * The platform was going to ship but no courier booked. A v2 plan keeps the
 * customer's delivery charge with KrishiDukan; only the seller's unused courier
 * offer is returned. A v1 plan preserves its original promise for orders paid
 * before this change.
 */
export function selfDeliveryAdjustment(plan: SettlementPlan, sellerKey: string, at: string): SettlementAdjustment | null {
  if (plan.deliveryTo !== "platform") return null;
  const key = key10(sellerKey);
  const delivery = plan.v === 1 ? plan.customerDeliveryPaise : 0;
  const feeOnDelivery = plan.v === 1 && plan.rates.feeBearer === "seller" ? gatewayFeePaise(delivery, plan.rates) : 0;
  // The share comes back only to the seller who made the offer.
  const share = key === plan.sellerKey ? plan.sellerCourierPaise : 0;
  const netPaise = Math.max(0, delivery - feeOnDelivery) + share;
  if (netPaise <= 0) return null;
  return {
    id: `self_delivery:${key}`,
    sellerKey: key,
    kind: "self_delivery",
    netPaise,
    at,
    note: "No courier booked; the seller delivered.",
  };
}

/** The seller's share of an actual courier cost: never more than they agreed at checkout. */
export function actualSellerCourierPaise(plan: SettlementPlan, actualCostRupees: number): number {
  if (plan.deliveryTo !== "platform" || plan.sellerCourierPaise <= 0) return 0;
  const actual = Math.max(0, Math.round(plan.sellerShare * Math.max(0, Number(actualCostRupees) || 0) * 100));
  return Math.min(plan.sellerCourierPaise, actual);
}

/** Booked cheaper than the checkout quote: the part of the seller's share they no longer owe. */
export function courierShareRefund(
  plan: SettlementPlan,
  actualCostRupees: number,
  sellerKey: string,
  at: string,
): SettlementAdjustment | null {
  if (key10(sellerKey) !== plan.sellerKey) return null;
  const diff = plan.sellerCourierPaise - actualSellerCourierPaise(plan, actualCostRupees);
  if (diff <= 0) return null;
  return {
    id: `courier_share_refund:${plan.sellerKey}`,
    sellerKey: plan.sellerKey,
    kind: "courier_share_refund",
    netPaise: diff,
    at,
    note: "Courier cost less than quoted at checkout.",
  };
}

/** The platform's side of one booking, for the delivery ledger and campaign budget. */
export function bookingSplit(plan: SettlementPlan, actualCostRupees: number): {
  costPaise: number;
  /** What the customer paid towards delivery, net of the gateway fee on it. */
  customerNetPaise: number;
  sellerPaise: number;
  campaignPaise: number;
  /** Platform's own money on this parcel (cost − customer − seller − campaign); negative = surplus. */
  platformPaise: number;
} {
  const costPaise = Math.max(0, Math.round((Number(actualCostRupees) || 0) * 100));
  const customerNetPaise = Math.max(0, plan.customerDeliveryPaise - gatewayFeePaise(plan.customerDeliveryPaise, plan.rates));
  const sellerPaise = actualSellerCourierPaise(plan, actualCostRupees);
  const leftAfter = Math.max(0, costPaise - customerNetPaise - sellerPaise);
  const campaignPaise = plan.campaignApplied ? leftAfter : 0;
  return {
    costPaise,
    customerNetPaise,
    sellerPaise,
    campaignPaise,
    platformPaise: costPaise - customerNetPaise - sellerPaise - campaignPaise,
  };
}

// ─── Readers: what the seller is owed ─────────────────────────────────────

export interface SettlementView {
  /** Goods + delivery money that is theirs, before deductions. */
  grossPaise: number;
  commissionPaise: number;
  gatewayFeePaise: number;
  /** Their courier share (free/partial delivery offer). */
  deliveryPaise: number;
  /** What their checkout transfer pays (after any partial refund). */
  transferPaise: number;
  /** Adjustments owed to this seller, paid or not. */
  adjustmentsPaise: number;
  /** Of those, not yet paid. */
  adjustmentsDuePaise: number;
  /** Everything this seller gets for the order. */
  netPaise: number;
}

/**
 * What the CURRENT seller of an order is owed, from its plan and adjustments.
 * A partial refund comes off the goods (commission and gateway fee follow it,
 * as the payout run already does for partial refunds); a refund of everything
 * leaves nothing.
 */
export function settlementView(
  plan: SettlementPlan,
  adjustments: readonly SettlementAdjustment[] | null | undefined,
  opts: { sellerKey?: string; refundedPaise?: number } = {},
): SettlementView {
  const rates = normaliseRates(plan.rates);
  const refunded = Math.max(0, Math.round(Number(opts.refundedPaise) || 0));
  const goods = Math.max(0, plan.goodsPaise - refunded);
  const kept = refunded >= plan.goodsPaise ? Math.max(0, plan.keptDeliveryPaise - (refunded - plan.goodsPaise)) : plan.keptDeliveryPaise;
  const commission = pctOfPaise(goods, rates.commissionPercent);
  const gateway = rates.feeBearer === "seller" ? gatewayFeePaise(goods + kept, rates) : 0;
  const delivery = goods > 0 ? plan.sellerCourierPaise : 0;
  const transfer = Math.max(0, goods + kept - commission - gateway - delivery);
  const who = key10(opts.sellerKey ?? plan.sellerKey);
  const mine = (adjustments ?? []).filter((a) => key10(a.sellerKey) === who && a.netPaise > 0);
  const adjustmentsPaise = mine.reduce((s, a) => s + a.netPaise, 0);
  const adjustmentsDuePaise = mine.filter((a) => !a.paidTransferId).reduce((s, a) => s + a.netPaise, 0);
  return {
    grossPaise: goods + kept,
    commissionPaise: commission,
    gatewayFeePaise: gateway,
    deliveryPaise: delivery,
    transferPaise: transfer,
    adjustmentsPaise,
    adjustmentsDuePaise,
    netPaise: transfer + adjustmentsPaise,
  };
}

/**
 * A payout made from the platform's balance (the admin payout run, the
 * after-KYC job): it pays the plan AND every adjustment still owed, in one
 * transfer, for a seller who had no Route transfer at checkout. Same shape as
 * route-split's SellerSplit, so the payout code records it the same way.
 */
export function balancePayoutSplit(
  plan: SettlementPlan,
  adjustments: readonly SettlementAdjustment[] | null | undefined,
  opts: { sellerKey?: string; refundedPaise?: number } = {},
): { grossPaise: number; commissionPaise: number; gatewayFeePaise: number; deliveryPaise: number; adjustmentsPaise: number; transferPaise: number } {
  const v = settlementView(plan, adjustments, opts);
  return {
    grossPaise: v.grossPaise,
    commissionPaise: v.commissionPaise,
    gatewayFeePaise: v.gatewayFeePaise,
    deliveryPaise: v.deliveryPaise,
    adjustmentsPaise: v.adjustmentsDuePaise,
    transferPaise: v.transferPaise + v.adjustmentsDuePaise,
  };
}

/** The adjustments list with this seller's unpaid ones marked paid by `transferId`. */
export function markAdjustmentsPaid(
  list: readonly SettlementAdjustment[],
  sellerKey: string,
  transferId: string,
  at: string,
  via: NonNullable<SettlementAdjustment["paidVia"]>,
): SettlementAdjustment[] {
  const who = key10(sellerKey);
  return list.map((a) =>
    key10(a.sellerKey) === who && !a.paidTransferId ? { ...a, paidTransferId: transferId, paidAt: at, paidVia: via } : a);
}

/**
 * The customer-facing amount behind this seller's part of the payment: their
 * goods plus what the customer paid for delivery. A refund defaults to this
 * (less the delivery once a courier has been booked, as today).
 */
export function customerPaidPaise(plan: SettlementPlan): number {
  return plan.goodsPaise + plan.customerDeliveryPaise;
}

// ─── Platform free-delivery campaign ──────────────────────────────────────

/** _serverConfig/deliveryCampaign, as an admin saves it. */
export interface CampaignDoc {
  active?: unknown;
  name?: unknown;
  /** ISO string or Firestore Timestamp. */
  startsAt?: unknown;
  endsAt?: unknown;
  /** ₹ the platform covers per parcel at most; 0 = no cap. */
  maxPerOrder?: unknown;
  /** ₹ total; 0 = no limit. */
  budget?: unknown;
  /** Server-kept: what bookings under the campaign have cost the platform. */
  spentPaise?: unknown;
}

export interface ActiveCampaign extends CampaignTerms {
  name: string;
}

export function toMillis(v: unknown): number {
  if (!v) return 0;
  if (typeof v === "number") return v;
  if (typeof v === "string") return Date.parse(v) || 0;
  const t = v as { toMillis?: () => number; seconds?: number; _seconds?: number };
  if (typeof t.toMillis === "function") return t.toMillis();
  const s = t.seconds ?? t._seconds;
  return typeof s === "number" ? s * 1000 : 0;
}

/**
 * The campaign in force at `nowMs`, or null. Off unless switched on, inside its
 * dates and under budget; a missing or unreadable date means "not running"
 * rather than "running forever".
 */
export function activeCampaign(doc: CampaignDoc | null | undefined, nowMs: number): ActiveCampaign | null {
  if (!doc || doc.active !== true) return null;
  const start = toMillis(doc.startsAt);
  const end = toMillis(doc.endsAt);
  if (!(start > 0) || !(end > start) || nowMs < start || nowMs >= end) return null;
  const budget = Number(doc.budget);
  const spent = Number(doc.spentPaise) || 0;
  if (Number.isFinite(budget) && budget > 0 && spent >= Math.round(budget * 100)) return null;
  const cap = Number(doc.maxPerOrder);
  return {
    name: String(doc.name ?? "").trim().slice(0, 60) || "Free delivery",
    maxPerOrder: Number.isFinite(cap) && cap > 0 ? cap : 0,
  };
}

/**
 * An admin's campaign form, checked. Errors are sentences for the admin.
 * Dates are ISO strings; the end must be after the start and in the future.
 */
export type CampaignInput = { active: boolean; name: string; startsAt: string; endsAt: string; maxPerOrder: number; budget: number };

/** Flat on purpose: the website compiles with strict: false, where a union on `ok` doesn't narrow. */
export function validateCampaignInput(raw: Record<string, unknown> | null | undefined, nowMs: number):
  { ok: boolean; value?: CampaignInput; error?: string } {
  const d = raw ?? {};
  const name = String(d.name ?? "").trim().slice(0, 60);
  if (!name) return { ok: false, error: "Give the campaign a name customers will see, e.g. Diwali free delivery." };
  const start = Date.parse(String(d.startsAt ?? ""));
  const end = Date.parse(String(d.endsAt ?? ""));
  if (!Number.isFinite(start) || !Number.isFinite(end)) return { ok: false, error: "Choose a start and an end date." };
  if (end <= start) return { ok: false, error: "The end must be after the start." };
  if (end <= nowMs) return { ok: false, error: "The end date has already passed." };
  const money = (v: unknown, label: string): number | string => {
    if (v === undefined || v === null || v === "") return 0;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) return `${label} must be 0 or more.`;
    return Math.round(n * 100) / 100;
  };
  const cap = money(d.maxPerOrder, "Most per order");
  if (typeof cap === "string") return { ok: false, error: cap };
  const budget = money(d.budget, "Total budget");
  if (typeof budget === "string") return { ok: false, error: budget };
  return {
    ok: true,
    value: {
      active: d.active === true,
      name,
      startsAt: new Date(start).toISOString(),
      endsAt: new Date(end).toISOString(),
      maxPerOrder: cap,
      budget,
    },
  };
}

// ─── Delivery ledger: reconciliation and courier wallets ──────────────────

export interface LedgerEntry {
  kind: "booked" | "cancelled" | "self_delivery";
  at: string;
  carrier?: string;
  simulated?: boolean;
  costPaise?: number;
  customerNetPaise?: number;
  sellerPaise?: number;
  campaignPaise?: number;
  platformPaise?: number;
  toSellerPaise?: number;
}

export interface LedgerWeek {
  /** Monday of the week, YYYY-MM-DD, India time. */
  weekOf: string;
  /** Bookings less cancellations. */
  parcels: number;
  /** What the couriers charged. */
  courierCostPaise: number;
  /** Delivery money customers paid, net of the gateway fee on it. */
  customerPaise: number;
  /** Sellers' shares (their delivery offers). */
  sellerPaise: number;
  campaignPaise: number;
  /** Platform's own money beyond the campaign (negative = it kept a surplus). */
  platformPaise: number;
  /** Delivery money handed to sellers who delivered themselves. */
  toSellerPaise: number;
}

const IST_MS = 5.5 * 60 * 60 * 1000;

/** Monday (India time) of the week containing `ms`, YYYY-MM-DD. */
export function weekOfIst(ms: number): string {
  const d = new Date(ms + IST_MS);
  const dow = (d.getUTCDay() + 6) % 7; // Monday = 0
  const monday = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - dow));
  return monday.toISOString().slice(0, 10);
}

/** Weekly totals, newest first. Simulated (test) bookings are left out: they cost nothing. */
export function summariseLedger(entries: readonly LedgerEntry[]): LedgerWeek[] {
  const weeks = new Map<string, LedgerWeek>();
  for (const e of entries) {
    if (e.simulated === true) continue;
    const ms = Date.parse(e.at);
    if (!Number.isFinite(ms)) continue;
    const key = weekOfIst(ms);
    const w = weeks.get(key) ?? {
      weekOf: key, parcels: 0, courierCostPaise: 0, customerPaise: 0, sellerPaise: 0,
      campaignPaise: 0, platformPaise: 0, toSellerPaise: 0,
    };
    const n = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);
    if (e.kind === "booked") w.parcels += 1;
    if (e.kind === "cancelled") w.parcels -= 1;
    w.courierCostPaise += n(e.costPaise);
    w.customerPaise += n(e.customerNetPaise);
    w.sellerPaise += n(e.sellerPaise);
    w.campaignPaise += n(e.campaignPaise);
    w.platformPaise += n(e.platformPaise);
    w.toSellerPaise += n(e.toSellerPaise);
    weeks.set(key, w);
  }
  return Array.from(weeks.values()).sort((a, b) => (a.weekOf < b.weekOf ? 1 : -1));
}

/**
 * A wallet with no balance API (Delhivery): the balance an admin last read off
 * the courier's panel, less what real bookings on that courier have cost since.
 */
export function estimateWalletPaise(recordedPaise: number, recordedAtMs: number, entries: readonly LedgerEntry[], carrier: string): number {
  let spent = 0;
  for (const e of entries) {
    if (e.simulated === true || e.carrier !== carrier) continue;
    if (e.kind !== "booked" && e.kind !== "cancelled") continue;
    const ms = Date.parse(e.at);
    if (!Number.isFinite(ms) || ms <= recordedAtMs) continue;
    spent += Number(e.costPaise) || 0;
  }
  return Math.round(recordedPaise - spent);
}

/** Alert when below the threshold, at most once per `everyMs` per wallet. */
export function walletAlertDue(balancePaise: number | null, thresholdRupees: number, lastAlertMs: number, nowMs: number, everyMs = 12 * 60 * 60 * 1000): boolean {
  if (balancePaise === null || !(thresholdRupees > 0)) return false;
  if (balancePaise >= Math.round(thresholdRupees * 100)) return false;
  return !(lastAlertMs > 0 && nowMs - lastAlertMs < everyMs);
}

// ─── Parsing (documents are untrusted shapes) ─────────────────────────────

export function normaliseRates(raw: Partial<SplitRates> | null | undefined): SplitRates {
  const pct = (v: unknown, d: number) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= 0 && n <= 100 ? n : d;
  };
  return {
    commissionPercent: pct(raw?.commissionPercent, 0),
    gatewayFeePercent: pct(raw?.gatewayFeePercent, 0),
    gatewayFeeGstPercent: pct(raw?.gatewayFeeGstPercent, 0),
    feeBearer: raw?.feeBearer === "platform" ? "platform" : "seller",
  };
}

/** A stored plan, or null when the document has none or a malformed one. */
export function readPlan(raw: unknown): SettlementPlan | null {
  const d = raw as Partial<SettlementPlan> | null | undefined;
  if (!d || typeof d !== "object" || (d.v !== 1 && d.v !== SETTLEMENT_VERSION)) return null;
  const int = (v: unknown) => (Number.isInteger(v) && (v as number) >= 0 ? (v as number) : null);
  const goods = int(d.goodsPaise);
  const transfer = int(d.transferPaise);
  if (goods === null || transfer === null) return null;
  if (d.deliveryTo !== "platform" && d.deliveryTo !== "seller") return null;
  return {
    v: d.v,
    sellerKey: key10(d.sellerKey),
    goodsPaise: goods,
    deliveryTo: d.deliveryTo,
    customerDeliveryPaise: int(d.customerDeliveryPaise) ?? 0,
    keptDeliveryPaise: int(d.keptDeliveryPaise) ?? 0,
    commissionPaise: int(d.commissionPaise) ?? 0,
    gatewayFeePaise: int(d.gatewayFeePaise) ?? 0,
    sellerCourierPaise: int(d.sellerCourierPaise) ?? 0,
    campaignPaise: int(d.campaignPaise) ?? 0,
    courierQuotePaise: int(d.courierQuotePaise) ?? 0,
    sellerShare: clampShare(Number(d.sellerShare)),
    campaignApplied: d.campaignApplied === true,
    transferPaise: transfer,
    rates: normaliseRates(d.rates),
  };
}

export function readAdjustments(raw: unknown): SettlementAdjustment[] {
  if (!Array.isArray(raw)) return [];
  const out: SettlementAdjustment[] = [];
  for (const a of raw as Array<Partial<SettlementAdjustment> | null>) {
    if (!a || typeof a.id !== "string" || !Number.isInteger(a.netPaise) || (a.netPaise as number) <= 0) continue;
    if (a.kind !== "self_delivery" && a.kind !== "courier_share_refund") continue;
    out.push({
      id: a.id,
      sellerKey: key10(a.sellerKey),
      kind: a.kind,
      netPaise: a.netPaise as number,
      at: String(a.at ?? ""),
      ...(a.note ? { note: String(a.note) } : {}),
      ...(a.paidTransferId ? { paidTransferId: String(a.paidTransferId), paidAt: String(a.paidAt ?? ""), paidVia: a.paidVia } : {}),
    });
  }
  return out;
}

/** Adds an adjustment unless one with the same id is already there. */
export function withAdjustment(
  list: readonly SettlementAdjustment[],
  adj: SettlementAdjustment | null,
): { list: SettlementAdjustment[]; added: boolean } {
  if (!adj || list.some((a) => a.id === adj.id)) return { list: [...list], added: false };
  return { list: [...list, adj], added: true };
}

/**
 * A seller's key in one form: a phone becomes its last 10 digits (so
 * "+918658031942" and "8658031942" match), anything else (a user id, for a
 * seller with no phone on file) is kept as written. Never mixes the two: the
 * digits inside a user id are not a phone number.
 */
export function key10(v: unknown): string {
  const raw = String(v ?? "").trim();
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  return /^[+\d\s()-]+$/.test(raw) && digits.length >= 10 ? digits.slice(-10) : raw;
}

/**
 * An admin retries the courier for an order that had fallen back to the
 * seller: the seller will not deliver it after all, so their self-delivery
 * adjustment goes — but only while unpaid. A paid one stays and the retry is
 * refused, so money already sent is never silently orphaned.
 */
export function withoutUnpaidAdjustment(
  list: readonly SettlementAdjustment[],
  kind: AdjustmentKind,
  sellerKey: string,
): { list: SettlementAdjustment[]; removed: SettlementAdjustment[]; paid: SettlementAdjustment[] } {
  const who = key10(sellerKey);
  const mine = (a: SettlementAdjustment) => a.kind === kind && key10(a.sellerKey) === who;
  return {
    list: list.filter((a) => !mine(a) || !!a.paidTransferId),
    removed: list.filter((a) => mine(a) && !a.paidTransferId),
    paid: list.filter((a) => mine(a) && !!a.paidTransferId),
  };
}
