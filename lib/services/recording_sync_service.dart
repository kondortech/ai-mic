import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// One-way sync: upload new recordings to Cloud Storage and Firestore;
/// on local delete, mark the recording as deleted in Firestore (soft delete).
class RecordingSyncService {
  RecordingSyncService._();
  static final RecordingSyncService instance = RecordingSyncService._();

  static const String _recordingsStoragePath = 'recordings';
  static const String _userRecordingsCollection = 'recordings';

  /// Returns the currently signed-in user. Sync only runs when the user is signed in.
  User? get currentUser =>
      Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser;

  /// Uploads the recording file to Storage and creates/overwrites Firestore metadata.
  /// Fire-and-forget: call from UI after local save; errors are silent (or surface via callback).
  Future<void> uploadRecording({
    required String localFilePath,
    required String fileName,
    required String description,
    required String timestamp,
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
      final ref = FirebaseStorage.instance
          .ref()
          .child(_recordingsStoragePath)
          .child(user.uid)
          .child(fileName);

      // Use putData so the upload Future completes reliably (putFile can hang on some platforms).
      await ref.putFile(file, SettableMetadata(contentType: 'audio/mp4'));

      final docId = _docIdFromFileName(fileName);
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(_userRecordingsCollection)
          .doc(docId);

      await docRef.set({
        'fileName': fileName,
        'description': description,
        'timestamp': timestamp,
        'deleted': false,
        'status': 'recording_uploaded',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
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

  /// True if the error indicates the Storage bucket does not exist (never enabled).
  static bool _isStorageBucketNotFound(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('object not found') ||
        s.contains('object_not_found') ||
        s.contains('bucket') && s.contains('not found') ||
        s.contains('404');
  }

  /// Marks the recording as deleted in Firestore. Does not delete the file in Storage.
  Future<void> markRecordingDeleted({
    required String fileName,
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
          .collection(_userRecordingsCollection)
          .doc(_docIdFromFileName(fileName));

      await docRef.set({
        'fileName': fileName,
        'deleted': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      onError?.call(e);
    }
  }

  /// Firestore document IDs cannot contain '.', so we replace with '_'.
  static String _docIdFromFileName(String fileName) =>
      fileName.replaceAll('.', '_');
}
