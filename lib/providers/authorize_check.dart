import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/recipient_check_provider.dart';

enum AuthorizeIssue { lockExpired, accountNotFound, nameMismatch }

/// Whether the Authorize button may be used, and why not. The rules:
/// the locked rate must still be running, the account must exist, and the
/// name must match (or be impossible to check automatically, which is allowed
/// but flagged). The server still has the final say.
class AuthorizeCheck {
  const AuthorizeCheck({
    required this.canAuthorize,
    this.issue,
    this.nameUnverified = false,
  });

  final bool canAuthorize;
  final AuthorizeIssue? issue;
  final bool nameUnverified;
}

AuthorizeCheck checkAuthorize({
  required QuoteState quote,
  required RecipientCheckState check,
  required String name,
}) {
  if (quote.status == QuoteStatus.expired) {
    return const AuthorizeCheck(
      canAuthorize: false,
      issue: AuthorizeIssue.lockExpired,
    );
  }

  final current = quote.quote;
  final selected = quote.selectedRoute;
  final option =
      (current != null && selected != null) ? current.forRoute(selected) : null;
  if (quote.status != QuoteStatus.ready ||
      option == null ||
      !option.isAvailable) {
    return const AuthorizeCheck(canAuthorize: false);
  }

  final result =
      check.status == RecipientCheckStatus.ready ? check.check : null;
  if (result == null) return const AuthorizeCheck(canAuthorize: false);

  if (result.accountStatus == AccountStatus.notFound) {
    return const AuthorizeCheck(
      canAuthorize: false,
      issue: AuthorizeIssue.accountNotFound,
    );
  }
  if (name.trim().isEmpty) return const AuthorizeCheck(canAuthorize: false);

  switch (result.nameMatch) {
    case NameMatch.match:
      return const AuthorizeCheck(canAuthorize: true);
    case NameMatch.unavailable:
      return const AuthorizeCheck(canAuthorize: true, nameUnverified: true);
    case NameMatch.mismatch:
      return const AuthorizeCheck(
        canAuthorize: false,
        issue: AuthorizeIssue.nameMismatch,
      );
    case null:
      return const AuthorizeCheck(canAuthorize: false);
  }
}
