import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/app/theme.dart';
import 'package:krishidukan_erp/core/tenant_permissions.dart';
import 'package:krishidukan_erp/features/auth/auth_repository.dart';
import 'package:krishidukan_erp/features/portal/portal_bills_screen.dart';
import 'package:krishidukan_erp/features/portal/portal_repository.dart';
import 'package:krishidukan_erp/features/portal/portal_shell.dart';
import 'package:krishidukan_erp/features/subscription/subscription_repository.dart';
import 'package:krishidukan_erp/widgets/offline_banner.dart';

/// Renders the retailer portal with fixed data (no Firebase) and checks what
/// a retailer actually sees: their balance, only the tabs the business
/// allows, their bills / payments / products, and the blocked screen.

const _user = AppUser(
  uid: 'u1',
  email: 'shop@example.com',
  name: 'Ramesh Traders',
  role: 'retailer',
  tenantId: 'tenant_x',
  businessName: 'Supplier Co',
  linkedId: 'r1',
);

const _plan = TenantSubscription(
  status: SubStatus.active,
  planId: 'manufacturer',
  planName: 'Manufacturer',
  screens: {'worklist'},
);

final _retailer = <String, dynamic>{
  'name': 'Ramesh Traders',
  'number': '9876543210',
  'atPost': 'Nandgaon',
  'taluka': 'Nandgaon',
  'district': 'Nashik',
  'state': 'Maharashtra',
  'gstin': '27AAPFU0939F1ZV',
  'portfolioSize': 'Small',
};

final _bills = <(String, Map<String, dynamic>)>[
  ('a', {'orderNumber': 'INV-1', 'invoiceDate': '2026-10-01', 'grandTotal': 1000, 'amountPaid': 1000,
    'paymentStatus': 'Paid', 'lineItems': [{'productName': 'Urea 45kg', 'qty': 10}]}),
  ('b', {'orderNumber': 'INV-2', 'invoiceDate': '2026-11-05', 'grandTotal': 500, 'amountPaid': 200,
    'paymentStatus': 'Partial', 'lineItems': [{'productName': 'DAP 50kg', 'qty': 2}]}),
];

final _payments = <(String, Map<String, dynamic>)>[
  ('p1', {'paymentId': 'PAY-2026-0007', 'amount': 1200, 'paymentDate': '2026-11-06', 'paymentMethod': 'UPI'}),
];

Widget _app({Map<String, Map<String, bool>>? features, Widget? home}) {
  final perms = TenantPermissions.fromDocs(null, features);
  return ProviderScope(
    overrides: [
      authStateProvider.overrideWith((ref) => Stream.value(null)),
      appUserProvider.overrideWith((ref) async => _user),
      portalAccessProvider.overrideWithValue(
        PortalAccess.resolve(user: _user, sub: _plan, subLoaded: true, perms: perms),
      ),
      portalRetailerDocProvider.overrideWith((ref) => Stream.value(_retailer)),
      portalBillDocsProvider.overrideWith((ref) => Stream.value(_bills)),
      portalPaymentDocsProvider.overrideWith((ref) => Stream.value(_payments)),
      offlineProvider.overrideWith((ref) => Stream.value(false)),
    ],
    child: MaterialApp(theme: buildTheme(), home: home ?? const RetailerShell()),
  );
}

Finder _navLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

void main() {
  setUp(() => AppColors.variant = AppThemeVariant.light);

  testWidgets('home shows the live balance and every allowed tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Billed 1,500 − paid 1,200 = 300 outstanding, all time.
    expect(find.text('₹300.00'), findsOneWidget);
    expect(find.text('Outstanding with Supplier Co'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget); // 1200 / 1500
    for (final t in ['Home', 'Bills', 'Payments', 'Products', 'Account']) {
      expect(_navLabel(t), findsOneWidget, reason: t);
    }
  });

  testWidgets('bills tab lists their bills and filters by payment', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(_navLabel('Bills'));
    await tester.pumpAndSettle();
    final billsPage = find.byType(PortalBillsScreen);
    Finder inBills(Finder f) => find.descendant(of: billsPage, matching: f);

    expect(inBills(find.text('INV-1')), findsOneWidget);
    expect(inBills(find.text('INV-2')), findsOneWidget);
    expect(inBills(find.text('Due ₹300')), findsOneWidget);
    expect(inBills(find.text('All · 2')), findsOneWidget);

    await tester.tap(inBills(find.text('Paid · 1')));
    await tester.pumpAndSettle();
    expect(inBills(find.text('INV-1')), findsOneWidget);
    expect(inBills(find.text('INV-2')), findsNothing);
  });

  testWidgets('payments, products and account tabs', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(_navLabel('Payments'));
    await tester.pumpAndSettle();
    expect(find.text('1 payment · ₹1,200 paid'), findsOneWidget);

    await tester.tap(_navLabel('Products'));
    await tester.pumpAndSettle();
    expect(find.text('Urea 45kg'), findsOneWidget);
    expect(find.text('DAP 50kg'), findsOneWidget);

    await tester.tap(_navLabel('Account'));
    await tester.pumpAndSettle();
    expect(find.text('27AAPFU0939F1ZV'), findsOneWidget);
    expect(find.text('Nashik'), findsOneWidget);
  });

  testWidgets('tabs the business switched off are not offered', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(features: {
      'retailer': {
        'worklist.retailerProfile.b2bOrders.view': false,
        'worklist.retailerProfile.payments.view': false,
        'worklist.retailerProfile.productSalesOverview.view': false,
      }
    }));
    await tester.pumpAndSettle();

    expect(_navLabel('Home'), findsOneWidget);
    expect(_navLabel('Account'), findsOneWidget);
    expect(_navLabel('Bills'), findsNothing);
    expect(_navLabel('Payments'), findsNothing);
    expect(_navLabel('Products'), findsNothing);
    // The summary still shows (the web's cards are not gated either), but
    // no bill rows.
    expect(find.text('₹300.00'), findsOneWidget);
    expect(find.text('INV-2'), findsNothing);
  });

  testWidgets('menu button opens the portal drawer from every tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    for (final t in ['Home', 'Bills', 'Payments', 'Products', 'Account']) {
      await tester.tap(_navLabel(t));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Menu').hitTestable().first);
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);
      expect(drawer, findsOneWidget, reason: 'drawer on $t');
      expect(find.descendant(of: drawer, matching: find.text('Account statement')), findsOneWidget);
      expect(find.descendant(of: drawer, matching: find.text('Log out')), findsOneWidget);
      expect(find.descendant(of: drawer, matching: find.text('Retailer · Supplier Co')), findsOneWidget);
      await tester.tap(find.byTooltip('Close menu'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('small phone (320dp): every tab lays out without overflow', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    for (final t in ['Bills', 'Payments', 'Products', 'Account', 'Home']) {
      await tester.tap(_navLabel(t));
      await tester.pumpAndSettle();
    }
    // Any RenderFlex overflow fails the test through the framework.
    expect(tester.takeException(), isNull);
  });

  testWidgets('retailer access turned off shows the blocked screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith((ref) => Stream.value(null)),
        appUserProvider.overrideWith((ref) async => _user),
        portalAccessProvider.overrideWithValue(PortalAccess.resolve(
          user: _user,
          sub: _plan,
          subLoaded: true,
          perms: TenantPermissions.fromDocs({'retailer': {'worklist': false}}, null),
        )),
        portalRetailerDocProvider.overrideWith((ref) => Stream.value(_retailer)),
      ],
      child: MaterialApp(
        home: RetailerPortalGate(blocked: (m) => Scaffold(body: Text(m))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Supplier Co has turned off retailer access for now. Please contact them.'), findsOneWidget);
  });
}
