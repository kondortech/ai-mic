import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// One-way sync: upload new inputs (audio) to Cloud Storage + Firestore.
/// On local delete, mark the input as deleted in Firestore (soft delete).
class RecordingSyncService {
  RecordingSyncService._();
  static final RecordingSyncService instance = RecordingSyncService._();

  /// Returns the currently signed-in user. Sync only runs when the user is signed in.
  User? get currentUser =>
      Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser;

  static String _audioStoragePath({
    required String userId,
    required String noteUuid,
  }) {
    // "<user_id>/inputs/<note_uuid>/raw_audio.mp4"
    return '$userId/inputs/$noteUuid/raw_audio.mp4';
  }

  /// Uploads the input audio file to Storage and creates Firestore metadata.
  /// Fire-and-forget: call from UI after local save; errors are silent (or surface via callback).
  Future<void> uploadNote({
    required String localFilePath,
    required String noteUuid,
    required String title,
    void Function(Object error)? onError,
  }) async {
    final user = currentUser;
    if (user == null) {
      final err = Exception('Not signed in');
      onError?.call(err);
      throw err;
    }

    final file = File(localFilePath);
    if (!await file.exists()) {
      final err = Exception('Local file not found');
      onError?.call(err);
      throw err;
    }

    try {
      final ref = FirebaseStorage.instance.ref().child(
        _audioStoragePath(userId: user.uid, noteUuid: noteUuid),
      );

      // Use putData so the upload Future completes reliably (putFile can hang on some platforms).
      await ref.putFile(file, SettableMetadata(contentType: 'audio/mp4'));

      // users/<user_id>/inputs/<note_uuid>
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('inputs')
          .doc(noteUuid);

      // Set exactly the fields required by your new schema.
      await docRef.set({
        'title': title,
        // If note was created from audio.
        'status':
            'uploaded', // 'uploaded' | 'transcribed' | 'plan_created' | 'plan_executed'
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'deleted': false,
      });
    } catch (e) {
      final message =
          _isStorageBucketNotFound(e)
              ? 'Firebase Storage bucket not found. Enable Storage in Firebase Console: '
                  'Build → Storage → Get started. See docs/STORAGE_SETUP.md for details.'
              : e.toString();
      onError?.call(Exception(message));
      throw Exception(message);
    }
  }

  /// True if the error indicates the Storage bucket does not exist.
  static bool _isStorageBucketNotFound(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('object not found') ||
        s.contains('object_not_found') ||
        s.contains('bucket') && s.contains('not found') ||
        s.contains('404');
  }

  /// Marks the input as deleted in Firestore. Does not delete the file in Storage.
  Future<void> markNoteDeleted({
    required String noteUuid,
    void Function(Object error)? onError,
  }) async {
    final user = currentUser;
    if (user == null) {
      onError?.call(Exception('Not signed in'));
      return;
    }

    try {
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('inputs')
          .doc(noteUuid);

      final snap = await docRef.get();
      if (!snap.exists) {
        // If the input doc doesn't exist yet (e.g. cloud upload partially failed),
        // create it with the required schema shape.
        await docRef.set({
          'title': '',
          'status':
              'uploaded', // 'uploaded' | 'transcribed' | 'plan_created' | 'plan_executed'
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'deleted': true,
        });
      } else {
        await docRef.set({
          'deleted': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      onError?.call(e);
    }
  }
}
