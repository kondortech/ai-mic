import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/google_calendar_connect_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _calendarBusy = false;

  String _calendarStatusLabel(Map<String, dynamic>? data) {
    if (data == null) return 'not connected';
    final explicitStatus = (data['status'] as String?)?.toLowerCase().trim();
    if (explicitStatus == 'not connected') return 'not connected';
    if (explicitStatus == 'connected') return 'connected';
    if (explicitStatus == 'expired') return 'expired';

    if (data['expired'] == true) return 'expired';

    return 'not connected';
  }

  Color _calendarStatusColor(String status) {
    switch (status) {
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
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              CircleAvatar(
                radius: 56,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  size: 64,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Profile',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                uid ?? '',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              const SizedBox(height: 28),
              Text(
                'Google Calendar',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Connect to allow secure server-side Calendar token usage.',
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
                    final status = _calendarStatusLabel(data);
                    final isConnected = status == 'connected';

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
                                  color: _calendarStatusColor(status),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Status: $status',
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
                                        : const Text('Disconnect'),
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
                                        : const Text('Connect Calendar'),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                )
              else
                const Text('Sign in to manage Calendar connection.'),
              const Spacer(),
              FilledButton.icon(
                onPressed: () async {
                  await signOut();
                  if (context.mounted) {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  }
                },
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onErrorContainer,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Google Calendar connected')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Connect failed: $e')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Google Calendar disconnected')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Disconnect failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }
}
