import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'match_chat_screen.dart';

class ChatListScreen extends StatelessWidget {
  final String currentUserUid;
  final String currentUserName;

  const ChatListScreen({
    super.key,
    required this.currentUserUid,
    required this.currentUserName,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('matches').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());

        final docs = snapshot.data!.docs;

        final myMatches = docs.where((doc) {
          final matchData = doc.data() as Map<String, dynamic>;
          final List roster = matchData['roster'] ?? [];
          return roster.any((r) => r['uid'] == currentUserUid) ||
              matchData['organizerId'] == currentUserUid;
        }).toList();

        if (myMatches.isEmpty)
          return const Center(child: Text("No active chats"));

        return ListView.builder(
          itemCount: myMatches.length,
          itemBuilder: (context, index) {
            final doc = myMatches[index];
            final matchData = doc.data() as Map<String, dynamic>;
            final lastMessageAt = matchData['lastMessageAt'] as Timestamp?;

            return FutureBuilder<bool>(
              future: _hasUnread(doc.id, lastMessageAt),
              builder: (context, unreadSnap) {
                final hasUnread = unreadSnap.data ?? false;
                return ListTile(
                  leading: Badge(
                    isLabelVisible: hasUnread,
                    backgroundColor: Colors.red,
                    smallSize: 10,
                    child: const Icon(Icons.chat),
                  ),
                  title: Text(
                    "Chat: ${matchData['location'] ?? 'Match'}",
                    style: TextStyle(
                      fontWeight: hasUnread
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: hasUnread
                      ? Text(
                          "new",
                          style: TextStyle(
                            color: Colors.orange.shade700,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MatchChatScreen(
                          matchId: doc.id,
                          currentUserId: currentUserUid,
                          currentUserName: currentUserName,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<bool> _hasUnread(String matchId, Timestamp? lastMessageAt) async {
    if (lastMessageAt == null) return false;
    try {
      final readDoc = await FirebaseFirestore.instance
          .collection('matches')
          .doc(matchId)
          .collection('chatReads')
          .doc(currentUserUid)
          .get();
      if (!readDoc.exists) return true;
      final readAt = readDoc.data()?['readAt'] as Timestamp?;
      if (readAt == null) return true;
      return lastMessageAt.millisecondsSinceEpoch >
          readAt.millisecondsSinceEpoch;
    } catch (_) {
      return false;
    }
  }
}
