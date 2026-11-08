import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/account/screens/beneficiaries_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _kes = Currency(
  code: 'KES',
  name: 'Kenyan Shilling',
  countryCode: 'KE',
  decimals: 2,
);
const _rail = PayoutRail(
  id: 'mpesa',
  name: 'M-Pesa',
  countryCode: 'KE',
  kind: PayoutKind.mobileMoney,
);
const _config = AppConfig(currencies: [_kes], payoutRails: [_rail]);

class _ReadyConfig extends ConfigNotifier {
  _ReadyConfig(this._state);

  final ConfigState _state;

  @override
  ConfigState build() => _state;
}

class _FakeBeneficiaryRepository extends BeneficiaryRepository {
  _FakeBeneficiaryRepository(this.items) : super(Dio());

  final List<Beneficiary> items;
  final List<String> removed = [];

  @override
  Future<List<Beneficiary>> list(AppConfig config) async =>
      List<Beneficiary>.of(items);

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    items.removeWhere((b) => b.id == id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(
    BeneficiaryRepository repo, {
    bool withConfig = true,
  }) =>
      ProviderContainer(overrides: [
        beneficiaryRepositoryProvider.overrideWithValue(repo),
        translationsProvider.overrideWithValue(translations),
        if (withConfig)
          appConfigProvider.overrideWith(
            () => _ReadyConfig(
              const ConfigState(status: ConfigStatus.ready, config: _config),
            ),
          ),
      ]);

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const BeneficiariesScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('the saved recipients the server sent are listed',
      (tester) async {
    final repo = _FakeBeneficiaryRepository([
      const Beneficiary(
        id: 'b1',
        name: 'Eastleigh Textiles',
        rail: _rail,
        accountOrPhone: '+254700000001',
        kycVerified: true,
      ),
      const Beneficiary(
        id: 'b2',
        name: 'Nairobi Motors',
        rail: _rail,
        accountOrPhone: '+254700000003',
      ),
    ]);
    final container = containerFor(repo);
    await open(tester, container);

    expect(find.text('Eastleigh Textiles'), findsOneWidget);
    expect(find.text('Nairobi Motors'), findsOneWidget);
    expect(find.text('Add recipient'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('deleting a recipient asks first, then removes it',
      (tester) async {
    final repo = _FakeBeneficiaryRepository([
      const Beneficiary(
        id: 'b1',
        name: 'Eastleigh Textiles',
        rail: _rail,
        accountOrPhone: '+254700000001',
      ),
    ]);
    final container = containerFor(repo);
    await open(tester, container);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    await tester.pump();

    expect(find.text('Recipient removed.'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump();

    expect(repo.removed, ['b1']);
    expect(find.text('Eastleigh Textiles'), findsNothing);
    expect(find.text('No saved recipients yet.'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('no config yet means the screen says it is not connected',
      (tester) async {
    final container = containerFor(
      _FakeBeneficiaryRepository(const []),
      withConfig: false,
    );
    await open(tester, container);

    expect(
      find.text('Saved recipients are not connected yet.'),
      findsOneWidget,
    );
    expect(find.text('Add recipient'), findsNothing);

    await finish(tester, container);
  });
}