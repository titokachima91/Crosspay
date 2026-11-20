/// Why the person is entering the phone flow.
///
/// The backend has one phone = one account, so both modes share the same OTP
/// path. The mode only changes copy and the post-verification message.
enum AuthEntryMode {
  signIn,
  createAccount;

  static AuthEntryMode fromArguments(Object? arguments) {
    if (arguments is Map && arguments['mode'] == createAccount.name) {
      return createAccount;
    }
    return signIn;
  }

  String get titleKey =>
      this == createAccount ? 'phone.title_create' : 'phone.title_signin';

  String get subtitleKey =>
      this == createAccount ? 'phone.subtitle_create' : 'phone.subtitle_signin';
}
