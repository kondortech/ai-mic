import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
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
  String? _transcript;
  bool _loadingTranscript = false;
  String? _transcriptError;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
    if (widget.recording.status == 'transcribed') {
      _loadTranscript();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
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
    final s = widget.recording.status;
    if (s == 'audio') return 'Audio uploaded';
    if (s == 'transcribed') return 'Transcribed';
    return s ?? 'Unknown';
  }

  Color get _statusColor {
    final s = widget.recording.status;
    if (s == 'audio') return Colors.red;
    if (s == 'transcribed') return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          r.displayTitle,
          overflow: TextOverflow.ellipsis,
        ),
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
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
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
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
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
                  color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3),
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
                      r.status == 'transcribed'
                          ? 'No transcription text.'
                          : 'Transcription not ready yet. Refresh the list when it is.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
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
