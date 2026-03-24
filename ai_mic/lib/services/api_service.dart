// Typed API service for Firebase Cloud Functions using OpenAPI-generated models
// from package:ai_mic_api.

import 'package:ai_mic_api/api.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Builds the overwrite plan payload. Each action has [tool] and [arguments].
/// [arguments] values are normalized to strings for the backend (CreateNoteArguments
/// or CreateCalendarEventArguments per tool).
Map<String, dynamic> _planPayloadForCallable({
  required List<Map<String, dynamic>> actions,
  required String? emptyReason,
  required DateTime generatedAt,
}) {
  return {
    'actions':
        actions.map((a) {
          final tool = (a['tool'] as String?)?.trim() ?? 'create_note';
          final args = a['arguments'] as Map<String, dynamic>? ?? {};
          return {
            'tool': tool,
            'arguments': args.map((k, v) => MapEntry(k, v?.toString() ?? '')),
          };
        }).toList(),
    'empty_reason': emptyReason,
    'generated_at': generatedAt.toUtc().toIso8601String(),
  };
}

class ApiService {
  ApiService._();
  static final ApiService instance = ApiService._();

  /// Transcribe an audio recording. Fire-and-forget; errors surface via exception.
  Future<void> transcribeRecording(String noteUuid) async {
    _requireAuth();
    final req = TranscribeRecordingRequest(noteUuid: noteUuid);
    await FirebaseFunctions.instance
        .httpsCallable('transcribeRecording')
        .call(req.toJson());
  }

  /// Connect Google Calendar with OAuth server auth code.
  Future<void> connectGoogleCalendar(String serverAuthCode) async {
    _requireAuth();
    final req = ConnectGoogleCalendarRequest(serverAuthCode: serverAuthCode);
    await FirebaseFunctions.instance
        .httpsCallable('connectGoogleCalendar')
        .call(req.toJson());
  }

  /// Disconnect Google Calendar.
  Future<void> disconnectGoogleCalendar() async {
    _requireAuth();
    await FirebaseFunctions.instance
        .httpsCallable('disconnectGoogleCalendar')
        .call(<String, dynamic>{});
  }

  /// Overwrite and save an execution plan for an input.
  /// [actions] each have [tool] ('create_note' | 'create_calendar_event') and
  /// [arguments] (CreateNoteArguments or CreateCalendarEventArguments fields).
  Future<void> overwriteExecutionPlan({
    required String inputUuid,
    required List<Map<String, dynamic>> actions,
    required String? emptyReason,
    required DateTime generatedAt,
  }) async {
    _requireAuth();
    final payload = {
      'inputUuid': inputUuid,
      'plan': _planPayloadForCallable(
        actions: actions,
        emptyReason: emptyReason,
        generatedAt: generatedAt,
      ),
    };
    await FirebaseFunctions.instance
        .httpsCallable('overwriteExecutionPlan')
        .call(payload);
  }

  /// Execute the stored plan for an input.
  Future<ExecuteStoredPlanResponse> executeStoredPlan(String inputUuid) async {
    _requireAuth();
    final req = ExecuteStoredPlanRequest(inputUuid: inputUuid);
    final result = await FirebaseFunctions.instance
        .httpsCallable('executeStoredPlan')
        .call(req.toJson());

    final parsed = ExecuteStoredPlanResponse.fromJson(result.data);
    if (parsed == null) {
      throw Exception('Invalid executeStoredPlan response');
    }
    return parsed;
  }

  void _requireAuth() {
    if (FirebaseAuth.instance.currentUser == null) {
      throw Exception('Not signed in');
    }
  }
}
