import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../widgets/ui.dart';
import 'portal_models.dart';
import 'portal_repository.dart';
import 'portal_widgets.dart';

/// Payments the business has recorded from this retailer — the web's
/// Payments tab (retailers/{id}/payments), newest first.
class PortalPaymentsScreen extends ConsumerWidget {
  const PortalPaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(portalPaymentsProvider);
    final bounds = ref.watch(portalBoundsProvider);

    // Rendered inside the shell's Scaffold (it owns the drawer and
    // bottom bar); a Scaffold here would swallow the menu button.
    return Column(
      children: [
        const PageHeader(title: 'My payments'),
        const SizedBox(height: 10),
        const PortalPeriodBar(),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorState(
                error: e,
                onRetry: () => ref.invalidate(portalPaymentDocsProvider)),
            data: (all) {
              final shown = paymentsInPeriod(all, bounds);
              final total = shown.fold<double>(0, (s, p) => s + p.amount);
              return RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () async {
                  ref.invalidate(portalPaymentDocsProvider);
                  await ref.read(portalPaymentDocsProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (shown.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${shown.length} payment${shown.length == 1 ? '' : 's'} · ${fmtInr(total)} paid',
                          style: AppText.label,
                        ),
                      ),
                    if (shown.isEmpty)
                      EmptyNote(
                        all.isEmpty
                            ? 'No payments recorded yet.'
                            : 'No payments in the selected period.',
                        icon: Icons.payments_outlined,
                      )
                    else
                      for (final p in shown) ...[
                        PortalPaymentTile(payment: p),
                        const SizedBox(height: 8),
                      ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Quantity bought per product across the retailer's bills — the web's
/// Product Sales tab.
class PortalProductsScreen extends ConsumerWidget {
  const PortalProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(portalBillsProvider);
    final bounds = ref.watch(portalBoundsProvider);

    // Rendered inside the shell's Scaffold (it owns the drawer and
    // bottom bar); a Scaffold here would swallow the menu button.
    return Column(
      children: [
        const PageHeader(title: 'Products bought'),
        const SizedBox(height: 10),
        const PortalPeriodBar(),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorState(
                error: e,
                onRetry: () => ref.invalidate(portalBillDocsProvider)),
            data: (all) {
              final rows = productSales(billsInPeriod(all, bounds));
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (rows.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                          '${rows.length} product${rows.length == 1 ? '' : 's'}',
                          style: AppText.label),
                    ),
                  if (rows.isEmpty)
                    EmptyNote(
                      all.isEmpty
                          ? 'No bills yet.'
                          : 'No products in the selected period.',
                      icon: Icons.inventory_2_outlined,
                    )
                  else
                    for (final r in rows) ...[
                      _ProductTile(row: r),
                      const SizedBox(height: 8),
                    ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.row});
  final ProductSale row;

  @override
  Widget build(BuildContext context) {
    final last = DateTime.tryParse(row.lastInvoiceDate);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Text(_qty(row.totalQty), style: AppText.amount),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              '${row.invoiceCount} bill${row.invoiceCount == 1 ? '' : 's'}',
              if (last != null) 'last ${fmtFullDate(last)}',
            ].join(' · '),
            style: AppText.small,
          ),
          const SizedBox(height: 8),
          Row(children: [
            StatusChip('Paid ${_qty(row.paidQty)}', color: AppColors.good),
            const SizedBox(width: 8),
            if (row.unpaidQty > 0)
              StatusChip('Unpaid ${_qty(row.unpaidQty)}',
                  color: AppColors.critical),
          ]),
        ],
      ),
    );
  }
}

String _qty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
