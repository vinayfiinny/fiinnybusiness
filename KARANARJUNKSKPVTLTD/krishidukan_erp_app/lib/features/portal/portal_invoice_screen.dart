import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../app/theme.dart';
import '../../core/parse.dart';
import '../../core/tenant_path.dart';
import '../../widgets/form_bits.dart' show showError;
import '../auth/auth_repository.dart';
import 'invoice_html.dart';

/// The bill and the business's invoice settings, read as stored — the two
/// documents the web's printB2BInvoice reads.
final _invoiceSourceProvider = FutureProvider.autoDispose
    .family<(Map<String, dynamic>?, Map<String, dynamic>?), String>((ref, id) async {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return (null, null);
  final db = ref.watch(firestoreProvider);
  final order = await tenantCollection(db, user.tenantId, 'salesOrders').doc(id).get();
  Map<String, dynamic>? branding;
  try {
    branding = (await tenantCollection(db, user.tenantId, 'settings').doc('invoice').get()).data();
  } catch (_) {
    // fetchInvoiceBranding on the web falls back to an empty branding too.
  }
  return (order.data(), branding ?? const {'businessName': '', 'address': ''});
});

/// For the screen only: lay the page out at the invoice's full printed width
/// (its .card is max 1050px) and let the web view fit it to the phone, so the
/// retailer sees the same page as the web and can pinch to zoom. The HTML that
/// is printed and shared is unchanged.
String screenHtml(String html) => html.replaceFirst(
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    '<meta name="viewport" content="width=1050">');

/// A retailer's own bill, shown exactly as the web prints it for them
/// ("Print Invoice" on their profile): the same HTML (invoice_html.dart, a
/// generated port of b2bInvoiceHtml.ts) in the phone's browser engine.
/// View, share and print only — a retailer can't change a bill.
///
/// Shown in a web view, not as a PDF preview: the PDF preview (page images)
/// stayed blank on testers' phones while printing the same PDF worked
/// (Nov 2026). Print and Share still produce the PDF.
class PortalInvoiceScreen extends ConsumerWidget {
  const PortalInvoiceScreen({super.key, required this.orderId, required this.number});

  final String orderId;
  final String number;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_invoiceSourceProvider(orderId));
    final business = ref.watch(appUserProvider).valueOrNull?.businessName ?? 'your supplier';
    final ready = async.valueOrNull;
    final order = ready?.$1;
    final html = order == null || order['deleted'] == true ? null : buildB2BInvoiceHtml(order, ready!.$2);
    final file = 'Invoice-${str(order?['orderNumber']).replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_')}.pdf';

    return Scaffold(
      appBar: AppBar(
        title: Text('Invoice $number'),
        actions: [
          if (html != null) ...[
            IconButton(
              tooltip: 'Share PDF',
              icon: const Icon(Icons.share_rounded),
              onPressed: () => _share(context, html, file),
            ),
            IconButton(
              tooltip: 'Print',
              icon: const Icon(Icons.print_rounded),
              onPressed: () => _print(context, html, file),
            ),
          ],
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const _Message('Could not load this invoice. Check your connection and try again.'),
        data: (_) => html == null
            ? const _Message('This bill is no longer available.')
            : Column(
                children: [
                  Expanded(child: _InvoiceView(html: screenHtml(html))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: Text(
                      'Something wrong on this bill? Contact $business to correct it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: AppColors.inkMute),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // convertHtml is marked deprecated in printing 5.x with no replacement, but
  // it is implemented on Android (the system WebView prints the HTML) and is
  // what makes the PDF identical to the web's print.
  // ignore: deprecated_member_use
  static Future<Uint8List> _pdf(String html, PdfPageFormat f) => Printing.convertHtml(html: html, format: f);

  static Future<void> _print(BuildContext context, String html, String file) async {
    try {
      await Printing.layoutPdf(
        name: file,
        // ignore: deprecated_member_use
        onLayout: (format) => Printing.convertHtml(html: html, format: format),
      );
    } catch (e) {
      if (context.mounted) showError(context, 'Could not print the invoice. Please try again.');
    }
  }

  static Future<void> _share(BuildContext context, String html, String file) async {
    try {
      final bytes = await _pdf(html, PdfPageFormat.a4);
      await Printing.sharePdf(bytes: bytes, filename: file);
    } catch (e) {
      if (context.mounted) showError(context, 'Could not create the PDF. Please try again.');
    }
  }
}

class _InvoiceView extends StatefulWidget {
  const _InvoiceView({required this.html});
  final String html;

  @override
  State<_InvoiceView> createState() => _InvoiceViewState();
}

class _InvoiceViewState extends State<_InvoiceView> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        // The invoice is a static page; never navigate away from it.
        onNavigationRequest: (r) =>
            r.url.startsWith('about:') || r.url.startsWith('data:') ? NavigationDecision.navigate : NavigationDecision.prevent,
      ))
      ..enableZoom(true);
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      // Honour the page's viewport (width=1050) and fit it to the screen.
      platform.setUseWideViewPort(true);
    }
    _controller.loadHtmlString(widget.html);
  }

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
