import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';

/// Detail page for a single recording: name, timestamp, play/stop, status, transcription.
class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key, required this.recording});

  final SavedRecording recording;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  String? _recordStatus;
  String? _transcript;
  bool _loadingTranscript = false;
  String? _transcriptError;

  Timer? _statusPollingTimer;
  int _statusPollingAttempts = 0;
  static const Duration _statusPollingInterval = Duration(seconds: 3);
  static const int _maxStatusPollingAttempts = 200; // ~10 minutes

  @override
  void initState() {
    super.initState();
    _recordStatus = widget.recording.status;
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });

    if (_recordStatus == 'transcribed') {
      _loadTranscript();
    } else {
      _startStatusPolling();
    }
  }

  @override
  void dispose() {
    _statusPollingTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _startStatusPolling() {
    // Polling is only relevant while we are waiting for the status to become 'transcribed'.
    _statusPollingTimer?.cancel();
    _statusPollingAttempts = 0;
    _statusPollingTimer = Timer.periodic(_statusPollingInterval, (_) async {
      if (!mounted) return;
      if (_statusPollingAttempts >= _maxStatusPollingAttempts) {
        _statusPollingTimer?.cancel();
        return;
      }

      _statusPollingAttempts++;
      await _pollStatusOnce();
    });
  }

  Future<void> _pollStatusOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final snap =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('notes')
              .doc(widget.recording.noteUuid)
              .get();

      if (!mounted) return;

      final nextStatus = snap.data()?['status'] as String?;
      if (nextStatus == null) return;

      if (nextStatus != _recordStatus) {
        setState(() => _recordStatus = nextStatus);
      }

      if (nextStatus == 'transcribed') {
        _statusPollingTimer?.cancel();
        _statusPollingTimer = null;
        _loadTranscript();
      }
    } catch (_) {
      // Transient network issues shouldn't break the page; keep polling.
    }
  }

  Future<void> _loadTranscript() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() {
      _loadingTranscript = true;
      _transcriptError = null;
    });
    try {
      final transcriptPath =
          '${user.uid}/notes/${widget.recording.noteUuid}/raw_text.txt';
      final ref = FirebaseStorage.instance.ref().child(transcriptPath);
      final data = await ref.getData();
      if (data != null && mounted) {
        setState(() {
          _transcript = utf8.decode(data);
          _loadingTranscript = false;
          _transcriptError = null;
        });
      } else if (mounted) {
        setState(() {
          _transcript = null;
          _loadingTranscript = false;
          _transcriptError = 'Transcript not found';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _transcript = null;
          _loadingTranscript = false;
          _transcriptError = e.toString();
        });
      }
    }
  }

  Future<String> _localPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/recordings/${widget.recording.localFileName}';
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    final path = await _localPath();
    if (!File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording file not found')),
        );
      }
      return;
    }
    await _player.play(DeviceFileSource(path));
    if (mounted) setState(() => _isPlaying = true);
  }

  String get _statusLabel {
    final s = _recordStatus;
    if (s == 'audio') return 'Audio uploaded';
    if (s == 'transcribed') return 'Transcribed';
    return s ?? 'Unknown';
  }

  Color get _statusColor {
    final s = _recordStatus;
    if (s == 'audio') return Colors.red;
    if (s == 'transcribed') return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    return Scaffold(
      appBar: AppBar(
        title: Text(r.displayTitle, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                r.displayTitle,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                formatTimestamp(r.timestamp),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Center(
                child: IconButton.filled(
                  onPressed: _togglePlay,
                  iconSize: 56,
                  icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                  style: IconButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    foregroundColor:
                        Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _statusLabel,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _statusColor,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Text(
                'Transcription',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_loadingTranscript)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_transcriptError != null)
                Card(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.3),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _transcriptError!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                )
              else if (_transcript != null && _transcript!.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      _transcript!,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _recordStatus == 'transcribed'
                          ? 'No transcription text.'
                          : 'Transcription not ready yet. Polling for completion...',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
