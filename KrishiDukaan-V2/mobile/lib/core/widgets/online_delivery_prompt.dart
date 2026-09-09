import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../constants/app_colors.dart';
import '../constants/app_text_styles.dart';

/// Shown in place of a product form's GST/Sell Mode section when the
/// seller's ACCOUNT hasn't turned Online Delivery on yet. Matches web
/// (add-product-inventory-form.tsx), which simply omits that section
/// entirely in the same situation — this adds a way forward (rather than
/// just silence), since neither the retailer inventory screen nor the
/// manufacturer catalog screen has an obvious path to Settings mid-flow the
/// way web's page layout does.
///
/// Shared by inventory_screen.dart (retailer) and
/// manufacturer_catalog_screen.dart — both product-add flows need the exact
/// same gate, and duplicating it was how the two silently drifted apart in
/// the first place.
class OnlineDeliveryPrompt extends StatelessWidget {
  const OnlineDeliveryPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_shipping_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This product will be offline-only for now',
                  style: AppTextStyles.bodyMedium
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Turn on Online Delivery in Settings (requires a GST number) to '
            'let buyers order this — and any product — for home delivery.',
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push('/profile/settings'),
            icon: const Icon(Icons.settings_outlined, size: 16),
            label: const Text('Go to Settings'),
          ),
        ],
      ),
    );
  }
}
