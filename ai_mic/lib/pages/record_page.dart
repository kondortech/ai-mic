import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../services/api_service.dart';
import '../services/recording_sync_service.dart';

import 'profile_page.dart';

enum PageState { idle, recording, uploading }

class RecordPage extends StatefulWidget {
  const RecordPage({super.key, this.onRecordingSavedToCloud});

  /// Called after a recording is successfully saved to the cloud. Passes the noteUuid.
  final void Function(String noteUuid)? onRecordingSavedToCloud;

  @override
  State<RecordPage> createState() => RecordPageState();
}

class RecordPageState extends State<RecordPage> {
  PageState _state = PageState.idle;
  final AudioRecorder _recorder = AudioRecorder();
  bool _isSubmitting = false;
  static const _uuid = Uuid();

  @override
  void dispose() {
    _recorder.dispose();
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
    if (_isSubmitting) return;
    try {
      final path = await _recorder.stop();
      if (path == null || !mounted) return;

      setState(() {
        _state = PageState.uploading;
        _isSubmitting = true;
      });

      final noteUuid = _uuid.v4();
      final title = '';

      try {
        await RecordingSyncService.instance.uploadNote(
          localFilePath: path,
          noteUuid: noteUuid,
          title: title,
          onError: (e) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
            }
          },
        );

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Recording saved')));
          widget.onRecordingSavedToCloud?.call(noteUuid);
        }
        unawaited(
          ApiService.instance.transcribeRecording(noteUuid).catchError((_) {}),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
        }
      } finally {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _state = PageState.idle;
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to stop recording: $e')));
        setState(() => _state = PageState.idle);
      }
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
      body: SafeArea(child: _buildMain()),
    );
  }

  Widget _buildMain() {
    final isRecording = _state == PageState.recording;
    final isUploading = _state == PageState.uploading;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed:
                    isUploading
                        ? null
                        : (isRecording ? _stopRecording : _startRecording),
                iconSize: 120,
                icon:
                    isUploading
                        ? const SizedBox(
                          width: 80,
                          height: 80,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                        : Icon(
                          isRecording ? Icons.stop_circle : Icons.mic,
                          color:
                              isRecording
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
                isUploading
                    ? 'Saving...'
                    : isRecording
                    ? 'Tap to stop recording'
                    : 'Tap to record',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
