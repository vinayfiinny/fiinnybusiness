import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/features/portal/portal_models.dart';

/// The same cases as src/utils/retailerLedger.test.ts on the web, so the app
/// and the web always show a retailer the same balance.
PortalSummary sum(List<(String, Map<String, dynamic>)> bills,
        List<(String, Map<String, dynamic>)> pays) =>
    PortalSummary.of(billsFromDocs(bills), paymentsFromDocs(pays));

void main() {
  test('a bill paid in cash at the counter is not shown as owed', () {
    final s = sum([('a', {'grandTotal': '25945', 'amountPaid': '25945', 'paymentStatus': 'Paid', 'status': 'delivered'})], []);
    expect(s.totalPaid, 25945);
    expect(s.outstanding, 0);
    expect(s.paidBills, 1);
  });

  test('payments recorded without linking still count, once', () {
    final s = sum([('a', {'grandTotal': 200000}), ('b', {'grandTotal': 117910})], [
      ('p1', {'amount': 100000, 'linkedOrderIds': []}),
      ('p2', {'amount': 88000}),
    ]);
    expect(s.totalPaid, 188000);
    expect(s.outstanding, 129910);
  });

  test('bills paid through payment records are not counted again', () {
    final s = sum([
      ('a', {'grandTotal': 54000, 'amountPaid': 54000, 'linkedPaymentIds': ['p1']}),
      ('b', {'grandTotal': 30000, 'amountPaid': 30000}),
      ('c', {'grandTotal': 10000, 'amountPaid': 10000}),
    ], [
      ('p1', {'amount': 54000}),
      ('p2', {'amount': 30000, 'orderId': 'b'}),
      ('p3', {'amount': 10000, 'linkedOrderIds': ['c']}),
    ]);
    expect(s.totalPaid, 94000);
    expect(s.outstanding, 0);
  });

  test('cancelled bills are not owed; deleted payments do not count', () {
    final s = sum([
      ('a', {'grandTotal': 1000}),
      ('b', {'grandTotal': 2560, 'status': 'cancelled'}),
    ], [
      ('p', {'amount': 300}),
      ('q', {'amount': 999, 'deleted': true}),
    ]);
    expect(s.totalBilled, 1000);
    expect(s.billCount, 1);
    expect(s.outstanding, 700);
  });

  test('an old unlinked payment and the same money on a bill count once (Baliraja)', () {
    final s = sum([
      ('a', {'netAmount': 6000, 'amountPaid': 6000, 'paymentStatus': 'Paid', 'invoiceDate': '2026-03-25'}),
      ('b', {'grandTotal': 12000, 'paymentStatus': 'Pending', 'invoiceDate': '2026-03-29'}),
    ], [
      ('p', {'amount': 6000}),
    ]);
    expect(s.totalPaid, 6000);
    expect(s.outstanding, 12000);
  });

  test('a new-style unlinked payment does not cancel money paid at the counter', () {
    final s = sum([
      ('a', {'grandTotal': 1000, 'amountPaid': 1000, 'paymentMethod': 'Cash'}),
      ('b', {'grandTotal': 5000}),
    ], [
      ('p', {'amount': 2000, 'linkedOrderIds': [], 'unallocatedAmount': 2000}),
    ]);
    expect(s.totalPaid, 3000);
    expect(s.outstanding, 3000);
  });

  test('the statement ends on the same balance as the summary', () {
    final bills = [
      ('a', {'orderNumber': 'KA-1', 'grandTotal': 2000, 'amountPaid': 2000, 'paymentMethod': 'Cash', 'invoiceDate': '2026-08-01'}),
      ('b', {'orderNumber': 'KA-2', 'grandTotal': 900, 'invoiceDate': '2026-08-05'}),
      ('c', {'orderNumber': 'KA-3', 'grandTotal': 500, 'status': 'cancelled', 'invoiceDate': '2026-08-06'}),
    ];
    final pays = [('p', {'amount': 400, 'paymentDate': '2026-08-10', 'linkedOrderIds': [], 'unallocatedAmount': 400})];
    final st = buildStatement(billDocs: bills, paymentDocs: pays);
    expect(st.closing, sum(bills, pays).outstanding);
    expect(st.closing, 500);
    expect(st.rows.map((r) => r.particulars), contains('Paid at billing (Cash)'));
    expect(st.rows.any((r) => r.refNo == 'KA-3'), isFalse); // cancelled bill left out
  });
}
