import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../services/cloud_functions_service.dart';

class SessionEmailQueueScreen extends StatelessWidget {
  final String organizerUid;
  final Contract contract;
  final String organizerEmail;

  const SessionEmailQueueScreen({
    super.key,
    required this.organizerUid,
    required this.contract,
    required this.organizerEmail,
  });

  String _dateKey(DateTime d) {
    final u = d.toUtc();
    return '${u.year}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Email Queue'),
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
              .where((m) => m.status == 'pending' || m.status == 'pending_approval')
              .toList();

          if (all.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No scheduled messages.\nActivate the contract to generate them.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            );
          }

          // Group by session date key
          final grouped = <String, List<ScheduledMessage>>{};
          for (final msg in all) {
            final key = msg.sessionDate != null ? _dateKey(msg.sessionDate!) : 'no_date';
            grouped.putIfAbsent(key, () => []).add(msg);
          }
          final sortedKeys = grouped.keys.toList()..sort();

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sortedKeys.length,
            itemBuilder: (context, i) {
              final key = sortedKeys[i];
              return _SessionDateCard(
                sessionDateKey: key,
                messages: grouped[key]!,
                contract: contract,
              );
            },
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

// Message types shown per session, in display order.
const _kSessionMessageTypes = [
  'availability_request',
  'availability_reminder',
  'lineup_publish',
];

class _SessionDateCard extends StatelessWidget {
  final String sessionDateKey;
  final List<ScheduledMessage> messages;
  final Contract contract;

  const _SessionDateCard({
    required this.sessionDateKey,
    required this.messages,
    required this.contract,
  });

  DateTime? get _sessionDate {
    for (final m in messages) {
      if (m.sessionDate != null) return m.sessionDate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = _sessionDate != null
        ? DateFormat('EEE, MMM d, yyyy').format(_sessionDate!.toUtc())
        : sessionDateKey;

    final byType = <String, ScheduledMessage>{};
    for (final m in messages) {
      byType[m.type] = m;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 14, color: Colors.blueGrey),
                const SizedBox(width: 6),
                Text(dateStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 10),
            ..._kSessionMessageTypes
                .where((t) => byType.containsKey(t))
                .map((t) => _MessageTypeRow(
                      sessionDateKey: sessionDateKey,
                      messageType: t,
                      message: byType[t]!,
                      contract: contract,
                    )),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MessageTypeRow extends StatefulWidget {
  final String sessionDateKey;
  final String messageType;
  final ScheduledMessage message;
  final Contract contract;

  const _MessageTypeRow({
    required this.sessionDateKey,
    required this.messageType,
    required this.message,
    required this.contract,
  });

  @override
  State<_MessageTypeRow> createState() => _MessageTypeRowState();
}

class _MessageTypeRowState extends State<_MessageTypeRow> {
  bool _loading = false;

  String get _typeLabel => switch (widget.messageType) {
    'availability_request'  => 'Availability Request',
    'availability_reminder' => 'Availability Reminder',
    'lineup_publish'        => 'Lineup',
    _                       => widget.messageType,
  };

  bool get _isApproval => widget.message.status == 'pending_approval';

  Future<void> _generate() async {
    setState(() => _loading = true);
    try {
      final count = await CloudFunctionsService.generateSessionMessages(
        contractId: widget.contract.id,
        sessionDate: widget.sessionDateKey,
        messageType: widget.messageType,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count email draft${count != 1 ? "s" : ""} generated — ready to review')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final msg = widget.message;
    final recipientCount = msg.renderedEmails.isNotEmpty
        ? msg.renderedEmails.length
        : msg.recipients.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send $_typeLabel?'),
        content: Text('Send to $recipientCount player${recipientCount != 1 ? "s" : ""}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700, foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      final count = await CloudFunctionsService.sendApprovedMessages(
        contractId: widget.contract.id,
        sessionDate: widget.sessionDateKey,
        messageType: widget.messageType,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count email${count != 1 ? "s" : ""} sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteDraft() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $_typeLabel Draft?'),
        content: const Text('The message will return to "upcoming" status.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      await FirebaseService().deleteApprovalDraftsForSession(
        widget.contract.id,
        widget.sessionDateKey,
        messageType: widget.messageType,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _review() {
    showDialog<void>(
      context: context,
      builder: (ctx) => _ReviewDialog(
        messages: [widget.message],
        title: '${_typeLabel} — ${widget.sessionDateKey}',
        onSend: () {
          Navigator.pop(ctx);
          _send();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final scheduledStr = msg.scheduledFor != null
        ? DateFormat("MMM d 'at' h:mm a").format(msg.scheduledFor!)
        : null;
    final recipientCount = msg.renderedEmails.isNotEmpty
        ? msg.renderedEmails.length
        : msg.recipients.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _isApproval ? Colors.orange.shade50 : Colors.grey.shade50,
        border: Border.all(
          color: _isApproval ? Colors.orange.shade200 : Colors.grey.shade200,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_typeLabel, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              if (_isApproval)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$recipientCount email${recipientCount != 1 ? "s" : ""} ready',
                    style: TextStyle(
                      fontSize: 10, color: Colors.orange.shade800, fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else if (scheduledStr != null)
                Text(scheduledStr, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _isApproval
                  ? [
                      _actionBtn(Icons.preview_outlined, 'Review', Colors.orange.shade700, _review),
                      _actionBtn(Icons.send, 'Send', Colors.green.shade700, _send),
                      _textBtn(Icons.refresh, 'Regenerate', Colors.blueGrey, _generate),
                      _textBtn(Icons.delete_outline, 'Delete', Colors.red.shade400, _deleteDraft),
                    ]
                  : [
                      _actionBtn(Icons.play_circle_outline, 'Generate Preview', Colors.blue.shade700, _generate),
                    ],
            ),
        ],
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback onPressed) =>
      ElevatedButton.icon(
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
        onPressed: onPressed,
      );

  Widget _textBtn(IconData icon, String label, Color color, VoidCallback onPressed) =>
      TextButton.icon(
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          foregroundColor: color,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        onPressed: onPressed,
      );
}

// ─────────────────────────────────────────────────────────────────────────────

class _ReviewDialog extends StatelessWidget {
  final List<ScheduledMessage> messages;
  final String title;
  final VoidCallback onSend;

  const _ReviewDialog({
    required this.messages,
    required this.title,
    required this.onSend,
  });

  String _typeLabel(String type) => switch (type) {
    'availability_request'  => 'Availability Request',
    'availability_reminder' => 'Availability Reminder',
    'lineup_publish'        => 'Lineup Publish',
    'last_ditch'            => 'Last-Ditch Fill Request',
    'sub_request'           => 'Sub Request',
    _                       => 'Payment Reminder',
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.blue.shade900,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: messages
                      .map((msg) => _MessageReviewCard(
                            msg: msg,
                            typeLabel: _typeLabel(msg.type),
                          ))
                      .toList(),
                ),
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Send'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: onSend,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MessageReviewCard extends StatefulWidget {
  final ScheduledMessage msg;
  final String typeLabel;

  const _MessageReviewCard({required this.msg, required this.typeLabel});

  @override
  State<_MessageReviewCard> createState() => _MessageReviewCardState();
}

class _MessageReviewCardState extends State<_MessageReviewCard> {
  bool _showAllRecipients = false;

  @override
  Widget build(BuildContext context) {
    final rendered = widget.msg.renderedEmails;
    final sample = rendered.isNotEmpty ? rendered.first : null;
    final recipientCount = rendered.isNotEmpty ? rendered.length : widget.msg.recipients.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: Colors.orange.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type + recipient count
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    widget.typeLabel,
                    style: TextStyle(
                      fontSize: 11, color: Colors.blue.shade800, fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$recipientCount recipient${recipientCount != 1 ? "s" : ""}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                if (widget.msg.generatedAt != null) ...[
                  const Spacer(),
                  Text(
                    'Generated ${DateFormat('MMM d, h:mm a').format(widget.msg.generatedAt!)}',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            if (sample != null) ...[
              // Subject
              Text(
                sample.subject,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              // Body
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  border: Border.all(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  sample.body,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
              if (rendered.length > 1) ...[
                const SizedBox(height: 6),
                Text(
                  'Showing email for ${sample.displayName}. '
                  'All ${rendered.length} emails are personalized with each player\'s name and link.',
                  style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade500, fontStyle: FontStyle.italic,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _showAllRecipients = !_showAllRecipients),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    foregroundColor: Colors.blue.shade700,
                  ),
                  child: Text(
                    _showAllRecipients
                        ? 'Hide recipient list'
                        : 'Show all ${rendered.length} recipients',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (_showAllRecipients)
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: rendered
                        .map((r) => Chip(
                              label: Text(r.displayName, style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.blue.shade50,
                            ))
                        .toList(),
                  ),
              ],
            ] else
              Text(
                'No content generated.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}
