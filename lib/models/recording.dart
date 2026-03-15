/// Format ISO 8601 timestamp for display (e.g. "2025-03-14 15:30").
String formatTimestamp(String iso) {
  try {
    final dt = DateTime.parse(iso);
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  } catch (_) {
    return iso;
  }
}

class SavedRecording {
  SavedRecording({
    required this.fileName,
    required this.description,
    required this.timestamp,
    this.status,
  });

  final String fileName;
  final String description;
  final String timestamp;
  /// From Firestore: e.g. `recording_uploaded`, `transcribed`.
  final String? status;

  String get displayTitle =>
      description.trim().isEmpty ? formatTimestamp(timestamp) : description;
}
