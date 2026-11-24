/**
 * What a retailer owes, computed one way everywhere: the retailer page's
 * summary cards and Overview (WorklistDetailsPage), the account statement PDF
 * (statementGenerator), and the ERP app's retailer portal, which mirrors this
 * file rule for rule (krishidukan_erp_app/lib/features/portal/portal_models.dart).
 *
 *   debit   every live bill (not deleted, not cancelled)
 *   credit  every payment record (retailers/{id}/payments, not deleted)
 *   credit  money marked paid ON a bill that no payment record covers —
 *           e.g. a cash bill settled at the counter: the bill is saved Paid
 *           with amountPaid, but no payment record is written for it.
 *   outstanding = debits − credits (never below 0)
 *
 * Why (Nov 2026 audit of the master tenant, 116 retailers): the page used to
 * add up payment records only, so 26 retailers whose bills were paid at
 * billing showed ₹1.1 lakh as owed that had already been collected, and 60
 * cancelled bills still counted as sales. A bill is "covered" when a payment
 * record points at it (orderId / linkedOrderIds) or it lists linkedPaymentIds;
 * its amountPaid then came from those records and is not counted twice.
 * Old payment records from before linking existed (no linkedOrderIds, no
 * orderId, no unallocatedAmount) may be the very money marked on a bill, so
 * they cover uncovered bill money first, oldest bill first; only the rest is
 * added (real case: a ₹6,000 bill marked paid + a ₹6,000 old record = once).
 */

/* eslint-disable @typescript-eslint/no-explicit-any -- reads loosely-typed Firestore docs */

const num = (v: unknown): number => {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
};

/** grandTotal → netAmount → totalAmount, as everywhere else on the page. */
export const billTotal = (o: any): number => num(o?.grandTotal ?? o?.netAmount ?? o?.totalAmount ?? 0);

export const isCancelledBill = (o: any): boolean =>
    ['cancelled', 'canceled', 'rejected'].includes(String(o?.status ?? '').trim().toLowerCase());

/** Bills that count towards what is owed. */
export const liveBills = <T extends Record<string, any>>(orders: T[]): T[] =>
    orders.filter((o) => o?.deleted !== true && !isCancelledBill(o));

const livePayments = <T extends Record<string, any>>(payments: T[]): T[] =>
    payments.filter((p) => p?.deleted !== true);

/** Bill ids whose amountPaid came from payment records (so it is not counted again). */
function coveredBillIds(orders: Record<string, any>[], payments: Record<string, any>[]): Set<string> {
    const ids = new Set<string>();
    for (const p of payments) {
        if (p?.orderId) ids.add(String(p.orderId));
        for (const id of Array.isArray(p?.linkedOrderIds) ? p.linkedOrderIds : []) ids.add(String(id));
    }
    for (const o of orders) {
        if (Array.isArray(o?.linkedPaymentIds) && o.linkedPaymentIds.length > 0) ids.add(String(o.id));
    }
    return ids;
}

export interface PaidAtBilling {
    order: Record<string, any>;
    amount: number;
}

/** A payment record from before payments were linked to bills. */
const isOldUnlinkedPayment = (p: any): boolean =>
    !('linkedOrderIds' in (p ?? {})) && !p?.orderId && !('unallocatedAmount' in (p ?? {}));

/**
 * Live bills with money recorded on the bill itself that no payment record
 * covers, oldest bill first, after old unlinked records have covered what
 * they can.
 */
export function paidAtBilling(orders: Record<string, any>[], payments: Record<string, any>[]): PaidAtBilling[] {
    const live = liveBills(orders);
    const pays = livePayments(payments);
    const covered = coveredBillIds(live, pays);
    const candidates: PaidAtBilling[] = [];
    for (const o of live) {
        if (covered.has(String(o.id))) continue;
        const amount = Math.min(Math.max(0, num(o.amountPaid)), billTotal(o));
        if (amount > 0) candidates.push({ order: o, amount });
    }
    candidates.sort((a, b) => String(a.order.invoiceDate ?? '').localeCompare(String(b.order.invoiceDate ?? '')));
    let pool = pays.filter(isOldUnlinkedPayment).reduce((s, p) => s + num(p.amount), 0);
    const out: PaidAtBilling[] = [];
    for (const c of candidates) {
        const used = Math.min(pool, c.amount);
        pool -= used;
        if (c.amount - used > 0) out.push({ order: c.order, amount: c.amount - used });
    }
    return out;
}

/** A bill the retailer has fully settled (its stored status can lag the amounts). */
export const isBillPaid = (o: any): boolean =>
    o?.paymentStatus === 'Paid' || (billTotal(o) > 0 && num(o?.amountPaid) >= billTotal(o));

export interface RetailerTotals {
    /** Σ live bill totals — "Total Sales". */
    totalSales: number;
    /** Σ payment records + money paid at billing — "Amount Paid". */
    totalPaid: number;
    outstanding: number;
    /** Live bills — "Total Orders". */
    billCount: number;
    /** Live bills fully paid — "Paid Orders". */
    paidBills: number;
}

export function retailerTotals(orders: Record<string, any>[], payments: Record<string, any>[]): RetailerTotals {
    const live = liveBills(orders);
    const totalSales = live.reduce((s, o) => s + billTotal(o), 0);
    const received = livePayments(payments).reduce((s, p) => s + num(p.amount), 0);
    const atBilling = paidAtBilling(orders, payments).reduce((s, x) => s + x.amount, 0);
    const totalPaid = received + atBilling;
    return {
        totalSales,
        totalPaid,
        outstanding: Math.max(0, totalSales - totalPaid),
        billCount: live.length,
        paidBills: live.filter(isBillPaid).length,
    };
}
