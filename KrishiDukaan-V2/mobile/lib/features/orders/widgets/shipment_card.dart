import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/models/order_model.dart';
import '../../dashboard/data/dashboard_repository.dart';

/// The courier parcel, for the customer and the seller. Same content as
/// app/views/ShipmentCard.tsx on the web.
class ShipmentCard extends StatefulWidget {
  final OrderModel order;
  final bool sellerView;
  const ShipmentCard({super.key, required this.order, this.sellerView = false});

  @override
  State<ShipmentCard> createState() => _ShipmentCardState();
}

class _ShipmentCardState extends State<ShipmentCard> {
  bool _busy = false;

  static const _simSteps = <(String, String)>[
    ('picked_up', 'Picked up'),
    ('in_transit', 'In transit'),
    ('out_for_delivery', 'Out for delivery'),
    ('delivered', 'Delivered'),
    ('returning', 'Return'),
    ('returned', 'Returned'),
    ('lost', 'Lost'),
  ];

  Future<void> _send(String action, {String? event}) async {
    setState(() => _busy = true);
    try {
      await DashboardRepository()
          .requestShipmentAction(widget.order.id, action, event: event);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send that. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = widget.order.shipment;
    if (s == null) return const SizedBox.shrink();

    if (!s.isCourier) {
      if (!widget.sellerView) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Please deliver this order yourself. ${s.reasonText ?? ''}'.trim(),
          style: AppTextStyles.bodySmall.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.service == null
                      ? s.carrierName
                      : '${s.carrierName} · ${s.service}',
                  style: AppTextStyles.bodyMedium
                      .copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Flexible(
                child: Text(
                  s.stageText,
                  textAlign: TextAlign.end,
                  style: AppTextStyles.caption.copyWith(
                    color: s.isTrouble ? AppColors.error : AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (s.simulated) ...[
            const SizedBox(height: 8),
            Text(
              'Test booking. Nothing is really shipped and the tracking link will not work.',
              style: AppTextStyles.caption.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
          if (s.stage == 'pickup_requested' && s.pickupDate != null) ...[
            const SizedBox(height: 6),
            Text('Pickup expected on ${s.pickupDate}.',
                style: AppTextStyles.bodySmall),
          ],
          if (s.awb != null) ...[
            const SizedBox(height: 6),
            SelectableText('Tracking ID: ${s.awb}',
                style: AppTextStyles.bodySmall
                    .copyWith(fontWeight: FontWeight.w700)),
          ],
          if (s.trackingUrl != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => _open(s.trackingUrl!),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Track this parcel'),
            ),
          if (widget.sellerView) ..._sellerParts(s),
        ],
      ),
    );
  }

  List<Widget> _sellerParts(ShipmentInfo s) => [
        if (s.cost != null && (s.sellerPaysCourier ?? 0) > 0)
          Text(
            'Your delivery offer: ₹${s.sellerPaysCourier!.toStringAsFixed(0)} of the courier cost is taken from your payout.',
            style: AppTextStyles.caption.copyWith(fontWeight: FontWeight.w600),
          )
        else if (s.cost != null)
          Text(
            'KrishiDukan pays the courier, so the delivery charge is not part of your payout.',
            style: AppTextStyles.caption,
          ),
        if (s.weightGuessed) ...[
          const SizedBox(height: 4),
          Text(
            'Weight was estimated (${s.weightKg} kg). A wrong size on the product can change what the courier charges.',
            style: AppTextStyles.caption.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (s.labelUrl != null)
              OutlinedButton.icon(
                onPressed: () => _open(s.labelUrl!),
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print label'),
              ),
            if (s.stage == 'booked')
              FilledButton.icon(
                onPressed: _busy ? null : () => _send('pickup'),
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: const Text('Ready for pickup'),
              ),
          ],
        ),
        if (s.simulated &&
            !const {'delivered', 'returned', 'lost'}.contains(s.stage)) ...[
          const Divider(height: 20),
          Text('Test: act as the courier',
              style: AppTextStyles.caption.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (event, label) in _simSteps)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed:
                      _busy ? null : () => _send('simulate', event: event),
                  child: Text(label, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ],
      ];
}
