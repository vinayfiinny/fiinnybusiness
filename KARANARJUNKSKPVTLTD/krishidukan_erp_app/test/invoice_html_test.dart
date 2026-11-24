import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/features/portal/invoice_html.dart';
import 'package:krishidukan_erp/features/portal/portal_invoice_screen.dart' show screenHtml;

/// The app's invoice must be byte-for-byte the web's "Print Invoice"
/// (src/utils/b2bInvoiceHtml.ts). The .html files in fixtures/invoice_golden
/// were produced by the WEB builder from cases.json; if b2bInvoiceHtml.ts
/// changes, regenerate them and port the change (see invoice_html.dart).
void main() {
  const dir = 'test/fixtures/invoice_golden';
  final c = jsonDecode(File('$dir/cases.json').readAsStringSync()) as Map<String, dynamic>;
  final bills = (c['bills'] as List).cast<Map<String, dynamic>>();
  final branding = c['branding'] as Map<String, dynamic>;

  for (var i = 0; i < bills.length; i++) {
    test('bill $i (${bills[i]['orderNumber']}) matches the web exactly', () {
      expect(buildB2BInvoiceHtml(bills[i], branding), File('$dir/$i.html').readAsStringSync());
    });
  }
  test('no branding saved matches the web exactly', () {
    expect(buildB2BInvoiceHtml(bills[0], null), File('$dir/nobrand.html').readAsStringSync());
  });
  test('the on-screen copy changes only the viewport line', () {
    final html = buildB2BInvoiceHtml(bills[0], branding);
    final shown = screenHtml(html);
    expect(shown, contains('<meta name="viewport" content="width=1050">'));
    expect(shown.replaceFirst('<meta name="viewport" content="width=1050">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">'), html);
  });
  test('amount in words (Indian system)', () {
    expect(numberToWords(154900), 'One Lakh Fifty Four Thousand Nine Hundred only');
    expect(numberToWords(154900.5), 'One Lakh Fifty Four Thousand Nine Hundred and Fifty Paise only');
    expect(numberToWords(0), 'Zero');
  });
}
