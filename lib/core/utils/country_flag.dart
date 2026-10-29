/// Turns a two-letter country code (e.g. from the server) into a flag emoji.
/// Returns an empty string for anything that is not two letters A to Z.
String countryFlag(String countryCode) {
  final code = countryCode.trim().toUpperCase();
  if (code.length != 2) return '';

  final first = code.codeUnitAt(0);
  final second = code.codeUnitAt(1);
  const a = 65; // 'A'
  const z = 90; // 'Z'
  if (first < a || first > z || second < a || second > z) return '';

  const regionalIndicatorA = 0x1F1E6;
  return String.fromCharCodes([
    regionalIndicatorA + (first - a),
    regionalIndicatorA + (second - a),
  ]);
}
