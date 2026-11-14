import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/core/roles.dart';
import 'package:krishidukan_erp/core/tenant_permissions.dart';
import 'package:krishidukan_erp/features/auth/auth_repository.dart';
import 'package:krishidukan_erp/features/portal/portal_models.dart';
import 'package:krishidukan_erp/features/portal/portal_repository.dart';
import 'package:krishidukan_erp/features/portal/statement_pdf.dart';
import 'package:krishidukan_erp/features/portal_access/invite_retailer_sheet.dart';
import 'package:krishidukan_erp/features/portal_access/portal_access_repository.dart';
import 'package:krishidukan_erp/features/subscription/subscription_repository.dart';

/// Retailer portal: the numbers must equal what the web retailer view
/// (WorklistDetailsPage.tsx) shows for the same documents, and the gates must
/// open exactly when the web's do.

Timestamp ts(int y, int m, int d) => Timestamp.fromDate(DateTime(y, m, d));

AppUser retailerUser({String linkedId = 'r1'}) => AppUser(
      uid: 'u1',
      email: 'shop@example.com',
      name: 'Shop',
      role: 'retailer',
      tenantId: 'tenant_x',
      businessName: 'Supplier Co',
      linkedId: linkedId,
    );

const okPlan = TenantSubscription(
  status: SubStatus.active,
  planId: 'manufacturer',
  planName: 'Manufacturer',
  screens: {'worklist', 'admin'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('roles', () {
    test('retailer gets the portal, never the staff app', () {
      final c = Capabilities.of('retailer');
      expect(c.isRetailerPortal, isTrue);
      expect(c.canUseApp, isFalse);
      expect(c.canBill, isFalse);
      expect(c.canViewAnalytics, isFalse);
      expect(c.canViewCustomers, isFalse);
    });
    test('manufacturer portal and staff are not retailer portal', () {
      expect(Capabilities.of('manufacturer').isRetailerPortal, isFalse);
      expect(Capabilities.of('manufacturer').canUseApp, isFalse);
      expect(Capabilities.of('admin').isRetailerPortal, isFalse);
      expect(Capabilities.of('admin').canUseApp, isTrue);
    });
  });

  group('period bounds (financialPeriod.ts)', () {
    final wed = DateTime(2026, 11, 18, 23, 30); // a Wednesday
    test('all = no filter', () => expect(periodBounds(PortalPeriod.all, wed), isNull));
    test('today', () => expect(periodBounds(PortalPeriod.today, wed), ('2026-11-18', '2026-11-18')));
    test('week starts Monday', () => expect(periodBounds(PortalPeriod.week, wed), ('2026-11-16', '2026-11-18')));
    test('Sunday belongs to the week that began the Monday before', () {
      expect(periodBounds(PortalPeriod.week, DateTime(2026, 11, 22)), ('2026-11-16', '2026-11-22'));
    });
    test('month', () => expect(periodBounds(PortalPeriod.month, wed), ('2026-11-01', '2026-11-18')));
    test('FY from 1 April', () {
      expect(periodBounds(PortalPeriod.fy, wed), ('2026-04-01', '2026-11-18'));
      expect(periodBounds(PortalPeriod.fy, DateTime(2027, 3, 31)), ('2026-04-01', '2027-03-31'));
      expect(periodBounds(PortalPeriod.fy, DateTime(2027, 4, 1)), ('2027-04-01', '2027-04-01'));
    });
    test('custom needs both dates', () {
      expect(periodBounds(PortalPeriod.custom, wed), isNull);
      expect(
        periodBounds(PortalPeriod.custom, wed, customFrom: DateTime(2026, 1, 5), customTo: DateTime(2026, 2, 1)),
        ('2026-01-05', '2026-02-01'),
      );
    });
  });

  group('bills', () {
    final docs = <(String, Map<String, dynamic>)>[
      ('a', {'orderNumber': 'INV-1', 'invoiceDate': '2026-10-01', 'grandTotal': 1000, 'amountPaid': 1000, 'paymentStatus': 'Paid', 'invoiceType': 'B2B_GST',
        'lineItems': [{'itemDescription': 'Urea', 'quantity': 10}]}),
      ('b', {'orderNumber': 'INV-2', 'invoiceDate': '2026-11-05', 'grandTotal': 500, 'amountPaid': 200, 'paymentStatus': 'Partial',
        'lineItems': [{'productName': 'Urea', 'qty': 4}, {'productName': 'DAP', 'qty': 2}]}),
      ('c', {'orderNumber': 'INV-3', 'invoiceDate': '2026-11-10', 'grandTotal': 300, 'deleted': true}),
      ('dddddddddd12345678', {'createdAt': ts(2026, 11, 12), 'netAmount': 250}),
      // Legacy: marked Paid before amountPaid existed.
      ('e', {'orderNumber': 'INV-0', 'invoiceDate': '2026-09-15', 'grandTotal': 400, 'paymentStatus': 'Paid',
        'lineItems': [{'productName': 'DAP', 'qty': 1}]}),
    ];
    final bills = billsFromDocs(docs);

    test('deleted bills are left out; newest invoiceDate first, undated last', () {
      expect(bills.map((b) => b.number), ['INV-2', 'INV-1', 'INV-0', '12345678']);
    });
    test('totals fall back grandTotal → netAmount → totalAmount', () {
      expect(bills.last.total, 250);
    });
    test('payment label and due follow the web row exactly', () {
      final byNo = {for (final b in bills) b.number: b};
      expect(byNo['INV-1']!.paymentLabel, 'Paid');
      expect(byNo['INV-1']!.outstanding, 0);
      expect(byNo['INV-2']!.paymentLabel, 'Partial');
      expect(byNo['INV-2']!.outstanding, 300);
      expect(byNo['12345678']!.paymentLabel, 'Pending');
      // Legacy doc: the web prints the stored "Paid" but still shows the full
      // amount as outstanding (amountPaid missing). The app must agree.
      expect(byNo['INV-0']!.fullyPaid, isFalse);
      expect(byNo['INV-0']!.paymentLabel, 'Paid');
      expect(byNo['INV-0']!.outstanding, 400);
    });
    test('period filter uses invoiceDate; undated bills drop out', () {
      final nov = billsInPeriod(bills, ('2026-11-01', '2026-11-30'));
      expect(nov.map((b) => b.number), ['INV-2']);
      expect(billsInPeriod(bills, null), hasLength(4));
    });
    test('summary = Σ bills − Σ payments, all time', () {
      final pays = paymentsFromDocs([
        ('p1', {'amount': 1200, 'createdAt': ts(2026, 10, 2)}),
        ('p2', {'amount': 100, 'createdAt': ts(2026, 11, 6)}),
      ]);
      final s = PortalSummary.of(bills, pays);
      expect(s.totalBilled, 2150);
      expect(s.totalPaid, 1300);
      expect(s.outstanding, 850);
      expect(s.paidPercent, 60); // 1300/2150 = 60.47 → 60
      expect(s.billCount, 4);
      expect(s.averageBill, 538); // round(537.5)
      expect(s.paidBills, 2); // stored 'Paid': INV-1 and legacy INV-0
    });
    test('overpaid never shows negative outstanding; completion caps at 100', () {
      final s = PortalSummary.of(bills, paymentsFromDocs([('p', {'amount': 99999})]));
      expect(s.outstanding, 0);
      expect(s.paidPercent, 100);
    });
    test('no bills: zero everything, no division by zero', () {
      final s = PortalSummary.of(const [], const []);
      expect(s.paidPercent, 0);
      expect(s.averageBill, 0);
    });
    test('monthly billed buckets the last 6 months, oldest first', () {
      final m = monthlyBilled(bills, DateTime(2026, 11, 20));
      expect(m.first.$1, DateTime(2026, 6, 1));
      expect(m.last.$1, DateTime(2026, 11, 1));
      expect(m.last.$2, 750); // INV-2 500 + undated-by-invoiceDate but createdAt Nov 250
      expect(m[4].$2, 1000); // Oct
      expect(m[3].$2, 400); // Sep
    });
  });

  group('product sales (productSalesData)', () {
    final bills = billsFromDocs([
      ('a', {'invoiceDate': '2026-10-01', 'grandTotal': 1, 'paymentStatus': 'Paid',
        'lineItems': [{'itemDescription': ' Urea ', 'quantity': 10}]}),
      ('b', {'invoiceDate': '2026-11-05', 'grandTotal': 1, 'paymentStatus': 'Partial',
        'lineItems': [{'productName': 'Urea', 'qty': 4}, {'productName': 'DAP', 'qty': 2}, {'productName': '', 'qty': 9}]}),
    ]);
    test('aggregates by trimmed name; paid split by stored status', () {
      final rows = productSales(bills);
      expect(rows.map((r) => r.name), ['Urea', 'DAP']);
      final urea = rows.first;
      expect(urea.totalQty, 14);
      expect(urea.paidQty, 10);
      expect(urea.unpaidQty, 4);
      expect(urea.invoiceCount, 2);
      expect(urea.firstInvoiceDate, '2026-10-01');
      expect(urea.lastInvoiceDate, '2026-11-05');
    });
  });

  group('payments', () {
    test('reference, transaction ref and allocation like the web table', () {
      final p = paymentsFromDocs([
        ('xxxxxxabcdef', {'amount': 500, 'paymentMethod': 'UPI', 'accountDetails': {'transactionRef': 'T1'},
          'linkedOrderIds': ['a'], 'unallocatedAmount': 0, 'createdAt': ts(2026, 11, 1)}),
        ('p2', {'paymentId': 'PAY-2026-0002', 'amount': 300, 'linkedOrderIds': ['a'], 'unallocatedAmount': 100,
          'createdAt': ts(2026, 11, 3)}),
        ('p3', {'paymentId': 'PAY-2026-0003', 'amount': 200, 'unallocatedAmount': 200, 'createdAt': ts(2026, 11, 2)}),
        ('p4', {'paymentId': 'PAY-OLD', 'amount': 50, 'orderId': 'a', 'createdAt': ts(2026, 10, 1)}),
      ]);
      expect(p.map((x) => x.reference), ['PAY-2026-0002', 'PAY-2026-0003', '#ABCDEF', 'PAY-OLD']);
      expect(p[0].allocation, PaymentAllocation.partlyAllocated);
      expect(p[1].allocation, PaymentAllocation.available);
      expect(p[2].allocation, PaymentAllocation.fullyAllocated);
      expect(p[2].transactionRef, 'T1');
      expect(p[3].linkedCount, 1);
      expect(p[3].allocation, PaymentAllocation.fullyAllocated);
    });
    test('period filter uses paymentDate', () {
      final p = paymentsFromDocs([
        ('a', {'amount': 1, 'paymentDate': '2026-11-02'}),
        ('b', {'amount': 1, 'paymentDate': '2026-10-02'}),
        ('c', {'amount': 1}),
      ]);
      expect(paymentsInPeriod(p, ('2026-11-01', '2026-11-30')).map((x) => x.id), ['a']);
    });
  });

  group('statement (statementGenerator.ts)', () {
    final billDocs = <(String, Map<String, dynamic>)>[
      ('b1', {'orderNumber': 'INV-1', 'invoiceDate': '2026-09-10', 'grandTotal': 1000, 'retailerName': 'Shop', 'invoiceType': 'B2B_GST'}),
      ('b2', {'orderNumber': 'INV-2', 'invoiceDate': '2026-10-05', 'grandTotal': 500}),
      ('b3', {'invoiceDate': '2026-10-20', 'grandTotal': 0}),
      ('b4', {'orderNumber': 'INV-4', 'invoiceDate': '2026-10-31', 'grandTotal': 200, 'deleted': true}),
      ('zzzzzzzzbill0005', {'createdAt': ts(2026, 11, 2), 'netAmount': 300}),
    ];
    final payDocs = <(String, Map<String, dynamic>)>[
      ('p1', {'paymentId': 'PAY-1', 'amount': 600, 'paymentDate': '2026-09-20', 'paymentMethod': 'UPI'}),
      ('p2', {'amount': 100, 'paymentDate': '2026-10-31', 'notes': 'cash at shop'}),
    ];

    test('all transactions: running balance, totals, closing', () {
      final st = buildStatement(billDocs: billDocs, paymentDocs: payDocs);
      expect(st.opening, 0);
      expect(st.rows.map((r) => r.refNo), ['INV-1', 'PAY-1', 'INV-2', 'P2', 'BILL0005']);
      expect(st.rows.map((r) => r.balance), [1000, 400, 900, 800, 1100]);
      expect(st.rows.first.particulars, 'Invoice — Shop');
      expect(st.rows.first.type, 'GST Invoice');
      expect(st.rows[1].particulars, 'Payment (UPI)');
      expect(st.rows[3].particulars, 'cash at shop');
      expect(st.totalDebit, 1800);
      expect(st.totalCredit, 700);
      expect(st.closing, 1100);
    });
    test('earlier rows fold into the opening balance; To includes its whole day', () {
      final st = buildStatement(
        billDocs: billDocs,
        paymentDocs: payDocs,
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 10, 31),
      );
      expect(st.opening, 400);
      expect(st.rows.map((r) => r.refNo), ['INV-2', 'P2']);
      expect(st.closing, 800);
    });
    test('the PDF builds', () async {
      final st = buildStatement(billDocs: billDocs, paymentDocs: payDocs);
      final bytes = await buildStatementPdf(
        st: st,
        issuer: 'Supplier Co',
        party: const StatementParty(name: 'रमेश ट्रेडर्स (Ramesh Traders)', atPost: 'Nandgaon', district: 'Nashik'),
        generatedAt: DateTime(2026, 11, 14),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final out = Platform.environment['STATEMENT_PDF_OUT'];
      if (out != null) File('$out/statement.pdf').writeAsBytesSync(bytes);
    });
    test('file name matches the web', () {
      expect(statementFileName('Ramesh  Traders & Co.', DateTime(2026, 11, 14)), 'Statement_RameshTradersCo_2026-11-14.pdf');
    });
  });

  group('tenant permissions (AuthContext merge)', () {
    test('no stored docs → web defaults', () {
      final p = TenantPermissions.fromDocs(null, null);
      expect(p.screen('retailer', 'worklist'), isTrue);
      expect(p.screen('analyst', 'admin'), isFalse);
      expect(p.screen('admin', 'admin'), isTrue);
      expect(p.feature('retailer', 'worklist.retailerProfile.b2bOrders.view'), isTrue);
      expect(p.feature('retailer', 'worklist.partners.call'), isFalse);
      expect(p.feature('retailer', 'reports.view'), isTrue);
    });
    test('stored values win key by key (production master today)', () {
      final p = TenantPermissions.fromDocs(
        {'retailer': {'worklist': false}, 'analyst': {'admin': true}},
        {'retailer': {'worklist.retailerProfile.b2bOrders.view': false}},
      );
      expect(p.screen('retailer', 'worklist'), isFalse);
      expect(p.screen('analyst', 'admin'), isTrue);
      expect(p.feature('retailer', 'worklist.retailerProfile.b2bOrders.view'), isFalse);
      // A key the stored map doesn't mention keeps its default.
      expect(p.feature('retailer', 'worklist.retailerProfile.payments.view'), isTrue);
    });
    test('admin bypasses both layers', () {
      final p = TenantPermissions.fromDocs({'admin': {'admin': false}}, {'admin': {'x.y': false}});
      expect(p.screen('admin', 'admin'), isTrue);
      expect(p.feature('admin', 'x.y'), isTrue);
    });
  });

  group('plan features (subscriptionPlans.ts)', () {
    test('no feature list → everything under the screen', () {
      expect(okPlan.allowsFeature('worklist.retailerProfile.payments.view'), isTrue);
      expect(okPlan.allowsFeatureGroup('worklist'), isTrue);
    });
    test('a restricted module only allows listed sections', () {
      const p = TenantSubscription(
        status: SubStatus.active,
        planId: 'x',
        planName: 'x',
        screens: {'worklist'},
        features: {'worklist.retailerProfile.b2bOrders', 'reports.daily'},
      );
      expect(p.allowsFeature('worklist.retailerProfile.b2bOrders.view'), isTrue);
      expect(p.allowsFeature('worklist.retailerProfile.payments.view'), isFalse);
      expect(p.allowsFeature('inventory.anything'), isTrue);
    });
    test('excluded group marker', () {
      const p = TenantSubscription(
        status: SubStatus.active,
        planId: 'x',
        planName: 'x',
        screens: {'worklist'},
        features: {'worklist.__excluded__'},
      );
      expect(p.allowsFeatureGroup('worklist'), isFalse);
    });
  });

  group('portal access gate', () {
    final defaults = TenantPermissions.fromDocs(null, null);

    test('login without linkedId is refused', () {
      final a = PortalAccess.resolve(user: retailerUser(linkedId: ''), sub: okPlan, subLoaded: true, perms: defaults);
      expect(a.denial, PortalDenial.notLinked);
    });
    test('waits for plan and permissions', () {
      expect(PortalAccess.resolve(user: retailerUser(), sub: null, subLoaded: false, perms: defaults).loading, isTrue);
      expect(PortalAccess.resolve(user: retailerUser(), sub: okPlan, subLoaded: true, perms: null).loading, isTrue);
    });
    test('plan without Worklist, suspended plan, no plan → refused', () {
      const noWorklist = TenantSubscription(status: SubStatus.active, planId: 'p', planName: 'p', screens: {'pos'});
      const suspended = TenantSubscription(
          status: SubStatus.suspended, planId: 'p', planName: 'p', screens: {'worklist'});
      for (final s in [noWorklist, suspended, null]) {
        expect(
          PortalAccess.resolve(user: retailerUser(), sub: s, subLoaded: true, perms: defaults).denial,
          PortalDenial.planExcludes,
        );
      }
    });
    test('role matrix switched off → refused (production master today)', () {
      final p = TenantPermissions.fromDocs({'retailer': {'worklist': false}}, null);
      expect(PortalAccess.resolve(user: retailerUser(), sub: okPlan, subLoaded: true, perms: p).denial,
          PortalDenial.turnedOff);
    });
    test('defaults: all three tabs', () {
      final a = PortalAccess.resolve(user: retailerUser(), sub: okPlan, subLoaded: true, perms: defaults);
      expect(a.allowed, isTrue);
      expect([a.bills, a.payments, a.products], [true, true, true]);
    });
    test('each tab follows its own switch', () {
      final p = TenantPermissions.fromDocs(null, {
        'retailer': {
          'worklist.retailerProfile.b2bOrders.view': true,
          'worklist.retailerProfile.payments.view': false,
          'worklist.retailerProfile.productSalesOverview.view': false,
        }
      });
      final a = PortalAccess.resolve(user: retailerUser(), sub: okPlan, subLoaded: true, perms: p);
      expect([a.bills, a.payments, a.products], [true, false, false]);
    });
  });

  group('invite form', () {
    test('validation', () {
      expect(validateInvite(email: 'shop@x.com', password: '123456'), isNull);
      expect(validateInvite(email: ' shop@x.com ', password: '123456'), isNull);
      expect(validateInvite(email: 'shop@x', password: '123456'), isNotNull);
      expect(validateInvite(email: 'shop x@y.com', password: '123456'), isNotNull);
      expect(validateInvite(email: 'shop@x.com', password: '12345'), isNotNull);
    });
    test('temporary password: 10 chars, no look-alikes', () {
      final pw = generateTempPassword(Random(1));
      expect(pw, hasLength(10));
      expect(RegExp(r'^[A-HJ-NP-Za-hj-km-np-z2-9]+$').hasMatch(pw), isTrue);
    });
  });
}
