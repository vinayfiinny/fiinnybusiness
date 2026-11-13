import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukaan_app/core/models/cart_model.dart';
import 'package:krishidukaan_app/core/services/analytics_service.dart';

CartItemModel line({double price = 1450, double original = 1450, int qty = 1, String? size = '1L', String name = 'Karan Arjun Power Plus'}) =>
    CartItemModel(
      catalogId: 'MhdOeDTFMn5065FvFeAM',
      catalogName: name,
      listingId: 'L1',
      sellerPhone: '+919000000002',
      sellerName: 'KaranArjun Krushi Seva Kendra',
      price: price,
      originalPrice: original,
      discountPct: 0,
      quantity: qty,
      variantLabel: size,
    );

void main() {
  test('item carries what the customer pays per unit, the size and the store', () {
    final i = AnalyticsService.itemFor(line(qty: 2)).asMap();
    expect(i['item_id'], 'MhdOeDTFMn5065FvFeAM');
    expect(i['item_name'], 'Karan Arjun Power Plus');
    expect(i['item_variant'], '1L');
    expect(i['affiliation'], 'KaranArjun Krushi Seva Kendra');
    expect(i['price'], 1450);
    expect(i['quantity'], 2);
    expect(i.containsKey('discount'), isFalse);
  });

  test('a discounted line reports the per-unit discount, price stays the paid price', () {
    final i = AnalyticsService.itemFor(line(price: 1300, original: 1450)).asMap();
    expect(i['price'], 1300);
    expect(i['discount'], 150);
  });

  test('add_to_cart quantity is the amount this action added, not the line total', () {
    final i = AnalyticsService.itemFor(line(qty: 5), quantity: 2).asMap();
    expect(i['quantity'], 2);
  });

  test('value = sum(price x quantity); shipping and tax are not folded in', () {
    expect(AnalyticsService.itemsValue([line(qty: 2), line(price: 99.995, qty: 1)]), 3000);
    expect(AnalyticsService.itemsValue([]), 0);
  });

  test('strings are capped at GA4\'s 100 characters', () {
    final i = AnalyticsService.itemFor(line(name: 'x' * 150)).asMap();
    expect((i['item_name'] as String).length, 100);
  });

  test('screen names fold ids so one screen is one name', () {
    expect(AnalyticsService.screenNameFor('/product/MhdOeDTFMn5065FvFeAM'), '/product/:id');
    expect(AnalyticsService.screenNameFor('/orders/abcdefghijklmnopqrst?x=1'), '/orders/:id');
    expect(AnalyticsService.screenNameFor('/stores/+918658031942'), '/stores/:id');
    expect(AnalyticsService.screenNameFor('/cart'), '/cart');
    expect(AnalyticsService.screenNameFor('/'), '/');
    expect(AnalyticsService.screenNameFor(''), '');
  });

  test('the sent-purchases list keeps only the latest 200', () {
    final ids = List.generate(250, (i) => 'p$i');
    final kept = AnalyticsService.keepLast(ids);
    expect(kept.length, 200);
    expect(kept.first, 'p50');
    expect(kept.last, 'p249');
  });
}
