import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

/// Drives the real repositories against a running sandbox facade.
///
/// This is opt-in so the normal suite stays offline and deterministic:
///
///   cd kachi-fintech-sandbox && PORT=8080 npm start
///   cd crosspay_app && LIVE_SANDBOX=1 flutter test test/live_sandbox_test.dart
///
/// LIVE_SANDBOX_KEY must match SANDBOX_API_KEY_CROSSPAY (default:
/// live-sandbox-key). Every run uses a fresh phone number and NIN, so it can
/// be repeated without colliding with earlier KYC verification rows.
void main() {
  final live = Platform.environment['LIVE_SANDBOX'] == '1';

  test(
    'the app repositories speak the live sandbox contract end to end',
    () async {
      final baseUrl = Platform.environment['LIVE_SANDBOX_URL'] ??
          'http://127.0.0.1:8080';
      final apiKey =
          Platform.environment['LIVE_SANDBOX_KEY'] ?? 'live-sandbox-key';

      String? token;
      final dio = buildDio(
        ApiConfig(baseUrl: baseUrl),
        tokenReader: () => token,
      );
      final admin = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          contentType: Headers.jsonContentType,
          headers: {'x-api-key': apiKey},
        ),
      );

      // 1. Reference data the app renders before anyone signs in.
      final config = await ConfigRepository(dio).fetch();
      expect(config.currencies, isNotEmpty);
      expect(config.hubs, isNotEmpty);
      expect(config.payoutRails, isNotEmpty);
      expect(config.currencyByCode('KES'), isNotNull);
      expect(config.currencyByCode('TZS'), isNotNull);
      final tanzania = config.countries.firstWhere((c) => c.code == 'TZ');
      expect(tanzania.dialCode, '255');
      expect(tanzania.nationalNumberLength, 9);

      final snapshot = await RatesRepository(dio).fetch(config);
      expect(snapshot.rates, isNotEmpty);
      expect(
        snapshot.rates.any((rate) => rate.from.code == 'KES' && rate.to.code == 'TZS'),
        isTrue,
      );

      // 2. Sign in with a fresh phone number, then finish KYC.
      final micros = DateTime.now().microsecondsSinceEpoch;
      final phone = '+2557${(micros % 100000000).toString().padLeft(8, '0')}';
      final nin = '${micros.toString().padLeft(16, '0')}1234';
      expect(nin, hasLength(20));

      final challenge = await AuthRepository(dio).requestOtp(phone);
      expect(challenge.codeLength, 6);
      expect(challenge.expiresInSeconds, greaterThan(0));

      final state = await admin.get<dynamic>('/api/v1/sandbox/state');
      final otps = (state.data as Map)['otps'] as List;
      final otp = otps.cast<Map>().firstWhere(
            (entry) => entry['phone'] == phone && entry['code'] != null,
            orElse: () => throw StateError('No sandbox OTP for $phone'),
          );

      final session = await AuthRepository(dio).verifyOtp(
        phone: phone,
        code: otp['code'] as String,
      );
      expect(session.accessToken, isNotEmpty);
      expect(session.profileComplete, isFalse);
      token = session.accessToken;

      await expectLater(
        ProfileRepository(dio).fetch(config),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'PROFILE_INCOMPLETE',
          ),
        ),
      );

      final kycStatus = await AuthRepository(dio).submitKyc(
        accountType: AccountType.personal,
        legalName: 'Amina Hassan',
        idNumber: nin,
      );
      expect(kycStatus, KycStatus.verified);

      final profile = await ProfileRepository(dio).fetch(config);
      expect(profile.phone, phone);
      expect(profile.displayName, 'Amina Hassan');
      expect(profile.kycStatus, KycStatus.verified);
      expect(profile.limitCurrency.code, 'TZS');
      expect(profile.dailyLimitMinor, greaterThan(0));

      final depth = await RatesRepository(dio).fetchDepth(config);
      expect(depth, isNotEmpty);
      expect(depth.every((corridor) => corridor.queueDepth >= 0), isTrue);

      // 3. Save a recipient and ask the destination network about it.
      final beneficiaries = BeneficiaryRepository(dio);
      final rail =
          config.payoutRails.firstWhere((item) => item.id == 'PSP_MPESA_TZ');
      expect(rail.kind, PayoutKind.mobileMoney);

      final check = await beneficiaries.check(
        rail: rail,
        account: '+255754123456',
        name: 'Juma Mwangi',
      );
      expect(check.accountStatus, AccountStatus.found);
      expect(check.nameMatch, NameMatch.match);

      final saved = await beneficiaries.add(
        config: config,
        rail: rail,
        name: 'Juma Mwangi',
        accountOrPhone: '+255754123456',
      );
      expect(saved.rail.id, rail.id);
      expect(saved.kycVerified, isTrue);
      expect((await beneficiaries.list(config)).any((item) => item.id == saved.id), isTrue);

      // 4. Price, start, collect and pay out a real trade.
      final trades = TradeRepository(dio);
      final send = config.currencyByCode('KES')!;
      final receive = config.currencyByCode('TZS')!;

      final estimate = await trades.estimate(
        sendCurrency: send,
        receiveCurrency: receive,
        sendAmountMinor: 100000,
      );
      expect(estimate.rate, greaterThan(0));
      expect(estimate.receiveAmountMinor, greaterThan(0));

      final quote = await trades.quote(
        sendCurrency: send,
        receiveCurrency: receive,
        sendAmountMinor: 100000,
      );
      final p2p = quote.routes.firstWhere((item) => item.route == RouteType.p2p);
      expect(p2p.isAvailable, isTrue);
      expect(p2p.totalDebitMinor, greaterThan(quote.sendAmountMinor));
      expect(p2p.payoutMinor, greaterThan(0));

      final recipient = RecipientDetails(
        rail: rail,
        account: '+255754123456',
        name: 'Juma Mwangi',
        reference: 'live contract test',
        check: check,
      );
      final initiated = await trades.initiate(
        quote: quote,
        route: RouteType.p2p,
        recipient: recipient,
        idempotencyKey: 'live-${quote.id}',
        config: config,
      );
      expect(initiated.trade.status, TradeStatus.pendingDeposit);
      expect(initiated.collection.pushSent, isTrue);
      expect(initiated.collection.amountMinor, p2p.totalDebitMinor);
      expect(initiated.collection.currency.code, 'KES');

      final collected = await admin.post<dynamic>(
        '/api/v1/sandbox/trades/${initiated.trade.id}/collect',
        data: <String, dynamic>{},
      );
      expect(collected.statusCode, 200);
      expect(collected.data['trade']['status'], 'disbursing');

      final paid = await admin.post<dynamic>(
        '/api/v1/sandbox/trades/${initiated.trade.id}/payout',
        data: <String, dynamic>{},
      );
      expect(paid.statusCode, 200);
      expect(paid.data['trade']['status'], 'completed');

      final finished = await trades.fetchTrade(initiated.trade.id, config);
      expect(finished.status, TradeStatus.completed);
      expect(finished.reference, initiated.trade.reference);
      expect(finished.sendAmountMinor, 100000);
      expect(finished.receiveAmountMinor, p2p.payoutMinor);

      final timeline = await trades.fetchTimeline(finished.id);
      expect(
        timeline.map((event) => event.status),
        containsAllInOrder([
          TradeStatus.pendingDeposit,
          TradeStatus.escrowed,
          TradeStatus.disbursing,
          TradeStatus.completed,
        ]),
      );

      final list = await trades.getTrades(config);
      expect(list.any((trade) => trade.id == finished.id), isTrue);

      // 5. Invoice links the app opens or shares.
      final invoice = await trades.getInvoice(finished.id, config: config);
      expect(invoice.tradeId, finished.id);
      expect(invoice.amount, p2p.totalDebitMinor);
      expect(invoice.currency, 'KES');
      expect(invoice.qrCodeUrl, endsWith('/qr.png'));
      expect(invoice.shareUrl, contains('/pay/'));
    },
    skip: live
        ? false
        : 'Set LIVE_SANDBOX=1 and start the sandbox facade on :8080',
  );
}
