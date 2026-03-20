import 'dart:async';
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
  Timer? _statusPollingTimer;
  bool _pollingInProgress = false;
  Set<String> _pendingNoteUuids = {};

  String _normalizeStatus(String? status) {
    if (status == 'audio') return 'uploaded';
    return status ?? '';
  }

  bool _isTerminalStatus(String? status) {
    final s = _normalizeStatus(status);
    return s == 'plan_created' || s == 'plan_executed';
  }

  bool _canDelete(SavedRecording recording) {
    return _normalizeStatus(recording.status) != 'plan_executed';
  }

  Future<bool> _canDeleteByRemoteStatus(String noteUuid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final snap =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('inputs')
              .doc(noteUuid)
              .get();
      final status = _normalizeStatus(snap.data()?['status'] as String?);
      return status != 'plan_executed';
    } catch (_) {
      // Be conservative: if status cannot be checked, deny deletion.
      return false;
    }
  }

  Color? _statusBorderColor(String? status) {
    final s = _normalizeStatus(status);
    if (s == 'uploaded') return const Color.fromARGB(255, 255, 255, 255);
    if (s == 'transcribed') return const Color.fromARGB(255, 243, 229, 193);
    if (s == 'plan_created') return Colors.orange;
    if (s == 'plan_executed') return Colors.green;
    return null;
  }

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
    _statusPollingTimer?.cancel();
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
      if (mounted) _syncPollingWithCurrentStatuses();
    } catch (_) {
      if (mounted) {
        setState(() {
          _recordings = [];
          _loading = false;
        });
      }
      if (mounted) _syncPollingWithCurrentStatuses();
    }
  }

  /// Fetches Firestore status for each note. Returns map noteUuid -> status.
  Future<Map<String, String>> _fetchStatusByNoteUuid({
    Set<String>? noteUuids,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {};
    try {
      final map = <String, String>{};

      // If we have a set of note Uuids, use chunked `whereIn` to reduce reads.
      // Firestore limits `whereIn` to 10 elements.
      final uuids = noteUuids?.where((e) => e.isNotEmpty).toList();
      if (uuids == null) {
        final snapshot =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .collection('inputs')
                .get();
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final status = data['status'] as String?;
          final deleted = data['deleted'] as bool? ?? false;
          if (status != null && !deleted) {
            map[doc.id] = status;
          }
        }
        return map;
      }

      const chunkSize = 10;
      for (var i = 0; i < uuids.length; i += chunkSize) {
        final end =
            (i + chunkSize > uuids.length) ? uuids.length : i + chunkSize;
        final chunk = uuids.sublist(i, end);
        if (chunk.isEmpty) continue;
        final snapshot =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .collection('inputs')
                .where(FieldPath.documentId, whereIn: chunk)
                .get();
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final status = data['status'] as String?;
          final deleted = data['deleted'] as bool? ?? false;
          if (status != null && !deleted) {
            map[doc.id] = status;
          }
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  void _syncPollingWithCurrentStatuses() {
    _pendingNoteUuids =
        _recordings
            .where((r) => !_isTerminalStatus(r.status))
            .map((r) => r.noteUuid)
            .toSet();

    // Also handle cases where status isn't present yet.
    final missingStatus =
        _recordings
            .where((r) => r.status == null)
            .map((r) => r.noteUuid)
            .toSet();
    _pendingNoteUuids = {..._pendingNoteUuids, ...missingStatus};

    if (_pendingNoteUuids.isEmpty) {
      _statusPollingTimer?.cancel();
      _statusPollingTimer = null;
      return;
    }

    _statusPollingTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollStatusesUntilTranscribed(),
    );
  }

  Future<void> _pollStatusesUntilTranscribed() async {
    if (!mounted) return;
    if (_pollingInProgress) return;
    if (_pendingNoteUuids.isEmpty) {
      _statusPollingTimer?.cancel();
      _statusPollingTimer = null;
      return;
    }

    _pollingInProgress = true;
    try {
      final statuses = await _fetchStatusByNoteUuid(
        noteUuids: _pendingNoteUuids,
      );
      if (!mounted) return;

      final indexByNoteUuid = <String, int>{};
      for (var i = 0; i < _recordings.length; i++) {
        indexByNoteUuid[_recordings[i].noteUuid] = i;
      }

      var didUpdate = false;
      for (final entry in statuses.entries) {
        final noteUuid = entry.key;
        final nextStatus = entry.value;
        final index = indexByNoteUuid[noteUuid];
        if (index == null) continue;
        final current = _recordings[index].status;
        if (current == nextStatus) continue;

        final old = _recordings[index];
        _recordings[index] = SavedRecording(
          noteUuid: old.noteUuid,
          localFileName: old.localFileName,
          title: old.title,
          timestamp: old.timestamp,
          status: nextStatus,
        );
        didUpdate = true;
      }

      if (didUpdate) setState(() {});

      // If everything is transcribed now, stop polling.
      _syncPollingWithCurrentStatuses();
    } catch (_) {
      // Ignore transient failures; next tick will retry.
    } finally {
      _pollingInProgress = false;
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
    if (!_canDelete(r)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording with executed plan cannot be deleted'),
          ),
        );
      }
      return;
    }
    final canDeleteRemote = await _canDeleteByRemoteStatus(r.noteUuid);
    if (!canDeleteRemote) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot delete this recording: plan already executed or status unavailable',
            ),
          ),
        );
      }
      return;
    }
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
              _recordings
                  .where((x) => x.localFileName != r.localFileName)
                  .toList();
        });
        _syncPollingWithCurrentStatuses();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recording deleted')));
      }
      // One-way sync: mark as deleted in Firestore (soft delete; file stays in Storage)
      RecordingSyncService.instance.markNoteDeleted(
        noteUuid: r.noteUuid,
        onError: (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Sync delete failed: $e')));
          }
        },
      );
    } catch (_) {
      if (mounted) {
        _loadRecordings();
      }
      if (mounted) _syncPollingWithCurrentStatuses();
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
                MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child:
            _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                  onRefresh: _loadRecordings,
                  child:
                      _recordings.isEmpty
                          ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.of(context).size.height * 0.5,
                                child: const Center(
                                  child: Text('No recordings yet'),
                                ),
                              ),
                            ],
                          )
                          : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            itemCount: _recordings.length,
                            itemBuilder: (context, index) {
                              final r = _recordings[index];
                              final isPlaying =
                                  _playingFileName == r.localFileName;
                              final borderColor = _statusBorderColor(r.status);
                              final canDelete = _canDelete(r);
                              return Card(
                                margin: const EdgeInsets.only(bottom: 12),
                                shape:
                                    borderColor != null
                                        ? RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          side: BorderSide(
                                            color: borderColor,
                                            width: 2,
                                          ),
                                        )
                                        : null,
                                child: InkWell(
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder:
                                            (_) => RecordingPage(recording: r),
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
                                            isPlaying
                                                ? Icons.stop
                                                : Icons.play_arrow,
                                          ),
                                          iconSize: 36,
                                        ),
                                        Expanded(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Center(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
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
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ),
                                              Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  formatTimestamp(r.timestamp),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurface
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          onPressed:
                                              canDelete
                                                  ? () => _deleteRecording(r)
                                                  : null,
                                          icon: const Icon(Icons.delete),
                                          iconSize: 28,
                                          tooltip:
                                              canDelete
                                                  ? 'Delete'
                                                  : 'Cannot delete executed plan recording',
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
