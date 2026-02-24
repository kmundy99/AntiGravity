import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../create_match.dart'; // Ensure CreateMatchScreen accepts initial data for cloning

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .where(
            'status',
            isEqualTo: 'Completed',
          ) // Assumes a weekly job marks them Completed
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

        // Sort descending in memory to avoid requiring Firestore composite indexes
        docs.sort((a, b) {
          final timeA =
              (a['match_date'] as Timestamp?)?.toDate() ?? DateTime(0);
          final timeB =
              (b['match_date'] as Timestamp?)?.toDate() ?? DateTime(0);
          return timeB.compareTo(timeA);
        });

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final match = Match.fromFirestore(doc);

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                title: Text(
                  match.location,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  "${match.matchDate.toString().split(' ')[0]} | Players: ${match.roster.where((r) => r.status == RosterStatus.accepted).length}",
                ),
                trailing: ElevatedButton(
                  onPressed: () {
                    // Navigate to CreateMatchScreen with cloned data
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            const CreateMatchScreen(), // Assume this handles cloning later
                      ),
                    );
                  },
                  child: const Text("Rematch"),
                ),
                onTap: () {
                  // Navigate to Read-Only Chat or History Detail
                },
              ),
            );
          },
        );
      },
    );
  }
}
