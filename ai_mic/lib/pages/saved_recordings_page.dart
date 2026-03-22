import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../l10n/app_localizations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../models/recording.dart';
import '../services/recording_sync_service.dart';

import 'recording_page.dart';

class SavedRecordingsPage extends StatefulWidget {
  const SavedRecordingsPage({super.key});

  @override
  SavedRecordingsPageState createState() => SavedRecordingsPageState();
}

class SavedRecordingsPageState extends State<SavedRecordingsPage> {
  List<SavedRecording> _recordings = [];
  final AudioPlayer _player = AudioPlayer();
  String? _playingNoteUuid;
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
    return s == 'plan_created' ||
        s == 'plan_executed' ||
        s == 'no_plan_created';
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
    if (s == 'no_plan_created') return Colors.red;
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadRecordings();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingNoteUuid = null);
    });
  }

  @override
  void dispose() {
    _statusPollingTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _recordings = [];
          _loading = false;
        });
      }
      return;
    }
    try {
      final snapshot =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('inputs')
              .orderBy('createdAt', descending: true)
              .get();

      final list = <SavedRecording>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final title = data['title'] as String? ?? '';
        final status = data['status'] as String?;
        final deleted = data['deleted'] as bool? ?? false;
        if (deleted) continue; // Filter soft-deleted in memory

        final createdAt = data['createdAt'];
        final String timestamp;
        if (createdAt != null && createdAt is Timestamp) {
          timestamp = createdAt.toDate().toIso8601String();
        } else {
          timestamp = '';
        }

        list.add(
          SavedRecording(
            noteUuid: doc.id,
            title: title,
            timestamp: timestamp,
            status: status,
          ),
        );
      }

      if (mounted) {
        setState(() {
          _recordings = list;
          _loading = false;
        });
      }
      if (mounted) _syncPollingWithCurrentStatuses();
    } catch (e) {
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

  Future<String> _downloadUrlFor(SavedRecording r) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not signed in');
    final ref = FirebaseStorage.instance.ref().child(
      '${user.uid}/inputs/${r.noteUuid}/raw_audio.mp4',
    );
    return ref.getDownloadURL();
  }

  Future<void> _togglePlay(SavedRecording r) async {
    if (_playingNoteUuid == r.noteUuid) {
      await _player.stop();
      if (mounted) setState(() => _playingNoteUuid = null);
      return;
    }
    try {
      final url = await _downloadUrlFor(r);
      await _player.stop();
      await _player.play(UrlSource(url));
      if (mounted) setState(() => _playingNoteUuid = r.noteUuid);
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.savedRecordingsPlayErrorWithMessage(e.toString()),
            ),
          ),
        );
      }
    }
  }

  Future<void> _deleteRecording(SavedRecording r) async {
    if (!_canDelete(r)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.savedRecordingsCannotDeleteExecuted,
            ),
          ),
        );
      }
      return;
    }
    final canDeleteRemote = await _canDeleteByRemoteStatus(r.noteUuid);
    if (!canDeleteRemote) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.savedRecordingsCannotDeleteStatus,
            ),
          ),
        );
      }
      return;
    }
    if (_playingNoteUuid == r.noteUuid) {
      await _player.stop();
      if (mounted) setState(() => _playingNoteUuid = null);
    }
    try {
      await RecordingSyncService.instance.markNoteDeleted(
        noteUuid: r.noteUuid,
        onError: (e) {
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.savedRecordingsDeleteFailedWithMessage(e.toString()),
                ),
              ),
            );
          }
        },
      );
      if (mounted) {
        setState(() {
          _recordings =
              _recordings.where((x) => x.noteUuid != r.noteUuid).toList();
        });
        _syncPollingWithCurrentStatuses();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.savedRecordingsDeleted),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.savedRecordingsDeleteFailedWithMessage(e.toString()),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.savedRecordingsTitle),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _loadRecordings(),
            tooltip: l10n.savedRecordingsRefresh,
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
                                child: Center(
                                  child: Text(l10n.savedRecordingsNone),
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
                              final isPlaying = _playingNoteUuid == r.noteUuid;
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
                                                  ? l10n
                                                      .savedRecordingsDeleteTooltip
                                                  : l10n
                                                      .savedRecordingsCannotDeleteTooltip,
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
