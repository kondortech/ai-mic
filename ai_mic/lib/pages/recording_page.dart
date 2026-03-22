import 'dart:async';
import 'dart:convert';

import 'package:ai_mic_api/api.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/recording.dart';
import '../services/api_service.dart';

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
        _normalizeStatus(_recordStatus) == 'no_plan_created' ||
        _normalizeStatus(_recordStatus) == 'transcribed') {
      _loadTranscript();
      _loadPlan();
    }
    if (_normalizeStatus(_recordStatus) != 'plan_created' &&
        _normalizeStatus(_recordStatus) != 'plan_executed' &&
        _normalizeStatus(_recordStatus) != 'no_plan_created') {
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
      if (nextStatus == 'plan_created' ||
          nextStatus == 'plan_executed' ||
          nextStatus == 'no_plan_created') {
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
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _transcript = null;
          _loadingTranscript = false;
          _transcriptError = l10n.recordingTranscriptNotFound;
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

  Future<String?> _pickTimestampForArg(int actionIndex, String key) async {
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
    if (date == null) return null;
    if (!mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (time == null) return null;

    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final value = combined.toIso8601String();
    _updateActionArg(actionIndex, key, value);
    return value;
  }

  Future<void> _overwriteAndExecutePlan() async {
    if (_executingPlan || _isPlanExecuted) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final actions =
        _planActions
            .map(
              (a) => PlanAction(
                tool: (a['tool'] as String?) ?? 'create_note',
                arguments:
                    (a['arguments'] as Map<String, dynamic>?)?.map(
                      (k, v) => MapEntry(k, v?.toString() ?? ''),
                    ) ??
                    {},
              ),
            )
            .toList();
    final plan = ExecutionPlan(
      actions: actions,
      emptyReason:
          actions.isEmpty ? (_planEmptyReason ?? 'No actions in plan.') : null,
      generatedAt: DateTime.now(),
    );

    setState(() => _executingPlan = true);
    try {
      await ApiService.instance.overwriteExecutionPlan(
        inputUuid: widget.recording.noteUuid,
        plan: plan,
      );

      final result = await ApiService.instance.executeStoredPlan(
        widget.recording.noteUuid,
      );

      await _pollStatusOnce();

      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        final executed = result.executed == true;
        final message =
            executed
                ? l10n.recordingPlanExecutionSuccess
                : ((result.reason != null && result.reason!.isNotEmpty)
                    ? result.reason!
                    : l10n.recordingPlanNoActions);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.recordingPlanExecutionFailedWithMessage(e.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _executingPlan = false);
    }
  }

  Future<String> _audioDownloadUrl() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not signed in');
    final ref = FirebaseStorage.instance.ref().child(
      '${user.uid}/inputs/${widget.recording.noteUuid}/raw_audio.mp4',
    );
    return ref.getDownloadURL();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    try {
      final url = await _audioDownloadUrl();
      await _player.play(UrlSource(url));
      if (mounted) setState(() => _isPlaying = true);
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recordingCouldNotPlayWithMessage(e.toString())),
          ),
        );
      }
    }
  }

  bool get _canExecutePlan =>
      _normalizeStatus(_recordStatus) == 'plan_created' &&
      _planActions.isNotEmpty;

  String _statusLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = _normalizeStatus(_recordStatus);
    if (s == 'uploaded') return l10n.recordingStatusUploaded;
    if (s == 'transcribed') return l10n.recordingStatusTranscribed;
    if (s == 'plan_created') return l10n.recordingStatusPlanCreated;
    if (s == 'plan_executed') return l10n.recordingStatusPlanExecuted;
    if (s == 'no_plan_created') return l10n.recordingStatusNoPlanCreated;
    return s.isEmpty ? l10n.recordingStatusUnknown : s;
  }

  Color get _statusColor {
    final s = _normalizeStatus(_recordStatus);
    if (s == 'uploaded') return Colors.grey;
    if (s == 'transcribed') return Colors.yellow.shade700;
    if (s == 'plan_created') return Colors.orange;
    if (s == 'plan_executed') return Colors.green;
    if (s == 'no_plan_created') return Colors.red;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
                _statusLabel(context),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _statusColor,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Text(
                l10n.recordingTranscription,
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
                          ? l10n.recordingNoTranscriptionText
                          : l10n.recordingTranscriptionNotReady,
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
                l10n.recordingExecutionPlan,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_isPlanExecuted)
                Text(
                  l10n.recordingPlanExecutedEditingDisabled,
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
                  color:
                      _normalizeStatus(_recordStatus) == 'no_plan_created'
                          ? Colors.red.shade50
                          : null,
                  shape:
                      _normalizeStatus(_recordStatus) == 'no_plan_created'
                          ? RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: Colors.red, width: 2),
                          )
                          : null,
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
                          ? l10n.recordingPlanNotGenerated
                          : l10n.recordingPlanWillBeGenerated,
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
                    _loadingPlan ||
                            _executingPlan ||
                            _isPlanExecuted ||
                            !_canExecutePlan
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
                  _executingPlan
                      ? l10n.recordingExecuting
                      : l10n.recordingSaveAndExecute,
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

class _TimestampFormField extends StatefulWidget {
  const _TimestampFormField({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool enabled;
  final Future<String?> Function() onTap;

  @override
  State<_TimestampFormField> createState() => _TimestampFormFieldState();
}

class _TimestampFormFieldState extends State<_TimestampFormField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_TimestampFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      readOnly: true,
      enabled: widget.enabled,
      controller: _controller,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: const Icon(Icons.calendar_today),
      ),
      onTap:
          widget.enabled
              ? () async {
                final result = await widget.onTap();
                if (result != null && mounted) {
                  _controller.text = result;
                }
              }
              : null,
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

  String get _title => (arguments['title']?.toString() ?? '').trim();
  String get _textPreview => (arguments['text']?.toString() ?? '').trim();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _showEditSheet(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.note,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.recordingActionCreateNote(actionIndex + 1),
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _title.isEmpty ? l10n.recordingNoTitle : _title,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (_textPreview.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  _textPreview,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  _title.isEmpty
                      ? l10n.recordingAddTitleAndText
                      : l10n.recordingNoText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showEditSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (sheetContext) => DraggableScrollableSheet(
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder:
                (sheetCtx, scrollController) => SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              sheetCtx,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.recordingEditAction(actionIndex + 1),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<String>(
                        value: (action['tool'] as String?) ?? 'create_note',
                        items: [
                          DropdownMenuItem(
                            value: 'create_note',
                            child: Text(l10n.recordingCreateNoteTool),
                          ),
                          DropdownMenuItem(
                            value: 'create_calendar_event',
                            child: Text(l10n.recordingCreateCalendarEventTool),
                          ),
                        ],
                        onChanged:
                            enabled
                                ? (value) {
                                  if (value != null) onToolChanged(value);
                                }
                                : null,
                        decoration: InputDecoration(
                          labelText: l10n.recordingTool,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        initialValue: arguments['title']?.toString() ?? '',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: l10n.recordingTitle,
                        ),
                        onChanged: (value) => onArgChanged('title', value),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        initialValue: arguments['text']?.toString() ?? '',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: l10n.recordingText,
                        ),
                        minLines: 3,
                        maxLines: 6,
                        onChanged: (value) => onArgChanged('text', value),
                      ),
                    ],
                  ),
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
  final Future<String?> Function(String key) onPickTimestamp;
  final bool enabled;

  String get _eventTitle => (arguments['title']?.toString() ?? '').trim();
  String get _startTime => arguments['start_time']?.toString() ?? '';
  String get _finishTime => arguments['finish_time']?.toString() ?? '';

  String _formatTimestamp(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatTimestampRange(String start, String end) {
    if (start.isEmpty && end.isEmpty) return '';
    if (start.isEmpty) return _formatTimestamp(end);
    if (end.isEmpty) return _formatTimestamp(start);
    final startDt = DateTime.tryParse(start);
    final endDt = DateTime.tryParse(end);
    if (startDt == null) return end;
    final startStr = _formatTimestamp(start);
    if (endDt == null) return startStr;
    final isSameDay =
        startDt.year == endDt.year &&
        startDt.month == endDt.month &&
        startDt.day == endDt.day;
    final endStr =
        isSameDay
            ? '${endDt.hour.toString().padLeft(2, '0')}:${endDt.minute.toString().padLeft(2, '0')}'
            : _formatTimestamp(end);
    return '$startStr – $endStr';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _showEditSheet(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.event,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.recordingActionCreateCalendarEvent(actionIndex + 1),
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _eventTitle.isEmpty ? l10n.recordingNoTitle : _eventTitle,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (_startTime.isNotEmpty || _finishTime.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  _formatTimestampRange(_startTime, _finishTime),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  l10n.recordingSetEventTime,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showEditSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (sheetContext) => DraggableScrollableSheet(
            initialChildSize: 0.7,
            maxChildSize: 0.95,
            minChildSize: 0.3,
            expand: false,
            builder:
                (sheetCtx, scrollController) => SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              sheetCtx,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.recordingEditAction(actionIndex + 1),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<String>(
                        value:
                            (action['tool'] as String?) ??
                            'create_calendar_event',
                        items: [
                          DropdownMenuItem(
                            value: 'create_note',
                            child: Text(l10n.recordingCreateNoteTool),
                          ),
                          DropdownMenuItem(
                            value: 'create_calendar_event',
                            child: Text(l10n.recordingCreateCalendarEventTool),
                          ),
                        ],
                        onChanged:
                            enabled
                                ? (value) {
                                  if (value != null) onToolChanged(value);
                                }
                                : null,
                        decoration: InputDecoration(
                          labelText: l10n.recordingTool,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        initialValue: arguments['title']?.toString() ?? '',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: l10n.recordingEventTitle,
                        ),
                        onChanged: (value) => onArgChanged('title', value),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        initialValue:
                            arguments['description']?.toString() ?? '',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: l10n.recordingEventDescription,
                        ),
                        minLines: 2,
                        maxLines: 4,
                        onChanged:
                            (value) => onArgChanged('description', value),
                      ),
                      const SizedBox(height: 16),
                      _TimestampFormField(
                        key: ValueKey('start_${arguments['start_time']}'),
                        label: l10n.recordingStartTimestamp,
                        value: arguments['start_time']?.toString() ?? '',
                        enabled: enabled,
                        onTap: () => onPickTimestamp('start_time'),
                      ),
                      const SizedBox(height: 16),
                      _TimestampFormField(
                        key: ValueKey('finish_${arguments['finish_time']}'),
                        label: l10n.recordingFinishTimestamp,
                        value: arguments['finish_time']?.toString() ?? '',
                        enabled: enabled,
                        onTap: () => onPickTimestamp('finish_time'),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        initialValue:
                            arguments['timezone']
                                        ?.toString()
                                        .trim()
                                        .isNotEmpty ==
                                    true
                                ? arguments['timezone']?.toString()
                                : 'local',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: l10n.recordingTimezone,
                        ),
                        onChanged: (value) => onArgChanged('timezone', value),
                      ),
                    ],
                  ),
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

  String get _toolName => (action['tool'] as String?) ?? 'create_note';
  String _previewText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (arguments.isEmpty) return l10n.recordingNoArguments;
    final first = arguments.entries.first;
    final val = first.value?.toString() ?? '';
    return val.isEmpty
        ? '${first.key}: (empty)'
        : '${first.key}: ${val.length > 30 ? "${val.substring(0, 30)}..." : val}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _showEditSheet(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.build,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.recordingActionGeneric(actionIndex + 1, _toolName),
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _previewText(context),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (sheetContext) => DraggableScrollableSheet(
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder:
                (sheetCtx, scrollController) => SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              sheetCtx,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.recordingEditAction(actionIndex + 1),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<String>(
                        value: (action['tool'] as String?) ?? 'create_note',
                        items: [
                          DropdownMenuItem(
                            value: 'create_note',
                            child: Text(l10n.recordingCreateNoteTool),
                          ),
                          DropdownMenuItem(
                            value: 'create_calendar_event',
                            child: Text(l10n.recordingCreateCalendarEventTool),
                          ),
                        ],
                        onChanged:
                            enabled
                                ? (value) {
                                  if (value != null) onToolChanged(value);
                                }
                                : null,
                        decoration: InputDecoration(
                          labelText: l10n.recordingTool,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ...arguments.entries.map((entry) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: TextFormField(
                            initialValue: entry.value?.toString() ?? '',
                            enabled: enabled,
                            decoration: InputDecoration(labelText: entry.key),
                            onChanged:
                                (value) => onArgChanged(entry.key, value),
                          ),
                        );
                      }),
                      if (arguments.isEmpty)
                        Text(
                          l10n.recordingNoArguments,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                ),
          ),
    );
  }
}
