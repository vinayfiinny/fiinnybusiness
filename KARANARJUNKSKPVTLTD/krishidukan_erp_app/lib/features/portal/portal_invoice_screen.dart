import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../app/theme.dart';
import '../../core/parse.dart';
import '../../core/tenant_path.dart';
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

/// A retailer's own bill, shown exactly as the web prints it for them
/// ("Print Invoice" on their profile): the same HTML (invoice_html.dart, a
/// generated port of b2bInvoiceHtml.ts) rendered by the phone's browser
/// engine into a PDF. View, share and print only — a retailer can't change a
/// bill; corrections come from the business.
class PortalInvoiceScreen extends ConsumerWidget {
  const PortalInvoiceScreen({super.key, required this.orderId, required this.number});

  final String orderId;
  final String number;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_invoiceSourceProvider(orderId));
    final business = ref.watch(appUserProvider).valueOrNull?.businessName ?? 'your supplier';
    return Scaffold(
      appBar: AppBar(title: Text('Invoice $number')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Message('Could not load this invoice. Check your connection and try again.'),
        data: (src) {
          final (order, branding) = src;
          if (order == null || order['deleted'] == true) {
            return const _Message('This bill is no longer available.');
          }
          final html = buildB2BInvoiceHtml(order, branding);
          final file = 'Invoice-${str(order['orderNumber']).replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_')}.pdf';
          return Column(
            children: [
              Expanded(
                child: PdfPreview(
                  // convertHtml is marked deprecated in printing 5.x with no
                  // replacement, but it is implemented on Android (the system
                  // WebView prints the HTML) — and it is the only way to show
                  // the web's invoice exactly, page for page.
                  // ignore: deprecated_member_use
                  build: (format) => Printing.convertHtml(html: html, format: format),
                  initialPageFormat: PdfPageFormat.a4,
                  pdfFileName: file,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowPrinting: true,
                  allowSharing: true,
                  onError: (context, error) => const _Message(
                      'This phone could not display the invoice. Try again, or ask for a printed copy.'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Text(
                  'Something wrong on this bill? Contact $business to correct it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.inkMute),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
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
