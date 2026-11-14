import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../widgets/form_bits.dart' show fmtInr2;
import '../../widgets/ui.dart';
import '../auth/auth_repository.dart';
import 'portal_models.dart';
import 'portal_repository.dart';
import 'portal_widgets.dart';

/// Retailer Home: what they owe, how much they've bought and paid, a
/// six-month trend, and their latest bills and payments. The header figures
/// are all time, from every bill and payment — the web's financial cards and
/// Partner Analytics compute them the same way.
class PortalHomeScreen extends ConsumerWidget {
  const PortalHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(portalAccessProvider);
    final summary = ref.watch(portalSummaryProvider);
    final bills =
        ref.watch(portalBillsProvider).valueOrNull ?? const <PortalBill>[];
    final payments = ref.watch(portalPaymentsProvider).valueOrNull ??
        const <PortalPayment>[];

    void go(PortalTab t) => ref.read(portalTabProvider.notifier).state = t;

    // Rendered inside the shell's Scaffold (it owns the drawer and
    // bottom bar); a Scaffold here would swallow the menu button.
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () async {
        ref.invalidate(portalBillDocsProvider);
        ref.invalidate(portalPaymentDocsProvider);
        await ref.read(portalBillDocsProvider.future);
      },
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const _Header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: summary.when(
              loading: () => const Column(children: [
                SizedBox(height: 16),
                SkeletonBox(height: 120),
                SizedBox(height: 12),
                SkeletonBox(height: 160),
              ]),
              error: (e, _) => Padding(
                padding: const EdgeInsets.only(top: 24),
                child: ErrorState(
                  error: e,
                  onRetry: () {
                    ref.invalidate(portalBillDocsProvider);
                    ref.invalidate(portalPaymentDocsProvider);
                  },
                ),
              ),
              data: (s) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader('Account summary'),
                  Row(children: [
                    Expanded(
                      child: StatTile(
                        label: 'Bills',
                        value: '${s.billCount}',
                        icon: Icons.receipt_long_outlined,
                        color: AppColors.primary,
                        sub: '${s.paidBills} paid',
                        onTap: access.bills ? () => go(PortalTab.bills) : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'Average bill',
                        value: fmtInrCompact(s.averageBill),
                        icon: Icons.calculate_outlined,
                        color: AppColors.b2b,
                        sub: 'per bill',
                      ),
                    ),
                  ]),
                  const SectionHeader('Purchases · last 6 months'),
                  AppCard(
                      child: _MonthlyBars(
                          points: monthlyBilled(bills, DateTime.now()))),
                  if (access.bills) ...[
                    SectionHeader(
                      'Recent bills',
                      actionLabel: bills.isEmpty ? null : 'See all',
                      onAction: () => go(PortalTab.bills),
                    ),
                    if (bills.isEmpty)
                      const EmptyNote('No bills yet.',
                          icon: Icons.receipt_long_outlined)
                    else
                      for (final b in bills.take(5)) ...[
                        PortalBillTile(bill: b),
                        const SizedBox(height: 8),
                      ],
                  ],
                  if (access.payments) ...[
                    SectionHeader(
                      'Recent payments',
                      actionLabel: payments.isEmpty ? null : 'See all',
                      onAction: () => go(PortalTab.payments),
                    ),
                    if (payments.isEmpty)
                      const EmptyNote('No payments recorded yet.',
                          icon: Icons.payments_outlined)
                    else
                      for (final p in payments.take(3)) ...[
                        PortalPaymentTile(payment: p),
                        const SizedBox(height: 8),
                      ],
                  ],
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => showStatementSheet(context),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Download account statement'),
                  ),
                  const SizedBox(height: 14),
                  const _ViewOnlyNote(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).valueOrNull;
    final retailer = ref.watch(portalRetailerDocProvider).valueOrNull;
    final top = MediaQuery.paddingOf(context).top;
    final fg = AppColors.onHeader;
    final name = (retailer?['name'] as String?)?.trim();

    return Stack(
      children: [
        Container(height: top + 128, color: AppColors.header),
        Column(
          children: [
            SizedBox(height: top),
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Menu',
                    onPressed: () => Scaffold.of(context).openDrawer(),
                    icon: Icon(Icons.menu_rounded, color: fg),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          greetingFor(DateTime.now().hour),
                          style: TextStyle(
                              fontSize: 12.5,
                              color: fg.withValues(alpha: 0.78)),
                        ),
                        Text(
                          (name == null || name.isEmpty)
                              ? (user?.name ?? '')
                              : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: fg),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _BalanceCard(),
            ),
          ],
        ),
      ],
    );
  }
}

/// Outstanding up front, then billed / paid and the paid share.
class _BalanceCard extends ConsumerWidget {
  const _BalanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(portalSummaryProvider).valueOrNull;
    final user = ref.watch(appUserProvider).valueOrNull;
    final due = s?.outstanding ?? 0;
    final clear = s != null && due <= 0;

    return Semantics(
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
          boxShadow: const [
            BoxShadow(
                color: Color(0x1A10234A), blurRadius: 20, offset: Offset(0, 8))
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Outstanding with ${user?.businessName ?? 'your supplier'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  s == null ? '—' : fmtInr2(due),
                  style: AppText.figure.copyWith(
                    fontSize: 28,
                    color: s == null
                        ? AppColors.ink
                        : (clear ? AppColors.good : AppColors.critical),
                  ),
                ),
                if (clear && s.totalBilled > 0) ...[
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: StatusChip('All clear', color: AppColors.good),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                semanticsLabel: 'Paid share',
                semanticsValue: '${s?.paidPercent ?? 0}%',
                value: (s?.paidPercent ?? 0) / 100,
                minHeight: 7,
                backgroundColor: AppColors.border,
                valueColor: AlwaysStoppedAnimation(AppColors.good),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _Figure('Total billed',
                        s == null ? '—' : fmtInr(s.totalBilled))),
                Expanded(
                  child: _Figure('Paid', s == null ? '—' : fmtInr(s.totalPaid),
                      color: AppColors.good),
                ),
                _Figure('Paid share', s == null ? '—' : '${s.paidPercent}%',
                    end: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.color, this.end = false});
  final String label;
  final String value;
  final Color? color;
  final bool end;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment:
            end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.small),
          const SizedBox(height: 2),
          Text(value, style: AppText.amount.copyWith(color: color)),
        ],
      );
}

/// Six month bars, labelled, scaled to the busiest month.
class _MonthlyBars extends StatelessWidget {
  const _MonthlyBars({required this.points});
  final List<(DateTime, double)> points;

  @override
  Widget build(BuildContext context) {
    final max = points.fold<double>(0, (m, p) => p.$2 > m ? p.$2 : m);
    if (max <= 0) {
      return SizedBox(
        height: 120,
        child: Center(
            child: Text('No purchases in the last 6 months.',
                style: AppText.label)),
      );
    }
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (month, total) in points)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(total > 0 ? fmtInrCompact(total) : '',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: AppText.small.copyWith(fontSize: 10)),
                    const SizedBox(height: 4),
                    Container(
                      height: total <= 0 ? 2 : 4 + 90 * (total / max),
                      decoration: BoxDecoration(
                        color:
                            total <= 0 ? AppColors.border : AppColors.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(DateFormat('MMM').format(month), style: AppText.small),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ViewOnlyNote extends ConsumerWidget {
  const _ViewOnlyNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final business =
        ref.watch(appUserProvider).valueOrNull?.businessName ?? 'your supplier';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.visibility_outlined, size: 16, color: AppColors.inkMute),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'View-only account. Your bills and payments are recorded by $business — '
            'contact them to place an order or correct anything.',
            style: AppText.small,
          ),
        ),
      ],
    );
  }
}
