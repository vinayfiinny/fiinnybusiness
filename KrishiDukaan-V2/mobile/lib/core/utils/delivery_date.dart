import 'package:intl/intl.dart';

/// "Thu, 19 Nov" from the server's YYYY-MM-DD delivery estimate
/// (app/lib/delivery-eta.ts on the website). Null when it can't be read.
String? formatDeliveryDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  return DateFormat('EEE, d MMM').format(d);
}
