import 'dart:math' as math;

import '../../core/parse.dart';
import '../analytics/models.dart' show tsToDate;

/// Everything the retailer portal shows is computed here, from the same
/// documents and with the same formulas as the web retailer view
/// (WorklistDetailsPage.tsx opened by a retailer portal user). Plain Dart on
/// raw maps, so the numbers can be tested without Firestore — and so app and
/// web always agree, including on legacy data where they both look odd.

// ── Period filter (financialPeriod.ts) ───────────────────────────────────────

enum PortalPeriod { all, today, week, month, fy, custom }

extension PortalPeriodX on PortalPeriod {
  String get label => switch (this) {
        PortalPeriod.all => 'All time',
        PortalPeriod.today => 'Today',
        PortalPeriod.week => 'This week',
        PortalPeriod.month => 'This month',
        PortalPeriod.fy => 'This FY',
        PortalPeriod.custom => 'Custom',
      };
}

/// Inclusive yyyy-mm-dd bounds, compared as strings like the web does
/// (bills by invoiceDate, payments by paymentDate). null = no filter.
/// The web derives "today" from toISOString() (UTC); here it is the phone's
/// local day, which is what the user means near midnight in India.
(String, String)? periodBounds(PortalPeriod p, DateTime now,
    {DateTime? customFrom, DateTime? customTo}) {
  final today = isoDay(now);
  switch (p) {
    case PortalPeriod.all:
      return null;
    case PortalPeriod.today:
      return (today, today);
    case PortalPeriod.week:
      final monday = now.subtract(Duration(days: now.weekday - 1));
      return (isoDay(monday), today);
    case PortalPeriod.month:
      return (isoDay(DateTime(now.year, now.month, 1)), today);
    case PortalPeriod.fy:
      // Indian financial year: 1 April – 31 March.
      final startYear = now.month >= 4 ? now.year : now.year - 1;
      return (isoDay(DateTime(startYear, 4, 1)), today);
    case PortalPeriod.custom:
      if (customFrom == null || customTo == null) return null;
      return (isoDay(customFrom), isoDay(customTo));
  }
}

bool _inBounds(String day, (String, String)? b) =>
    b == null ||
    (day.isNotEmpty && day.compareTo(b.$1) >= 0 && day.compareTo(b.$2) <= 0);

// ── Bills ────────────────────────────────────────────────────────────────────

class PortalBill {
  const PortalBill({
    required this.id,
    required this.number,
    required this.invoiceDate,
    required this.date,
    required this.total,
    required this.amountPaid,
    required this.status,
    required this.paymentStatus,
    required this.isGst,
    required this.items,
  });

  final String id;

  /// orderNumber || invoiceNumber || last 8 of the id, upper-cased.
  final String number;

  /// Raw yyyy-mm-dd ('' when the bill has none — the period filter then
  /// leaves it out, exactly like the web).
  final String invoiceDate;

  /// invoiceDate, else createdAt — for display and sorting.
  final DateTime? date;

  /// grandTotal ?? netAmount ?? totalAmount.
  final double total;
  final double amountPaid;

  /// Order lifecycle: draft / confirmed / dispatched / delivered / cancelled.
  final String status;

  /// The stored word: 'Paid' / 'Partial' / 'Pending' ('' if absent).
  final String paymentStatus;
  final bool isGst;
  final List<Map<String, dynamic>> items;

  double get outstanding => math.max(0, total - amountPaid);

  /// The web's ✅ Paid: something was received and nothing is left.
  bool get fullyPaid => total > 0 && outstanding == 0 && amountPaid > 0;

  /// What the web's Payment column prints: "Paid" when fully paid by amount,
  /// otherwise the stored status word (default "Pending").
  String get paymentLabel =>
      fullyPaid ? 'Paid' : (paymentStatus.isEmpty ? 'Pending' : paymentStatus);

  /// Product Sales counts a bill as paid by its stored status (the web does).
  bool get paidByStatus => paymentStatus.toLowerCase() == 'paid';

  int get itemCount => items.length;

  static PortalBill fromDoc(String id, Map<String, dynamic> d) {
    final raw = d['lineItems'] ?? d['items'];
    return PortalBill(
      id: id,
      number: str(d['orderNumber']).isNotEmpty
          ? str(d['orderNumber'])
          : str(d['invoiceNumber']).isNotEmpty
              ? str(d['invoiceNumber'])
              : _tail(id, 8),
      invoiceDate: str(d['invoiceDate']),
      date:
          DateTime.tryParse(str(d['invoiceDate'])) ?? tsToDate(d['createdAt']),
      total: dbl(d['grandTotal'] ?? d['netAmount'] ?? d['totalAmount']),
      amountPaid: dbl(d['amountPaid']),
      status: str(d['status']),
      paymentStatus: str(d['paymentStatus']),
      isGst: str(d['invoiceType']) == 'B2B_GST',
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map) Map<String, dynamic>.from(e)
            ]
          : const [],
    );
  }
}

/// salesOrders where retailerId == linkedId → visible bills: deleted ones
/// dropped, newest first by invoiceDate (yyyy-mm-dd), then createdAt — the
/// web's sort, so lists match row for row.
List<PortalBill> billsFromDocs(Iterable<(String, Map<String, dynamic>)> docs) {
  final rows = <(PortalBill, String, int)>[];
  for (final (id, d) in docs) {
    if (d['deleted'] == true) continue;
    final created = tsToDate(d['createdAt'])?.millisecondsSinceEpoch ?? 0;
    rows.add((PortalBill.fromDoc(id, d), str(d['invoiceDate']), created));
  }
  rows.sort((a, b) {
    final (_, ad, ac) = a;
    final (_, bd, bc) = b;
    if (ad.isNotEmpty && bd.isNotEmpty) return bd.compareTo(ad);
    if (ad.isNotEmpty) return -1;
    if (bd.isNotEmpty) return 1;
    return bc.compareTo(ac);
  });
  return [for (final (b, _, _) in rows) b];
}

List<PortalBill> billsInPeriod(List<PortalBill> all, (String, String)? b) =>
    b == null ? all : all.where((x) => _inBounds(x.invoiceDate, b)).toList();

// ── Payments ─────────────────────────────────────────────────────────────────

enum PaymentAllocation { fullyAllocated, partlyAllocated, available }

class PortalPayment {
  const PortalPayment({
    required this.id,
    required this.reference,
    required this.amount,
    required this.paymentDate,
    required this.date,
    required this.method,
    required this.notes,
    required this.transactionRef,
    required this.linkedCount,
    required this.unallocated,
  });

  final String id;

  /// paymentId, else "#" + last 6 of the id.
  final String reference;
  final double amount;
  final String paymentDate;
  final DateTime? date;
  final String method;
  final String notes;
  final String transactionRef;
  final int linkedCount;
  final double unallocated;

  /// The web's Status column: linked to bills AND money left → partly; linked
  /// → fully allocated; not linked with money left → available; else fully.
  PaymentAllocation get allocation {
    final linked = linkedCount > 0;
    final available = unallocated > 0;
    if (linked && available) return PaymentAllocation.partlyAllocated;
    if (!linked && available) return PaymentAllocation.available;
    return PaymentAllocation.fullyAllocated;
  }

  static PortalPayment fromDoc(String id, Map<String, dynamic> d) {
    final linked = d['linkedOrderIds'];
    final account = d['accountDetails'];
    return PortalPayment(
      id: id,
      reference: str(d['paymentId']).isNotEmpty
          ? str(d['paymentId'])
          : '#${_tail(id, 6)}',
      amount: dbl(d['amount']),
      paymentDate: str(d['paymentDate']),
      date:
          DateTime.tryParse(str(d['paymentDate'])) ?? tsToDate(d['createdAt']),
      method: str(d['paymentMethod']),
      notes: str(d['notes']),
      transactionRef: account is Map ? str(account['transactionRef']) : '',
      linkedCount: linked is List
          ? linked.length
          : (str(d['orderId']).isNotEmpty ? 1 : 0),
      unallocated: dbl(d['unallocatedAmount']),
    );
  }
}

/// retailers/{id}/payments → newest first by createdAt (web sorts the same
/// way, client-side).
List<PortalPayment> paymentsFromDocs(
    Iterable<(String, Map<String, dynamic>)> docs) {
  final rows = [
    for (final (id, d) in docs)
      (
        PortalPayment.fromDoc(id, d),
        tsToDate(d['createdAt'])?.millisecondsSinceEpoch ?? 0
      )
  ];
  rows.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (p, _) in rows) p];
}

List<PortalPayment> paymentsInPeriod(
        List<PortalPayment> all, (String, String)? b) =>
    b == null ? all : all.where((x) => _inBounds(x.paymentDate, b)).toList();

// ── Summary (header cards + Partner Analytics) ───────────────────────────────

class PortalSummary {
  const PortalSummary({
    required this.totalBilled,
    required this.totalPaid,
    required this.billCount,
    required this.paidBills,
  });

  /// Σ bill totals (all time) — the web's "Total Sales".
  final double totalBilled;

  /// Σ every payment received, linked or not — "Amount Paid".
  final double totalPaid;
  final int billCount;

  /// Bills whose stored paymentStatus is 'Paid' — "Paid Orders".
  final int paidBills;

  double get outstanding => math.max(0, totalBilled - totalPaid);

  /// "Completion": paid share of billed, capped at 100.
  int get paidPercent => totalBilled > 0
      ? math.min(100, (totalPaid / totalBilled * 100).round())
      : 0;

  double get averageBill =>
      billCount > 0 ? (totalBilled / billCount).roundToDouble() : 0;

  static PortalSummary of(
          List<PortalBill> bills, List<PortalPayment> payments) =>
      PortalSummary(
        totalBilled: bills.fold(0.0, (s, b) => s + b.total),
        totalPaid: payments.fold(0.0, (s, p) => s + p.amount),
        billCount: bills.length,
        paidBills: bills.where((b) => b.paymentStatus == 'Paid').length,
      );
}

/// Billed amount per calendar month for the last [months] months (oldest
/// first), bucketed by the bill's date.
List<(DateTime, double)> monthlyBilled(List<PortalBill> bills, DateTime now,
    {int months = 6}) {
  final starts = [
    for (var i = months - 1; i >= 0; i--) DateTime(now.year, now.month - i, 1)
  ];
  final totals = List<double>.filled(months, 0);
  for (final b in bills) {
    final d = b.date;
    if (d == null) continue;
    for (var i = 0; i < months; i++) {
      if (d.year == starts[i].year && d.month == starts[i].month) {
        totals[i] += b.total;
        break;
      }
    }
  }
  return [for (var i = 0; i < months; i++) (starts[i], totals[i])];
}

// ── Product Sales (productSalesData) ─────────────────────────────────────────

class ProductSale {
  ProductSale(this.name);

  final String name;
  double totalQty = 0;
  double paidQty = 0;
  double unpaidQty = 0;
  int invoiceCount = 0;
  String firstInvoiceDate = '';
  String lastInvoiceDate = '';
}

/// One row per product name across [bills]: quantities split by the bill's
/// stored payment status, invoice count, first/last invoice date. Sorted by
/// total quantity, largest first.
List<ProductSale> productSales(List<PortalBill> bills) {
  final map = <String, ProductSale>{};
  for (final b in bills) {
    for (final item in b.items) {
      final name = str(item['productName'] ?? item['itemDescription']).trim();
      if (name.isEmpty) continue;
      final qty = dbl(item['qty'] ?? item['quantity']);
      final row = map.putIfAbsent(name, () => ProductSale(name));
      row.totalQty += qty;
      if (b.paidByStatus) {
        row.paidQty += qty;
      } else {
        row.unpaidQty += qty;
      }
      row.invoiceCount += 1;
      final d = b.invoiceDate;
      if (d.isNotEmpty) {
        if (row.lastInvoiceDate.isEmpty ||
            d.compareTo(row.lastInvoiceDate) > 0) {
          row.lastInvoiceDate = d;
        }
        if (row.firstInvoiceDate.isEmpty ||
            d.compareTo(row.firstInvoiceDate) < 0) {
          row.firstInvoiceDate = d;
        }
      }
    }
  }
  final rows = map.values.toList()
    ..sort((a, b) => b.totalQty.compareTo(a.totalQty));
  return rows;
}

// ── Ledger statement (statementGenerator.ts) ─────────────────────────────────

class StatementRow {
  const StatementRow({
    required this.date,
    required this.particulars,
    required this.type,
    required this.refNo,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  final DateTime date;
  final String particulars;
  final String type;
  final String refNo;
  final double debit;
  final double credit;

  /// Running balance after this row; positive = retailer owes (Dr).
  final double balance;
}

class Statement {
  const Statement({
    required this.from,
    required this.to,
    required this.opening,
    required this.rows,
  });

  final DateTime? from;
  final DateTime? to;
  final double opening;
  final List<StatementRow> rows;

  double get totalDebit => rows.fold(0.0, (s, r) => s + r.debit);
  double get totalCredit => rows.fold(0.0, (s, r) => s + r.credit);
  double get closing => opening + totalDebit - totalCredit;
}

/// generateRetailerStatement(): every bill is a debit, every payment a
/// credit (zero amounts skipped), oldest first. Rows before [from] fold into
/// the opening balance; rows after the end of [to] are left out.
Statement buildStatement({
  required List<(String, Map<String, dynamic>)> billDocs,
  required List<(String, Map<String, dynamic>)> paymentDocs,
  DateTime? from,
  DateTime? to,
}) {
  final tx = <(DateTime, String, String, String, double, double)>[];
  for (final (id, d) in billDocs) {
    if (d['deleted'] == true) continue;
    final amount = dbl(d['grandTotal'] ?? d['netAmount'] ?? d['totalAmount']);
    if (amount == 0) continue;
    final date = DateTime.tryParse(str(d['invoiceDate'])) ??
        tsToDate(d['createdAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final name = str(d['retailerName']);
    tx.add((
      date,
      name.isEmpty ? 'Invoice' : 'Invoice — $name',
      str(d['invoiceType']) == 'B2B_GST' ? 'GST Invoice' : 'Invoice',
      str(d['orderNumber']).isNotEmpty
          ? str(d['orderNumber'])
          : str(d['invoiceNumber']).isNotEmpty
              ? str(d['invoiceNumber'])
              : _tail(id, 8),
      amount,
      0.0,
    ));
  }
  for (final (id, p) in paymentDocs) {
    final amount = dbl(p['amount']);
    if (amount == 0) continue;
    final date = DateTime.tryParse(str(p['paymentDate'])) ??
        tsToDate(p['createdAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final method = str(p['paymentMethod']);
    tx.add((
      date,
      str(p['notes']).isNotEmpty
          ? str(p['notes'])
          : (method.isEmpty ? 'Payment' : 'Payment ($method)'),
      'Payment',
      str(p['paymentId']).isNotEmpty
          ? str(p['paymentId'])
          : str(p['orderNumber']).isNotEmpty
              ? str(p['orderNumber'])
              : _tail(id, 8),
      0.0,
      amount,
    ));
  }
  tx.sort((a, b) => a.$1.compareTo(b.$1));

  final start = from == null ? null : DateTime(from.year, from.month, from.day);
  final end =
      to == null ? null : DateTime(to.year, to.month, to.day, 23, 59, 59);

  var opening = 0.0;
  for (final t in tx) {
    if (start != null && t.$1.isBefore(start)) opening += t.$5 - t.$6;
  }
  var running = opening;
  final rows = <StatementRow>[];
  for (final (date, particulars, type, ref, debit, credit) in tx) {
    if (start != null && date.isBefore(start)) continue;
    if (end != null && date.isAfter(end)) continue;
    running += debit - credit;
    rows.add(StatementRow(
      date: date,
      particulars: particulars,
      type: type,
      refNo: ref,
      debit: debit,
      credit: credit,
      balance: running,
    ));
  }
  return Statement(from: start, to: end, opening: opening, rows: rows);
}

String _tail(String id, int n) =>
    (id.length <= n ? id : id.substring(id.length - n)).toUpperCase();
