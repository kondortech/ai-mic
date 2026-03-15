import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Mic',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

/// Format ISO 8601 timestamp for display (e.g. "2025-03-14 15:30").
String formatTimestamp(String iso) {
  try {
    final dt = DateTime.parse(iso);
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  } catch (_) {
    return iso;
  }
}

class SavedRecording {
  SavedRecording({
    required this.fileName,
    required this.description,
    required this.timestamp,
  });

  final String fileName;
  final String description;
  final String timestamp;

  String get displayTitle =>
      description.trim().isEmpty ? formatTimestamp(timestamp) : description;
}

/// Bottom nav shell with Record and Saved Recordings pages.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final GlobalKey<_SavedRecordingsPageState> _savedRecordingsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const RecordPage(),
          SavedRecordingsPage(key: _savedRecordingsKey),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() => _currentIndex = index);
          if (index == 1) {
            _savedRecordingsKey.currentState?.refresh();
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Record'),
          BottomNavigationBarItem(icon: Icon(Icons.list), label: 'Saved'),
        ],
      ),
    );
  }
}

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
    _discard();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Mic'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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

class SavedRecordingsPage extends StatefulWidget {
  const SavedRecordingsPage({super.key});

  @override
  State<SavedRecordingsPage> createState() => _SavedRecordingsPageState();
}

class _SavedRecordingsPageState extends State<SavedRecordingsPage> {
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
