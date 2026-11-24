// ignore_for_file: unnecessary_string_escapes, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures
import 'package:intl/intl.dart';

import '../../core/parse.dart' show gstinError;

/// INVOICE_CONTACT_LABEL in src/utils/constants.ts.
const invoiceContactLabel = '9307199040, 7232839475';

/// B2B GST bills use the web invoice editor's A4 layout. Older order types
/// keep the retailer worklist's standalone print layout.
String buildPortalInvoiceHtml(
        Map<String, dynamic> order, Map<String, dynamic>? branding) =>
    buildB2BInvoiceHtml(order, branding, a4: order['invoiceType'] == 'B2B_GST');

const _a4Styles = '''
  .a4 h1 { letter-spacing: -0.01em; }
  .a4 .buyer-field { display: flex; gap: 8px; margin-top: 3px; }
  .a4 .buyer-address { white-space: pre-wrap; margin: 3px 0; font-size: 0.82rem; }
  .a4 .gst-state { color: #10b981; font-size: 0.72rem; margin-top: 2px; }
  .a4 .licenses { display: flex; gap: 10px; flex-wrap: wrap; color: #555; font-size: 0.7rem; margin-top: 2px; }
  .a4 .items .value { text-align: center; }
  .a4 .items .qty, .a4 .items .gross, .a4 .items .item-name { font-weight: 600; }
  @media screen {
    body { background: #f5f5f5; padding: 16px; }
    .card.a4 { min-height: 1485px; background: #fff; border: 1px solid #ddd; border-radius: 10px; box-shadow: 0 10px 40px rgba(0,0,0,0.1); padding: 18px 22px; }
  }
  @media print {
    .card.a4 { padding: 8mm; }
    .a4 .items th, .a4 .items td { padding: 3px 4px; font-size: 0.76rem; }
    .a4 .gst-state { display: none; }
  }
''';

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

/// The saved salesOrders doc and settings/invoice doc, as raw maps.
/// The legacy layout mirrors src/utils/b2bInvoiceHtml.ts. The A4 layout
/// follows the read-only document content of src/pages/B2BInvoicePage.tsx.
String buildB2BInvoiceHtml(
    Map<String, dynamic> o, Map<String, dynamic>? branding,
    {bool a4 = false}) {
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
  String amount(double value) => a4 ? _fixedAmount(value) : _fmt(value);

  final lineRows = [
    for (var idx = 0; idx < items.length; idx++)
      a4 ? _a4Row(items[idx], idx) : _row(items[idx], idx)
  ].join('');
  final billLabel =
      a4 && o['modeOfPayment'] == 'Cash' ? 'CASH BILL' : 'CREDIT BILL';
  final gstLabel = a4 ? 'GSTIN NO' : 'GSTTIN NO';
  final billedDate = a4 ? _a4Date(o['invoiceDate']) : o['invoiceDate'];

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
  @media print { body { margin: 0; } }${a4 ? '\n$_a4Styles' : ''}
</style>
</head>
<body>
<div class="card${a4 ? ' a4' : ''}">

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
        </div>${a4 ? _a4Licenses(b) : ''}
      </div>
    </div>
    <div style="text-align:right;font-weight:700;font-size:1rem;color:#111;border:2px solid #111;padding:4px 12px;border-radius:6px">$billLabel</div>
  </div>

  ${_truthy(b['gstin']) ? '<div style="text-align:center;font-weight:700;font-size:0.9rem;margin-bottom:10px;letter-spacing:0.05em">$gstLabel: ${_esc(b['gstin'])}</div>' : ''}

  <!-- BUYER + META -->
  <div style="display:grid;grid-template-columns:1fr 1fr;margin-bottom:10px;border:1px solid #222">
    <div style="border-right:1px solid #222;padding:8px">
      <div class="label" style="margin-bottom:4px">Details for Buyer (Billed &amp; Shipped To)</div>
      <div style="font-weight:700;font-size:0.88rem">${_esc(o['retailerName'])}</div>${a4 ? _a4Buyer(o) : '\n' '''
      <div style="font-size:0.82rem;margin-top:2px">${_esc(o['buyerAddress'])}</div>
      ${_truthy(o['buyerGstin']) ? '<div style="font-size:0.82rem;margin-top:2px"><span class="label">GSTIN:</span> ${_esc(o['buyerGstin'])}</div>' : ''}
      ${_truthy(o['buyerContact']) ? '<div style="font-size:0.82rem;margin-top:2px"><span class="label">Contact No.:</span> ${_esc(o['buyerContact'])}</div>' : ''}'''}
    </div>
    <div style="padding:8px;display:flex;flex-direction:column;gap:4px">
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Invoice No :</span><span style="font-weight:700">${_esc(o['orderNumber'])}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Invoice Date :</span><span>${_esc(billedDate)}</span>
      </div>
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Terms of Delivery :</span><span>${_esc(o['termsOfDelivery'])}</span>
      </div>${a4 ? _a4Transporter(o) : ''}
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
    <table${a4 ? ' class="items"' : ''}>
      <thead>
        <tr>
          <th style="width:30px">S.No</th>${a4 ? _a4ItemHeaders : '\n' '''
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
          <th style="width:82px">Gross Amount</th>'''}
        </tr>
      </thead>
      <tbody>
        ${lineRows}
        <tr style="font-weight:700;background:#f9f9f9">
          <td colspan="${a4 ? 9 : 11}" style="text-align:right;padding-right:8px;border:1px solid #222;font-size:0.78rem">TOTAL</td>
          <td style="text-align:center;border:1px solid #222;font-size:0.78rem">${amount(totalGross)}</td>
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
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${amount(taxableValue)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_jsNum(halfPct)}%</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${amount(cgst)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${_jsNum(halfPct)}%</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${amount(sgst)}</td>
            <td style="border:1px solid #ccc;padding:3px 5px;text-align:center">${amount(totalTax)}</td>
          </tr>
          <tr>
            <td style="border:1px solid #ccc;padding:3px 5px;font-weight:700">Total: ${amount(taxableValue)}</td>
            <td colspan="4" style="border:1px solid #ccc;padding:3px 5px"></td>
            <td style="border:1px solid #ccc;padding:3px 5px;font-weight:700;text-align:center">${amount(totalTax)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div style="padding:8px;display:flex;flex-direction:column;gap:3px;font-size:0.82rem">
      <div style="display:flex;justify-content:space-between"><span>Output CGST@${_jsNum(halfPct)}%</span><span>${amount(cgst)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Output SGST@${_jsNum(halfPct)}%</span><span>${amount(sgst)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Round Off</span><span>${amount(roundOff)}</span></div>
      <div style="display:flex;justify-content:space-between"><span>Discount (-)</span><span>${amount(discountAmount)}</span></div>
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
    <strong>REMARK :</strong>${a4 ? _esc(o['remarks']) : ''}
  </div>

  <!-- DECLARATION + SIGNATURE -->
  <div style="border:1px solid #222;border-top:none;margin-bottom:10px;display:grid;grid-template-columns:1fr 1fr">
    <div style="border-right:1px solid #222;padding:8px;font-size:0.75rem">
      <div class="label" style="margin-bottom:3px">Declaration :</div>
      <div style="color:#444;line-height:1.5">We declare that this invoice shows the actual price of the goods described and that all particulars are true and correct.</div>${a4 ? _customerSignature : ''}
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

String _fixedAmount(double amount) =>
    amount.isFinite ? amount.toStringAsFixed(2) : '—';

final _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _isoMonth = RegExp(r'^(\d{4})-(\d{2})');

String _a4Date(Object? value) {
  final date = _jsStr(value);
  final match = _isoDate.firstMatch(date.trim());
  if (match == null) return date;
  return '${int.parse(match[2]!)}/${int.parse(match[3]!)}/${match[1]}';
}

String _a4Expiry(Object? value) {
  final expiry = _jsStr(value);
  final match = _isoMonth.firstMatch(expiry.trim());
  return match == null ? expiry : '${match[2]}/${match[1]!.substring(2)}';
}

// State names used by the A4 web form's GSTIN validator.
const _gstStates = {
  '01': 'Jammu & Kashmir',
  '02': 'Himachal Pradesh',
  '03': 'Punjab',
  '04': 'Chandigarh',
  '05': 'Uttarakhand',
  '06': 'Haryana',
  '07': 'Delhi',
  '08': 'Rajasthan',
  '09': 'Uttar Pradesh',
  '10': 'Bihar',
  '11': 'Sikkim',
  '12': 'Arunachal Pradesh',
  '13': 'Nagaland',
  '14': 'Manipur',
  '15': 'Mizoram',
  '16': 'Tripura',
  '17': 'Meghalaya',
  '18': 'Assam',
  '19': 'West Bengal',
  '20': 'Jharkhand',
  '21': 'Odisha',
  '22': 'Chhattisgarh',
  '23': 'Madhya Pradesh',
  '24': 'Gujarat',
  '26': 'Dadra & Nagar Haveli / Daman & Diu',
  '27': 'Maharashtra',
  '28': 'Andhra Pradesh',
  '29': 'Karnataka',
  '30': 'Goa',
  '31': 'Lakshadweep',
  '32': 'Kerala',
  '33': 'Tamil Nadu',
  '34': 'Puducherry',
  '35': 'Andaman & Nicobar',
  '36': 'Telangana',
  '37': 'Andhra Pradesh (New)',
  '38': 'Ladakh',
};

String _a4Buyer(Map<String, dynamic> order) {
  final gstin = _jsStr(order['buyerGstin']).trim().toUpperCase();
  final gstState = gstin.isNotEmpty && gstinError(gstin) == null
      ? _gstStates[gstin.substring(0, 2)]
      : null;
  final savedState = _jsStr(order['buyerState']).trim();
  final buyerState = savedState.isEmpty ? gstState : savedState;
  return '''
      <div class="buyer-address">${_esc(order['buyerAddress'])}</div>
      <div class="buyer-field"><span class="label">GST No.:</span>
        <div>${_esc(gstin)}
          ${gstState == null ? '' : '<div class="gst-state">✓ ${_esc(gstState)}</div>'}
        </div>
      </div>
      <div class="buyer-field"><span class="label">Contact No.:</span><span>${_esc(order['buyerContact'])}</span></div>
      <div class="buyer-field"><span class="label">State :</span><span>${_esc(buyerState)}</span></div>''';
}

String _a4Transporter(Map<String, dynamic> order) {
  final name = _jsStr(order['transporterName']).trim();
  final phone = _jsStr(order['transporterContact']).trim();
  return '''
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Transporter :</span><span>${name.isEmpty ? '—' : _esc(name)}</span>
      </div>
      ${phone.isEmpty ? '' : '''
      <div style="display:grid;grid-template-columns:130px 1fr;gap:4px;align-items:center">
        <span class="label">Transporter Ph :</span><span>${_esc(phone)}</span>
      </div>'''}''';
}

String _a4Licenses(Map<String, dynamic> branding) {
  const labels = {
    'fertilizerLicense': 'Fert. Lic',
    'pesticideLicense': 'Pest. Lic',
    'seedsLicense': 'Seeds Lic',
  };
  final licenses = [
    for (final label in labels.entries)
      if (_truthy(branding[label.key]))
        '<span><strong>${label.value}:</strong> ${_esc(branding[label.key])}</span>',
  ];
  return licenses.isEmpty
      ? ''
      : '<div class="licenses">${licenses.join()}</div>';
}

const _a4ItemHeaders = '''
          <th style="min-width:150px">Item Descriptions</th>
          <th style="width:90px">Company</th>
          <th style="width:80px">Batch No.</th>
          <th style="width:72px">Exp. Date</th>
          <th style="width:48px">Per</th>
          <th style="width:48px">GST %</th>
          <th style="width:56px">Qty</th>
          <th style="width:70px">Rate</th>
          <th style="width:88px">Gross Amount</th>''';

String _a4Row(Map<String, dynamic> row, int index) {
  final gross = _number(row['grossAmount']);
  return '''
        <tr>
          <td class="value">${index + 1}</td>
          <td class="item-name">${_esc(row['itemDescription'])}</td>
          <td class="value">${_esc(row['mfgCompany'])}</td>
          <td class="value">${_esc(row['batchNo'])}</td>
          <td class="value">${_esc(_a4Expiry(row['expDate']))}</td>
          <td class="value">${_esc(row['per'] ?? 'Nos')}</td>
          <td class="value">${_esc(row['gstPct'])}</td>
          <td class="value qty">${_esc(row['quantity'])}</td>
          <td class="value">${_esc(row['rate'])}</td>
          <td class="value gross">${_truthy(gross) ? _fixedAmount(gross) : ''}</td>
        </tr>''';
}

const _customerSignature = '''
      <div style="margin-top:18px;border-top:1px solid #555;padding-top:3px;width:150px;text-align:center;font-size:0.72rem">Customer Signature</div>''';

// The leading '\n' is the newline Dart drops after an opening ''' — the web
// template starts each row with it.
String _row(Map<String, dynamic> r, int idx) => '\n'
    '''
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
