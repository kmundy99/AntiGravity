import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';

class GeneralEmailQueueScreen extends StatelessWidget {
  final String adminUid;
  final String adminEmail;

  const GeneralEmailQueueScreen({
    super.key,
    required this.adminUid,
    required this.adminEmail,
  });

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Email Queue'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<ScheduledMessage>>(
        stream: firebase.getScheduledMessagesStream(adminUid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final all = (snapshot.data ?? [])
              .where((m) => m.contractId == 'general' && m.type == 'general_availability_request')
              .where((m) => m.status == 'pending_approval' || m.status == 'pending')
              .toList();

          if (all.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No pending drafts.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: all.length,
            itemBuilder: (context, i) {
              return _GeneralMessageRow(
                message: all[i],
                adminEmail: adminEmail,
              );
            },
          );
        },
      ),
    );
  }
}

class _GeneralMessageRow extends StatefulWidget {
  final ScheduledMessage message;
  final String adminEmail;

  const _GeneralMessageRow({
    required this.message,
    required this.adminEmail,
  });

  @override
  State<_GeneralMessageRow> createState() => _GeneralMessageRowState();
}

class _GeneralMessageRowState extends State<_GeneralMessageRow> {
  bool _loading = false;

  bool get _isApproval => widget.message.status == 'pending_approval';

  Future<void> _send() async {
    final msg = widget.message;
    final recipientCount = msg.recipients.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send Availability Requests?'),
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
      // Send directly via mail collection directly
      for (final email in msg.renderedEmails) {
        // Query user doc to get their email address
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(email.uid).get();
        if (userDoc.exists) {
            final data = userDoc.data()!;
            String emailAddr = data['email'] ?? '';
            if (emailAddr.isEmpty && (data['primary_contact'] ?? '').toString().contains('@')) {
               emailAddr = data['primary_contact'];
            }
            if (emailAddr.isNotEmpty) {
               await FirebaseFirestore.instance.collection('mail').add({
                  'to': emailAddr,
                  'message': {
                      'subject': email.subject,
                      'html': email.body.replaceAll('\n', '<br>'),
                  },
                  if (widget.adminEmail.isNotEmpty) 'reply_to': widget.adminEmail,
               });
            }
        }
      }
      
      // Update message status to sent
      await FirebaseFirestore.instance.collection('scheduled_messages').doc(msg.id).update({
          'status': 'sent'
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Requests sent')),
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
        title: const Text('Delete Draft?'),
        content: const Text('This will delete the generated email drafts.'),
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
      await FirebaseFirestore.instance.collection('scheduled_messages').doc(widget.message.id).delete();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _review() {
    showDialog<void>(
      context: context,
      builder: (ctx) => _ReviewDialog(
        message: widget.message,
        title: 'Availability Request Drafts',
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
    final recipientCount = msg.recipients.length;

    // Remove milliseconds and parse to Local for better display, or just use generatedAt directly
    final generatedStr = msg.generatedAt != null
        ? DateFormat("MMM d 'at' h:mm a").format(msg.generatedAt!.toLocal())
        : null;

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
              const Text('Availability Request', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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
            ],
          ),
          const SizedBox(height: 8),
          if (generatedStr != null) ...[
             Text('Generated: $generatedStr', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
             const SizedBox(height: 8),
          ],
          if (_loading)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                 _actionBtn(Icons.preview_outlined, 'Review', Colors.orange.shade700, _review),
                 _actionBtn(Icons.send, 'Send', Colors.green.shade700, _send),
                 _textBtn(Icons.delete_outline, 'Delete', Colors.red.shade400, _deleteDraft),
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

class _ReviewDialog extends StatefulWidget {
  final ScheduledMessage message;
  final String title;
  final VoidCallback onSend;

  const _ReviewDialog({
    required this.message,
    required this.title,
    required this.onSend,
  });

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  bool _showAllRecipients = false;
  late TextEditingController _bodyController;
  Timer? _debounce;

  late List<RecipientInfo> _recipients;
  late List<RenderedEmail> _renderedEmails;

  @override
  void initState() {
    super.initState();
    _recipients = List.from(widget.message.recipients);
    _renderedEmails = List.from(widget.message.renderedEmails);

    final initialBody = _renderedEmails.isNotEmpty ? _renderedEmails.first.body : widget.message.body;
    _bodyController = TextEditingController(text: initialBody);
  }

  @override
  void dispose() {
    _bodyController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onBodyChanged(String newBody) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () async {
      // Update all rendered emails with the new body template
      // Note: for general requests, there are no personalization tags like {name} in the body currently,
      // the template creates it. But we update it uniformly here.
      final msg = widget.message;
      final updatedRendered = _renderedEmails.map((e) => e.copyWith(body: newBody)).toList();

      // Also update local state so if we rely on it elsewhere it's fresh
      if (mounted) {
        setState(() {
          _renderedEmails = updatedRendered;
        });
      }

      try {
        await FirebaseService().updateScheduledMessage(msg.id, {
          'body': newBody,
          'rendered_emails': updatedRendered.map((e) => e.toMap()).toList(),
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save email draft: $e')),
          );
        }
      }
    });
  }

  void _removeRecipient(RecipientInfo player) async {
    setState(() {
      _recipients.removeWhere((r) => r.uid == player.uid);
      _renderedEmails.removeWhere((r) => r.uid == player.uid);
    });

    try {
      await FirebaseService().updateScheduledMessage(widget.message.id, {
        'recipients': _recipients.map((e) => e.toMap()).toList(),
        'rendered_emails': _renderedEmails.map((e) => e.toMap()).toList(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove recipient: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rendered = _renderedEmails;
    final sample = rendered.isNotEmpty ? rendered.first : null;
    
    final recipients = _recipients;
    final recipientCount = recipients.length;

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
                      widget.title,
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
                  children: [
                    Card(
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
                            Text(
                              '$recipientCount recipient${recipientCount != 1 ? "s" : ""}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                            const SizedBox(height: 8),

                            if (sample != null) ...[
                              Text(
                                sample.subject,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: TextField(
                                  controller: _bodyController,
                                  maxLines: null,
                                  minLines: 3,
                                  style: const TextStyle(fontSize: 12, height: 1.5),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.all(10),
                                    hintText: 'Email body...',
                                  ),
                                  onChanged: _onBodyChanged,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (rendered.length > 1)
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
                                      : 'Show all ${recipients.length} recipients',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                              if (_showAllRecipients)
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: recipients
                                      .map((r) => InputChip(
                                            label: Text(r.displayName, style: const TextStyle(fontSize: 11)),
                                            visualDensity: VisualDensity.compact,
                                            backgroundColor: Colors.blue.shade50,
                                            deleteIcon: const Icon(Icons.close, size: 14, color: Colors.red),
                                            onDeleted: () => _removeRecipient(r),
                                          ))
                                      .toList(),
                                ),
                            ] else
                              Text(
                                'No content generated.',
                                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
                    onPressed: widget.onSend,
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
