import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/core/tenant_permissions.dart';

/// The retailer portal baseline (see enforceRetailerPortalRole on the web).
void main() {
  // What master actually had stored: every retailer permission off, plus
  // every write feature on.
  final stored = TenantPermissions.fromDocs(
    {
      'retailer': {'worklist': false, 'dashboard': false},
      'analyst': {'worklist': false},
    },
    {
      'retailer': {
        'worklist.invoices.delete': true,
        'worklist.partners.create': true,
        'worklist.retailerProfile.b2bOrders.deleteOrder': true,
        'worklist.payments.view': false, // an admin hiding a tab: respected
        'worklist.invoices.view': true,
      },
    },
  );

  test('a saved matrix with worklist off cannot lock retailers out', () {
    expect(stored.screen('retailer', 'worklist'), isTrue);
    expect(stored.screen('retailer', 'dashboard'), isFalse); // others untouched
    expect(stored.screen('analyst', 'worklist'), isFalse); // other roles untouched
  });

  test('write features are never granted to a retailer', () {
    expect(stored.feature('retailer', 'worklist.invoices.delete'), isFalse);
    expect(stored.feature('retailer', 'worklist.partners.create'), isFalse);
    expect(stored.feature('retailer', 'worklist.retailerProfile.b2bOrders.deleteOrder'), isFalse);
  });

  test('bills and payments are always visible; product sales stays admin-controllable', () {
    expect(stored.feature('retailer', 'worklist.payments.view'), isTrue); // stored false, overridden
    expect(stored.feature('retailer', 'worklist.invoices.view'), isTrue);
    final hidden = TenantPermissions.fromDocs(null, {
      'retailer': {'worklist.retailerProfile.productSalesOverview.view': false},
    });
    expect(hidden.feature('retailer', 'worklist.retailerProfile.productSalesOverview.view'), isFalse);
    // nothing stored → the built-in defaults
    expect(const TenantPermissions().feature('retailer', 'worklist.retailerProfile.view'), isTrue);
    expect(const TenantPermissions().screen('retailer', 'worklist'), isTrue);
  });

  test('admin is unrestricted', () {
    expect(stored.feature('admin', 'worklist.invoices.delete'), isTrue);
  });
}
