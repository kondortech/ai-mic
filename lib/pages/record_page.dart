import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../services/recording_sync_service.dart';

import 'profile_page.dart';

enum PageState { idle, recording, preview }

class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  PageState _state = PageState.idle;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _currentRecordingPath;
  DateTime? _currentRecordingTimestamp;
  final TextEditingController _descriptionController = TextEditingController();
  bool _isPlaying = false;
  static const _uuid = Uuid();

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

    final description = _descriptionController.text.trim();
    final appDir = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${appDir.path}/recordings');
    if (!await recordingsDir.exists()) {
      await recordingsDir.create(recursive: true);
    }

    final id = _uuid.v4();
    final fileName = 'recording_$id.m4a';
    final destPath = '${recordingsDir.path}/$fileName';
    await File(_currentRecordingPath!).copy(destPath);

    final metaPath = '${appDir.path}/recordings_meta.json';
    List<Map<String, String>> list = [];
    final metaFile = File(metaPath);
    if (await metaFile.exists()) {
      final content = await metaFile.readAsString();
      try {
        final decoded = jsonDecode(content) as List<dynamic>;
        list = decoded.map((e) => Map<String, String>.from(e as Map)).toList();
      } catch (_) {}
    }
    list.add({
      'fileName': fileName,
      'description': description,
      'timestamp': _currentRecordingTimestamp!.toIso8601String(),
    });
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(list),
    );

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Recording saved')));
    }

    // One-way sync: upload to Firebase Storage + Firestore metadata
    final timestampIso = _currentRecordingTimestamp!.toIso8601String();
    RecordingSyncService.instance.uploadRecording(
      localFilePath: destPath,
      fileName: fileName,
      description: description,
      timestamp: timestampIso,
      onError: (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
        }
      },
    );

    _discard();
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: isRecording ? _stopRecording : _startRecording,
            iconSize: 120,
            icon: Icon(
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
            isRecording ? 'Tap to stop recording' : 'Tap to record',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
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
                onPressed: _discard,
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(width: 32),
              IconButton.filled(
                onPressed: _submit,
                icon: const Icon(Icons.check),
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
