/// Formats a countdown as mm:ss. Partial seconds round UP, so a fresh
/// 30-second timer reads 00:30 and never 00:29.
String formatClock(Duration duration) {
  if (duration <= Duration.zero) return '00:00';
  final totalSeconds = (duration.inMilliseconds + 999) ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
