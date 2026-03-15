import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'main_shell.dart';
import 'sign_in_page.dart';

/// Shows [SignInPage] when no user is signed in, [MainShell] when signed in.
/// If Firebase is not initialized (e.g. missing config), shows [MainShell] so the app works locally.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (Firebase.apps.isEmpty) {
      return const MainShell();
    }
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user == null) {
          return const SignInPage();
        }
        return const MainShell();
      },
    );
  }
}
