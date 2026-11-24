// ignore_for_file: unnecessary_string_escapes, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures
// The HTML below is generated from src/utils/b2bInvoiceHtml.ts — keep as is.
import 'package:intl/intl.dart';

/// The B2B invoice EXACTLY as the web prints it for a retailer ("Print
/// Invoice" on their profile: src/utils/printB2BInvoice.ts →
/// buildB2BInvoiceHtml in src/utils/b2bInvoiceHtml.ts). The HTML below is
/// generated from that file mechanically, not retyped, and is rendered by the
/// same kind of browser engine, so the retailer sees the same bill in the app
/// as on the web. Keep the two in step: change b2bInvoiceHtml.ts, regenerate.
///
/// JavaScript semantics are kept on purpose (falsy checks, `??`, Number(),
/// String(), toLocaleString('en-IN')) so edge values print identically.

/// INVOICE_CONTACT_LABEL in src/utils/constants.ts.
const invoiceContactLabel = '9307199040, 7232839475';

// ── JavaScript-equivalent helpers ───────────────────────────────────────────

/// JS truthiness: null, false, 0, NaN and '' are false.
bool _truthy(Object? v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// JS Number(): null → 0, '' → 0, numeric text → number, anything else NaN.
double _number(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  return double.tryParse(s) ?? double.nan;
}

/// JS String() of a number: 18.0 → "18", 2.5 → "2.5".
String _jsNum(num n) {
  if (n.isNaN) return 'NaN';
  if (n.isInfinite) return n > 0 ? 'Infinity' : '-Infinity';
  if (n == n.truncateToDouble()) return n.toInt().toString();
  return n.toString();
}

String _jsStr(Object? v) {
  if (v == null) return '';
  if (v is num) return _jsNum(v);
  return v.toString();
}

/// esc() in b2bInvoiceHtml.ts: & < > only.
String _esc(Object? v) => _jsStr(v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

final _two = NumberFormat('#,##,##0.00', 'en_IN');
final _upTo3 = NumberFormat('#,##,##0.###', 'en_IN');

/// fmt(): 2 decimals with Indian grouping, '—' for 0 / NaN.
String _fmt(double n) => _truthy(n) ? _two.format(n) : '—';

/// n.toLocaleString('en-IN'): up to 3 decimals, Indian grouping.
String _locale(double n) => n.isNaN ? 'NaN' : _upTo3.format(n);

/// numberToWords in src/utils/numberToWords.ts, line for line.
String numberToWords(double num) {
  if (num == 0) return 'Zero';
  const ones = [
    '',
    'One',
    'Two',
    'Three',
    'Four',
    'Five',
    'Six',
    'Seven',
    'Eight',
    'Nine',
    'Ten',
    'Eleven',
    'Twelve',
    'Thirteen',
    'Fourteen',
    'Fifteen',
    'Sixteen',
    'Seventeen',
    'Eighteen',
    'Nineteen'
  ];
  const tens = [
    '',
    '',
    'Twenty',
    'Thirty',
    'Forty',
    'Fifty',
    'Sixty',
    'Seventy',
    'Eighty',
    'Ninety'
  ];
  late String Function(int) convert;
  convert = (int n) {
    if (n < 20) return ones[n];
    if (n < 100) return tens[n ~/ 10] + (n % 10 != 0 ? ' ${ones[n % 10]}' : '');
    if (n < 1000)
      return '${ones[n ~/ 100]} Hundred${n % 100 != 0 ? ' ${convert(n % 100)}' : ''}';
    if (n < 100000)
      return '${convert(n ~/ 1000)} Thousand${n % 1000 != 0 ? ' ${convert(n % 1000)}' : ''}';
    if (n < 10000000)
      return '${convert(n ~/ 100000)} Lakh${n % 100000 != 0 ? ' ${convert(n % 100000)}' : ''}';
    return '${convert(n ~/ 10000000)} Crore${n % 10000000 != 0 ? ' ${convert(n % 10000000)}' : ''}';
  };
  final intPart = num.floor();
  final decPart = ((num - intPart) * 100).round();
  var result = convert(intPart);
  if (decPart > 0) result += ' and ${convert(decPart)} Paise';
  return '$result only';
}

/// buildB2BInvoiceHtml(o, branding): the saved salesOrders doc and the
/// tenant's settings/invoice doc (fetchInvoiceBranding), as raw maps.
String buildB2BInvoiceHtml(
    Map<String, dynamic> o, Map<String, dynamic>? branding) {
  final b = branding ?? const <String, dynamic>{};
  final sellerName = _truthy(b['businessName'])
      ? _jsStr(b['businessName'])
      : 'Your Business Name';
  final netAmount = _number(o['netAmount'] ?? o['grandTotal'] ?? 0);
  final prevBal = _number(o['previousBalance'] ?? 0);
  final netBalance =
      o['netBalance'] != null ? _number(o['netBalance']) : netAmount + prevBal;
  final taxableValue = _number(o['taxableValue'] ?? 0);
  final cgst = _number(o['cgst'] ?? 0);
  final sgst = _number(o['sgst'] ?? 0);
  final totalTax = _number(o['totalTax'] ?? 0);
  final discountAmount = _number(o['discountAmount'] ?? 0);
  final roundOff = _number(o['roundOff'] ?? 0);
  final items = [
    for (final r
        in (o['lineItems'] is List ? o['lineItems'] as List : const []))
      if (r is Map) Map<String, dynamic>.from(r) else <String, dynamic>{}
  ];
  final totalGross = o['lineItems'] == null
      ? 0.0
      : items.fold<double>(0, (s, r) {
          final g = _number(r['grossAmount']);
          return s + (_truthy(g) ? g : 0);
        });

  // Derive GST % from first non-zero line item
  final firstGst = items.where((r) => _number(r['gstPct']) > 0).firstOrNull;
  final firstGstPct = _number(firstGst?['gstPct'] ?? 0);
  final halfPct = firstGstPct / 2;

  final lineRows = [
    for (var idx = 0; idx < items.length; idx++) _row(items[idx], idx)
  ].join('');

  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>B2B Invoice ${_esc(o['orderNumber'])}</title>
<style>
  * { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; color-scheme: light !important; box-sizing: border-box; }
  html, body { background: #fff; color: #000; margin: 0; padding: 0; font-family: \'Times New Roman\', serif; }
  .card { max-width: 1050px; margin: 0 auto; padding: 20px 24px; }
  table { border-collapse: collapse; width: 100%; }
  th { background: #f2f2f2; font-weight: 700; text-align: center; border: 1px solid #222; padding: 4px 5px; font-size: 0.82rem; }
  td { border: 1px solid #222; padding: 4px 5px; font-size: 0.82rem; }
  .label { font-weight: 700; font-size: 0.82rem; }
  @media print { body { margin: 0; } }
</style>
</head>
<body>
<div class="card">

  <!-- TITLE -->
  <div style="text-align:center;font-weight:700;font-size:1rem;letter-spacing:0.15em;margin-bottom:2px">GST INVOICE</div>
  <div style="display:flex;align-items:center;justify-content:space-between;border-bottom:2px solid #111;padding-bottom:8px;margin-bottom:10px;flex-wrap:wrap;gap:0.5rem">
    <div style="display:flex;align-items:center;gap:12px">
      ${_truthy(b['logoUrl']) ? '<img src="${_esc(b['logoUrl'])}" alt="Logo" style="height:44px;object-fit:contain">' : ''}
      <div>
        <h1 style="margin:0;font-size:1.6rem;font-weight:900">${_esc(sellerName)}</h1>
        <div style="font-size:0.78rem;color:#444;margin-top:2px">
          ${_esc(b['address'])}<br>
          ${_truthy(b['gstin']) ? '<strong>GSTIN:</strong> ${_esc(b['gstin'])}&nbsp;' : ''}
          <strong>Contact:</strong> ${invoiceContactLabel}
          ${_truthy(b['contact']) ? '&nbsp; Contact No.: ${_esc(b['contact'])}' : ''}
          ${_truthy(b['email']) ? '&nbsp; Email: ${_esc(b['email'])}' : ''}
        </div>
      </div>
    </div>
    <div style="text-align:right;font-weight:700;font-size:1rem;color:#111;border:2px solid #111;padding:4px 12px;border-radius:6px">CREDIT BILL</div>
  </div>

  ${_truthy(b['gstin']) ? '<div style="text-align:center;font-weight:700;font-size:0.9rem;margin-bottom:10px;letter-spacing:0.05em">GSTTIN NO: ${_esc(b['gstin'])}</div>' : ''}

  <!-- BUYER + META -->
  <div style="display:grid;grid-template-columns:1fr 1fr;margin-bottom:10px;border:1px solid #222">
    <div style="border-right:1px solid #222;padding:8px">
      <div class="label" style="margin-bottom:4px">Details for Buyer (Billed &amp; Shipped To)</div>
      <div style="font-weight:700;font-size:0.88rem">${_esc(o['retailerName'])}</div>
      <div style="font-size:0.82rem;margin-top:2px">${_esc(o['buyerAddress'])}</div>
      ${_truthy(o['buyerGstin']) ? '<div style="font-size:0.82rem;margin-top:2px"><span class="label">GSTIN:</span> ${_esc(o['buyerGstin'])}</div>' : ''}
      ${_truthy(o['buyerContact']) ? '<div style="font-size:0.82rem;margin-top:2px"><span class="label">Contact No.:</span> ${_esc(o['buyerContact'])}</div>' : ''}
    </div>
    <div style="padding:8px;display:flex;flex-direction:column;gap:4px">
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Invoice No :</span><span style="font-weight:700">${_esc(o['orderNumber'])}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Invoice Date :</span><span>${_esc(o['invoiceDate'])}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Terms of Delivery :</span><span>${_esc(o['termsOfDelivery'])}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Mode of Payment :</span><span>${_esc(o['modeOfPayment'])}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Salesman Name :</span><span>${_esc(o['salesmanName'])}</span>
      </div>
    </div>
  </div>

  <!-- ITEMS TABLE -->
  <div style="margin-bottom:10px;overflow-x:auto">
    <table>
      <thead>
        <tr>
          <th style="width:30px">S.No</th>
          <th style="min-width:140px">Item Descriptions</th>
          <th style="width:78px">BATCH NO.</th>
          <th style="width:78px">Exp. Date</th>
          <th style="width:46px">GST %</th>
          <th style="width:54px">Mid Off</th>
          <th style="width:44px">Per</th>
          <th style="width:46px">Boxes</th>
          <th style="width:52px">Box Qty</th>
          <th style="width:54px">Qty</th>
          <th style="width:62px">RATE</th>
          <th style="width:82px">Gross Amount</th>
        </tr>
      </thead>
      <tbody>
        ${lineRows}
        <tr style="font-weight:700;background:#f9f9f9">
          <td colspan="11" style="text-align:right;padding-right:8px;border:1px solid #222;font-size:0.78rem">TOTAL</td>
          <td style="text-align:center;border:1px solid #222;font-size:0.78rem">${_fmt(totalGross)}</td>
        </tr>
      </tbody>
    </table>
  </div>

  <!-- GST SUMMARY + NET AMOUNT -->
  <div style="display:grid;grid-template-columns:1fr 1fr;margin-bottom:10px;border:1px solid #222">
    <div style="border-right:1px solid #222;padding:8px">
      <table style="width:100%;border-collapse:collapse;font-size:0.8rem">
        <thead>
          <tr>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">Taxable Value</th>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">Central Tax Rate</th>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">Amount</th>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">State Tax Rate</th>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">Amount</th>
            <th style="border:1px solid #ccc;padding:3px 5px;background:#f2f2f2">Total Tax Amount</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_fmt(taxableValue)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_jsNum(halfPct)}%</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_fmt(cgst)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_jsNum(halfPct)}%</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_fmt(sgst)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_fmt(totalTax)}</td>
          </tr>
          <tr>
            <td style="border:1px solid #ccc;padding:3px 5px;font-weight:700">Total: ${_fmt(taxableValue)}</td>
            <td colspan="4" style="border:1px solid #ccc;padding:3px 5px"></td>
            <td style="border:1px solid #ccc;padding:3px 5px;font-weight:700;text-align:center">${_fmt(totalTax)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div style="padding:8px;display:flex;flex-direction:column;gap:3px;font-size:0.82rem">
      <div style="display:flex;justify-content:space-between"><span>Output CGST@${_jsNum(halfPct)}%</span><span>${_fmt(cgst)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Output SGST@${_jsNum(halfPct)}%</span><span>${_fmt(sgst)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Round Off</span><span>${_fmt(roundOff)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Discount (-)</span><span>${_fmt(discountAmount)}</span></div>
      <div style="border-top:2px solid #111;margin-top:4px;padding-top:4px;display:flex;justify-content:space-between;font-weight:900;font-size:1rem">
        <span>NET AMOUNT</span><span>₹${_locale(netAmount)}</span>
      </div>
    </div>
  </div>

  <!-- AMOUNT IN WORDS -->
  <div style="border:1px solid #222;margin-bottom:10px;display:grid;grid-template-columns:100px 1fr;align-items:stretch">
    <div style="border-right:1px solid #222;padding:6px;font-weight:700;display:flex;align-items:center;font-size:0.82rem">Amount<br>in Words</div>
    <div style="padding:6px;font-weight:600;font-size:0.85rem;font-style:italic">INR ${numberToWords(netAmount)}</div>
  </div>

  <!-- BALANCE + BANK + SIGNATURE -->
  <div style="display:grid;grid-template-columns:1fr 1fr;margin-bottom:10px;border:1px solid #222">
    <div style="border-right:1px solid #222;padding:8px;font-size:0.82rem">
      <div class="label" style="margin-bottom:6px">Account Statement</div>
      <div style="display:flex;justify-content:space-between;margin-bottom:3px">
        <span>Previous Balance</span><span>₹${_locale(prevBal)} Dr</span>
      </div>
      <div style="display:flex;justify-content:space-between;margin-bottom:3px">
        <span>Current Invoice</span><span style="font-weight:600">₹${_locale(netAmount)} Dr</span>
      </div>
      <div style="display:flex;justify-content:space-between;border-top:1px solid #ccc;padding-top:3px;font-weight:700">
        <span>Net Balance</span><span>₹${_locale(netBalance)} Dr</span>
      </div>
    </div>
    <div style="padding:8px;font-size:0.8rem">
      <div class="label" style="margin-bottom:4px">Company\'s Bank Details for NEFT / RTGS :</div>
      <div style="white-space:pre-line;color:#333;line-height:1.6">${_esc(b['bankDetails'] ?? '')}</div>
    </div>
  </div>

  <!-- REMARK -->
  <div style="border:1px solid #222;margin-bottom:0;padding:5px 8px;font-size:0.82rem;display:flex;align-items:center;gap:8px">
    <strong>REMARK :</strong>
  </div>

  <!-- DECLARATION + SIGNATURE -->
  <div style="border:1px solid #222;border-top:none;margin-bottom:10px;display:grid;grid-template-columns:1fr 1fr">
    <div style="border-right:1px solid #222;padding:8px;font-size:0.75rem">
      <div class="label" style="margin-bottom:3px">Declaration :</div>
      <div style="color:#444;line-height:1.5">We declare that this invoice shows the actual price of the goods described and that all particulars are true and correct.</div>
    </div>
    <div style="padding:8px;display:flex;flex-direction:column;align-items:flex-end;justify-content:space-between;font-size:0.8rem">
      <div style="font-weight:700">For ${_esc(sellerName)}</div>
      ${_truthy(b['signatureUrl']) ? '<img src="${_esc(b['signatureUrl'])}" alt="" style="height:46px;max-width:160px;object-fit:contain;margin-top:4px">' : ''}
      <div style="border-top:1px solid #555;padding-top:4px;min-width:140px;text-align:center;margin-top:${_truthy(b['signatureUrl']) ? '4px' : '28px'}">
        ${_esc(b['signatureName'] ?? 'Authorised Signatory')}
      </div>
    </div>
  </div>

  <!-- JURISDICTION -->
  <div style="text-align:center;font-weight:700;font-size:0.82rem;letter-spacing:0.06em;margin-bottom:16px">SUBJECT TO PUNE JURISDICTION</div>

</div>
</body>
</html>''';
}

// The leading '\n' is the newline Dart drops after an opening ''' — the web
// template starts each row with it.
String _row(Map<String, dynamic> r, int idx) => '\n' '''
        <tr>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${idx + 1}</td>
            <td style="border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['itemDescription'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['batchNo'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['expDate'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['gstPct'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['midOff'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['per'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['boxes'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['boxQty'])}</td>
            <td style="text-align:center;font-weight:600;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['quantity'])}</td>
            <td style="text-align:center;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_esc(r['rate'])}</td>
            <td style="text-align:center;font-weight:600;border:1px solid #222;padding:2px 3px;font-size:0.78rem">${_truthy(r['grossAmount']) ? _fmt(_number(r['grossAmount'])) : ''}</td>
        </tr>''';
