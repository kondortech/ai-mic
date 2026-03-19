import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/google_sign_in_config.dart';
import 'google_calendar_scopes.dart';

/// Connects Google Calendar via server auth code → Cloud Function stores refresh token.
class GoogleCalendarConnectService {
  GoogleCalendarConnectService._();
  static final GoogleCalendarConnectService instance = GoogleCalendarConnectService._();

  /// Scopes the backend will store for Calendar API use.
  static const List<String> calendarScopes = kGoogleCalendarScopes;

  Future<void> connectCalendar({
    void Function(Object error)? onError,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) {
      final e = Exception('Sign in first');
      onError?.call(e);
      throw e;
    }
    if (kGoogleSignInWebClientId.isEmpty) {
      final e = Exception(
        'Set kGoogleSignInWebClientId in lib/config/google_sign_in_config.dart '
        '(Web client ID from Google Cloud Console).',
      );
      onError?.call(e);
      throw e;
    }

    final googleSignIn = GoogleSignIn(
      scopes: calendarScopes,
      serverClientId: kGoogleSignInWebClientId,
      forceCodeForRefreshToken: true,
    );

    final account = await googleSignIn.signIn();
    if (account == null) return;

    final code = account.serverAuthCode;
    if (code == null || code.isEmpty) {
      final e = Exception(
        'No server auth code. Ensure Web client ID is correct and Calendar API '
        'scope is granted. Try disconnecting the app in Google Account settings and retry.',
      );
      onError?.call(e);
      throw e;
    }

    try {
      await FirebaseFunctions.instance
          .httpsCallable('connectGoogleCalendar')
          .call<Map<String, dynamic>>({'serverAuthCode': code});
    } catch (e) {
      onError?.call(e);
      rethrow;
    }
  }

  Future<void> disconnectCalendar({
    void Function(Object error)? onError,
  }) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('disconnectGoogleCalendar')
          .call();
    } catch (e) {
      onError?.call(e);
      rethrow;
    }
  }
}
