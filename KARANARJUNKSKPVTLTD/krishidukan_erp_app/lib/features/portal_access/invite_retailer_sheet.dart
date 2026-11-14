import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../core/erp_links.dart' show erpBaseUrl;
import '../../core/parse.dart';
import '../../widgets/ui.dart';
import '../auth/auth_repository.dart';
import '../customers/customer.dart';
import '../customers/customer_picker_sheet.dart';
import 'portal_access_repository.dart';

/// Opens the invite form. [retailer] preselects the partner (from their
/// detail screen); otherwise the admin picks one.
Future<void> showInviteRetailerSheet(BuildContext context, {Customer? retailer}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      enableDrag: false,
      builder: (_) => _InviteSheet(initial: retailer),
    );

/// 10 characters without look-alikes (0/O, 1/l/I) so it survives being read
/// out over the phone.
String generateTempPassword([Random? rng]) {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  final r = rng ?? Random.secure();
  return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
}

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet({this.initial});
  final Customer? initial;

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  Customer? _retailer;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = true;
  bool _busy = false;
  String? _error;
  ({String email, String password, Customer retailer})? _done;

  @override
  void initState() {
    super.initState();
    _setRetailer(widget.initial);
    _password.text = generateTempPassword();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setRetailer(Customer? c) {
    _retailer = c;
    if (c != null && c.email.trim().isNotEmpty && _email.text.trim().isEmpty) {
      _email.text = c.email.trim();
    }
  }

  Future<void> _pick() async {
    final c = await pickCustomer(context, b2bOnly: true);
    if (c != null) setState(() => _setRetailer(c));
  }

  Future<void> _submit() async {
    final r = _retailer;
    if (r == null) {
      setState(() => _error = 'Choose the retailer first.');
      return;
    }
    final problem = validateInvite(email: _email.text, password: _password.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final repo = ref.read(portalAccessRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await repo.invite(retailer: r, email: _email.text, password: _password.text);
      if (mounted) {
        setState(() => _done = (email: _email.text.trim().toLowerCase(), password: _password.text, retailer: r));
      }
    } on InviteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create the login. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
        child: _done == null ? _form() : _success(_done!),
      ),
    );
  }

  Widget _form() {
    final r = _retailer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Give portal access', style: AppText.title),
        const SizedBox(height: 4),
        Text(
          'The retailer signs in to this app or $erpBaseUrl with this email and password. '
          'They see only their own bills, payments and balance — nothing else in your business, '
          'and they cannot change anything.',
          style: AppText.label,
        ),
        const SizedBox(height: 18),
        Text('Retailer', style: AppText.small),
        const SizedBox(height: 6),
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          onTap: _busy || widget.initial != null ? null : _pick,
          child: Row(children: [
            InitialAvatar(r?.name ?? '?', size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: r == null
                  ? Text('Choose a B2B partner', style: AppText.body.copyWith(color: AppColors.inkMute))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                      if (r.placeLine.isNotEmpty || r.phone.isNotEmpty)
                        Text([r.phone, r.placeLine].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
                    ]),
            ),
            if (widget.initial == null) Icon(Icons.expand_more_rounded, color: AppColors.inkMute),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Login email',
            hintText: 'retailer@shop.com',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Temporary password',
            helperText: 'At least 6 characters. They can change it later.',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: _showPassword ? 'Hide' : 'Show',
                icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              IconButton(
                tooltip: 'New password',
                icon: const Icon(Icons.autorenew_rounded),
                onPressed: _busy ? null : () => setState(() => _password.text = generateTempPassword()),
              ),
            ]),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppColors.critical, fontSize: 13)),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onPrimary),
                )
              : const Icon(Icons.person_add_alt_1_rounded, size: 18),
          label: Text(_busy ? 'Creating login…' : 'Create login'),
        ),
      ],
    );
  }

  Widget _success(({String email, String password, Customer retailer}) d) {
    final business = ref.read(appUserProvider).valueOrNull?.businessName ?? '';
    final message = 'Namaste ${d.retailer.name},\n'
        '${business.isEmpty ? 'We have' : '$business has'} given you access to your account — '
        'see your bills, payments and balance any time.\n\n'
        'Open the KaranArjun ERP app or $erpBaseUrl and sign in with:\n'
        'Email: ${d.email}\n'
        'Password: ${d.password}\n\n'
        'Please change the password after your first login.';
    final phone = phoneKey(d.retailer.phone);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          IconBadge(icon: Icons.check_rounded, color: AppColors.good, size: 40),
          const SizedBox(width: 12),
          Expanded(child: Text('Login created for ${d.retailer.name}', style: AppText.title.copyWith(fontSize: 18))),
        ]),
        const SizedBox(height: 14),
        AppCard(
          color: AppColors.cardHi,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Email', style: AppText.small),
            SelectableText(d.email, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Temporary password', style: AppText.small),
            SelectableText(d.password, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: 8),
        Text('Send these to the retailer now — the password is not shown again.', style: AppText.small),
        const SizedBox(height: 16),
        if (phone.length >= 10)
          FilledButton.icon(
            onPressed: () {
              final to = phone.length == 10 ? '91$phone' : phone;
              launchUrl(Uri.parse('https://wa.me/$to?text=${Uri.encodeComponent(message)}'),
                  mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.chat_rounded, size: 18),
            label: const Text('Send on WhatsApp'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: message));
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Login details copied')));
            }
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy login details'),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}
