import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';
import '../services/recording_sync_service.dart';

import 'profile_page.dart';
import 'recording_page.dart';

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
      final statusByNoteUuid = await _fetchStatusByNoteUuid();
      final list = <SavedRecording>[];
      for (final e in decoded) {
        final map = Map<String, String>.from(e as Map);
        final noteUuid = map['noteUuid'];
        final localFileName = map['localFileName'];
        final title = map['title'] ?? '';
        final timestamp = map['timestamp'] ?? '';
        if (noteUuid == null || noteUuid.isEmpty) continue;
        if (localFileName == null || localFileName.isEmpty) continue;
        list.add(
          SavedRecording(
            noteUuid: noteUuid,
            localFileName: localFileName,
            title: title,
            timestamp: timestamp,
            status: statusByNoteUuid[noteUuid],
          ),
        );
      }
      list.sort((a, b) => (b.timestamp).compareTo(a.timestamp));
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

  /// Fetches Firestore status for each note. Returns map noteUuid -> status.
  Future<Map<String, String>> _fetchStatusByNoteUuid() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {};
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('notes')
          .get();
      final map = <String, String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status = data['status'] as String?;
        final deleted = data['deleted'] as bool? ?? false;
        if (status != null && !deleted) {
          map[doc.id] = status;
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  void refresh() => _loadRecordings();

  Future<String> _pathFor(SavedRecording r) async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/recordings/${r.localFileName}';
  }

  Future<void> _togglePlay(SavedRecording r) async {
    if (_playingFileName == r.localFileName) {
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
    if (mounted) setState(() => _playingFileName = r.localFileName);
  }

  Future<void> _deleteRecording(SavedRecording r) async {
    if (_playingFileName == r.localFileName) {
      await _player.stop();
      if (mounted) setState(() => _playingFileName = null);
    }
    final appDir = await getApplicationDocumentsDirectory();
    final filePath = '${appDir.path}/recordings/${r.localFileName}';
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
              .where((e) => e['localFileName'] != r.localFileName)
              .toList();
      await metaFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(list),
      );
      if (mounted) {
        setState(() {
          _recordings =
              _recordings.where((x) => x.localFileName != r.localFileName).toList();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recording deleted')));
      }
      // One-way sync: mark as deleted in Firestore (soft delete; file stays in Storage)
      RecordingSyncService.instance.markNoteDeleted(
        noteUuid: r.noteUuid,
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
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _loadRecordings(),
            tooltip: 'Refresh status',
          ),
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _loadRecordings,
                child: _recordings.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.5,
                            child: const Center(child: Text('No recordings yet')),
                          ),
                        ],
                      )
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: _recordings.length,
                        itemBuilder: (context, index) {
                    final r = _recordings[index];
                    final isPlaying = _playingFileName == r.localFileName;
                    final borderColor = switch (r.status) {
                      'audio' => Colors.red,
                      'transcribed' => Colors.orange,
                      _ => null,
                    };
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: borderColor != null
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: borderColor, width: 2),
                            )
                          : null,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RecordingPage(recording: r),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(12),
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
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
