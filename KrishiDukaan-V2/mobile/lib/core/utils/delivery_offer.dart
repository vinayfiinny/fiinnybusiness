/// Delivery offers, same rules as the website's app/lib/free-delivery.ts.
class GstDeliveryOffer {
  /// A share-offer percentage: a whole number 1–99, else 0 (100 is "free",
  /// stored as its own flag).
  static int parsePct(Object? v) {
    final n = v is num ? v.toDouble() : double.tryParse(v?.toString().trim() ?? '');
    if (n == null || !n.isFinite) return 0;
    final r = n.round();
    return r >= 1 && r <= 99 ? r : 0;
  }
}
