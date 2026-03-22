import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/recording.dart';
import 'calendar_events_page.dart';
import 'notes_page.dart';
import 'profile_page.dart';
import 'record_page.dart';
import 'recording_page.dart';
import 'tools_page.dart';

/// Bottom nav shell: Notes, Calendar, Mic (Record), Tools, Profile.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 2; // Mic is the default/focal tab
  final GlobalKey<RecordPageState> _recordPageKey =
      GlobalKey<RecordPageState>();

  void _onRecordingSaved(String noteUuid) {
    final recording = SavedRecording(
      noteUuid: noteUuid,
      title: '',
      timestamp: DateTime.now().toIso8601String(),
      status: 'uploaded',
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingPage(recording: recording),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const NotesPage(),
          const CalendarEventsPage(),
          RecordPage(
            key: _recordPageKey,
            onRecordingSavedToCloud: _onRecordingSaved,
          ),
          const ToolsPage(),
          const ProfilePage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() => _currentIndex = index);
        },
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.note),
            label: l10n.navNotes,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.calendar_today),
            label: l10n.navCalendar,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.mic),
            label: l10n.navRecord,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.build),
            label: l10n.navTools,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.person),
            label: l10n.navProfile,
          ),
        ],
      ),
    );
  }
}
