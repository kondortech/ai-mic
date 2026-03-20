// Typed API service for Firebase Cloud Functions.
// Uses generated types internally. Exposes only domain types (from api_models.dart)
// to the rest of the app - no OpenAPI-generated types leak outside this service.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_models.dart';

// Generated types - used only within this file
import 'package:ai_mic_api/api.dart';

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
  Future<void> overwriteExecutionPlan({
    required String inputUuid,
    required ExecutionPlanInput plan,
  }) async {
    _requireAuth();
    final actionsJson =
        plan.actions
            .map(
              (a) => <String, dynamic>{
                'tool': a.tool,
                'arguments': a.arguments,
              },
            )
            .toList();
    final planJson = <String, dynamic>{
      'actions': actionsJson,
      'empty_reason': plan.emptyReason,
      'generated_at': plan.generatedAt,
    };
    final reqMap = <String, dynamic>{'inputUuid': inputUuid, 'plan': planJson};
    await FirebaseFunctions.instance
        .httpsCallable('overwriteExecutionPlan')
        .call(reqMap);
  }

  /// Execute the stored plan for an input.
  Future<ExecuteStoredPlanResult> executeStoredPlan(String inputUuid) async {
    _requireAuth();
    final req = ExecuteStoredPlanRequest(inputUuid: inputUuid);
    final result = await FirebaseFunctions.instance
        .httpsCallable('executeStoredPlan')
        .call(req.toJson());

    final data = result.data;
    if (data is! Map) {
      return const ExecuteStoredPlanResult(
        executed: false,
        reason: 'Invalid response',
      );
    }

    final map = Map<String, dynamic>.from(data);
    final executed = map['executed'] == true;
    final reason = map['reason']?.toString();

    return ExecuteStoredPlanResult(executed: executed, reason: reason);
  }

  void _requireAuth() {
    if (FirebaseAuth.instance.currentUser == null) {
      throw Exception('Not signed in');
    }
  }
}
