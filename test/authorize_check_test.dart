import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/authorize_check.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/recipient_check_provider.dart';

// Test inputs only. Not app data.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'YY', decimals: 2);

Quote _quote() => Quote(
      id: 'q1',
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
      rate: 2,
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      routes: const [
        RouteQuote(
          route: RouteType.p2p,
          feeBps: 0,
          feeMinor: 0,
          payoutMinor: 0,
          totalDebitMinor: 0,
          estimatedMinSeconds: 0,
          estimatedMaxSeconds: 0,
          isRecommended: true,
          isAvailable: true,
        ),
      ],
    );

QuoteState _ready() => QuoteState(
      quote: _quote(),
      selectedRoute: RouteType.p2p,
      status: QuoteStatus.ready,
    );

RecipientCheckState _checked(AccountStatus account, NameMatch? match) =>
    RecipientCheckState(
      status: RecipientCheckStatus.ready,
      check: RecipientCheck(
        accountStatus: account,
        networkName: 'Test Network',
        nameMatch: match,
      ),
    );

void main() {
  test('a found account with a matching name may be authorized', () {
    final result = checkAuthorize(
      quote: _ready(),
      check: _checked(AccountStatus.found, NameMatch.match),
      name: 'Test Person',
    );
    expect(result.canAuthorize, true);
    expect(result.nameUnverified, false);
    expect(result.issue, isNull);
  });

  test('a name that cannot be checked is allowed but flagged', () {
    final result = checkAuthorize(
      quote: _ready(),
      check: _checked(AccountStatus.found, NameMatch.unavailable),
      name: 'Test Person',
    );
    expect(result.canAuthorize, true);
    expect(result.nameUnverified, true);
  });

  test('a mismatching name is blocked', () {
    final result = checkAuthorize(
      quote: _ready(),
      check: _checked(AccountStatus.found, NameMatch.mismatch),
      name: 'Test Person',
    );
    expect(result.canAuthorize, false);
    expect(result.issue, AuthorizeIssue.nameMismatch);
  });

  test('an account that is not found is blocked', () {
    final result = checkAuthorize(
      quote: _ready(),
      check: _checked(AccountStatus.notFound, null),
      name: 'Test Person',
    );
    expect(result.canAuthorize, false);
    expect(result.issue, AuthorizeIssue.accountNotFound);
  });

  test('no name, no answer yet, or no name check yet means no authorization', () {
    expect(
      checkAuthorize(
        quote: _ready(),
        check: _checked(AccountStatus.found, NameMatch.match),
        name: '  ',
      ).canAuthorize,
      false,
    );
    expect(
      checkAuthorize(
        quote: _ready(),
        check: const RecipientCheckState(status: RecipientCheckStatus.loading),
        name: 'Test Person',
      ).canAuthorize,
      false,
    );
    expect(
      checkAuthorize(
        quote: _ready(),
        check: _checked(AccountStatus.found, null),
        name: 'Test Person',
      ).canAuthorize,
      false,
    );
  });

  test('an ended rate lock blocks authorization', () {
    final result = checkAuthorize(
      quote: QuoteState(
        quote: _quote(),
        selectedRoute: RouteType.p2p,
        status: QuoteStatus.expired,
      ),
      check: _checked(AccountStatus.found, NameMatch.match),
      name: 'Test Person',
    );
    expect(result.canAuthorize, false);
    expect(result.issue, AuthorizeIssue.lockExpired);
  });

  test('without a chosen route there is nothing to authorize', () {
    final result = checkAuthorize(
      quote: QuoteState(quote: _quote(), status: QuoteStatus.ready),
      check: _checked(AccountStatus.found, NameMatch.match),
      name: 'Test Person',
    );
    expect(result.canAuthorize, false);
  });
}
