import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../widgets/form_bits.dart' show fmtInr2;
import '../../widgets/ui.dart';
import '../auth/auth_repository.dart';
import '../billing/bill_detail_screen.dart';
import 'portal_models.dart';
import 'portal_repository.dart';
import 'statement_pdf.dart';

/// Re-created per signed-in user so the next login starts clean.
String? _uid(Ref ref) =>
    ref.watch(authStateProvider.select((a) => a.valueOrNull?.uid));

enum PortalTab { home, bills, payments, products, account }

final portalTabProvider = StateProvider<PortalTab>((ref) {
  _uid(ref);
  return PortalTab.home;
});

/// One period for Bills, Payments and Products — the web shares a single
/// date filter across those three tabs too.
final portalPeriodProvider = StateProvider<PortalPeriod>((ref) {
  _uid(ref);
  return PortalPeriod.all;
});

final portalCustomRangeProvider = StateProvider<DateTimeRange?>((ref) {
  _uid(ref);
  return null;
});

/// The active period's yyyy-mm-dd bounds (null = all time).
final portalBoundsProvider = Provider<(String, String)?>((ref) {
  final p = ref.watch(portalPeriodProvider);
  final custom = ref.watch(portalCustomRangeProvider);
  return periodBounds(p, DateTime.now(),
      customFrom: custom?.start, customTo: custom?.end);
});

/// Horizontal period chips; "Custom" opens a date-range picker.
class PortalPeriodBar extends ConsumerWidget {
  const PortalPeriodBar({super.key});

  Future<void> _pickCustom(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: ref.read(portalCustomRangeProvider),
    );
    if (picked == null) return;
    ref.read(portalCustomRangeProvider.notifier).state = picked;
    ref.read(portalPeriodProvider.notifier).state = PortalPeriod.custom;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(portalPeriodProvider);
    final custom = ref.watch(portalCustomRangeProvider);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final p in PortalPeriod.values) ...[
            ChoiceChip(
              label: Text(p == PortalPeriod.custom &&
                      selected == p &&
                      custom != null
                  ? '${fmtDayMonth(custom.start)} – ${fmtDayMonth(custom.end)}'
                  : p.label),
              avatar: p == PortalPeriod.custom
                  ? Icon(Icons.date_range_rounded,
                      size: 16,
                      color: selected == p
                          ? AppColors.onPrimary
                          : AppColors.inkDim)
                  : null,
              selected: selected == p,
              showCheckmark: false,
              selectedColor: AppColors.primary,
              labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected == p ? AppColors.onPrimary : AppColors.inkDim,
              ),
              onSelected: (_) => p == PortalPeriod.custom
                  ? _pickCustom(context, ref)
                  : ref.read(portalPeriodProvider.notifier).state = p,
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

Color billPaymentColor(PortalBill b) => b.fullyPaid
    ? AppColors.good
    : b.paymentLabel == 'Partial'
        ? AppColors.warning
        : AppColors.critical;

/// One bill: number, date, items, total, payment chip and what is still due.
class PortalBillTile extends StatelessWidget {
  const PortalBillTile({super.key, required this.bill});
  final PortalBill bill;

  @override
  Widget build(BuildContext context) {
    final b = bill;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => BillDetailScreen(orderId: b.id, portal: true))),
      child: Row(
        children: [
          IconBadge(
            icon: Icons.receipt_long_outlined,
            color: b.isGst ? AppColors.b2b : AppColors.primary,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(b.number,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (b.isGst) ...[
                    const SizedBox(width: 6),
                    Text('GST',
                        style: AppText.small.copyWith(
                            color: AppColors.b2b, fontWeight: FontWeight.w700)),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    if (b.date != null) fmtFullDate(b.date!),
                    '${b.itemCount} item${b.itemCount == 1 ? '' : 's'}',
                    if (b.status.isNotEmpty) _cap(b.status),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(fmtInr2(b.total), style: AppText.amount),
              const SizedBox(height: 4),
              StatusChip(b.paymentLabel, color: billPaymentColor(b)),
              if (b.outstanding > 0) ...[
                const SizedBox(height: 3),
                Text('Due ${fmtInr(b.outstanding)}',
                    style: AppText.small.copyWith(
                        color: AppColors.critical,
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// One payment the business recorded from this retailer.
class PortalPaymentTile extends StatelessWidget {
  const PortalPaymentTile({super.key, required this.payment});
  final PortalPayment payment;

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final (label, color) = switch (p.allocation) {
      PaymentAllocation.fullyAllocated => ('Adjusted to bills', AppColors.good),
      PaymentAllocation.partlyAllocated => (
          '${fmtInr(p.unallocated)} not yet adjusted',
          AppColors.warning
        ),
      PaymentAllocation.available => (
          '${fmtInr(p.unallocated)} not yet adjusted',
          AppColors.warning
        ),
    };
    final detail = [
      if (p.date != null) fmtFullDate(p.date!),
      if (p.method.isNotEmpty) p.method,
      if (p.transactionRef.isNotEmpty) 'Ref ${p.transactionRef}',
    ].join(' · ');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
              icon: Icons.south_west_rounded, color: AppColors.good, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.reference,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail, style: AppText.small),
                if (p.notes.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(p.notes,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.small),
                ],
                const SizedBox(height: 6),
                // A plain coloured line, not a chip: the label can be long
                // ("₹12,500 not yet adjusted") and must wrap on small phones.
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(fmtInr2(p.amount),
              style: AppText.amount.copyWith(color: AppColors.good)),
        ],
      ),
    );
  }
}

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// "Download statement": optional From / To dates (blank = all), then the
/// same ledger PDF the web makes, shared through the system sheet.
Future<void> showStatementSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _StatementSheet(),
    );

class _StatementSheet extends ConsumerStatefulWidget {
  const _StatementSheet();

  @override
  ConsumerState<_StatementSheet> createState() => _StatementSheetState();
}

class _StatementSheetState extends ConsumerState<_StatementSheet> {
  DateTime? _from;
  DateTime? _to;
  bool _busy = false;
  String? _error;

  Future<void> _pick(bool from) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDate: (from ? _from : _to) ?? now,
    );
    if (picked != null) setState(() => from ? _from = picked : _to = picked);
  }

  Future<void> _make() async {
    final user = ref.read(appUserProvider).valueOrNull;
    final retailer = ref.read(portalRetailerDocProvider).valueOrNull;
    if (user == null || retailer == null) return;
    if (_from != null && _to != null && _from!.isAfter(_to!)) {
      setState(() => _error = '"From" must be on or before "To".');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bills = await ref.read(portalBillDocsProvider.future);
      final payments = await ref.read(portalPaymentDocsProvider.future);
      final st = buildStatement(
          billDocs: bills, paymentDocs: payments, from: _from, to: _to);
      final issuer = await statementIssuer(ref.read(firestoreProvider), user);
      final name = (retailer['name'] as String?)?.trim().isNotEmpty == true
          ? (retailer['name'] as String).trim()
          : 'Retailer';
      final bytes = await buildStatementPdf(
        st: st,
        issuer: issuer,
        party: StatementParty(
          name: name,
          atPost: (retailer['atPost'] as String?) ?? '',
          taluka: (retailer['taluka'] as String?) ?? '',
          district: (retailer['district'] as String?) ?? '',
        ),
      );
      await Printing.sharePdf(
          bytes: bytes, filename: statementFileName(name, DateTime.now()));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'Could not create the statement. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget dateBox(String label, DateTime? v, bool from) => Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : () => _pick(from),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: AppText.small),
                Text(v == null ? 'Any date' : fmtFullDate(v),
                    style: AppText.body),
              ],
            ),
          ),
        );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Account statement', style: AppText.title),
            const SizedBox(height: 4),
            Text(
                'Every bill and payment with a running balance. Leave the dates blank for all transactions.',
                style: AppText.label),
            const SizedBox(height: 16),
            Row(children: [
              dateBox('From', _from, true),
              const SizedBox(width: 10),
              dateBox('To', _to, false),
            ]),
            if (_from != null || _to != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed:
                      _busy ? null : () => setState(() => _from = _to = null),
                  child: const Text('Clear dates'),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: AppColors.critical, fontSize: 13)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _make,
              icon: _busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.onPrimary),
                    )
                  : const Icon(Icons.picture_as_pdf_rounded, size: 18),
              label: Text(_busy ? 'Preparing…' : 'Download statement'),
            ),
          ],
        ),
      ),
    );
  }
}
