/// Small date helpers shared by the ledger screens. Times from the server are
/// UTC instants; they are shown in the device's own time zone.
class DateFormatX {
  DateFormatX._();

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "7 Nov 2026"
  static String day(DateTime value) {
    final d = value.toLocal();
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  /// "7 Nov 2026, 14:05"
  static String dayTime(DateTime value) {
    final d = value.toLocal();
    final hour = d.hour.toString().padLeft(2, '0');
    final minute = d.minute.toString().padLeft(2, '0');
    return '${day(d)}, $hour:$minute';
  }

  /// "14:05" — used where the day is already clear from the row above.
  static String time(DateTime value) {
    final d = value.toLocal();
    final hour = d.hour.toString().padLeft(2, '0');
    final minute = d.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// "1h 05m" / "12m" / "45s" — for server-provided durations.
  static String duration(int seconds) {
    if (seconds <= 0) return '0s';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m';
    return '${s}s';
  }
}
