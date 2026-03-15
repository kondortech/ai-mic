import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Sign out from Firebase and Google (if used). AuthGate will show SignInPage.
Future<void> signOut() async {
  await FirebaseAuth.instance.signOut();
  try {
    await GoogleSignIn().signOut();
  } catch (_) {}
}
