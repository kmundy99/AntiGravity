import 'package:flutter/material.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';
import '../utils/message_templates.dart';

class ComposeMessageScreen extends StatefulWidget {
  final ComposeMessageConfig config;

  const ComposeMessageScreen({super.key, required this.config});

  @override
  State<ComposeMessageScreen> createState() => _ComposeMessageScreenState();
}

class _ComposeMessageScreenState extends State<ComposeMessageScreen> {
  final _firebase = FirebaseService();

  late MessageType _selectedType;
  late TextEditingController _subjectCtrl;
  late TextEditingController _bodyCtrl;

  bool _bodyEdited = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.config.initialType;
    final subject = MessageTemplates.defaultSubject(_selectedType, widget.config);
    final body = MessageTemplates.defaultBody(_selectedType, widget.config);
    _subjectCtrl = TextEditingController(text: subject);
    _bodyCtrl = TextEditingController(text: body);
    _bodyCtrl.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _bodyCtrl.removeListener(_onBodyChanged);
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    if (!_bodyEdited) setState(() => _bodyEdited = true);
  }

  void _switchType(MessageType newType) async {
    if (newType == _selectedType) return;

    final newBody = MessageTemplates.defaultBody(newType, widget.config);
    final currentBody = _bodyCtrl.text;
    final defaultBody = MessageTemplates.defaultBody(_selectedType, widget.config);

    if (_bodyEdited && currentBody != defaultBody && currentBody.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard edits?'),
          content: const Text('Switching message type will replace your edited body with the new template.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Switch type')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _selectedType = newType;
      _subjectCtrl.text = MessageTemplates.defaultSubject(newType, widget.config);
      _bodyCtrl.text = newBody;
      _bodyEdited = false;
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);

    final config = widget.config;
    final type = _selectedType;
    final subject = _subjectCtrl.text;
    final body = _bodyCtrl.text;
    final builder = MessageTemplates.linkBuilder(type, config);

    int sent = 0;
    int failed = 0;

    for (final recipient in config.recipients) {
      try {
        await NotificationService.sendComposed(
          recipientUid: recipient.uid,
          recipientDisplayName: recipient.displayName,
          subject: subject,
          body: body,
          linkBuilder: builder,
        );
        sent++;
      } catch (_) {
        failed++;
      }
    }

    // Log to message_log
    try {
      final entry = MessageLogEntry(
        sentBy: config.organizerUid,
        sentAt: DateTime.now(),
        type: type,
        subject: subject,
        body: body,
        recipients: config.recipients,
        contextType: config.contextType,
        contextId: config.contextId,
        deliveryCount: sent,
        expireAt: DateTime.now().add(const Duration(days: 90)),
      );
      await _firebase.logMessage(entry);
    } catch (_) {
      // Logging failure should not surface to user
    }

    // postSendAction (e.g. update requestSentAt)
    try {
      await config.postSendAction?.call();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _sending = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Sent to $sent'
              : 'Sent: $sent, failed: $failed',
        ),
      ),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final recipients = config.recipients;
    final showTypeDropdown = config.availableTypes.length > 1;
    final usesLink = MessageTemplates.usesLink(_selectedType);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compose Message'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── To ────────────────────────────────────────────────────
          _SectionLabel(label: 'To'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ...recipients.take(5).map((r) => Chip(
                label: Text(r.displayName, style: const TextStyle(fontSize: 13)),
                visualDensity: VisualDensity.compact,
              )),
              if (recipients.length > 5)
                Chip(
                  label: Text('+${recipients.length - 5} more', style: const TextStyle(fontSize: 13)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Colors.grey.shade200,
                ),
            ],
          ),
          const Divider(height: 24),

          // ── Type dropdown (hidden when only 1 type) ───────────────
          if (showTypeDropdown) ...[
            _SectionLabel(label: 'Type'),
            const SizedBox(height: 6),
            InputDecorator(
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MessageType>(
                  value: _selectedType,
                  isDense: true,
                  isExpanded: true,
                  items: config.availableTypes.map((t) => DropdownMenuItem(
                    value: t,
                    child: Text(MessageTemplates.displayName(t)),
                  )).toList(),
                  onChanged: (t) { if (t != null) _switchType(t); },
                ),
              ),
            ),
            const Divider(height: 24),
          ],

          // ── Subject ───────────────────────────────────────────────
          _SectionLabel(label: 'Subject'),
          const SizedBox(height: 6),
          TextField(
            controller: _subjectCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const Divider(height: 24),

          // ── Body ──────────────────────────────────────────────────
          _SectionLabel(label: 'Message'),
          const SizedBox(height: 6),
          TextField(
            controller: _bodyCtrl,
            maxLines: 8,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '{playerName} → each recipient\'s name'
            '${usesLink ? '\n{link} → per-player URL' : ''}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 24),

          // ── Actions ───────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _sending ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 16),
                label: Text(_sending ? 'Sending…' : 'Send to ${recipients.length}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                ),
                onPressed: _sending || recipients.isEmpty ? null : _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
  );
}
