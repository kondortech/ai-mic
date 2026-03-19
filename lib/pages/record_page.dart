import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';
import '../services/recording_sync_service.dart';

import 'profile_page.dart';
import 'recording_page.dart';

enum PageState { idle, recording, preview }

class RecordPage extends StatefulWidget {
  const RecordPage({super.key, this.onRecordingSavedToCloud});

  /// Called after a recording is successfully saved to the cloud. Use to e.g. switch to saved list.
  final VoidCallback? onRecordingSavedToCloud;

  @override
  State<RecordPage> createState() => RecordPageState();
}

class RecordPageState extends State<RecordPage> {
  PageState _state = PageState.idle;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _currentRecordingPath;
  DateTime? _currentRecordingTimestamp;
  final TextEditingController _descriptionController = TextEditingController();
  bool _isPlaying = false;
  bool _isSubmitting = false;
  static const _uuid = Uuid();

  List<SavedRecording> _recentNotes = const [];
  bool _loadingRecentNotes = false;

  @override
  void initState() {
    super.initState();
    _loadRecentNotes();
  }

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> _startRecording() async {
    final hasPermission = await _ensurePermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required')),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (mounted) setState(() => _state = PageState.recording);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _recorder.stop();
      final timestamp = DateTime.now();
      if (mounted) {
        setState(() {
          _state = PageState.preview;
          _currentRecordingPath = path;
          _currentRecordingTimestamp = timestamp;
          _descriptionController.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to stop recording: $e')));
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (_currentRecordingPath == null) return;

    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    await _player.play(DeviceFileSource(_currentRecordingPath!));
    if (mounted) setState(() => _isPlaying = true);
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  void _discard() {
    _player.stop();
    final pathToDelete = _currentRecordingPath;
    setState(() {
      _state = PageState.idle;
      _currentRecordingPath = null;
      _currentRecordingTimestamp = null;
      _descriptionController.clear();
      _isPlaying = false;
    });
    if (pathToDelete != null) {
      try {
        final file = File(pathToDelete);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _submit() async {
    if (_currentRecordingPath == null || _currentRecordingTimestamp == null) {
      return;
    }
    if (_isSubmitting) return;

    final description = _descriptionController.text.trim();
    final timestampIso = _currentRecordingTimestamp!.toIso8601String();
    final noteUuid = _uuid.v4();
    final localFileName = 'raw_audio_$noteUuid.m4a';

    if (mounted) setState(() => _isSubmitting = true);

    try {
      // 1. Save to local storage (app documents directory + metadata)
      String destPath;
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final recordingsDir = Directory('${appDir.path}/recordings');
        if (!await recordingsDir.exists()) {
          await recordingsDir.create(recursive: true);
        }
        destPath = '${recordingsDir.path}/$localFileName';
        await File(_currentRecordingPath!).copy(destPath);

        final metaPath = '${appDir.path}/recordings_meta.json';
        List<Map<String, String>> list = [];
        final metaFile = File(metaPath);
        if (await metaFile.exists()) {
          final content = await metaFile.readAsString();
          try {
            final decoded = jsonDecode(content) as List<dynamic>;
            list =
                decoded.map((e) => Map<String, String>.from(e as Map)).toList();
          } catch (_) {}
        }
        list.add({
          'noteUuid': noteUuid,
          'localFileName': localFileName,
          'title': description,
          'timestamp': timestampIso,
        });
        await metaFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(list),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to save locally: $e')));
        }
        return;
      }

      // 2. Upload to Firebase Storage + Firestore (await so we know if it succeeded)
      try {
        await RecordingSyncService.instance.uploadNote(
          localFilePath: destPath,
          noteUuid: noteUuid,
          title: description,
          onError: (e) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
            }
          },
        );

        // Refresh the inline "Recent notes" flow on the home page.
        await _loadRecentNotes();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Recording saved and synced to cloud'),
            ),
          );
        }
        // Trigger transcription in the background (fire-and-forget)
        unawaited(
          FirebaseFunctions.instance
              .httpsCallable('transcribeRecording')
              .call({'noteUuid': noteUuid})
              .then((_) {}, onError: (_, __) {}),
        );
        if (mounted) widget.onRecordingSavedToCloud?.call();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved locally. Cloud sync failed: $e')),
          );
        }
      }

      if (mounted) _discard();
    } finally {
      _isSubmitting = false;
      if (mounted) setState(() {});
    }
  }

  /// Exposed for the app shell to trigger a reload if needed.
  Future<void> refreshRecentNotes() => _loadRecentNotes();

  Future<void> _loadRecentNotes() async {
    if (!mounted) return;
    final user = FirebaseAuth.instance.currentUser;

    setState(() => _loadingRecentNotes = true);
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final metaPath = '${appDir.path}/recordings_meta.json';
      final file = File(metaPath);

      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _recentNotes = const [];
          _loadingRecentNotes = false;
        });
        return;
      }

      final content = await file.readAsString();
      final decoded = jsonDecode(content) as List<dynamic>;

      final parsed = <SavedRecording>[];
      for (final e in decoded) {
        final map = Map<String, dynamic>.from(e as Map);
        final noteUuid = map['noteUuid'] as String?;
        final localFileName = map['localFileName'] as String?;
        final title = map['title'] as String? ?? '';
        final timestamp = map['timestamp'] as String? ?? '';
        if (noteUuid == null || noteUuid.isEmpty) continue;
        if (localFileName == null || localFileName.isEmpty) continue;
        parsed.add(
          SavedRecording(
            noteUuid: noteUuid,
            localFileName: localFileName,
            title: title,
            timestamp: timestamp,
          ),
        );
      }

      parsed.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final limited = parsed.take(3).toList();

      final statusByNoteUuid = <String, String>{};
      if (user != null && limited.isNotEmpty) {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('notes')
            .get();
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final status = data['status'] as String?;
          final deleted = data['deleted'] as bool? ?? false;
          if (status != null && !deleted) {
            statusByNoteUuid[doc.id] = status;
          }
        }
      }

      final withStatus = limited.map((r) {
        return SavedRecording(
          noteUuid: r.noteUuid,
          localFileName: r.localFileName,
          title: r.title,
          timestamp: r.timestamp,
          status: statusByNoteUuid[r.noteUuid],
        );
      }).toList();

      if (!mounted) return;
      setState(() {
        _recentNotes = withStatus;
        _loadingRecentNotes = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recentNotes = const [];
        _loadingRecentNotes = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Mic'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _state == PageState.preview ? _buildPreview() : _buildMain(),
      ),
    );
  }

  Widget _buildMain() {
    final isRecording = _state == PageState.recording;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: isRecording ? _stopRecording : _startRecording,
                iconSize: 120,
                icon: Icon(
                  isRecording ? Icons.stop_circle : Icons.mic,
                  color: isRecording
                      ? Colors.red
                      : Theme.of(context).colorScheme.primary,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: (isRecording
                          ? Colors.red
                          : Theme.of(context).colorScheme.primaryContainer)
                      .withValues(alpha: 0.3),
                  padding: const EdgeInsets.all(24),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isRecording ? 'Tap to stop recording' : 'Tap to record',
                style: Theme.of(context).textTheme.titleMedium,
              ),

              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Recent notes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              _buildRecentNotesPreview(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentNotesPreview() {
    if (_loadingRecentNotes) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_recentNotes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('No notes yet'),
      );
    }

    return SizedBox(
      height: 210,
      child: ListView.builder(
        itemCount: _recentNotes.length,
        itemBuilder: (context, index) {
          final r = _recentNotes[index];
          final status = r.status;
          final statusColor = status == 'audio'
              ? Colors.red
              : status == 'transcribed'
                  ? Colors.orange
                  : null;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: statusColor == null
                ? null
                : RoundedRectangleBorder(
                    side: BorderSide(color: statusColor, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RecordingPage(recording: r),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: statusColor ?? Theme.of(context).dividerColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            formatTimestamp(r.timestamp),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.6),
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      status == 'transcribed'
                          ? Icons.text_fields
                          : Icons.mic,
                      size: 18,
                      color: statusColor ?? Theme.of(context).iconTheme.color,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreview() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _togglePlayback,
                    icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                    iconSize: 40,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        hintText: 'Describe your recording...',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filled(
                onPressed: _isSubmitting ? null : _discard,
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(width: 32),
              IconButton.filled(
                onPressed: _isSubmitting ? null : _submit,
                icon:
                    _isSubmitting
                        ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.check),
                style: IconButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
