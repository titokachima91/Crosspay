import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/features/support/models/support_trade_context.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F3.5 - a real place to contact support.
///
/// Trade details are attached automatically when the screen is opened from a
/// trade. Contact channels come from `GET /config`; until the server publishes
/// them the screen says so plainly. In-app messaging is not connected yet, so
/// the screen only offers copyable details instead of a fake send action.
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});

  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  final _description = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final status = ref.read(appConfigProvider).status;
      if (status == ConfigStatus.unavailable || status == ConfigStatus.error) {
        ref.read(appConfigProvider.notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.tr('support.copied'))),
    );
  }

  String _tradeDetails(SupportTradeContext trade) {
    final lines = <String>[
      '${ref.tr('support.reference')}: ${trade.reference}',
      if (trade.status != null)
        '${ref.tr('support.status')}: ${ref.tr(trade.status!.labelKey)}',
      if (trade.verificationHash != null)
        '${ref.tr('support.hash')}: ${trade.verificationHash}',
    ];
    return lines.join('\n');
  }

  String _requestDetails(SupportTradeContext? trade) {
    final lines = <String>[
      if (trade != null) _tradeDetails(trade),
      if (_description.text.trim().isNotEmpty) _description.text.trim(),
    ];
    return lines.join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trade = SupportTradeContext.fromArguments(
      ModalRoute.of(context)?.settings.arguments,
    );
    final configState = ref.watch(appConfigProvider);
    final support = configState.config.support;
    final hasChannels = support?.hasChannels ?? false;
    final checkingChannels = configState.status == ConfigStatus.loading;
    final requestEmpty = trade == null && _description.text.trim().isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('support.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                const _HeroCard(),
                const SizedBox(height: 24),
                if (trade == null) ...[
                  _NoteCard(
                    icon: Icons.info_outline,
                    text: ref.tr('support.no_trade_note'),
                  ),
                  const SizedBox(height: 24),
                ] else ...[
                  _SectionTitle(ref.tr('support.trade_details')),
                  const SizedBox(height: 8),
                  _TradeDetailsCard(
                    trade: trade,
                    onCopy: () => _copy(_tradeDetails(trade)),
                  ),
                  const SizedBox(height: 24),
                ],
                _SectionTitle(ref.tr('support.contact_options')),
                const SizedBox(height: 8),
                if (checkingChannels)
                  const _LoadingChannelsCard()
                else if (!hasChannels)
                  const _EmptyChannelsCard()
                else
                  _ChannelList(support: support!, onCopy: _copy),
                if (hasChannels && support?.hours != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.schedule,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${ref.tr('support.hours')}: ${support!.hours}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                _SectionTitle(ref.tr('support.message_title')),
                const SizedBox(height: 8),
                TextField(
                  controller: _description,
                  minLines: 3,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: ref.tr('support.message_hint'),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: requestEmpty
                        ? null
                        : () => _copy(_requestDetails(trade)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(ref.tr('support.copy_request')),
                  ),
                ),
                const SizedBox(height: 12),
                _NoteCard(
                  icon: Icons.info_outline,
                  text: ref.tr('support.send_note'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends ConsumerWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withOpacity(0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.support_agent, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ref.tr('support.hero_title'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ref.tr('support.hero_body'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TradeDetailsCard extends ConsumerWidget {
  const _TradeDetailsCard({required this.trade, required this.onCopy});

  final SupportTradeContext trade;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          _DetailRow(
            label: ref.tr('support.reference'),
            value: trade.reference,
          ),
          if (trade.status != null) ...[
            Divider(height: 20, color: scheme.outlineVariant),
            _DetailRow(
              label: ref.tr('support.status'),
              value: ref.tr(trade.status!.labelKey),
            ),
          ],
          if (trade.verificationHash != null) ...[
            Divider(height: 20, color: scheme.outlineVariant),
            _DetailRow(
              label: ref.tr('support.hash'),
              value: trade.verificationHash!,
              monospace: true,
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onCopy,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.copy, size: 18),
              label: Text(ref.tr('support.copy_details')),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: monospace ? 12 : 14,
              fontFamily: monospace ? 'monospace' : null,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingChannelsCard extends ConsumerWidget {
  const _LoadingChannelsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              ref.tr('support.checking'),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChannelsCard extends ConsumerWidget {
  const _EmptyChannelsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.support_agent, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ref.tr('support.not_connected_title'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ref.tr('support.not_connected_body'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelList extends ConsumerWidget {
  const _ChannelList({required this.support, required this.onCopy});

  final SupportInfo support;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[
      if (support.email != null && support.email!.trim().isNotEmpty)
        _ChannelRow(
          icon: Icons.mail_outline,
          label: ref.tr('support.email'),
          value: support.email!,
          onTap: () => onCopy(support.email!),
        ),
      if (support.phone != null && support.phone!.trim().isNotEmpty)
        _ChannelRow(
          icon: Icons.call_outlined,
          label: ref.tr('support.phone'),
          value: support.phone!,
          onTap: () => onCopy(support.phone!),
        ),
      if (support.whatsapp != null && support.whatsapp!.trim().isNotEmpty)
        _ChannelRow(
          icon: Icons.chat_outlined,
          label: ref.tr('support.whatsapp'),
          value: support.whatsapp!,
          onTap: () => onCopy(support.whatsapp!),
        ),
    ];

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1) const SizedBox(height: 8),
        ],
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.touch_app_outlined,
                size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ref.tr('support.tap_to_copy'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.copy, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
