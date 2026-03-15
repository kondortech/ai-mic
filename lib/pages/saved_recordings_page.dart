import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';
import '../services/recording_sync_service.dart';

import 'profile_page.dart';

class SavedRecordingsPage extends StatefulWidget {
  const SavedRecordingsPage({super.key});

  @override
  SavedRecordingsPageState createState() => SavedRecordingsPageState();
}

class SavedRecordingsPageState extends State<SavedRecordingsPage> {
  List<SavedRecording> _recordings = [];
  final AudioPlayer _player = AudioPlayer();
  String? _playingFileName;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecordings();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingFileName = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    final appDir = await getApplicationDocumentsDirectory();
    final metaPath = '${appDir.path}/recordings_meta.json';
    final file = File(metaPath);
    if (!await file.exists()) {
      if (mounted) {
        setState(() {
          _recordings = [];
          _loading = false;
        });
      }
      return;
    }
    try {
      final content = await file.readAsString();
      final decoded = jsonDecode(content) as List<dynamic>;
      final list =
          decoded.map((e) {
            final map = Map<String, String>.from(e as Map);
            return SavedRecording(
              fileName: map['fileName'] ?? '',
              description: map['description'] ?? '',
              timestamp: map['timestamp'] ?? '',
            );
          }).toList();
      if (mounted) {
        setState(() {
          _recordings = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _recordings = [];
          _loading = false;
        });
      }
    }
  }

  void refresh() => _loadRecordings();

  Future<String> _pathFor(SavedRecording r) async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/recordings/${r.fileName}';
  }

  Future<void> _togglePlay(SavedRecording r) async {
    if (_playingFileName == r.fileName) {
      await _player.stop();
      if (mounted) setState(() => _playingFileName = null);
      return;
    }
    final path = await _pathFor(r);
    if (!File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording file not found')),
        );
      }
      return;
    }
    await _player.stop();
    await _player.play(DeviceFileSource(path));
    if (mounted) setState(() => _playingFileName = r.fileName);
  }

  Future<void> _deleteRecording(SavedRecording r) async {
    if (_playingFileName == r.fileName) {
      await _player.stop();
      if (mounted) setState(() => _playingFileName = null);
    }
    final appDir = await getApplicationDocumentsDirectory();
    final filePath = '${appDir.path}/recordings/${r.fileName}';
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    final metaPath = '${appDir.path}/recordings_meta.json';
    final metaFile = File(metaPath);
    if (!await metaFile.exists()) {
      if (mounted) _loadRecordings();
      return;
    }
    try {
      final content = await metaFile.readAsString();
      final decoded = jsonDecode(content) as List<dynamic>;
      final list =
          decoded
              .map((e) => Map<String, String>.from(e as Map))
              .where((e) => e['fileName'] != r.fileName)
              .toList();
      await metaFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(list),
      );
      if (mounted) {
        setState(() {
          _recordings =
              _recordings.where((x) => x.fileName != r.fileName).toList();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recording deleted')));
      }
      // One-way sync: mark as deleted in Firestore (soft delete; file stays in Storage)
      RecordingSyncService.instance.markRecordingDeleted(
        fileName: r.fileName,
        onError: (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Sync delete failed: $e')),
            );
          }
        },
      );
    } catch (_) {
      if (mounted) {
        _loadRecordings();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Recordings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ProfilePage(),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child:
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _recordings.isEmpty
                ? const Center(child: Text('No recordings yet'))
                : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _recordings.length,
                  itemBuilder: (context, index) {
                    final r = _recordings[index];
                    final isPlaying = _playingFileName == r.fileName;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => _togglePlay(r),
                              icon: Icon(
                                isPlaying ? Icons.stop : Icons.play_arrow,
                              ),
                              iconSize: 36,
                            ),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      child: Text(
                                        r.displayTitle,
                                        style:
                                            Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      formatTimestamp(r.timestamp),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => _deleteRecording(r),
                              icon: const Icon(Icons.delete),
                              iconSize: 28,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      ),
    );
  }
}
