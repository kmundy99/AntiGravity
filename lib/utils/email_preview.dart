import 'package:flutter/material.dart';

/// Shows a preview dialog for an outgoing email.
///
/// Returns:
/// - `({send: true,  subject: ..., body: ...})` if the user clicked Send
/// - `({send: false, subject: ..., body: ...})` if the user clicked "Don't Send"
/// - `null` if the dialog was dismissed (back button / tap outside)
///
/// [recipientLabel] is a short description shown under the subject,
/// e.g. "John Smith" or "3 players".
Future<({bool send, String subject, String body})?> showEmailPreviewDialog({
  required BuildContext context,
  required String subject,
  required String body,
  required String recipientLabel,
  String sendLabel = 'Send',
  String skipLabel = "Don't Send",
}) async {
  final subjectCtrl = TextEditingController(text: subject);
  final bodyCtrl = TextEditingController(text: body);

  final result = await showDialog<({bool send, String subject, String body})>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text('Review Email'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To: $recipientLabel',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: subjectCtrl,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyCtrl,
              decoration: const InputDecoration(
                labelText: 'Message',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 7,
              minLines: 4,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            ctx,
            (send: false, subject: subjectCtrl.text, body: bodyCtrl.text),
          ),
          child: Text(skipLabel, style: const TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            ctx,
            (send: true, subject: subjectCtrl.text, body: bodyCtrl.text),
          ),
          child: Text(sendLabel),
        ),
      ],
    ),
  );

  subjectCtrl.dispose();
  bodyCtrl.dispose();
  return result;
}
