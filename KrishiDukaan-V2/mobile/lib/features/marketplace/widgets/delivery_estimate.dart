import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_config.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/utils/delivery_date.dart';

/// "Deliver to 411062 — FREE delivery by Thu, 19 Nov · Change" on the product
/// page, like Amazon. Same price and rules as checkout: the website's
/// GET /api/delivery/estimate. The pincode is remembered on this phone (or
/// taken from the profile); nothing shows when courier delivery is switched
/// off by the admin.
class DeliveryEstimateBox extends StatefulWidget {
  final String productId;
  final String? sellerPhone;
  final String? size;
  final String? profilePincode;

  const DeliveryEstimateBox({
    super.key,
    required this.productId,
    this.sellerPhone,
    this.size,
    this.profilePincode,
  });

  @override
  State<DeliveryEstimateBox> createState() => _DeliveryEstimateBoxState();
}

class _DeliveryEstimateBoxState extends State<DeliveryEstimateBox> {
  static const _prefKey = 'kd_delivery_pincode';
  static final _pin = RegExp(r'^[1-9]\d{5}$');

  String _pincode = '';
  bool _loading = false;
  Map<String, dynamic>? _est;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void didUpdateWidget(covariant DeliveryEstimateBox old) {
    super.didUpdateWidget(old);
    if (old.sellerPhone != widget.sellerPhone ||
        old.size != widget.size ||
        old.productId != widget.productId) {
      unawaited(_fetch());
    }
  }

  Future<void> _init() async {
    var saved = '';
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefKey) ?? '';
    } catch (_) {}
    if (!_pin.hasMatch(saved)) saved = widget.profilePincode?.trim() ?? '';
    if (!mounted) return;
    setState(() => _pincode = _pin.hasMatch(saved) ? saved : '');
    await _fetch();
  }

  Future<void> _fetch() async {
    if (!_pin.hasMatch(_pincode) || widget.productId.isEmpty) {
      if (mounted) setState(() => _est = null);
      return;
    }
    final id = ++_request;
    setState(() => _loading = true);
    try {
      final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/delivery/estimate')
          .replace(
            queryParameters: {
              'productId': widget.productId,
              'pincode': _pincode,
              if ((widget.sellerPhone ?? '').isNotEmpty)
                'seller': widget.sellerPhone!,
              if ((widget.size ?? '').isNotEmpty) 'size': widget.size!,
            },
          );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      final body = res.statusCode == 200 ? jsonDecode(res.body) : null;
      if (!mounted || id != _request) return;
      setState(() => _est = body is Map<String, dynamic> ? body : null);
    } catch (_) {
      if (mounted && id == _request) setState(() => _est = null);
    } finally {
      if (mounted && id == _request) setState(() => _loading = false);
    }
  }

  Future<void> _change() async {
    final ctrl = TextEditingController(text: _pincode);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deliver to'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(hintText: 'Enter 6-digit pincode'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Check'),
          ),
        ],
      ),
    );
    if (next == null || !_pin.hasMatch(next)) return;
    try {
      await (await SharedPreferences.getInstance()).setString(_prefKey, next);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _pincode = next);
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final est = _est;
    if (est != null && est['enabled'] == false) return const SizedBox.shrink();

    Widget line;
    if (_pincode.isEmpty) {
      line = Text(
        'Enter your pincode to see the delivery date',
        style: AppTextStyles.bodySmall,
      );
    } else if (_loading) {
      line = Text('Checking delivery…', style: AppTextStyles.bodySmall);
    } else if (est == null) {
      line = const SizedBox.shrink();
    } else if (est['available'] == true) {
      final free = est['free'] == true;
      final date = formatDeliveryDate(est['deliveryBy']?.toString());
      final charge = (est['charge'] as num?)?.round() ?? 0;
      final sellerPct = (est['sellerPct'] as num?)?.round() ?? 0;
      final freeAbove = (est['freeAbove'] as num?)?.round();
      line = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: AppTextStyles.bodyMedium.copyWith(
                fontWeight: FontWeight.w600,
              ),
              children: [
                TextSpan(
                  text: free ? 'FREE delivery' : 'Delivery ₹$charge',
                  style: free
                      ? const TextStyle(color: AppColors.success)
                      : null,
                ),
                if (date != null) ...[
                  const TextSpan(text: ' by '),
                  TextSpan(
                    text: date,
                    style: const TextStyle(color: AppColors.success),
                  ),
                ],
              ],
            ),
          ),
          if (!free && sellerPct > 0)
            Text(
              'The store pays $sellerPct% of your delivery',
              style: AppTextStyles.caption.copyWith(color: AppColors.success),
            ),
          if (!free && freeAbove != null && freeAbove > 0)
            Text(
              'FREE delivery on orders of ₹$freeAbove+ from this store',
              style: AppTextStyles.caption,
            ),
        ],
      );
    } else {
      line = Text(
        "Courier delivery isn't available to this pincode; the store will tell you the delivery charge.",
        style: AppTextStyles.bodySmall,
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.local_shipping_outlined,
            size: 20,
            color: AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_pincode.isNotEmpty)
                  Text('Deliver to $_pincode', style: AppTextStyles.caption),
                line,
              ],
            ),
          ),
          TextButton(
            onPressed: _change,
            child: Text(_pincode.isEmpty ? 'Enter' : 'Change'),
          ),
        ],
      ),
    );
  }
}
