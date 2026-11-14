import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_repository.dart';
import 'tenant_path.dart';

/// The admin-editable role matrix (settings/rolePermissions) and granular
/// feature switches (settings/featurePermissions), merged over the web's
/// built-in defaults exactly like AuthContext.tsx: for each role the stored
/// map wins key by key; a missing or empty doc means "defaults only"; a read
/// error also falls back to defaults.
///
/// Read-only. The web writes the defaults when a doc is missing; the app never
/// writes settings (a retailer couldn't, and an admin edits them on the web).
class TenantPermissions {
  const TenantPermissions({
    this.roleScreens = const {},
    this.roleFeatures = const {},
  });

  /// Stored rolePermissions: role → AppScreen id → granted.
  final Map<String, Map<String, bool>> roleScreens;

  /// Stored featurePermissions: role → feature id → granted.
  final Map<String, Map<String, bool>> roleFeatures;

  /// `permissions[role][screen]` in ProtectedRoute / AdminPage. The admin role
  /// is unrestricted at this layer on the web (the plan still applies).
  bool screen(String role, String screen) {
    if (role == 'admin') return true;
    return roleScreens[role]?[screen] ?? _defaultScreen(role, screen);
  }

  /// useFeaturePermissions().can(id) minus the plan layer (check that with
  /// TenantSubscription.allowsFeature). Admin bypasses, as on the web.
  bool feature(String role, String id) {
    if (role == 'admin') return true;
    return roleFeatures[role]?[id] ?? _defaultFeature(role, id);
  }

  static TenantPermissions fromDocs(
    Map<String, dynamic>? rolePermissions,
    Map<String, dynamic>? featurePermissions,
  ) =>
      TenantPermissions(
        roleScreens: _boolMaps(rolePermissions),
        roleFeatures: _boolMaps(featurePermissions),
      );
}

/// defaultPermissions in AuthContext.tsx, for the screens the app consults.
/// Anything else is denied — the web treats an unconfigured screen the same.
const _defaultScreens = <String, Map<String, bool>>{
  'analyst': {'worklist': true, 'admin': false},
  'shopkeeper': {'worklist': true, 'admin': false},
  'sales': {'worklist': true, 'admin': false},
  'retailer': {'worklist': true, 'admin': false},
  'manufacturer': {'worklist': false, 'admin': false},
};

bool _defaultScreen(String role, String screen) =>
    _defaultScreens[role]?[screen] ?? false;

/// RETAILER_ALLOWED in src/utils/featurePermissions.ts. For the retailer role
/// buildDefaults() grants these worklist ids and denies every other worklist
/// id; modules outside worklist default to granted.
const retailerDefaultFeatures = {
  'worklist.invoices.view',
  'worklist.payments.view',
  'worklist.retailerProfile.view',
  'worklist.retailerProfile.b2bOrders.view',
  'worklist.retailerProfile.payments.view',
  'worklist.retailerProfile.productSalesOverview.view',
};

bool _defaultFeature(String role, String id) {
  if (role == 'retailer') {
    return id.startsWith('worklist.') ? retailerDefaultFeatures.contains(id) : true;
  }
  // Only the retailer portal asks for features today; deny anything else
  // rather than guess another role's defaults.
  return false;
}

Map<String, Map<String, bool>> _boolMaps(Map<String, dynamic>? doc) {
  if (doc == null || doc.isEmpty) return const {};
  final out = <String, Map<String, bool>>{};
  doc.forEach((role, perms) {
    if (perms is! Map) return;
    final m = <String, bool>{};
    perms.forEach((k, v) {
      if (k is String && v is bool) m[k] = v;
    });
    out[role] = m;
  });
  return out;
}

Stream<Map<String, dynamic>?> _settingsDoc(Ref ref, String id) {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null || user.tenantId.isEmpty) return Stream.value(null);
  return tenantCollection(ref.watch(firestoreProvider), user.tenantId, 'settings')
      .doc(id)
      .snapshots()
      .map<Map<String, dynamic>?>((s) => s.data())
      // AuthContext falls back to the defaults when the listener errors, so
      // an error becomes "no stored doc" rather than an endless spinner.
      .transform(StreamTransformer.fromHandlers(
        handleError: (Object _, StackTrace __, EventSink<Map<String, dynamic>?> sink) =>
            sink.add(null),
      ));
}

final _rolePermissionsDocProvider =
    StreamProvider<Map<String, dynamic>?>((ref) => _settingsDoc(ref, 'rolePermissions'));

final _featurePermissionsDocProvider =
    StreamProvider<Map<String, dynamic>?>((ref) => _settingsDoc(ref, 'featurePermissions'));

/// null while either doc is still loading, so a gated screen shows a spinner
/// instead of flashing "not allowed" for a moment.
final tenantPermissionsProvider = Provider<TenantPermissions?>((ref) {
  final roles = ref.watch(_rolePermissionsDocProvider);
  final features = ref.watch(_featurePermissionsDocProvider);
  if (roles.isLoading || features.isLoading) return null;
  return TenantPermissions.fromDocs(roles.valueOrNull, features.valueOrNull);
});
