import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../widgets/ui.dart';
import 'portal_models.dart';
import 'portal_repository.dart';
import 'portal_widgets.dart';

/// Payment filter of the web's B2B Orders table.
enum BillPayFilter { all, paid, pending, partial }

extension on BillPayFilter {
  String get label => switch (this) {
        BillPayFilter.all => 'All',
        BillPayFilter.paid => 'Paid',
        BillPayFilter.pending => 'Pending',
        BillPayFilter.partial => 'Partial',
      };

  /// soFPayment in WorklistDetailsPage.tsx, rule for rule.
  bool matches(PortalBill b) => switch (this) {
        BillPayFilter.all => true,
        BillPayFilter.paid => b.fullyPaid,
        BillPayFilter.pending => !b.fullyPaid &&
            (b.paymentStatus.isEmpty ? 'Pending' : b.paymentStatus) ==
                'Pending',
        BillPayFilter.partial => b.paymentStatus == 'Partial',
      };
}

/// The retailer's own bills — the web's "B2B Orders" tab.
class PortalBillsScreen extends ConsumerStatefulWidget {
  const PortalBillsScreen({super.key});

  @override
  ConsumerState<PortalBillsScreen> createState() => _PortalBillsScreenState();
}

class _PortalBillsScreenState extends ConsumerState<PortalBillsScreen> {
  BillPayFilter _filter = BillPayFilter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(portalBillsProvider);
    final bounds = ref.watch(portalBoundsProvider);

    // Rendered inside the shell's Scaffold (it owns the drawer and
    // bottom bar); a Scaffold here would swallow the menu button.
    return Column(
      children: [
        const PageHeader(title: 'My bills'),
        const SizedBox(height: 10),
        const PortalPeriodBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search bill number',
              prefixIcon: Icon(Icons.search_rounded, size: 21),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorState(
                error: e,
                onRetry: () => ref.invalidate(portalBillDocsProvider)),
            data: (all) {
              final inPeriod = billsInPeriod(all, bounds);
              final counts = {
                for (final f in BillPayFilter.values)
                  f: inPeriod.where(f.matches).length,
              };
              final shown = inPeriod
                  .where(_filter.matches)
                  .where((b) =>
                      _query.isEmpty || b.number.toLowerCase().contains(_query))
                  .toList();
              final billed = shown.fold<double>(0, (s, b) => s + b.total);
              final due = shown.fold<double>(0, (s, b) => s + b.outstanding);

              return RefreshIndicator(
                color: AppColors.primary,
                onRefresh: () async {
                  ref.invalidate(portalBillDocsProvider);
                  await ref.read(portalBillDocsProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final f in BillPayFilter.values)
                          ChoiceChip(
                            label: Text('${f.label} · ${counts[f]}'),
                            selected: _filter == f,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (shown.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${shown.length} bill${shown.length == 1 ? '' : 's'} · ${fmtInr(billed)} billed'
                          '${due > 0 ? ' · ${fmtInr(due)} due' : ''}',
                          style: AppText.label,
                        ),
                      ),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: EmptyNote(
                          all.isEmpty
                              ? 'No bills yet.'
                              : (inPeriod.isEmpty
                                  ? 'No bills in the selected period.'
                                  : 'No bills match these filters.'),
                          icon: Icons.receipt_long_outlined,
                        ),
                      )
                    else
                      for (final b in shown) ...[
                        PortalBillTile(bill: b),
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
