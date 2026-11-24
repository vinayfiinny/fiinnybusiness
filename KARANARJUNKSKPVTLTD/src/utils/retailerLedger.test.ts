import { describe, expect, it } from 'vitest';
import { paidAtBilling, retailerTotals } from './retailerLedger';

// Shapes taken from real master-tenant retailers (Nov 2026 audit).
describe('retailerTotals', () => {
    it('a bill paid in cash at the counter is not shown as owed', () => {
        // SUJIT SANTOSH MANE: one Cash bill saved Paid, no payment record.
        const t = retailerTotals([{ id: 'a', grandTotal: '25945', amountPaid: '25945', paymentStatus: 'Paid', status: 'delivered' }], []);
        expect(t.totalSales).toBe(25945);
        expect(t.totalPaid).toBe(25945);
        expect(t.outstanding).toBe(0);
        expect(t.paidBills).toBe(1);
    });

    it('payments recorded without linking to a bill still count (no double count)', () => {
        // Yogesh Krushi Agency Lasalgaon: bills unpaid on the bill, money as unlinked payments.
        const t = retailerTotals(
            [{ id: 'a', grandTotal: 200000 }, { id: 'b', grandTotal: 117910 }],
            [{ id: 'p1', amount: 100000, linkedOrderIds: [] }, { id: 'p2', amount: 88000 }],
        );
        expect(t.totalPaid).toBe(188000);
        expect(t.outstanding).toBe(129910);
    });

    it('a bill paid through payment records is not counted again', () => {
        const t = retailerTotals(
            [
                { id: 'a', grandTotal: 54000, amountPaid: 54000, linkedPaymentIds: ['p1'] },
                { id: 'b', grandTotal: 30000, amountPaid: 30000 }, // covered by p2.orderId
                { id: 'c', grandTotal: 10000, amountPaid: 10000 }, // covered by p3.linkedOrderIds
            ],
            [
                { id: 'p1', amount: 54000 },
                { id: 'p2', amount: 30000, orderId: 'b' },
                { id: 'p3', amount: 10000, linkedOrderIds: ['c'] },
            ],
        );
        expect(t.totalPaid).toBe(94000);
        expect(t.outstanding).toBe(0);
    });

    it('cancelled and deleted bills are not owed; deleted payments do not count', () => {
        const t = retailerTotals(
            [
                { id: 'a', grandTotal: 1000 },
                { id: 'b', grandTotal: 2560, status: 'cancelled' },
                { id: 'c', grandTotal: 500, deleted: true },
            ],
            [{ id: 'p', amount: 300 }, { id: 'q', amount: 999, deleted: true }],
        );
        expect(t.totalSales).toBe(1000);
        expect(t.billCount).toBe(1);
        expect(t.outstanding).toBe(700);
    });

    it('an old unlinked payment and the same money marked on a bill count once', () => {
        // Baliraja Krushi Seva: bill 015 marked paid ₹6,000 (no link) + an old ₹6,000
        // record with no link fields at all. Owes the other bill, ₹12,000.
        const t = retailerTotals(
            [
                { id: 'a', netAmount: 6000, amountPaid: 6000, paymentStatus: 'Paid', invoiceDate: '2026-03-25' },
                { id: 'b', grandTotal: 12000, paymentStatus: 'Pending', invoiceDate: '2026-03-29' },
            ],
            [{ id: 'p', amount: 6000 }],
        );
        expect(t.totalPaid).toBe(6000);
        expect(t.outstanding).toBe(12000);
    });

    it('a new-style unlinked payment does not cancel money paid at the counter', () => {
        // linkedOrderIds: [] / unallocatedAmount present = a general Record Payment.
        const t = retailerTotals(
            [{ id: 'a', grandTotal: 1000, amountPaid: 1000, paymentMethod: 'Cash' }, { id: 'b', grandTotal: 5000 }],
            [{ id: 'p', amount: 2000, linkedOrderIds: [], unallocatedAmount: 2000 }],
        );
        expect(t.totalPaid).toBe(3000);
        expect(t.outstanding).toBe(3000);
    });

    it('money on a bill is capped at the bill total', () => {
        // amountPaid 63000 on a 34200 bill (real data): only the bill amount counts.
        expect(paidAtBilling([{ id: 'a', grandTotal: 34200, amountPaid: 63000 }], [])[0].amount).toBe(34200);
    });

    it('a stale status does not hide a fully paid bill', () => {
        expect(retailerTotals([{ id: 'a', grandTotal: 54000, amountPaid: 54000, paymentStatus: 'Pending' }], []).paidBills).toBe(1);
    });
});
