import 'package:flutter/material.dart';

import 'record_page.dart';
import 'saved_recordings_page.dart';

/// Bottom nav shell with Record and Saved Recordings pages.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final GlobalKey<RecordPageState> _recordPageKey = GlobalKey<RecordPageState>();
  final GlobalKey<SavedRecordingsPageState> _savedRecordingsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          RecordPage(
            key: _recordPageKey,
            onRecordingSavedToCloud: () {
              _recordPageKey.currentState?.refreshRecentNotes();
              // Keep the flow on the main home page.
              if (_currentIndex != 0) {
                setState(() => _currentIndex = 0);
              }
            },
          ),
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
