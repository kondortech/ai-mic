// Typed API service for Firebase Cloud Functions using OpenAPI-generated models
// from package:ai_mic_api.

import 'package:ai_mic_api/api.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// JSON-safe payload for [HttpsCallable.call]. OpenAPI `dart` generator's
/// [OverwriteExecutionPlanRequest.toJson] embeds nested objects instead of maps.
Map<String, dynamic> _overwriteExecutionPlanRequestForCallable(
  OverwriteExecutionPlanRequest req,
) {
  return {
    'inputUuid': req.inputUuid,
    'plan': _executionPlanForCallable(req.plan),
  };
}

Map<String, dynamic> _executionPlanForCallable(ExecutionPlan plan) {
  return {
    'actions': plan.actions.map((a) => a.toJson()).toList(),
    'empty_reason': plan.emptyReason,
    'generated_at': plan.generatedAt.toUtc().toIso8601String(),
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
  Future<void> overwriteExecutionPlan({
    required String inputUuid,
    required ExecutionPlan plan,
  }) async {
    _requireAuth();
    final req = OverwriteExecutionPlanRequest(inputUuid: inputUuid, plan: plan);
    await FirebaseFunctions.instance
        .httpsCallable('overwriteExecutionPlan')
        .call(_overwriteExecutionPlanRequestForCallable(req));
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
