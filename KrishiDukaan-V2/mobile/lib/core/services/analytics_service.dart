import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cart_model.dart';
import '../models/catalog_model.dart';

/// Every Firebase Analytics (GA4) event the app sends, in one place, using
/// Google's standard e-commerce names so GA4 and Google Ads recognise them:
///
///   view_item · add_to_cart · remove_from_cart · view_cart · begin_checkout
///   add_shipping_info · add_payment_info · purchase · refund · screen_view
///
/// RULES
///   - Never personal data: no name, phone, address, UPI ID or card. The user
///     id is the Firebase Auth uid (pseudonymous).
///   - Currency INR. `value` = sum(item price × quantity); shipping and tax go
///     in their own fields, never folded into value.
///   - purchase only after the server confirmed the payment (see
///     checkout_screen _completeOrder), and exactly once per payment
///     ([logPurchase] claims the transaction first).
///   - transaction_id = the Razorpay payment id: one checkout may create
///     several orders (one per seller) but it is one payment, and it is the
///     same reference the website already sends to Google Ads.
///   - Analytics must never break shopping: every call swallows its errors.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  static const currency = 'INR';
  FirebaseAnalytics get _ga => FirebaseAnalytics.instance;

  /// Web builds use the website's own GA4 tag; only the app logs here.
  bool get _enabled => !kIsWeb;

  Future<void> _safe(Future<void> Function() run) async {
    if (!_enabled) return;
    try {
      await run();
    } catch (e) {
      debugPrint('[Analytics] skipped: $e');
    }
  }

  /// Ties events to the signed-in shopper by uid (never phone/email), and
  /// clears it on sign-out. Call once after Firebase.initializeApp.
  void start() {
    if (!_enabled) return;
    FirebaseAuth.instance.authStateChanges().listen((user) {
      _safe(() => _ga.setUserId(id: user?.uid));
    });
  }

  // ── Screens ────────────────────────────────────────────────────────────

  String? _lastScreen;

  /// One screen_view per screen change; ids in the path are folded so
  /// "/product/abc123…" and "/product/xyz…" are the same screen.
  void screenView(String path) {
    final name = screenNameFor(path);
    if (name.isEmpty || name == _lastScreen) return;
    _lastScreen = name;
    _safe(() => _ga.logScreenView(screenName: name, screenClass: name));
  }

  // ── Shopping journey ───────────────────────────────────────────────────

  final Set<String> _viewedThisSession = {};

  /// view_item: a product detail screen opened (once per product per app
  /// session, so rebuilds and back-and-forth don't inflate it).
  void viewItem(CatalogModel p) {
    if (!_viewedThisSession.add(p.id)) return;
    final price = p.displayPrice.price;
    _safe(() => _ga.logViewItem(
          currency: currency,
          value: price,
          items: [
            AnalyticsEventItem(
              itemId: p.id,
              itemName: clip(p.name),
              itemCategory: p.category.isEmpty ? null : clip(p.category),
              itemBrand: p.store == null || p.store!.isEmpty ? null : clip(p.store!),
              price: price,
              quantity: 1,
            ),
          ],
        ));
  }

  /// add_to_cart for the quantity THIS action added.
  void addToCart(CartItemModel line, int addedQty) {
    if (addedQty <= 0) return;
    _safe(() => _ga.logAddToCart(
          currency: currency,
          value: round2(line.price * addedQty),
          items: [itemFor(line, quantity: addedQty)],
        ));
  }

  /// remove_from_cart for the quantity THIS action removed.
  void removeFromCart(CartItemModel line, int removedQty) {
    if (removedQty <= 0) return;
    _safe(() => _ga.logRemoveFromCart(
          currency: currency,
          value: round2(line.price * removedQty),
          items: [itemFor(line, quantity: removedQty)],
        ));
  }

  void viewCart(List<CartItemModel> lines) {
    if (lines.isEmpty) return;
    _safe(() => _ga.logViewCart(
          currency: currency,
          value: itemsValue(lines),
          items: lines.map(itemFor).toList(),
        ));
  }

  void beginCheckout(List<CartItemModel> lines) {
    if (lines.isEmpty) return;
    _safe(() => _ga.logBeginCheckout(
          currency: currency,
          value: itemsValue(lines),
          items: lines.map(itemFor).toList(),
        ));
  }

  /// add_shipping_info: delivery details accepted. No address in the event.
  void addShippingInfo(List<CartItemModel> lines, {String shippingTier = 'standard'}) {
    if (lines.isEmpty) return;
    _safe(() => _ga.logAddShippingInfo(
          currency: currency,
          value: itemsValue(lines),
          shippingTier: shippingTier,
          items: lines.map(itemFor).toList(),
        ));
  }

  /// add_payment_info: the payment step opened. A label only, never details.
  void addPaymentInfo(List<CartItemModel> lines, {String paymentType = 'Razorpay'}) {
    if (lines.isEmpty) return;
    _safe(() => _ga.logAddPaymentInfo(
          currency: currency,
          value: itemsValue(lines),
          paymentType: paymentType,
          items: lines.map(itemFor).toList(),
        ));
  }

  /// purchase: call only after the server confirmed the payment. Sent once per
  /// [transactionId], however often this is called (retries, a second device,
  /// reopening the app): [_claim] records the transaction first.
  Future<void> logPurchase({
    required String transactionId,
    required List<CartItemModel> lines,
    required double shipping,
    required double tax,
    List<String> orderIds = const [],
  }) async {
    if (!_enabled || transactionId.isEmpty || lines.isEmpty) return;
    if (!await _claim(transactionId, orderIds)) return;
    await _safe(() => _ga.logPurchase(
          transactionId: transactionId,
          currency: currency,
          value: itemsValue(lines),
          shipping: round2(shipping),
          tax: round2(tax),
          items: lines.map(itemFor).toList(),
        ));
  }

  /// refund: a customer's cancellation that the server refunded.
  void logRefund({required String transactionId, required double amount, required String orderId}) {
    if (transactionId.isEmpty || amount <= 0) return;
    _safe(() async {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getStringList(_refundsKey) ?? const [];
      if (done.contains(orderId)) return;
      await _ga.logRefund(transactionId: transactionId, currency: currency, value: round2(amount));
      await prefs.setStringList(_refundsKey, keepLast([...done, orderId]));
    });
  }

  // ── Purchase de-duplication ────────────────────────────────────────────

  static const _purchasesKey = 'ga_purchases_logged';
  static const _refundsKey = 'ga_refunds_logged';

  /// True only for the first claim of [transactionId]. Checks this device
  /// first, then a server record (analyticsPurchases/{id}, create-once in
  /// firestore.rules) so a retry from another device or a reinstall can't
  /// count the same payment twice. If the server record can't be reached,
  /// the device record still prevents repeats here.
  Future<bool> _claim(String transactionId, List<String> orderIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getStringList(_purchasesKey) ?? const [];
      if (done.contains(transactionId)) return false;
      var first = true;
      try {
        final db = FirebaseFirestore.instance;
        final ref = db.collection('analyticsPurchases').doc(transactionId);
        first = await db.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (snap.exists) return false;
          tx.set(ref, {
            'uid': FirebaseAuth.instance.currentUser?.uid,
            'platform': defaultTargetPlatform.name,
            'orderIds': orderIds.take(20).toList(),
            'at': FieldValue.serverTimestamp(),
          });
          return true;
        });
      } catch (e) {
        debugPrint('[Analytics] purchase record unavailable, using device record: $e');
      }
      await prefs.setStringList(_purchasesKey, keepLast([...done, transactionId]));
      return first;
    } catch (_) {
      return false; // never risk a duplicate
    }
  }

  // ── Pure helpers (unit-tested) ─────────────────────────────────────────

  /// GA4 item for a cart line. Price is what the customer pays per unit
  /// (after discount); the discount is reported per unit as well.
  static AnalyticsEventItem itemFor(CartItemModel l, {int? quantity}) {
    final discount = l.originalPrice > l.price ? round2(l.originalPrice - l.price) : null;
    return AnalyticsEventItem(
      itemId: l.catalogId,
      itemName: clip(l.catalogName),
      itemVariant: l.variantLabel == null || l.variantLabel!.isEmpty ? null : clip(l.variantLabel!),
      affiliation: l.sellerName.isEmpty ? null : clip(l.sellerName),
      price: round2(l.price),
      quantity: quantity ?? l.quantity,
      discount: discount,
    );
  }

  static double itemsValue(List<CartItemModel> lines) =>
      round2(lines.fold(0.0, (s, l) => s + l.price * l.quantity));

  static double round2(num v) => (v * 100).roundToDouble() / 100;

  /// GA4 caps string values at 100 characters.
  static String clip(String s) => s.length <= 100 ? s : s.substring(0, 100);

  static List<String> keepLast(List<String> ids) =>
      ids.length <= 200 ? ids : ids.sublist(ids.length - 200);

  /// "/product/MhdOeDTFMn5065FvFeAM" → "/product/:id"; query strings dropped.
  static String screenNameFor(String path) {
    final clean = path.split('?').first.split('#').first.trim();
    if (clean.isEmpty) return '';
    final parts = clean.split('/').map((seg) {
      final idLike = RegExp(r'^[A-Za-z0-9_-]{15,}$').hasMatch(seg) ||
          RegExp(r'^\+?\d{6,}$').hasMatch(seg);
      return idLike ? ':id' : seg;
    });
    final name = parts.join('/');
    return clip(name.isEmpty ? '/' : name);
  }
}
