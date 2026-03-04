import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';

class ScheduledMessagesListScreen extends StatelessWidget {
  final String organizerUid;
  final Contract contract;
  final Future<void> Function(ScheduledMessage) onSendNow;
  final Future<void> Function(ScheduledMessage) onEdit;

  const ScheduledMessagesListScreen({
    super.key,
    required this.organizerUid,
    required this.contract,
    required this.onSendNow,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();
    final cutoff = DateTime.now().subtract(const Duration(days: 30));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scheduled Messages'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<ScheduledMessage>>(
        stream: firebase.getScheduledMessagesStream(organizerUid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final all = (snapshot.data ?? [])
              .where((m) => m.contractId == contract.id)
              .where((m) =>
                  m.status == 'pending' ||
                  (m.status == 'sent' &&
                      m.scheduledFor.isAfter(cutoff)) ||
                  (m.status == 'cancelled' &&
                      m.scheduledFor.isAfter(cutoff)))
              .toList()
            ..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));

          if (all.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No scheduled messages.\nSave the contract as Active to generate them.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            );
          }

          // Group by status
          final pending = all.where((m) => m.status == 'pending').toList();
          final sent = all.where((m) => m.status == 'sent').toList();
          final cancelled = all.where((m) => m.status == 'cancelled').toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (pending.isNotEmpty) ...[
                _sectionHeader('Pending (${pending.length})'),
                ...pending.map((msg) => _ScheduledMsgTile(
                      msg: msg,
                      contract: contract,
                      onSendNow: () => onSendNow(msg),
                      onEdit: () => onEdit(msg),
                      onSkip: () => firebase.updateScheduledMessage(
                          msg.id, {'status': 'cancelled'}),
                    )),
                const SizedBox(height: 16),
              ],
              if (sent.isNotEmpty) ...[
                _sectionHeader('Sent (last 30 days)'),
                ...sent.map((msg) => _ScheduledMsgTile(
                      msg: msg,
                      contract: contract,
                      readonly: true,
                    )),
                const SizedBox(height: 16),
              ],
              if (cancelled.isNotEmpty) ...[
                _sectionHeader('Skipped (last 30 days)'),
                ...cancelled.map((msg) => _ScheduledMsgTile(
                      msg: msg,
                      contract: contract,
                      readonly: true,
                    )),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blueGrey),
      ),
    );
  }
}

class _ScheduledMsgTile extends StatelessWidget {
  final ScheduledMessage msg;
  final Contract contract;
  final bool readonly;
  final VoidCallback? onSendNow;
  final VoidCallback? onEdit;
  final VoidCallback? onSkip;

  const _ScheduledMsgTile({
    required this.msg,
    required this.contract,
    this.readonly = false,
    this.onSendNow,
    this.onEdit,
    this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final typeLabel = switch (msg.type) {
      'availability_request' => 'Availability Request',
      'last_ditch'           => 'Last-Ditch Fill Request',
      'sub_request'          => 'Sub Request',
      'lineup_publish'       => 'Auto Lineup Publish',
      _                      => 'Payment Reminder',
    };
    final scheduledStr = DateFormat('EEE, MMM d · h:mm a').format(msg.scheduledFor);
    final sessionStr = msg.sessionDate != null
        ? ' — Session ${DateFormat('MMM d').format(msg.sessionDate!)}'
        : '';
    final filterLabel = msg.recipientsFilter == 'unpaid'
        ? 'unpaid players'
        : '${msg.recipients.length} players';

    Color statusColor;
    String statusLabel;
    switch (msg.status) {
      case 'pending':
        statusColor = Colors.blue;
        statusLabel = 'Pending';
      case 'sent':
        statusColor = Colors.green;
        statusLabel = 'Sent';
      case 'cancelled':
        statusColor = Colors.grey;
        statusLabel = 'Skipped';
      default:
        statusColor = Colors.grey;
        statusLabel = msg.status;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$typeLabel$sessionStr',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              scheduledStr,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            Text(
              'To: $filterLabel',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            Text(
              msg.subject,
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (!readonly) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onEdit,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Edit', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: onSkip,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: Colors.grey,
                    ),
                    child: const Text('Skip', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: onSendNow,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: Colors.blue.shade700,
                    ),
                    child: const Text('Send Now', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
