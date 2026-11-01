import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/profile_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';

enum SendProblem { verificationPending, verificationRequired, overLimit }

/// Whether the Review button may be used, and why not. These are display
/// checks only: the server enforces the real rules.
class SendCheck {
  const SendCheck({required this.canReview, this.problem});

  final bool canReview;
  final SendProblem? problem;
}

SendCheck checkSend({
  required QuoteState quote,
  required EstimateState estimate,
  required UserProfile? profile,
}) {
  if (profile != null) {
    if (profile.kycStatus == KycStatus.pending) {
      return const SendCheck(
        canReview: false,
        problem: SendProblem.verificationPending,
      );
    }
    if (profile.kycStatus != KycStatus.verified) {
      return const SendCheck(
        canReview: false,
        problem: SendProblem.verificationRequired,
      );
    }

    // The limit is in one currency; compare only when the amounts match.
    if (quote.sendCurrency == profile.limitCurrency &&
        quote.sendAmountMinor > profile.dailyRemainingMinor) {
      return const SendCheck(canReview: false, problem: SendProblem.overLimit);
    }
  }

  final ready = profile != null &&
      quote.canRequestQuote &&
      estimate.status == EstimateStatus.ready &&
      estimate.estimate != null;
  return SendCheck(canReview: ready);
}

final sendCheckProvider = Provider<SendCheck>((ref) {
  return checkSend(
    quote: ref.watch(quoteProvider),
    estimate: ref.watch(estimateProvider),
    profile: ref.watch(profileProvider).profile,
  );
});
