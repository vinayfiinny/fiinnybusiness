import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../widgets/ui.dart';
import '../customers/customer.dart';
import '../customers/customers_repository.dart';
import 'invite_retailer_sheet.dart';
import 'portal_access_repository.dart';

/// Every retailer login of this business, with invite and remove — the
/// "Invite Retailer" part of the web's Admin → Manage Users.
class PortalAccessScreen extends ConsumerWidget {
  const PortalAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(canInviteRetailersProvider);
    final logins = ref.watch(portalLoginsProvider);
    final customers = ref.watch(customersProvider).valueOrNull ?? const <Customer>[];
    final byId = {for (final c in customers) c.id: c};

    return Scaffold(
      appBar: AppBar(title: const Text('Retailer portal access')),
      floatingActionButton: allowed == true
          ? FloatingActionButton.extended(
              onPressed: () => showInviteRetailerSheet(context),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Invite retailer'),
            )
          : null,
      body: allowed == null
          ? const Center(child: CircularProgressIndicator())
          : allowed == false
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: EmptyNote(
                    'Only the business admin can give retailers portal access '
                    '(and your plan must include Admin).',
                    icon: Icons.lock_outline_rounded,
                  ),
                )
              : logins.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(portalLoginsProvider)),
                  data: (list) => ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    children: [
                      Text(
                        'Invited retailers sign in to this app or the web ERP and see only their own '
                        'bills, payments and balance. They cannot change anything.',
                        style: AppText.label,
                      ),
                      const SizedBox(height: 14),
                      if (list.isEmpty)
                        const EmptyNote('No retailer has portal access yet.', icon: Icons.storefront_outlined)
                      else
                        for (final l in list) ...[
                          PortalLoginTile(login: l, retailer: byId[l.retailerId]),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
    );
  }
}

/// One login: who it is for, the email, when it was made, and Remove.
class PortalLoginTile extends ConsumerWidget {
  const PortalLoginTile({super.key, required this.login, this.retailer, this.showRetailer = true});
  final PortalLogin login;
  final Customer? retailer;
  final bool showRetailer;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(portalAccessRepositoryProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove portal access?'),
        content: Text(
          '${login.email} will no longer be able to see ${retailer?.name ?? 'this retailer'}\'s bills '
          'and payments. Their bills and balance are not affected.',
          style: TextStyle(color: AppColors.inkDim),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.critical, minimumSize: const Size(0, 42)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || repo == null) return;
    try {
      await repo.remove(login);
      messenger.showSnackBar(SnackBar(content: Text('Portal access removed for ${login.email}')));
    } on InviteException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not remove access. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = showRetailer ? (retailer?.name ?? (login.name.isNotEmpty ? login.name : 'Retailer')) : login.email;
    final sub = [
      if (showRetailer) login.email,
      if (login.createdAt != null) 'since ${fmtFullDate(login.createdAt!)}',
      if (showRetailer && retailer == null) 'retailer record not found',
    ].join(' · ');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(children: [
        IconBadge(icon: Icons.storefront_outlined, color: AppColors.b2b, size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            if (sub.isNotEmpty)
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.small),
          ]),
        ),
        IconButton(
          tooltip: 'Remove access',
          icon: Icon(Icons.person_remove_outlined, color: AppColors.critical),
          onPressed: () => _remove(context, ref),
        ),
      ]),
    );
  }
}

/// "Portal access" block on a B2B partner's detail screen: their logins, or
/// a button to invite them. Renders nothing for people who can't invite.
class PartnerPortalAccessCard extends ConsumerWidget {
  const PartnerPortalAccessCard({super.key, required this.customer});
  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (customer.isPosCustomer || ref.watch(canInviteRetailersProvider) != true) {
      return const SizedBox.shrink();
    }
    final mine = (ref.watch(portalLoginsProvider).valueOrNull ?? const <PortalLogin>[])
        .where((l) => l.retailerId == customer.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Portal access',
          actionLabel: mine.isEmpty ? null : 'Add login',
          onAction: () => showInviteRetailerSheet(context, retailer: customer),
        ),
        if (mine.isEmpty)
          AppCard(
            child: Row(children: [
              Expanded(
                child: Text('${customer.name} can\'t see their bills in the app yet.', style: AppText.label),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: () => showInviteRetailerSheet(context, retailer: customer),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: const Text('Invite'),
              ),
            ]),
          )
        else
          for (final l in mine) ...[
            PortalLoginTile(login: l, retailer: customer, showRetailer: false),
            const SizedBox(height: 6),
          ],
      ],
    );
  }
}
