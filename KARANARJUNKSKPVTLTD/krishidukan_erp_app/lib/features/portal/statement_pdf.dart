import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../billing/invoice_pdf.dart' show loadPdfTheme;
import 'portal_models.dart';

final _amt = NumberFormat('#,##,##0.00', 'en_IN');
final _day = DateFormat('dd MMM yyyy');
const _green = PdfColor.fromInt(0xFF1C783C); // rgb(28,120,60), the web's
const _red = PdfColor.fromInt(0xFFC81E1E);
const _okGreen = PdfColor.fromInt(0xFF1C8C46);

String _cell(double v) => v == 0 ? '' : _amt.format(v);
String _bal(double v) => '${_amt.format(v.abs())} ${v >= 0 ? 'Dr' : 'Cr'}';

/// Retailer details printed at the top of the statement.
class StatementParty {
  const StatementParty({
    required this.name,
    this.atPost = '',
    this.taluka = '',
    this.district = '',
  });
  final String name;
  final String atPost;
  final String taluka;
  final String district;
}

/// A4 ledger statement with the same layout as generateRetailerStatement()
/// on the web: party header, period, opening balance, one row per bill
/// (debit) and payment (credit) with a running balance, closing balance,
/// totals and a page footer.
Future<Uint8List> buildStatementPdf({
  required Statement st,
  required StatementParty party,
  required String issuer,
  DateTime? generatedAt,
}) async {
  final theme = await loadPdfTheme();
  final rs = theme != null ? '₹' : 'Rs.';
  final generated = generatedAt ?? DateTime.now();
  final address = [party.atPost, party.taluka, party.district]
      .where((s) => s.trim().isNotEmpty)
      .join(' / ');
  final period = (st.from == null && st.to == null)
      ? 'All Transactions'
      : '${st.from == null ? 'All' : _day.format(st.from!)} → ${st.to == null ? 'Today' : _day.format(st.to!)}';

  const bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
  final closing = st.closing;

  List<pw.Widget> row(List<String> cells,
          {bool isBold = false, PdfColor? lastColor}) =>
      [
        for (var i = 0; i < cells.length; i++)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: pw.Text(
              cells[i],
              textAlign: i >= 4 ? pw.TextAlign.right : pw.TextAlign.left,
              style: pw.TextStyle(
                fontSize: 7.5,
                fontWeight: isBold ? pw.FontWeight.bold : null,
                color: i == cells.length - 1 ? lastColor : null,
              ),
            ),
          ),
      ];

  final doc = pw.Document(theme: theme);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 36),
      footer: (ctx) => pw.Text(
        '$issuer | ${party.name} Ledger Statement | Page ${ctx.pageNumber} of ${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
      ),
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(party.name.toUpperCase(),
                      style: pw.TextStyle(
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                          color: _green)),
                  pw.SizedBox(height: 4),
                  pw.Text('Ledger Account',
                      style: const pw.TextStyle(
                          fontSize: 8.5, color: PdfColors.grey700)),
                  if (address.isNotEmpty)
                    pw.Text(address,
                        style: const pw.TextStyle(
                            fontSize: 8.5, color: PdfColors.grey700)),
                  pw.Text('Statement Period: $period',
                      style: const pw.TextStyle(
                          fontSize: 8.5, color: PdfColors.grey700)),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('LEDGER STATEMENT',
                    style: pw.TextStyle(
                        fontSize: 13, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.Text('Generated: ${_day.format(generated)}',
                    style: const pw.TextStyle(
                        fontSize: 8, color: PdfColors.grey600)),
                if (issuer.isNotEmpty)
                  pw.Text('Issued by: $issuer',
                      style: const pw.TextStyle(
                          fontSize: 8, color: PdfColors.grey600)),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: PdfColors.grey400, thickness: 0.6),
        pw.SizedBox(height: 6),
        pw.Table(
          border: const pw.TableBorder(
            horizontalInside:
                pw.BorderSide(color: PdfColors.grey300, width: 0.4),
          ),
          columnWidths: const {
            0: pw.FixedColumnWidth(58),
            1: pw.FlexColumnWidth(),
            2: pw.FixedColumnWidth(56),
            3: pw.FixedColumnWidth(66),
            4: pw.FixedColumnWidth(58),
            5: pw.FixedColumnWidth(58),
            6: pw.FixedColumnWidth(70),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _green),
              children: [
                for (final h in [
                  'Date',
                  'Particulars',
                  'Type',
                  'Ref No',
                  'Debit ($rs)',
                  'Credit ($rs)',
                  'Balance ($rs)'
                ])
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 4, vertical: 5),
                    child: pw.Text(h,
                        style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.white)),
                  ),
              ],
            ),
            pw.TableRow(
                children: row([
              '',
              'Opening Balance',
              '',
              '',
              st.opening > 0 ? _cell(st.opening) : '',
              st.opening < 0 ? _cell(-st.opening) : '',
              _bal(st.opening),
            ], isBold: true)),
            for (var i = 0; i < st.rows.length; i++)
              pw.TableRow(
                decoration: i.isOdd
                    ? const pw.BoxDecoration(color: PdfColors.grey100)
                    : null,
                children: row([
                  _day.format(st.rows[i].date),
                  st.rows[i].particulars,
                  st.rows[i].type,
                  st.rows[i].refNo,
                  _cell(st.rows[i].debit),
                  _cell(st.rows[i].credit),
                  _bal(st.rows[i].balance),
                ]),
              ),
            pw.TableRow(
                children: row([
              '',
              'Closing Balance',
              '',
              '',
              _cell(st.totalDebit),
              _cell(st.totalCredit),
              _bal(closing),
            ], isBold: true, lastColor: closing > 0 ? _red : _okGreen)),
          ],
        ),
        pw.SizedBox(height: 14),
        pw.Row(
          children: [
            for (final (label, value, alert) in [
              ('Total Debit', '$rs ${_amt.format(st.totalDebit)}', false),
              ('Total Credit', '$rs ${_amt.format(st.totalCredit)}', false),
              (
                'Outstanding',
                '$rs ${_amt.format(closing.abs())} ${closing >= 0 ? '(Dr)' : '(Cr)'}',
                closing > 0
              ),
            ])
              pw.SizedBox(
                width: 150,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(label,
                        style: const pw.TextStyle(
                            fontSize: 8, color: PdfColors.grey600)),
                    pw.SizedBox(height: 2),
                    pw.Text(value,
                        style: bold.copyWith(
                            fontSize: 9,
                            color: alert ? _red : PdfColors.grey900)),
                  ],
                ),
              ),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}

/// `Statement_NameNoSpaces_yyyy-mm-dd.pdf` — the web's file name.
String statementFileName(String retailerName, DateTime now) {
  final slug = retailerName
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  return 'Statement_${slug.isEmpty ? 'Retailer' : slug}_${DateFormat('yyyy-MM-dd').format(now)}.pdf';
}
