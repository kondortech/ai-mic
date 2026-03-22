import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/google_calendar_connect_service.dart';

/// Page for managing tools (Google Calendar connect, etc.).
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  bool _calendarBusy = false;

  /// Raw status key for logic (connected, expired, not connected).
  String _calendarStatusKey(Map<String, dynamic>? data) {
    if (data == null) return 'not connected';
    final explicitStatus = (data['status'] as String?)?.toLowerCase().trim();
    if (explicitStatus == 'connected') return 'connected';
    if (explicitStatus == 'expired') return 'expired';
    if (data['expired'] == true) return 'expired';
    return 'not connected';
  }

  String _calendarStatusLabel(
    BuildContext context,
    Map<String, dynamic>? data,
  ) {
    final l10n = AppLocalizations.of(context)!;
    switch (_calendarStatusKey(data)) {
      case 'connected':
        return l10n.toolsConnectedStatus;
      case 'expired':
        return l10n.toolsExpired;
      default:
        return l10n.toolsNotConnected;
    }
  }

  Color _calendarStatusColor(String statusKey) {
    switch (statusKey) {
      case 'connected':
        return Colors.green;
      case 'expired':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.toolsTitle),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.toolsIntro,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                l10n.toolsGoogleCalendar,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.toolsGoogleCalendarDesc,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 12),
              if (uid != null)
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream:
                      FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .collection('tokens-last-status')
                          .doc('google_calendar')
                          .snapshots(),
                  builder: (context, snap) {
                    final data = snap.data?.data();
                    final statusKey = _calendarStatusKey(data);
                    final statusLabel = _calendarStatusLabel(context, data);
                    final isConnected = statusKey == 'connected';

                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isConnected
                                      ? Icons.event_available
                                      : Icons.event_busy,
                                  color: _calendarStatusColor(statusKey),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    l10n.toolsStatusWithValue(statusLabel),
                                    style:
                                        Theme.of(context).textTheme.bodyLarge,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (isConnected)
                              OutlinedButton(
                                onPressed:
                                    _calendarBusy
                                        ? null
                                        : () => _disconnectCalendar(context),
                                child:
                                    _calendarBusy
                                        ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : Text(l10n.toolsDisconnect),
                              )
                            else
                              FilledButton(
                                onPressed:
                                    _calendarBusy
                                        ? null
                                        : () => _connectCalendar(context),
                                child:
                                    _calendarBusy
                                        ? SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color:
                                                Theme.of(
                                                  context,
                                                ).colorScheme.onPrimary,
                                          ),
                                        )
                                        : Text(l10n.toolsConnectCalendar),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                )
              else
                Text(l10n.toolsSignInRequired),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _connectCalendar(BuildContext context) async {
    setState(() => _calendarBusy = true);
    try {
      await GoogleCalendarConnectService.instance.connectCalendar();
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.toolsConnected)));
      }
    } catch (e) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.toolsConnectFailedWithMessage(e.toString())),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }

  Future<void> _disconnectCalendar(BuildContext context) async {
    setState(() => _calendarBusy = true);
    try {
      await GoogleCalendarConnectService.instance.disconnectCalendar();
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.toolsDisconnected)));
      }
    } catch (e) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.toolsDisconnectFailedWithMessage(e.toString())),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }
}
