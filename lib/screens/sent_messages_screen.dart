import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../utils/message_templates.dart';

class SentMessagesScreen extends StatelessWidget {
  final String organizerUid;
  final String? contextId;

  const SentMessagesScreen({
    super.key,
    required this.organizerUid,
    this.contextId,
  });

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Message History'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<MessageLogEntry>>(
        stream: firebase.getSentMessagesStream(organizerUid, contextId: contextId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final entries = snapshot.data ?? [];

          if (entries.isEmpty) {
            return const Center(
              child: Text(
                'No messages sent yet.',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }

          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _MessageTile(entry: entry);
            },
          );
        },
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final MessageLogEntry entry;
  const _MessageTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('M/d/yy h:mm a');
    final dateStr = df.format(entry.sentAt);

    final recipientNames = entry.recipients.map((r) => r.displayName).toList();
    final recipientsPreview = recipientNames.length <= 3
        ? recipientNames.join(', ')
        : '${recipientNames.take(2).join(', ')} +${recipientNames.length - 2}';

    return ListTile(
      onTap: () => _showDetail(context),
      title: Row(
        children: [
          Text(dateStr, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 8),
          _TypeChip(type: entry.type),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              recipientsPreview,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.subject,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            entry.body,
            style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: Text(
        '${entry.deliveryCount} sent',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final df = DateFormat('MMMM d, yyyy h:mm a');
        return AlertDialog(
          title: Text(entry.subject),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Sent: ${df.format(entry.sentAt)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _TypeChip(type: entry.type),
                      const SizedBox(width: 8),
                      Text(
                        '${entry.deliveryCount} delivered',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('To:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: entry.recipients.map((r) => Chip(
                      label: Text(r.displayName, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                    )).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text('Message:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      border: Border.all(color: Colors.grey.shade200),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(entry.body, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _TypeChip extends StatelessWidget {
  final MessageType type;
  const _TypeChip({required this.type});

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      MessageType.matchInvite => Colors.blue,
      MessageType.contractInvite => Colors.indigo,
      MessageType.paymentReminder => Colors.orange,
      MessageType.availabilityRequest => Colors.teal,
      MessageType.availabilityReminder => Colors.teal,
      MessageType.subRequest => Colors.purple,
      MessageType.sessionLineup => Colors.indigo,
      MessageType.paymentConfirmation => Colors.green,
      MessageType.custom => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        MessageTemplates.displayName(type),
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
