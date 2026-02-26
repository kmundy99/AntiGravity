import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/feedback_utils.dart';
import '../services/notification_service.dart';

class MatchChatScreen extends StatefulWidget {
  final String matchId;
  final String currentUserId;
  final String currentUserName;

  const MatchChatScreen({
    super.key,
    required this.matchId,
    required this.currentUserId,
    required this.currentUserName,
  });

  @override
  State<MatchChatScreen> createState() => _MatchChatScreenState();
}

class _MatchChatScreenState extends State<MatchChatScreen> {
  final TextEditingController _msgCtrl = TextEditingController();

  void _sendMessage() async {
    if (_msgCtrl.text.isEmpty) return;

    final text = _msgCtrl.text;

    await FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.matchId)
        .collection('messages')
        .add({
          'text': text,
          'senderId': widget.currentUserId,
          'senderName': widget.currentUserName,
          'timestamp': FieldValue.serverTimestamp(),
        });

    _msgCtrl.clear();

    try {
      final matchDoc = await FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .get();
      if (matchDoc.exists) {
        final matchData = matchDoc.data() as Map<String, dynamic>;
        final roster = matchData['roster'] as List<dynamic>? ?? [];

        for (var p in roster) {
          final r = p as Map<String, dynamic>;
          final uid = r['uid'] as String? ?? '';
          if (uid != widget.currentUserId &&
              uid.isNotEmpty &&
              !uid.startsWith('shadow_')) {
            NotificationService.sendChatNotification(
              contact: uid,
              matchId: widget.matchId,
              senderName: widget.currentUserName,
              messagePreview: text,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to send chat notifications: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Match Chat")),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 60.0), // Above the text input
        child: FloatingActionButton(
          heroTag: 'feedbackBtnMatchChat',
          onPressed: () {
            showFeedbackModal(
              context,
              widget.currentUserId,
              widget.currentUserName,
              "Match Chat Screen",
            );
          },
          backgroundColor: Colors.amber.shade300,
          foregroundColor: Colors.black87,
          child: const Icon(Icons.lightbulb_outline),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('matches')
                  .doc(widget.matchId)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data!.docs;
                return ListView.builder(
                  reverse: true,
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final msg = docs[index].data() as Map<String, dynamic>;
                    final isMe = msg['senderId'] == widget.currentUserId;

                    return Align(
                      alignment: isMe
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Colors.blue.shade100
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: isMe
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg['senderName'] ?? '',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            Text(msg['text'] ?? ''),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgCtrl,
                    decoration: const InputDecoration(
                      hintText: "Type a message...",
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.blue),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
