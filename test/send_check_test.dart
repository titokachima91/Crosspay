import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/send_check_provider.dart';

// Test inputs only. Not app data.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

const _estimate = Estimate(
  rate: 2,
  receiveAmountMinor: 100,
  estimatedMinSeconds: 60,
  estimatedMaxSeconds: 120,
  route: RouteType.p2p,
);

const _readyEstimate =
    EstimateState(status: EstimateStatus.ready, estimate: _estimate);

QuoteState _quote(int amount, {Currency send = _a}) => QuoteState(
      sendCurrency: send,
      receiveCurrency: send == _a ? _b : _a,
      sendAmountMinor: amount,
    );

UserProfile _profile({
  KycStatus kyc = KycStatus.verified,
  int limit = 10000,
  int used = 2000,
}) =>
    UserProfile(
      id: 'u',
      phone: '+999712345678',
      displayName: 'Test Person',
      accountType: AccountType.personal,
      kycStatus: kyc,
      limitCurrency: _a,
      dailyLimitMinor: limit,
      dailyUsedMinor: used,
    );

void main() {
  test('a verified person with a ready estimate and enough limit may review', () {
    final check = checkSend(
      quote: _quote(1000),
      estimate: _readyEstimate,
      profile: _profile(),
    );
    expect(check.canReview, true);
    expect(check.problem, isNull);
  });

  test('no review while the estimate is still loading or missing', () {
    expect(
      checkSend(
        quote: _quote(1000),
        estimate: const EstimateState(
          status: EstimateStatus.loading,
          estimate: _estimate,
        ),
        profile: _profile(),
      ).canReview,
      false,
    );
    expect(
      checkSend(
        quote: _quote(0),
        estimate: const EstimateState(),
        profile: _profile(),
      ).canReview,
      false,
    );
  });

  test('a pending person sees the pending message', () {
    final check = checkSend(
      quote: _quote(1000),
      estimate: _readyEstimate,
      profile: _profile(kyc: KycStatus.pending),
    );
    expect(check.canReview, false);
    expect(check.problem, SendProblem.verificationPending);
  });

  test('a rejected or unverified person must finish verification', () {
    for (final status in [KycStatus.rejected, KycStatus.notStarted]) {
      final check = checkSend(
        quote: _quote(1000),
        estimate: _readyEstimate,
        profile: _profile(kyc: status),
      );
      expect(check.problem, SendProblem.verificationRequired);
    }
  });

  test('more than the remaining daily limit is blocked', () {
    final check = checkSend(
      quote: _quote(8001),
      estimate: _readyEstimate,
      profile: _profile(),
    );
    expect(check.canReview, false);
    expect(check.problem, SendProblem.overLimit);

    expect(
      checkSend(
        quote: _quote(8000),
        estimate: _readyEstimate,
        profile: _profile(),
      ).canReview,
      true,
    );
  });

  test('the limit is only compared when it is in the same currency', () {
    final check = checkSend(
      quote: _quote(999999999, send: _b),
      estimate: _readyEstimate,
      profile: _profile(),
    );
    expect(check.problem, isNull);
    expect(check.canReview, true);
  });

  test('without a profile there is no review', () {
    final check = checkSend(
      quote: _quote(1000),
      estimate: _readyEstimate,
      profile: null,
    );
    expect(check.canReview, false);
    expect(check.problem, isNull);
  });
}
