import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../config.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/credits.dart';
import 'buy_credits.dart';

/// Credits: balance, inviting friends, entering a friend's code, buying, and the history.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key, this.paid = false});

  /// Back from Stripe Checkout.
  final bool paid;

  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  late Future<Map<String, dynamic>> _referrals = Api.myReferrals();
  late Future<List<Map<String, dynamic>>> _ledger = Api.ledger();

  void _reload() => setState(() {
        _referrals = Api.myReferrals();
        _ledger = Api.ledger();
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/settings')),
        title: const Text('Credits'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          PageBody(
            maxWidth: 820,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CreditsBuilder(builder: (context, c) => _Balance(credits: c)),
              const SizedBox(height: 16),
              FutureBuilder<Map<String, dynamic>>(
                future: _referrals,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorView(errorText(snap.error!), onRetry: _reload);
                  if (!snap.hasData) return const LinearProgressIndicator();
                  final r = snap.data!;
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    InviteCard(
                      code: '${r['code'] ?? ''}',
                      rewarded: (r['rewarded'] as num?)?.toInt() ?? 0,
                      onNewCode: _reload,
                    ),
                    if (r['can_add_code'] == true) ...[
                      const SizedBox(height: 16),
                      _AddCode(onDone: _reload, typo: '${r['status']}' == 'declined:invalid_code'),
                    ],
                  ]);
                },
              ),
              const SizedBox(height: 16),
              BuyCreditsSection(paid: widget.paid),
              const SizedBox(height: 16),
              const _Prices(),
              const SizedBox(height: 16),
              Text('History', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _ledger,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorView(errorText(snap.error!));
                  if (!snap.hasData) return const LinearProgressIndicator();
                  if (snap.data!.isEmpty) {
                    return Text('Nothing yet.', style: theme.textTheme.bodySmall);
                  }
                  return Card(child: Column(children: [for (final row in snap.data!) _LedgerRow(row: row)]));
                },
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Balance extends StatelessWidget {
  const _Balance({required this.credits});
  final Credits? credits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onPrimaryContainer;
    final c = credits;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: brandGradient(theme.colorScheme), borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        Icon(Icons.toll, size: 44, color: on),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c == null ? '…' : '${c.available}', style: theme.textTheme.displaySmall?.copyWith(color: on, fontWeight: FontWeight.w800)),
            Text('credits to spend', style: theme.textTheme.titleMedium?.copyWith(color: on)),
            if (c != null && c.held > 0)
              Text('${c.held} held for work in progress · balance ${c.balance}', style: TextStyle(color: on)),
          ]),
        ),
      ]),
    );
  }
}

/// Your referral code and every way to share it.
class InviteCard extends StatefulWidget {
  const InviteCard({super.key, required this.code, required this.rewarded, this.onNewCode});
  final String code;
  final int rewarded;
  final VoidCallback? onNewCode;

  @override
  State<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<InviteCard> {
  bool _busy = false;

  String get _link => '${AppConfig.siteUrl}/register?ref=${widget.code}';
  String get _message => 'I use Pounce to find jobs that fit my resume and get tailored CVs and cover letters. '
      'Join with my code ${widget.code} and we both get 30 free credits: $_link';

  Future<void> _open(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      toast(context, 'Couldn\'t open that app. Copy the link instead.');
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) toast(context, 'Copied the $what');
  }

  Future<void> _newCode() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make a new code?'),
        content: const Text('Your current code and link stop working. Friends who already joined keep their credits.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('New code')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await Api.regenerateReferralCode();
      widget.onNewCode?.call();
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Uri.encodeComponent(_message);
    final options = [
      (Icons.chat_outlined, 'WhatsApp', () => _open(Uri.parse('https://wa.me/?text=$text'))),
      (Icons.mail_outline, 'Email', () => _open(Uri.parse(
          'mailto:?subject=${Uri.encodeComponent('Join me on Pounce: 30 free credits')}&body=$text'))),
      (Icons.sms_outlined, 'SMS', () => _open(Uri.parse('sms:?body=$text'))),
      (Icons.send_outlined, 'Telegram', () => _open(Uri.parse(
          'https://t.me/share/url?url=${Uri.encodeComponent(_link)}&text=${Uri.encodeComponent('Join me on Pounce with code ${widget.code}: we both get 30 free credits')}'))),
      (Icons.work_outline, 'LinkedIn', () => _open(Uri.parse(
          'https://www.linkedin.com/sharing/share-offsite/?url=${Uri.encodeComponent(_link)}'))),
      (Icons.tag, 'X', () => _open(Uri.parse('https://twitter.com/intent/tweet?text=$text'))),
      (Icons.link, 'Copy link', () => _copy(_link, 'link')),
      (Icons.ios_share, 'More', () => SharePlus.instance.share(ShareParams(text: _message, subject: 'Join me on Pounce'))),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.card_giftcard, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('Invite friends, get 30 credits each', style: theme.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 4),
          Text('When a friend signs up with your code and verifies their email, you both get 30 credits. '
              '${widget.rewarded == 0 ? 'Nobody has joined with your code yet.' : '${widget.rewarded} friend${widget.rewarded == 1 ? ' has' : 's have'} joined so far.'}',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Expanded(
                child: SelectableText(widget.code,
                    style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 4, fontFamily: 'monospace')),
              ),
              IconButton(tooltip: 'Copy code', onPressed: () => _copy(widget.code, 'code'), icon: const Icon(Icons.copy)),
              IconButton(tooltip: 'Make a new code', onPressed: _busy ? null : _newCode, icon: const Icon(Icons.autorenew)),
            ]),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (icon, label, onTap) in options)
              ActionChip(avatar: Icon(icon, size: 18), label: Text(label), onPressed: onTap),
          ]),
          const SizedBox(height: 8),
          Text('Each email address can only earn sign-up credits once, and throwaway inboxes don\'t count.',
              style: theme.textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class _AddCode extends StatefulWidget {
  const _AddCode({required this.onDone, required this.typo});
  final VoidCallback onDone;
  final bool typo;

  @override
  State<_AddCode> createState() => _AddCodeState();
}

class _AddCodeState extends State<_AddCode> {
  final _code = TextEditingController();
  bool _busy = false;

  static const _reasons = {
    'email_used': 'This email address has already had sign-up credits.',
    'disposable_email': 'Throwaway email addresses can\'t get referral credits.',
    'self': 'You can\'t use your own code.',
    'invalid_code': 'That code doesn\'t exist.',
    'referrer_limit': 'That code has reached its limit.',
    'referrer_daily_limit': 'That code has been used a lot today. Try again tomorrow.',
  };

  Future<void> _apply() async {
    setState(() => _busy = true);
    try {
      final r = await Api.applyReferralCode(_code.text);
      if (!mounted) return;
      toast(context, r['status'] == 'rewarded'
          ? 'Done: you and your friend both got 30 credits'
          : 'No credits this time. ${_reasons[r['reason']] ?? ''}');
      widget.onDone();
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Have a friend\'s code?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            widget.typo
                ? 'The code you signed up with didn\'t work. Enter the right one (within 7 days of joining).'
                : 'You can still add it within 7 days of joining. You both get 30 credits.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(hintText: 'ABCD2345'),
                onSubmitted: (_) => _apply(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _busy ? null : _apply, child: const Text('Apply')),
          ]),
        ]),
      ),
    );
  }
}

class _Prices extends StatelessWidget {
  const _Prices();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      (Icons.manage_search, 'Finding and scoring jobs that fit you', 'Free'),
      (Icons.description_outlined, 'Tailored resume and cover letter for a job', '1 credit'),
      (Icons.school_outlined, 'Interview prep for a job', '1 credit'),
      (Icons.edit_document, 'Resume and cover letter builder', 'Free, 20 AI requests a day'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('What costs what', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final (icon, what, cost) in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(icon),
              title: Text(what),
              trailing: Text(cost, style: theme.textTheme.labelLarge),
            ),
          Text('Credits are held while the work runs and only used when it succeeds. If something fails, you keep them.',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.row});
  final Map<String, dynamic> row;

  static const _icons = {
    'welcome': Icons.celebration_outlined,
    'referral': Icons.card_giftcard,
    'spend': Icons.auto_awesome_outlined,
    'purchase': Icons.shopping_bag_outlined,
    'admin': Icons.admin_panel_settings_outlined,
    'refund': Icons.undo,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = (row['delta'] as num).toInt();
    final at = DateTime.tryParse('${row['at']}')?.toLocal();
    return ListTile(
      leading: Icon(_icons[row['reason']] ?? Icons.toll),
      title: Text('${row['note'] ?? row['reason']}'),
      subtitle: Text([
        if (at != null) DateFormat.yMMMd().add_jm().format(at),
        if (row['job_id'] != null) '${row['job_id']}',
        'balance ${row['balance_after']}',
      ].join(' · ')),
      trailing: Text(
        '${delta > 0 ? '+' : ''}$delta',
        style: theme.textTheme.titleMedium?.copyWith(color: delta > 0 ? Colors.green.shade600 : theme.colorScheme.error),
      ),
    );
  }
}
