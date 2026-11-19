import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/security/biometric_manager.dart';
import 'package:crosspay_app/core/security/pin_manager.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/account/screens/security_settings_screen.dart';

/// Stand-in for local_auth. It records attempts so tests can prove that the
/// gate does not even ask the device when the person has not enabled biometrics.
class _FakeBiometrics extends BiometricManager {
  _FakeBiometrics({required this.available, required this.succeeds});

  final bool available;
  final bool succeeds;
  int attempts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    attempts++;
    return succeeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  Future<bool> runGate(
    WidgetTester tester,
    PinManager pin,
    BiometricManager biometrics,
  ) async {
    Future<bool>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = pin.ensureUnlocked(
                  context,
                  biometrics: biometrics,
                  biometricReason: 'Unlock the test app',
                );
              },
              child: const Text('unlock'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('unlock'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    return result!;
  }

  testWidgets('an enabled biometric check unlocks without the PIN dialog',
      (tester) async {
    final pin = PinManager();
    await pin.setPin('1234');
    await pin.setBiometricUnlock(true);
    final biometrics = _FakeBiometrics(available: true, succeeds: true);

    final unlocked = await runGate(tester, pin, biometrics);

    expect(unlocked, true);
    expect(biometrics.attempts, 1);
    expect(find.text('Enter PIN'), findsNothing);
    expect(find.text('Unlock'), findsNothing);
  });

  testWidgets('a denied biometric check falls back to the PIN dialog',
      (tester) async {
    final pin = PinManager();
    await pin.setPin('1234');
    await pin.setBiometricUnlock(true);
    final biometrics = _FakeBiometrics(available: true, succeeds: false);

    Future<bool>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = pin.ensureUnlocked(
                  context,
                  biometrics: biometrics,
                  biometricReason: 'Unlock the test app',
                );
              },
              child: const Text('unlock'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('unlock'));
    await tester.pumpAndSettle();

    expect(biometrics.attempts, 1);
    expect(find.text('Enter PIN'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, false);
  });

  testWidgets('biometrics are not attempted until the person enables them',
      (tester) async {
    final pin = PinManager();
    await pin.setPin('1234');
    final biometrics = _FakeBiometrics(available: true, succeeds: true);

    Future<bool>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = pin.ensureUnlocked(
                  context,
                  biometrics: biometrics,
                  biometricReason: 'Unlock the test app',
                );
              },
              child: const Text('unlock'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('unlock'));
    await tester.pumpAndSettle();

    expect(biometrics.attempts, 0);
    expect(find.text('Enter PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, false);
  });

  testWidgets('security settings enables and disables biometric unlock',
      (tester) async {
    final pin = PinManager();
    await pin.setPin('1234');
    final biometrics = _FakeBiometrics(available: true, succeeds: true);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: SecuritySettingsScreen(
            pinManager: pin,
            biometrics: biometrics,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
        find.text('On — fingerprint or face is offered first'), findsNothing);
    expect(await pin.hasBiometricUnlock(), false);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    expect(biometrics.attempts, 1);
    expect(await pin.hasBiometricUnlock(), true);
    expect(
        find.text('Biometric unlock is on. Your PIN still works as fallback.'),
        findsOneWidget);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(await pin.hasBiometricUnlock(), false);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('security settings explains when no biometric is enrolled',
      (tester) async {
    final pin = PinManager();
    await pin.setPin('1234');
    final biometrics = _FakeBiometrics(available: false, succeeds: false);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: SecuritySettingsScreen(
            pinManager: pin,
            biometrics: biometrics,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Not available or no biometric is enrolled on this device'),
      findsOneWidget,
    );
    expect(find.text('Test biometrics now'), findsNothing);
    final biometricSwitch = tester.widget<Switch>(find.byType(Switch).at(1));
    expect(biometricSwitch.onChanged, isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
