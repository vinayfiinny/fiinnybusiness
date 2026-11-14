import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../widgets/app_drawer.dart' show confirmSignOut;
import '../../widgets/offline_banner.dart';
import '../../widgets/ui.dart';
import '../auth/auth_repository.dart';
import '../billing/invoice_pdf.dart' show InvoiceBranding;
import '../settings/theme_provider.dart';
import 'portal_bills_screen.dart';
import 'portal_home_screen.dart';
import 'portal_payments_screen.dart';
import 'portal_repository.dart';
import 'portal_widgets.dart';

/// Entry point for a retailer portal login: checks the same gates as the web
/// before showing anything, then the portal shell.
class RetailerPortalGate extends ConsumerWidget {
  const RetailerPortalGate({super.key, required this.blocked});

  /// Shown when the portal can't open (sign-out lives there).
  final Widget Function(String message) blocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(portalAccessProvider);
    final retailer = ref.watch(portalRetailerDocProvider);
    final business =
        ref.watch(appUserProvider).valueOrNull?.businessName ?? 'your supplier';

    if (access.denial != null) {
      return blocked(switch (access.denial!) {
        PortalDenial.notLinked =>
          'This login is not linked to a retailer account yet. Ask $business to send you a new invite.',
        PortalDenial.planExcludes =>
          'Retailer accounts are not part of $business\'s current plan. Please contact $business.',
        PortalDenial.turnedOff =>
          '$business has turned off retailer access for now. Please contact them.',
      });
    }
    if (access.loading || retailer.isLoading) return const _Loading();
    if (retailer.hasError) {
      return blocked(
          'Could not load your account. Check your connection and try again.');
    }
    if (retailer.valueOrNull == null) {
      return blocked(
          'Your retailer account was not found. Please contact $business.');
    }
    return const RetailerShell();
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Scaffold(
        body:
            Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
}

/// Bottom bar: Home and Account always (the web always shows the summary and
/// Overview); Bills / Payments / Products only when the business allows them.
class RetailerShell extends ConsumerWidget {
  const RetailerShell({super.key});

  static List<PortalTab> tabsFor(PortalAccess a) => [
        PortalTab.home,
        if (a.bills) PortalTab.bills,
        if (a.payments) PortalTab.payments,
        if (a.products) PortalTab.products,
        PortalTab.account,
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(portalAccessProvider);
    final tabs = tabsFor(access);
    final requested = ref.watch(portalTabProvider);
    final tab = tabs.contains(requested) ? requested : PortalTab.home;

    return PopScope(
      canPop: tab == PortalTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ref.read(portalTabProvider.notifier).state = PortalTab.home;
        }
      },
      child: Scaffold(
        drawer: const _PortalDrawer(),
        body: Column(
          children: [
            const OfflineBanner(),
            Expanded(
              child: IndexedStack(
                index: tabs.indexOf(tab),
                children: [
                  for (final t in tabs)
                    KeyedSubtree(key: ValueKey(t), child: _screen(t))
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border))),
          child: NavigationBar(
            selectedIndex: tabs.indexOf(tab),
            onDestinationSelected: (i) =>
                ref.read(portalTabProvider.notifier).state = tabs[i],
            destinations: [
              for (final t in tabs)
                NavigationDestination(
                  icon: Icon(_meta(t).$1),
                  selectedIcon: Icon(_meta(t).$2),
                  label: _meta(t).$3,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _screen(PortalTab t) => switch (t) {
        PortalTab.home => const PortalHomeScreen(),
        PortalTab.bills => const PortalBillsScreen(),
        PortalTab.payments => const PortalPaymentsScreen(),
        PortalTab.products => const PortalProductsScreen(),
        PortalTab.account => const PortalAccountScreen(),
      };
}

(IconData, IconData, String) _meta(PortalTab t) => switch (t) {
      PortalTab.home => (Icons.home_outlined, Icons.home_rounded, 'Home'),
      PortalTab.bills => (
          Icons.receipt_long_outlined,
          Icons.receipt_long_rounded,
          'Bills'
        ),
      PortalTab.payments => (
          Icons.payments_outlined,
          Icons.payments_rounded,
          'Payments'
        ),
      PortalTab.products => (
          Icons.inventory_2_outlined,
          Icons.inventory_2_rounded,
          'Products'
        ),
      PortalTab.account => (
          Icons.person_outline_rounded,
          Icons.person_rounded,
          'Account'
        ),
    };

class _PortalDrawer extends ConsumerWidget {
  const _PortalDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).valueOrNull;
    final retailer = ref.watch(portalRetailerDocProvider).valueOrNull;
    final tabs = RetailerShell.tabsFor(ref.watch(portalAccessProvider));
    final current = ref.watch(portalTabProvider);
    final variant = ref.watch(themeVariantProvider);
    final name = (retailer?['name'] as String?)?.trim() ?? user?.name ?? '';

    void go(PortalTab t) {
      Navigator.of(context).pop();
      ref.read(portalTabProvider.notifier).state = t;
    }

    return Drawer(
      width: 300,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: IconButton(
                tooltip: 'Close menu',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, color: AppColors.ink),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
              child: Row(children: [
                InitialAvatar(name, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                              fontSize: 15.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Retailer · ${user?.businessName ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.label),
                    ],
                  ),
                ),
              ]),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final t in tabs)
                    _Item(_meta(t).$1, _meta(t).$3,
                        selected: t == current, onTap: () => go(t)),
                  _Item(Icons.download_rounded, 'Account statement', onTap: () {
                    Navigator.of(context).pop();
                    showStatementSheet(context);
                  }),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    secondary: Icon(Icons.dark_mode_outlined,
                        color: AppColors.inkDim, size: 22),
                    title: Text('Dark mode', style: AppText.body),
                    value: variant == AppThemeVariant.dark,
                    onChanged: (on) => ref
                        .read(themeVariantProvider.notifier)
                        .set(on ? AppThemeVariant.dark : AppThemeVariant.light),
                  ),
                ],
              ),
            ),
            const Divider(),
            _Item(Icons.logout_rounded, 'Log out',
                color: AppColors.critical,
                onTap: () => confirmSignOut(context, ref)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.icon, this.label,
      {required this.onTap, this.selected = false, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? (selected ? AppColors.primary : AppColors.ink);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? AppColors.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Icon(icon,
                  size: 22, color: color ?? (selected ? c : AppColors.inkDim)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: c)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The supplier's contact details from their invoice settings — so a
/// retailer can call or write to the business straight from the app.
final _supplierProvider =
    FutureProvider.autoDispose<InvoiceBranding?>((ref) async {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return null;
  return InvoiceBranding.load(
      ref.watch(firestoreProvider), user.tenantId, user.businessName);
});

/// Business details (the web's Overview / My Account tab), the supplier,
/// statement, appearance, password and sign-out.
class PortalAccountScreen extends ConsumerWidget {
  const PortalAccountScreen({super.key});

  Future<void> _resetPassword(BuildContext context, WidgetRef ref) async {
    final email = ref.read(appUserProvider).valueOrNull?.email ?? '';
    final messenger = ScaffoldMessenger.of(context);
    if (email.isEmpty) return;
    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(email);
      messenger.showSnackBar(
          SnackBar(content: Text('Password reset link sent to $email')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not send the reset link. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(portalRetailerDocProvider).valueOrNull ??
        const <String, dynamic>{};
    final user = ref.watch(appUserProvider).valueOrNull;
    final supplier = ref.watch(_supplierProvider).valueOrNull;
    final supplierAddress = supplier?.address ?? '';
    final supplierPhone = supplier?.contact ?? '';
    final supplierEmail = supplier?.email ?? '';
    String v(String k) {
      final s = (r[k] ?? '').toString().trim();
      return s.isEmpty ? '—' : s;
    }

    final details = [
      ('Business name', v('name')),
      ('Contact', v('number')),
      ('Email', v('email')),
      ('Village / At post', v('atPost')),
      ('Taluka', v('taluka')),
      ('District', v('district')),
      ('State', v('state')),
      ('GSTIN', v('gstin')),
      ('Licence number', v('licenseNumber')),
      ('Customer type', v('portfolioSize')),
    ];

    // Rendered inside the shell's Scaffold (it owns the drawer and
    // bottom bar); a Scaffold here would swallow the menu button.
    return Column(
      children: [
        const PageHeader(title: 'Account'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              const SectionHeader('Business details'),
              AppCard(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Column(children: [
                  for (var i = 0; i < details.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    InfoRow(details[i].$1, details[i].$2),
                  ],
                ]),
              ),
              const SizedBox(height: 6),
              Text(
                  'To change these details, contact ${user?.businessName ?? 'your supplier'}.',
                  style: AppText.small),
              const SectionHeader('Your supplier'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(supplier?.businessName ?? user?.businessName ?? '',
                        style:
                            AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    if (supplierAddress.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(supplierAddress, style: AppText.small),
                    ],
                    if (supplierPhone.isNotEmpty || supplierEmail.isNotEmpty)
                      const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (supplierPhone.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(
                              Uri(scheme: 'tel', path: supplierPhone)),
                          icon: const Icon(Icons.call_outlined, size: 18),
                          label: Text(supplierPhone),
                        ),
                      if (supplierEmail.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(
                              Uri(scheme: 'mailto', path: supplierEmail)),
                          icon:
                              const Icon(Icons.mail_outline_rounded, size: 18),
                          label: const Text('Email'),
                        ),
                    ]),
                  ],
                ),
              ),
              const SectionHeader('Statement'),
              OutlinedButton.icon(
                onPressed: () => showStatementSheet(context),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download account statement'),
              ),
              const SectionHeader('Login'),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  ListTile(
                    leading: Icon(Icons.alternate_email_rounded,
                        color: AppColors.inkDim),
                    title: Text('Signed in as', style: AppText.small),
                    subtitle: Text(user?.email ?? '', style: AppText.body),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading:
                        Icon(Icons.lock_reset_rounded, color: AppColors.inkDim),
                    title: Text('Change password', style: AppText.body),
                    subtitle: Text('We\'ll email you a reset link',
                        style: AppText.small),
                    onTap: () => _resetPassword(context, ref),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading:
                        Icon(Icons.logout_rounded, color: AppColors.critical),
                    title: Text('Log out',
                        style:
                            AppText.body.copyWith(color: AppColors.critical)),
                    onTap: () => confirmSignOut(context, ref),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
