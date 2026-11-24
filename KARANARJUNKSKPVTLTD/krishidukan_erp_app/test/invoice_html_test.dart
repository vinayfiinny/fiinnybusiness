import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/features/portal/invoice_html.dart';
import 'package:krishidukan_erp/features/portal/portal_invoice_screen.dart'
    show renderPortalInvoicePdf, screenHtml;
import 'package:pdf/pdf.dart';

/// The legacy layout matches the web's standalone Print Invoice fixtures.
/// B2B GST bills use the A4 layout from the web invoice editor.
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
  test('the portal selects the web A4 layout for saved GST invoices', () {
    final bill = {
      ...bills[0],
      'invoiceDate': '2026-11-24',
      'modeOfPayment': 'Cash',
      'transporterName': 'Sample Carrier',
      'transporterContact': '9000000000',
      'cgst': 0,
      'sgst': 0,
      'lineItems': [
        {
          'itemDescription': 'Sample <Fertilizer>',
          'mfgCompany': 'Sample & Co',
          'expDate': '2029-06-12',
          'quantity': 2,
          'rate': 1000,
          'grossAmount': 2000,
          'gstPct': 0,
        }
      ],
    };
    final html = buildPortalInvoiceHtml(bill, branding);
    expect(html, contains('class="card a4"'));
    expect(html, contains('>CASH BILL<'));
    expect(html, contains('GSTIN NO:'));
    expect(html, contains('✓ Maharashtra'));
    expect(html, contains('color: #10b981'));
    expect(html, contains('State :</span><span>Maharashtra'));
    expect(html, contains('>11/24/2026<'));
    expect(html, contains('Transporter :</span><span>Sample Carrier'));
    expect(html, contains('Transporter Ph :</span><span>9000000000'));
    expect(html, contains('>Company</th>'));
    expect(html, contains('>Sample &amp; Co<'));
    expect(html, contains('>Sample &lt;Fertilizer&gt;<'));
    expect(html, contains('>06/29<'));
    expect(html, contains('>2000.00<'));
    expect(html, contains('Output CGST@0%</span><span>0.00'));
    expect(html, contains('Customer Signature'));
    expect(html, isNot(contains('>Mid Off</th>')));
    expect(html, isNot(contains('<input')));
    expect(html, isNot(contains('<select')));
    expect(RegExp(r'<tr>\s*<td class="value">').allMatches(html), hasLength(1));

    expect(buildPortalInvoiceHtml(bills[1], branding),
        File('$dir/1.html').readAsStringSync());
  });
  test('the on-screen copy changes only the viewport line', () {
    final html = buildPortalInvoiceHtml(bills[0], branding);
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
    final html = buildPortalInvoiceHtml(bills[0], branding);
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
