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
      onError?.call(Exception('Not signed in'));
      return;
    }

    final file = File(localFilePath);
    if (!await file.exists()) {
      onError?.call(Exception('Local file not found'));
      return;
    }

    try {
      final ref = FirebaseStorage.instance
          .ref()
          .child(_recordingsStoragePath)
          .child(user.uid)
          .child(fileName);

      await ref.putFile(
        file,
        SettableMetadata(contentType: 'audio/mp4'),
      );

      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(_userRecordingsCollection)
          .doc(_docIdFromFileName(fileName));

      await docRef.set({
        'fileName': fileName,
        'description': description,
        'timestamp': timestamp,
        'deleted': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      onError?.call(e);
    }
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
