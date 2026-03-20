import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
  List<Map<String, dynamic>> _planActions = const [];
  String? _planEmptyReason;
  bool _loadingPlan = false;
  String? _planError;
  bool _executingPlan = false;

  Timer? _statusPollingTimer;
  int _statusPollingAttempts = 0;
  static const Duration _statusPollingInterval = Duration(seconds: 3);
  static const int _maxStatusPollingAttempts = 200; // ~10 minutes

  String _normalizeStatus(String? status) {
    if (status == 'audio') return 'uploaded';
    return status ?? '';
  }

  bool get _isPlanExecuted =>
      _normalizeStatus(_recordStatus) == 'plan_executed';

  @override
  void initState() {
    super.initState();
    _recordStatus = widget.recording.status;
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });

    if (_normalizeStatus(_recordStatus) == 'plan_created' ||
        _normalizeStatus(_recordStatus) == 'plan_executed' ||
        _normalizeStatus(_recordStatus) == 'transcribed') {
      _loadTranscript();
      _loadPlan();
    }
    if (_normalizeStatus(_recordStatus) != 'plan_created' &&
        _normalizeStatus(_recordStatus) != 'plan_executed') {
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
              .collection('inputs')
              .doc(widget.recording.noteUuid)
              .get();

      if (!mounted) return;

      final nextStatus = snap.data()?['status'] as String?;
      if (nextStatus == null) return;

      if (nextStatus != _recordStatus) {
        setState(() => _recordStatus = nextStatus);
      }

      if (nextStatus == 'transcribed') {
        _loadTranscript();
        _loadPlan();
      }
      if (nextStatus == 'plan_created' || nextStatus == 'plan_executed') {
        _statusPollingTimer?.cancel();
        _statusPollingTimer = null;
        _loadTranscript();
        _loadPlan();
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
          '${user.uid}/inputs/${widget.recording.noteUuid}/raw_text.txt';
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

  Future<void> _loadPlan() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() {
      _loadingPlan = true;
      _planError = null;
    });
    try {
      final planPath =
          '${user.uid}/inputs/${widget.recording.noteUuid}/plan.json';
      final ref = FirebaseStorage.instance.ref().child(planPath);
      final data = await ref.getData();
      if (data != null && mounted) {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          throw Exception('Invalid plan format');
        }
        final actionsRaw = decoded['actions'];
        final parsedActions = <Map<String, dynamic>>[];
        if (actionsRaw is List) {
          for (final item in actionsRaw) {
            if (item is Map) {
              final actionMap = Map<String, dynamic>.from(item);
              final argsMap = actionMap['arguments'];
              actionMap['arguments'] =
                  argsMap is Map
                      ? Map<String, dynamic>.from(argsMap)
                      : <String, dynamic>{};
              if ((actionMap['tool'] as String?) == 'create_calendar_event') {
                final args = actionMap['arguments'] as Map<String, dynamic>;
                final tz = args['timezone']?.toString().trim() ?? '';
                if (tz.isEmpty) {
                  args['timezone'] = 'local';
                }
              }
              parsedActions.add(actionMap);
            }
          }
        }
        setState(() {
          _planActions = parsedActions;
          _planEmptyReason = decoded['empty_reason'] as String?;
          _loadingPlan = false;
          _planError = null;
        });
      } else if (mounted) {
        setState(() {
          _planActions = const [];
          _planEmptyReason = null;
          _loadingPlan = false;
          _planError = 'Plan not found';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _planActions = const [];
          _planEmptyReason = null;
          _loadingPlan = false;
          _planError = e.toString();
        });
      }
    }
  }

  void _updateActionTool(int index, String value) {
    setState(() {
      _planActions[index]['tool'] = value;
    });
  }

  void _updateActionArg(int index, String key, String value) {
    final args = _planActions[index]['arguments'] as Map<String, dynamic>;
    setState(() {
      args[key] = value;
    });
  }

  Future<void> _pickTimestampForArg(int actionIndex, String key) async {
    final args = _planActions[actionIndex]['arguments'] as Map<String, dynamic>;
    final currentRaw = args[key]?.toString();
    final parsedCurrent =
        currentRaw == null ? null : DateTime.tryParse(currentRaw);
    final initialDate = parsedCurrent ?? DateTime.now();

    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (time == null) return;

    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    _updateActionArg(actionIndex, key, combined.toIso8601String());
  }

  Future<void> _overwriteAndExecutePlan() async {
    if (_executingPlan || _isPlanExecuted) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final plan = {
      'actions': _planActions,
      'empty_reason':
          _planActions.isEmpty
              ? (_planEmptyReason ?? 'No actions in plan.')
              : null,
      'generated_at': DateTime.now().toIso8601String(),
    };

    setState(() => _executingPlan = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('overwriteExecutionPlan')
          .call({'inputUuid': widget.recording.noteUuid, 'plan': plan});

      final res = await FirebaseFunctions.instance
          .httpsCallable('executeStoredPlan')
          .call({'inputUuid': widget.recording.noteUuid});

      await _pollStatusOnce();

      if (mounted) {
        final data =
            (res.data is Map)
                ? Map<String, dynamic>.from(res.data as Map)
                : <String, dynamic>{};
        final executed = data['executed'] == true;
        final reason = data['reason']?.toString();
        final message =
            executed
                ? 'Plan executed successfully'
                : (reason != null && reason.isNotEmpty
                    ? reason
                    : 'Plan has no actions');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Plan execution failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _executingPlan = false);
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
    final s = _normalizeStatus(_recordStatus);
    if (s == 'uploaded') return 'Uploaded';
    if (s == 'transcribed') return 'Transcribed';
    if (s == 'plan_created') return 'Plan created';
    if (s == 'plan_executed') return 'Plan executed';
    return s.isEmpty ? 'Unknown' : s;
  }

  Color get _statusColor {
    final s = _normalizeStatus(_recordStatus);
    if (s == 'uploaded') return Colors.grey;
    if (s == 'transcribed') return Colors.yellow.shade700;
    if (s == 'plan_created') return Colors.orange;
    if (s == 'plan_executed') return Colors.green;
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
              const SizedBox(height: 24),
              Text(
                'Execution Plan',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_isPlanExecuted)
                Text(
                  'Plan is executed. Editing is disabled.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  textAlign: TextAlign.center,
                ),
              if (_isPlanExecuted) const SizedBox(height: 8),
              if (_loadingPlan)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_planError != null)
                Card(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.3),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _planError!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                )
              else if (_planActions.isNotEmpty)
                Column(
                  children: [
                    for (var i = 0; i < _planActions.length; i++)
                      _buildActionCard(i),
                  ],
                )
              else if (_planEmptyReason != null &&
                  _planEmptyReason!.trim().isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _planEmptyReason!,
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
                          ? 'Plan not generated yet.'
                          : 'Plan will be generated after transcription.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed:
                    _loadingPlan || _executingPlan || _isPlanExecuted
                        ? null
                        : _overwriteAndExecutePlan,
                icon:
                    _executingPlan
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.playlist_add_check),
                label: Text(
                  _executingPlan ? 'Executing...' : 'Save & Execute Plan',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard(int index) {
    final action = _planActions[index];
    final tool = (action['tool'] as String?) ?? 'create_note';
    final args = action['arguments'] as Map<String, dynamic>;

    if (tool == 'create_calendar_event') {
      return _CreateCalendarEventActionCard(
        actionIndex: index,
        action: action,
        arguments: args,
        onToolChanged: (value) => _updateActionTool(index, value),
        onArgChanged: (key, value) => _updateActionArg(index, key, value),
        onPickTimestamp: (key) => _pickTimestampForArg(index, key),
        enabled: !_isPlanExecuted,
      );
    }
    if (tool == 'create_note') {
      return _CreateNoteActionCard(
        actionIndex: index,
        action: action,
        arguments: args,
        onToolChanged: (value) => _updateActionTool(index, value),
        onArgChanged: (key, value) => _updateActionArg(index, key, value),
        enabled: !_isPlanExecuted,
      );
    }
    return _GenericActionCard(
      actionIndex: index,
      action: action,
      arguments: args,
      onToolChanged: (value) => _updateActionTool(index, value),
      onArgChanged: (key, value) => _updateActionArg(index, key, value),
      enabled: !_isPlanExecuted,
    );
  }
}

class _CreateNoteActionCard extends StatelessWidget {
  const _CreateNoteActionCard({
    required this.actionIndex,
    required this.action,
    required this.arguments,
    required this.onToolChanged,
    required this.onArgChanged,
    required this.enabled,
  });

  final int actionIndex;
  final Map<String, dynamic> action;
  final Map<String, dynamic> arguments;
  final ValueChanged<String> onToolChanged;
  final void Function(String key, String value) onArgChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Action ${actionIndex + 1} · Create Note',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: (action['tool'] as String?) ?? 'create_note',
              items: const [
                DropdownMenuItem(
                  value: 'create_note',
                  child: Text('create_note'),
                ),
                DropdownMenuItem(
                  value: 'create_calendar_event',
                  child: Text('create_calendar_event'),
                ),
              ],
              onChanged: (value) {
                if (!enabled) return;
                if (value != null) onToolChanged(value);
              },
              disabledHint: Text((action['tool'] as String?) ?? 'create_note'),
              decoration: const InputDecoration(labelText: 'Tool'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: arguments['title']?.toString() ?? '',
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Title'),
              onChanged: (value) => onArgChanged('title', value),
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: arguments['text']?.toString() ?? '',
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Text'),
              minLines: 2,
              maxLines: 6,
              onChanged: (value) => onArgChanged('text', value),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateCalendarEventActionCard extends StatelessWidget {
  const _CreateCalendarEventActionCard({
    required this.actionIndex,
    required this.action,
    required this.arguments,
    required this.onToolChanged,
    required this.onArgChanged,
    required this.onPickTimestamp,
    required this.enabled,
  });

  final int actionIndex;
  final Map<String, dynamic> action;
  final Map<String, dynamic> arguments;
  final ValueChanged<String> onToolChanged;
  final void Function(String key, String value) onArgChanged;
  final Future<void> Function(String key) onPickTimestamp;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Action ${actionIndex + 1} · Create Calendar Event',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue:
                  (action['tool'] as String?) ?? 'create_calendar_event',
              items: const [
                DropdownMenuItem(
                  value: 'create_note',
                  child: Text('create_note'),
                ),
                DropdownMenuItem(
                  value: 'create_calendar_event',
                  child: Text('create_calendar_event'),
                ),
              ],
              onChanged: (value) {
                if (!enabled) return;
                if (value != null) onToolChanged(value);
              },
              disabledHint: Text(
                (action['tool'] as String?) ?? 'create_calendar_event',
              ),
              decoration: const InputDecoration(labelText: 'Tool'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: arguments['title']?.toString() ?? '',
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Event title'),
              onChanged: (value) => onArgChanged('title', value),
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: arguments['description']?.toString() ?? '',
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Event description'),
              minLines: 2,
              maxLines: 4,
              onChanged: (value) => onArgChanged('description', value),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey(
                'action_${actionIndex}_start_time_${arguments['start_time']?.toString() ?? ''}',
              ),
              readOnly: true,
              enabled: enabled,
              initialValue: arguments['start_time']?.toString() ?? '',
              decoration: const InputDecoration(
                labelText: 'Start timestamp',
                suffixIcon: Icon(Icons.calendar_today),
              ),
              onTap: enabled ? () => onPickTimestamp('start_time') : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey(
                'action_${actionIndex}_finish_time_${arguments['finish_time']?.toString() ?? ''}',
              ),
              readOnly: true,
              enabled: enabled,
              initialValue: arguments['finish_time']?.toString() ?? '',
              decoration: const InputDecoration(
                labelText: 'Finish timestamp',
                suffixIcon: Icon(Icons.calendar_today),
              ),
              onTap: enabled ? () => onPickTimestamp('finish_time') : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue:
                  arguments['timezone']?.toString().trim().isNotEmpty == true
                      ? arguments['timezone']?.toString()
                      : 'local',
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Timezone'),
              onChanged: (value) => onArgChanged('timezone', value),
            ),
          ],
        ),
      ),
    );
  }
}

class _GenericActionCard extends StatelessWidget {
  const _GenericActionCard({
    required this.actionIndex,
    required this.action,
    required this.arguments,
    required this.onToolChanged,
    required this.onArgChanged,
    required this.enabled,
  });

  final int actionIndex;
  final Map<String, dynamic> action;
  final Map<String, dynamic> arguments;
  final ValueChanged<String> onToolChanged;
  final void Function(String key, String value) onArgChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Action ${actionIndex + 1}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: (action['tool'] as String?) ?? 'create_note',
              items: const [
                DropdownMenuItem(
                  value: 'create_note',
                  child: Text('create_note'),
                ),
                DropdownMenuItem(
                  value: 'create_calendar_event',
                  child: Text('create_calendar_event'),
                ),
              ],
              onChanged: (value) {
                if (!enabled) return;
                if (value != null) onToolChanged(value);
              },
              disabledHint: Text((action['tool'] as String?) ?? 'create_note'),
              decoration: const InputDecoration(labelText: 'Tool'),
            ),
            const SizedBox(height: 12),
            ...arguments.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextFormField(
                  initialValue: entry.value?.toString() ?? '',
                  enabled: enabled,
                  decoration: InputDecoration(labelText: entry.key),
                  onChanged: (value) => onArgChanged(entry.key, value),
                ),
              );
            }),
            if (arguments.isEmpty)
              Text(
                'No arguments',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
