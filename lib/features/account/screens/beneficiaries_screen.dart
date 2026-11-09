import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/beneficiaries_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F5.2 — saved recipients (list, add, edit, delete). Everything comes from
/// `GET/POST/PATCH/DELETE /beneficiaries`; while the endpoints are missing the
/// screen says so plainly and offers no fake rows.
class BeneficiariesScreen extends ConsumerStatefulWidget {
  const BeneficiariesScreen({super.key});

  @override
  ConsumerState<BeneficiariesScreen> createState() =>
      _BeneficiariesScreenState();
}

class _BeneficiariesScreenState extends ConsumerState<BeneficiariesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(beneficiariesProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(beneficiariesProvider);
    final rails = ref.watch(appConfigProvider).config.payoutRails;

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('recipients.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: ref.tr('common.retry'),
            onPressed: () => ref.read(beneficiariesProvider.notifier).load(),
          ),
        ],
      ),
      floatingActionButton: rails.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.emerald,
              foregroundColor: Colors.white,
              onPressed: state.saving ? null : () => _openForm(rails),
              icon: const Icon(Icons.person_add_alt),
              label: Text(ref.tr('recipients.add')),
            ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _body(state, rails),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BeneficiariesState state, List<PayoutRail> rails) {
    if (state.status == BeneficiariesStatus.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == BeneficiariesStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref.tr(state.errorKey ?? 'error.unknown'),
              textAlign: TextAlign.center,
              style: const TextStyle(
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => ref.read(beneficiariesProvider.notifier).load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        ),
      );
    }
    if (state.status == BeneficiariesStatus.unavailable) {
      return Center(
        child: Text(
          ref.tr('recipients.unavailable'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        child: Text(
          ref.tr('recipients.empty'),
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }
    return ListView.separated(
      itemCount: state.items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final item = state.items[i];
        return _RecipientTile(
          item: item,
          onEdit: state.saving ? null : () => _openForm(rails, existing: item),
          onDelete: state.saving ? null : () => _remove(item),
        );
      },
    );
  }

Future<void> _openForm(List<PayoutRail> rails, {Beneficiary? existing}) async {
    final draft = await showDialog<_RecipientDraft>(
      context: context,
      builder: (_) => _RecipientForm(rails: rails, existing: existing),
    );
    if (draft == null || !mounted) return;

    final notifier = ref.read(beneficiariesProvider.notifier);
    final ok = existing == null
        ? await notifier.add(
            rail: draft.rail,
            name: draft.name,
            accountOrPhone: draft.accountOrPhone,
          )
        : await notifier.update(
            id: existing.id,
            rail: draft.rail,
            name: draft.name,
            accountOrPhone: draft.accountOrPhone,
          );
    if (!mounted) return;

    final key = ok
        ? 'recipients.saved'
        : (ref.read(beneficiariesProvider).errorKey ?? 'error.unknown');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.tr(key))),
    );
  }

  Future<void> _remove(Beneficiary item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ref.tr('recipients.delete')),
        content: Text(item.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(ref.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(ref.tr('recipients.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await ref.read(beneficiariesProvider.notifier).remove(item.id);
    if (!mounted) return;
    final key = ok
        ? 'recipients.deleted'
        : (ref.read(beneficiariesProvider).errorKey ?? 'error.unknown');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.tr(key))),
    );
  }
}

class _RecipientTile extends ConsumerWidget {
  const _RecipientTile({
    required this.item,
    required this.onEdit,
    required this.onDelete,
  });

  final Beneficiary item;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                        ),
                      ),
                    ),
                    if (item.kycVerified) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.verified,
                        size: 15,
                        color: AppColors.emerald,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.rail.name} · ${item.accountOrPhone}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            color: AppColors.danger,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// What the form returns: a new or edited recipient, not yet saved.
class _RecipientDraft {
  const _RecipientDraft({
    required this.rail,
    required this.name,
    required this.accountOrPhone,
  });

  final PayoutRail rail;
  final String name;
  final String accountOrPhone;
}

class _RecipientForm extends ConsumerStatefulWidget {
  const _RecipientForm({required this.rails, this.existing});

  final List<PayoutRail> rails;
  final Beneficiary? existing;

  @override
  ConsumerState<_RecipientForm> createState() => _RecipientFormState();
}

class _RecipientFormState extends ConsumerState<_RecipientForm> {
  late final TextEditingController _name;
  late final TextEditingController _account;
  late PayoutRail _rail;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _account = TextEditingController(text: existing?.accountOrPhone ?? '');
    _rail = existing?.rail ?? widget.rails.first;
  }

  @override
  void dispose() {
    _name.dispose();
    _account.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final account = _account.text.trim();
    if (name.isEmpty || account.isEmpty) return;
    Navigator.of(context).pop(
      _RecipientDraft(rail: _rail, name: name, accountOrPhone: account),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        ref.tr(
          widget.existing == null ? 'recipients.add' : 'recipients.edit',
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: ref.tr('recipients.name'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PayoutRail>(
              value: _rail,
              decoration: InputDecoration(
                labelText: ref.tr('recipients.rail'),
              ),
              items: [
                for (final rail in widget.rails)
                  DropdownMenuItem(value: rail, child: Text(rail.name)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _rail = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _account,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                labelText: ref.tr('recipients.account'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(ref.tr('common.cancel')),
        ),
        TextButton(
          onPressed: _save,
          child: Text(ref.tr('common.save')),
        ),
      ],
    );
  }
}