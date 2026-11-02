/// Display formatting, kept deliberately identical to the SwiftUI app's.
class Formatting {
  const Formatting._();

  /// Mirrors `MediaTime.description` in VoxScriptaCore: `h:mm:ss.mmm`, or
  /// `m:ss.mmm` under an hour.
  ///
  /// Copied rather than improved on. Milliseconds in a library row are
  /// arguably noise — but the SwiftUI app shows them, and two interfaces
  /// formatting the same number two ways is exactly the drift the parity
  /// contract exists to prevent. If it should change it should change in
  /// VoxScriptaCore, and then here.
  static String duration(Duration value) {
    final negative = value.isNegative;
    final total = value.abs();
    final milliseconds = total.inMilliseconds % 1000;
    final seconds = total.inSeconds % 60;
    final minutes = total.inMinutes % 60;
    final hours = total.inHours;
    final sign = negative ? '-' : '';
    final ms = milliseconds.toString().padLeft(3, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$sign$hours:${minutes.toString().padLeft(2, '0')}:$ss.$ms';
    }
    return '$sign$minutes:$ss.$ms';
  }

  /// A short, plain description of when something was last touched.
  ///
  /// Interface-only — nothing downstream reads it — so it is written for a
  /// library list rather than for precision.
  static String relativeDate(DateTime when, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final difference = reference.difference(when);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    }
    if (difference.inDays < 7) {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    }
    final month = when.month.toString().padLeft(2, '0');
    final day = when.day.toString().padLeft(2, '0');
    return '${when.year}-$month-$day';
  }
}
