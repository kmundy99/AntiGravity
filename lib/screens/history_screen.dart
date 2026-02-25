import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../create_match.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      // FIX: Query by date instead of status == 'Completed'
      // Nothing in the app ever sets status to 'Completed', so the old query
      // always returned zero results. Instead, show matches whose date has passed.
      stream: FirebaseFirestore.instance
          .collection('matches')
          .where(
            'match_date',
            isLessThan: Timestamp.fromDate(
              DateTime.now().subtract(const Duration(hours: 2)),
            ),
          )
          .orderBy('match_date', descending: true)
          .limit(50) // Reasonable cap to avoid loading thousands of old matches
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }
          return const Center(child: CircularProgressIndicator());
        }
        var docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return const Center(child: Text("No past matches. Go play!"));
        }

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final match = Match.fromFirestore(doc);
            final dateStr = DateFormat('M/d/yyyy').format(match.matchDate);
            final acceptedCount = match.roster
                .where((r) => r.status == RosterStatus.accepted)
                .length;

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                title: Text(
                  match.location,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text("$dateStr | Players: $acceptedCount"),
                // FIX: Rematch button now passes location + previous player UIDs
                trailing: ElevatedButton(
                  onPressed: () {
                    // Collect UIDs of previously accepted players (excluding organizer)
                    final previousPlayerUids = match.roster
                        .where(
                          (r) =>
                              r.status == RosterStatus.accepted &&
                              r.uid != match.organizerId,
                        )
                        .map((r) => r.uid)
                        .toList();

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CreateMatchScreen(
                          prefillLocation: match.location,
                          prefillPlayerUids: previousPlayerUids,
                        ),
                      ),
                    );
                  },
                  child: const Text("Rematch"),
                ),
                onTap: () {
                  // TODO: Navigate to Read-Only Chat or History Detail
                },
              ),
            );
          },
        );
      },
    );
  }
}
