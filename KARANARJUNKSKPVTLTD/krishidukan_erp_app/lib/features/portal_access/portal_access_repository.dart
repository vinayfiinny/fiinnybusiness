import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audit.dart';
import '../../core/env.dart';
import '../../core/tenant_permissions.dart';
import '../analytics/models.dart' show tsToDate;
import '../auth/auth_repository.dart';
import '../customers/customer.dart';
import '../subscription/subscription_repository.dart';

/// A retailer portal login of this business (users/{uid}, role 'retailer').
class PortalLogin {
  const PortalLogin({
    required this.uid,
    required this.email,
    required this.name,
    required this.retailerId,
    this.createdAt,
  });

  final String uid;
  final String email;
  final String name;

  /// linkedId — the retailers/{id} doc this login sees.
  final String retailerId;
  final DateTime? createdAt;
}

/// Who may give retailers portal access — AdminPage.tsx's canManageUsers
/// inside the plan-gated Admin hub: the plan must include the Admin screen,
/// and the role is admin or has been granted Admin in the role matrix.
/// firestore.rules additionally require admin/analyst to write users docs.
/// null while the plan / permissions are still loading.
final canInviteRetailersProvider = Provider<bool?>((ref) {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return null;
  if (!const {'admin', 'analyst', 'master'}.contains(user.role)) return false;
  final sub = ref.watch(subscriptionProvider);
  final perms = ref.watch(tenantPermissionsProvider);
  if (!(sub.hasValue || sub.hasError) || perms == null) return null;
  final planOk = sub.valueOrNull?.allowsScreen('admin') ?? false;
  return planOk && perms.screen(user.role, 'admin');
});

/// Every retailer login of this business, newest first. Same query as the
/// web's user list (where tenantId == mine), narrowed to role 'retailer'.
final portalLoginsProvider = StreamProvider<List<PortalLogin>>((ref) {
  final user = ref.watch(appUserProvider).valueOrNull;
  final allowed = ref.watch(canInviteRetailersProvider);
  if (user == null || allowed != true) return Stream.value(const []);
  return ref
      .watch(firestoreProvider)
      .collection('users')
      .where('tenantId', isEqualTo: user.tenantId)
      .where('role', isEqualTo: 'retailer')
      .snapshots()
      .map((s) {
    final list = [
      for (final d in s.docs)
        PortalLogin(
          uid: d.id,
          email: (d.data()['email'] as String?) ?? '',
          name: (d.data()['name'] as String?) ?? '',
          retailerId: (d.data()['linkedId'] as String?) ?? '',
          createdAt: tsToDate(d.data()['createdAt']),
        )
    ];
    list.sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));
    return list;
  });
});

class InviteException implements Exception {
  InviteException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Checks the form before anything is created. null = fine.
String? validateInvite({required String email, required String password}) {
  if (!_emailRe.hasMatch(email.trim())) return 'Enter a valid email address.';
  if (password.length < 6) return 'Password must be at least 6 characters.';
  return null;
}

class PortalAccessRepository {
  PortalAccessRepository(this._db, this._user);

  final FirebaseFirestore _db;
  final AppUser _user;

  /// handleInviteRetailer() in AdminPage.tsx:
  ///  1. create the Firebase Auth login on a throwaway secondary Firebase app,
  ///     so the admin on this phone stays signed in;
  ///  2. write users/{uid} linking the login to THIS business (tenantId) and
  ///     to the retailer record (linkedId / assignedRetailers) with the
  ///     read-only role 'retailer' — the same fields the web writes;
  ///  3. if that write fails, delete the new login so it is never orphaned.
  /// Returns the new uid.
  Future<String> invite({
    required Customer retailer,
    required String email,
    required String password,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final problem = validateInvite(email: cleanEmail, password: password);
    if (problem != null) throw InviteException(problem);
    if (retailer.isPosCustomer) {
      throw InviteException('Portal access is for B2B partners, not counter customers.');
    }

    // Already a login of this business with that email? Say so before
    // creating anything. The web stores the email as typed, so check that
    // spelling too.
    final typed = email.trim();
    if (await _existsInTenant(cleanEmail) ||
        (typed != cleanEmail && await _existsInTenant(typed))) {
      throw InviteException('$cleanEmail already has a login in your business.');
    }

    final app = await Firebase.initializeApp(
      name: 'portal-invite-${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    try {
      final auth = FirebaseAuth.instanceFor(app: app);
      if (useFirebaseEmulator) await auth.useAuthEmulator(firebaseEmulatorHost, 9099);

      final UserCredential cred;
      try {
        cred = await auth.createUserWithEmailAndPassword(email: cleanEmail, password: password);
      } on FirebaseAuthException catch (e) {
        throw InviteException(await _authMessage(e, cleanEmail));
      }
      final uid = cred.user!.uid;

      try {
        await _db.collection('users').doc(uid).set({
          'email': cleanEmail,
          'name': retailer.name.isNotEmpty ? retailer.name : 'Retailer',
          'role': 'retailer',
          'tenantId': _user.tenantId,
          'linkedId': retailer.id,
          'assignedRetailers': [retailer.id],
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {
        // Roll back so a failed link never leaves a login with no account.
        try {
          await cred.user!.delete();
        } catch (_) {/* best effort, as on the web */}
        throw InviteException('Could not save the retailer login. Nothing was created — please try again.');
      }

      logAudit(_db, _user,
          module: 'Manage Users',
          action: 'Create',
          entityName: retailer.name.isNotEmpty ? retailer.name : cleanEmail,
          entityId: uid,
          remarks: 'Retailer portal access · Email: $cleanEmail');
      return uid;
    } finally {
      try {
        await FirebaseAuth.instanceFor(app: app).signOut();
      } catch (_) {}
      try {
        await app.delete();
      } catch (_) {}
    }
  }

  /// handleDeleteUser() in AdminPage.tsx: deletes the users doc, which ends
  /// the portal (every rule check reads it). The Firebase login itself stays,
  /// exactly as on the web; inviting the same email again then reports it.
  Future<void> remove(PortalLogin login) async {
    if (login.uid == _user.uid) throw InviteException('You cannot remove your own login.');
    await _db.collection('users').doc(login.uid).delete();
    logAudit(_db, _user,
        module: 'Manage Users',
        action: 'Delete',
        entityName: login.name.isNotEmpty ? login.name : login.email,
        entityId: login.uid,
        remarks: 'Role was: retailer');
  }

  Future<bool> _existsInTenant(String email) async {
    final s = await _db
        .collection('users')
        .where('tenantId', isEqualTo: _user.tenantId)
        .where('email', isEqualTo: email)
        .limit(1)
        .get();
    return s.docs.isNotEmpty;
  }

  Future<String> _authMessage(FirebaseAuthException e, String email) async {
    switch (e.code) {
      case 'email-already-in-use':
        // Same distinction as the web: invited here already, or a login that
        // exists with no record in this business.
        final here = await _existsInTenant(email).catchError((_) => false);
        return here
            ? '$email already has a login in your business.'
            : '$email already has a KaranArjun login that is not part of your business '
                '(it may be another business\'s user, or a half-finished earlier invite). '
                'Use a different email, or contact support to clear it.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Choose a stronger password (at least 6 characters).';
      case 'network-request-failed':
        return 'No internet connection. Nothing was created — try again when online.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a few minutes and try again.';
      case 'operation-not-allowed':
        return 'Email logins are turned off for this project. Contact support.';
      default:
        return e.message ?? 'Could not create the login (${e.code}).';
    }
  }
}

final portalAccessRepositoryProvider = Provider<PortalAccessRepository?>((ref) {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return null;
  return PortalAccessRepository(ref.watch(firestoreProvider), user);
});
