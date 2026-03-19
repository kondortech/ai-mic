import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/google_sign_in_config.dart';

class GoogleCalendarConnectService {
  GoogleCalendarConnectService._();
  static final GoogleCalendarConnectService instance =
      GoogleCalendarConnectService._();

  static const List<String> _calendarScopes = <String>[
    'https://www.googleapis.com/auth/calendar',
  ];

  Future<void> connectCalendar({void Function(Object error)? onError}) async {
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
      scopes: _calendarScopes,
      serverClientId: kGoogleSignInWebClientId,
      forceCodeForRefreshToken: true,
    );

    final account = await googleSignIn.signIn();
    if (account == null) return;

    final code = account.serverAuthCode;
    if (code == null || code.isEmpty) {
      final e = Exception(
        'No server auth code. Ensure Web client ID is correct and try reconnecting.',
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
