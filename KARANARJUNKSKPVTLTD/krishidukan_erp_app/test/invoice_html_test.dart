import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/features/portal/invoice_html.dart';
import 'package:krishidukan_erp/features/portal/portal_invoice_screen.dart'
    show renderPortalInvoicePdf, screenHtml;
import 'package:pdf/pdf.dart';

/// The app's invoice must be byte-for-byte the web's "Print Invoice"
/// (src/utils/b2bInvoiceHtml.ts). The .html files in fixtures/invoice_golden
/// were produced by the WEB builder from cases.json; if b2bInvoiceHtml.ts
/// changes, regenerate them and port the change (see invoice_html.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dir = 'test/fixtures/invoice_golden';
  final c = jsonDecode(File('$dir/cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final bills = (c['bills'] as List).cast<Map<String, dynamic>>();
  final branding = c['branding'] as Map<String, dynamic>;

  for (var i = 0; i < bills.length; i++) {
    test('bill $i (${bills[i]['orderNumber']}) matches the web exactly', () {
      expect(buildB2BInvoiceHtml(bills[i], branding),
          File('$dir/$i.html').readAsStringSync());
    });
  }
  test('no branding saved matches the web exactly', () {
    expect(buildB2BInvoiceHtml(bills[0], null),
        File('$dir/nobrand.html').readAsStringSync());
  });
  test('the on-screen copy changes only the viewport line', () {
    final html = buildB2BInvoiceHtml(bills[0], branding);
    final shown = screenHtml(html);
    expect(shown, contains('<meta name="viewport" content="width=1050">'));
    expect(
        shown.replaceFirst('<meta name="viewport" content="width=1050">',
            '<meta name="viewport" content="width=device-width,initial-scale=1">'),
        html);
  });
  test(
      'invoice export preserves the HTML and paper size with zero native margins',
      () async {
    const channel = MethodChannel('net.nfet.printing');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final html = buildB2BInvoiceHtml(bills[0], branding);
    const paper = PdfPageFormat.a4;
    final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7'));

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'convertHtml');
      expect(call.arguments, containsPair('html', html));
      expect(call.arguments, containsPair('width', paper.width));
      expect(call.arguments, containsPair('height', paper.height));
      for (final margin in [
        'marginLeft',
        'marginTop',
        'marginRight',
        'marginBottom'
      ]) {
        expect(call.arguments, containsPair(margin, 0.0));
      }
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall('onHtmlRendered', {
          'job': call.arguments['job'],
          'doc': bytes,
        })),
        null,
      );
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await renderPortalInvoicePdf(html, paper), orderedEquals(bytes));
  });
  test('amount in words (Indian system)', () {
    expect(numberToWords(154900),
        'One Lakh Fifty Four Thousand Nine Hundred only');
    expect(numberToWords(154900.5),
        'One Lakh Fifty Four Thousand Nine Hundred and Fifty Paise only');
    expect(numberToWords(0), 'Zero');
  });
}
