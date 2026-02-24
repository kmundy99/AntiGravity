import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import 'notification_service.dart';

class MatchService {
  /// Unifies the recruitment flow by handling deduplication, role assignment, database updates,
  /// and email/SMS trigger generation in a single pass.
  static Future<void> addPlayersToMatch({
    required BuildContext context,
    required Match match,
    required String matchId,
    required List<User> newRecruits,
    required String organizerName,
  }) async {
    if (newRecruits.isEmpty) return;

    final existingUids = match.roster.map((r) => r.uid).toSet();
    final newRosterEntries = <Roster>[];

    // 1. Deduplicate & construct Roster objects
    for (final recruit in newRecruits) {
      final contactId = recruit.primaryContact;

      // Skip if somehow empty (though fromFirestore now guarantees it exists as doc.id)
      if (contactId.isEmpty) continue;

      // Skip if they are already in the roster
      if (existingUids.contains(contactId)) continue;

      newRosterEntries.add(
        Roster(
          uid: contactId,
          displayName: recruit.displayName,
          status: RosterStatus.invited,
          ntrpLevel: recruit.ntrpLevel,
        ),
      );
    }

    if (newRosterEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selected players are already in the match or invalid.',
          ),
        ),
      );
      return;
    }

    // 2. Transact changes to Firestore
    final mapsToAdd = newRosterEntries.map((r) => r.toMap()).toList();
    await FirebaseFirestore.instance.collection('matches').doc(matchId).update({
      'roster': FieldValue.arrayUnion(mapsToAdd),
    });

    // 3. Dispatch Emails/SMS
    for (final recruit in newRecruits) {
      final contact = recruit.primaryContact;
      if (contact.isNotEmpty && !existingUids.contains(contact)) {
        NotificationService.sendInvite(
          contact: contact,
          match: match,
          matchId: matchId,
          organizerName: organizerName,
          isSms: !contact.contains('@'),
        );
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invited ${newRosterEntries.length} new players!'),
        ),
      );
    }
  }
}
