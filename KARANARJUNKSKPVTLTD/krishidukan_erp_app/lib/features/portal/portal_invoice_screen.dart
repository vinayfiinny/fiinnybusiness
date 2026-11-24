import 'dart:async';
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
    .family<(Map<String, dynamic>?, Map<String, dynamic>?), String>(
        (ref, id) async {
  final user = ref.watch(appUserProvider).valueOrNull;
  if (user == null) return (null, null);
  final db = ref.watch(firestoreProvider);
  final order = await tenantCollection(db, user.tenantId, 'salesOrders')
      .doc(id)
      .get()
      .timeout(const Duration(seconds: 20));
  final data = order.data();
  if (data == null || data['deleted'] == true) return (null, null);

  Map<String, dynamic>? branding;
  try {
    final settings = await tenantCollection(db, user.tenantId, 'settings')
        .doc('invoice')
        .get()
        .timeout(const Duration(seconds: 5));
    branding = settings.data();
  } catch (_) {
    // fetchInvoiceBranding on the web falls back to an empty branding too.
  }
  return (data, branding);
});

/// For the screen only: lay the page out at the invoice's full printed width
/// (its .card is max 1050px) and let the web view fit it to the phone, so the
/// retailer sees the same page as the web and can pinch to zoom. The HTML that
/// is printed and shared is unchanged.
String screenHtml(String html) => html.replaceFirst(
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    '<meta name="viewport" content="width=1050">');

/// Render the same HTML used by the web invoice, including its own padding.
Future<Uint8List> renderPortalInvoicePdf(
    String html, PdfPageFormat paper) async {
  // printing 5.15.1 on Android converts the left margin at 72 times the
  // intended size. Pass only the paper dimensions and let the HTML set margins.
  final format = PdfPageFormat(paper.width, paper.height);
  // ignore: deprecated_member_use
  final bytes = await Printing.convertHtml(html: html, format: format)
      .timeout(const Duration(seconds: 25));
  if (bytes.isEmpty) throw StateError('The invoice PDF is empty.');
  return bytes;
}

/// A retailer's saved bill, rendered in the phone's browser engine.
/// View, share and print use the same invoice layout.
///
/// Shown in a web view, not as a PDF preview: the PDF preview (page images)
/// stayed blank on testers' phones while printing the same PDF worked
/// (Nov 2026). Print and Share still produce the PDF.
class PortalInvoiceScreen extends ConsumerStatefulWidget {
  const PortalInvoiceScreen(
      {super.key, required this.orderId, required this.number});

  final String orderId;
  final String number;

  @override
  ConsumerState<PortalInvoiceScreen> createState() =>
      _PortalInvoiceScreenState();
}

class _PortalInvoiceScreenState extends ConsumerState<PortalInvoiceScreen> {
  bool _exporting = false;

  Future<void> _export(
      Future<void> Function() action, String errorMessage) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await action();
    } on TimeoutException {
      if (mounted) {
        showError(
            context, 'The invoice PDF took too long to prepare. Try again.');
      }
    } catch (_) {
      if (mounted) showError(context, errorMessage);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(String html, String file) async {
    final bytes = await renderPortalInvoicePdf(html, PdfPageFormat.a4);
    if (!mounted) return;
    if (!await Printing.sharePdf(bytes: bytes, filename: file)) {
      throw StateError('The share sheet could not be opened.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _invoiceSourceProvider(widget.orderId);
    final async = ref.watch(source);
    final business =
        ref.watch(appUserProvider).valueOrNull?.businessName ?? 'your supplier';
    final ready = async.valueOrNull;
    final order = ready?.$1;
    final html =
        order == null ? null : buildPortalInvoiceHtml(order, ready?.$2);
    final invoiceNumber = str(order?['orderNumber']);
    final fileNumber = (invoiceNumber.isEmpty ? widget.number : invoiceNumber)
        .replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
    final file = 'Invoice-$fileNumber.pdf';

    return Scaffold(
      appBar: AppBar(
        title: Text('Invoice ${widget.number}'),
        bottom: _exporting
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  semanticsLabel: 'Preparing invoice PDF',
                ),
              )
            : null,
        actions: [
          if (html != null) ...[
            IconButton(
              tooltip: 'Share PDF',
              icon: const Icon(Icons.share_rounded),
              onPressed: _exporting
                  ? null
                  : () => _export(() => _share(html, file),
                      'Could not share the invoice. Try again.'),
            ),
            IconButton(
              tooltip: 'Print',
              icon: const Icon(Icons.print_rounded),
              onPressed: _exporting
                  ? null
                  : () => _export(
                        () => Printing.layoutPdf(
                          name: file,
                          onLayout: (format) =>
                              renderPortalInvoicePdf(html, format),
                        ),
                        'Could not print the invoice. Try again.',
                      ),
            ),
          ],
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _Message(
          'Could not load this invoice. Check your connection and try again.',
          onRetry: () => ref.invalidate(source),
        ),
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
}

class _InvoiceView extends StatefulWidget {
  const _InvoiceView({required this.html});
  final String html;

  @override
  State<_InvoiceView> createState() => _InvoiceViewState();
}

class _InvoiceViewState extends State<_InvoiceView> {
  WebViewController? _controller;
  late Future<void> _page;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _InvoiceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.html != oldWidget.html) _start();
  }

  void _start() {
    _controller = null;
    _page = _load(widget.html).timeout(const Duration(seconds: 20));
  }

  Future<void> _load(String html) async {
    final loaded = Completer<void>();
    final controller = WebViewController();
    _controller = controller;
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onWebResourceError: (error) {
        if (error.isForMainFrame == true && !loaded.isCompleted) {
          loaded.completeError(StateError('The invoice page could not load.'));
        }
      },
      onNavigationRequest: (request) =>
          request.url.startsWith('about:') || request.url.startsWith('data:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
    ));
    await controller.setBackgroundColor(Colors.white);
    await controller.enableZoom(true);
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // Honour the page's viewport (width=1050) and fit it to the screen.
      await platform.setUseWideViewPort(true);
    }
    await Future.wait<void>([loaded.future, controller.loadHtmlString(html)],
        eagerError: true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return FutureBuilder<void>(
      future: _page,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasError) {
          return _Message('Could not display the invoice preview.',
              onRetry: () => setState(_start));
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null)
              WebViewWidget(key: ObjectKey(controller), controller: controller),
            if (snapshot.connectionState != ConnectionState.done)
              const Center(child: CircularProgressIndicator()),
          ],
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
