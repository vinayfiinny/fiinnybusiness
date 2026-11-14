import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tenant_path.dart';
import '../../core/tenant_permissions.dart';
import '../auth/auth_repository.dart';
import '../subscription/subscription_repository.dart';
import 'portal_models.dart';

// Live data for a signed-in retailer portal user. Every read is keyed on
// AppUser.linkedId and shaped so firestore.rules can prove it is theirs
// (isPortalUser('retailer', tenantId, …)): their own retailers/{id} doc and
// its subcollections, and salesOrders filtered to retailerId == linkedId. A
// retailer can never list another retailer's bills, even by mistake.
//
// Never read here: retailers/{id}/notes and /tasks. The rules happen to let
// a retailer read them, but they are the business's private notes about the
// retailer and the web portal hides them too.

typedef Docs = List<(String, Map<String, dynamic>)>;

AppUser? _retailer(Ref ref) {
  final u = ref.watch(appUserProvider).valueOrNull;
  if (u == null || !u.can.isRetailerPortal || u.linkedId.isEmpty) return null;
  return u;
}

/// retailers/{linkedId} — null when missing or soft-deleted.
final portalRetailerDocProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final u = _retailer(ref);
  if (u == null) return Stream.value(null);
  return tenantCollection(ref.watch(firestoreProvider), u.tenantId, 'retailers')
      .doc(u.linkedId)
      .snapshots()
      .map((s) {
    final d = s.data();
    return (d == null || d['deleted'] == true) ? null : d;
  });
});

final portalBillDocsProvider = StreamProvider<Docs>((ref) {
  final u = _retailer(ref);
  if (u == null) return Stream.value(const []);
  return tenantCollection(
          ref.watch(firestoreProvider), u.tenantId, 'salesOrders')
      .where('retailerId', isEqualTo: u.linkedId)
      .snapshots()
      .map((s) => [for (final d in s.docs) (d.id, d.data())]);
});

final portalPaymentDocsProvider = StreamProvider<Docs>((ref) {
  final u = _retailer(ref);
  if (u == null) return Stream.value(const []);
  return tenantCollection(ref.watch(firestoreProvider), u.tenantId, 'retailers')
      .doc(u.linkedId)
      .collection('payments')
      .snapshots()
      .map((s) => [for (final d in s.docs) (d.id, d.data())]);
});

final portalBillsProvider = Provider<AsyncValue<List<PortalBill>>>(
  (ref) => ref.watch(portalBillDocsProvider).whenData(billsFromDocs),
);

final portalPaymentsProvider = Provider<AsyncValue<List<PortalPayment>>>(
  (ref) => ref.watch(portalPaymentDocsProvider).whenData(paymentsFromDocs),
);

/// Header cards + analytics: all time, from every bill and every payment.
final portalSummaryProvider = Provider<AsyncValue<PortalSummary>>((ref) {
  final bills = ref.watch(portalBillsProvider);
  final payments = ref.watch(portalPaymentsProvider);
  if (bills.hasError) return AsyncError(bills.error!, bills.stackTrace!);
  if (payments.hasError) {
    return AsyncError(payments.error!, payments.stackTrace!);
  }
  if (!bills.hasValue || !payments.hasValue) return const AsyncLoading();
  return AsyncData(PortalSummary.of(bills.value!, payments.value!));
});

// ── What the retailer may open ───────────────────────────────────────────────

enum PortalDenial { notLinked, planExcludes, turnedOff }

/// The gates the web applies before and inside /worklist/{linkedId}:
///  • the business's plan includes the Worklist screen and group
///    (ProtectedRoute: isScreenAllowedByPlan + isFeatureGroupAllowed),
///  • the role matrix grants the retailer role Worklist
///    (settings/rolePermissions — default on),
///  • each tab needs its feature switch (settings/featurePermissions) and the
///    plan sub-section (useFeaturePermissions).
class PortalAccess {
  const PortalAccess._({
    this.loading = false,
    this.denial,
    this.bills = false,
    this.payments = false,
    this.products = false,
  });

  const PortalAccess.loading() : this._(loading: true);
  const PortalAccess.denied(PortalDenial why) : this._(denial: why);

  final bool loading;
  final PortalDenial? denial;

  /// B2B Orders tab.
  final bool bills;

  /// Payments tab.
  final bool payments;

  /// Product Sales tab.
  final bool products;

  bool get allowed => !loading && denial == null;

  static PortalAccess resolve({
    required AppUser user,
    required TenantSubscription? sub,
    required bool subLoaded,
    required TenantPermissions? perms,
  }) {
    if (user.linkedId.isEmpty) {
      return const PortalAccess.denied(PortalDenial.notLinked);
    }
    if (!subLoaded || perms == null) return const PortalAccess.loading();
    final planOk = sub != null &&
        sub.allowsScreen('worklist') &&
        sub.allowsFeatureGroup('worklist');
    if (!planOk) return const PortalAccess.denied(PortalDenial.planExcludes);
    if (!perms.screen(user.role, 'worklist')) {
      return const PortalAccess.denied(PortalDenial.turnedOff);
    }
    bool can(String id) =>
        sub.allowsFeature(id) && perms.feature(user.role, id);
    return PortalAccess._(
      bills: can('worklist.retailerProfile.b2bOrders.view'),
      payments: can('worklist.retailerProfile.payments.view'),
      products: can('worklist.retailerProfile.productSalesOverview.view'),
    );
  }
}

final portalAccessProvider = Provider<PortalAccess>((ref) {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return const PortalAccess.loading();
  final sub = ref.watch(subscriptionProvider);
  return PortalAccess.resolve(
    user: user,
    sub: sub.valueOrNull,
    // An unreadable subscription means "no plan" on the web → restricted.
    subLoaded: sub.hasValue || sub.hasError,
    perms: ref.watch(tenantPermissionsProvider),
  );
});

/// Ledger statement branding: settings/invoiceBranding (what the web
/// statement reads), else the business name.
Future<String> statementIssuer(FirebaseFirestore db, AppUser user) async {
  try {
    final s = await tenantCollection(db, user.tenantId, 'settings')
        .doc('invoiceBranding')
        .get();
    final name = (s.data()?['businessName'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) return name;
  } catch (_) {/* cosmetic */}
  return user.businessName;
}
