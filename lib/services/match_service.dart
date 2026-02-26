import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import 'notification_service.dart';

class MatchService {
  static final _matchesRef = FirebaseFirestore.instance.collection('matches');

  // ---------------------------------------------------------------------------
  // RECRUITMENT
  // ---------------------------------------------------------------------------

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

    for (final recruit in newRecruits) {
      // UUID MIGRATION: Use recruit.uid (Firestore doc ID) instead of primaryContact
      final recruitUid = recruit.uid;
      if (recruitUid.isEmpty) continue;
      if (existingUids.contains(recruitUid)) continue;

      newRosterEntries.add(
        Roster(
          uid: recruitUid,
          displayName: recruit.displayName,
          status: RosterStatus.invited,
          ntrpLevel: recruit.ntrpLevel,
        ),
      );
    }

    if (newRosterEntries.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Selected players are already in the match or invalid.',
            ),
          ),
        );
      }
      return;
    }

    final mapsToAdd = newRosterEntries.map((r) => r.toMap()).toList();
    await _matchesRef.doc(matchId).update({
      'roster': FieldValue.arrayUnion(mapsToAdd),
    });

    final futures = <Future>[];
    for (final entry in newRosterEntries) {
      futures.add(
        NotificationService.sendInvite(
          contact: entry.uid, // UUID
          match: match,
          matchId: matchId,
          organizerName: organizerName,
          isSms: false, // kept for API compatibility; _send() handles routing
        ),
      );
    }
    await Future.wait(futures, eagerError: false);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invited ${newRosterEntries.length} new players!'),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // ACCEPT INVITE
  // ---------------------------------------------------------------------------

  static Future<bool> acceptInvite({
    required String matchId,
    required String playerUid,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return false;

    final match = Match.fromFirestore(doc);
    final roster = List<Roster>.from(match.roster);

    final idx = roster.indexWhere((r) => r.uid == playerUid);
    if (idx == -1) return false;

    final acceptedCount = roster
        .where((r) => r.status == RosterStatus.accepted)
        .length;
    if (acceptedCount >= match.requiredCount) {
      return false;
    }

    roster[idx] = Roster(
      uid: roster[idx].uid,
      displayName: roster[idx].displayName,
      status: RosterStatus.accepted,
      waitlistTimestamp: roster[idx].waitlistTimestamp,
      ntrpLevel: roster[idx].ntrpLevel,
    );

    await _matchesRef.doc(matchId).update({
      'roster': roster.map((r) => r.toMap()).toList(),
    });

    return true;
  }

  // ---------------------------------------------------------------------------
  // DECLINE INVITE
  // ---------------------------------------------------------------------------

  static Future<void> declineInvite({
    required String matchId,
    required String playerUid,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return;

    final match = Match.fromFirestore(doc);
    final roster = List<Roster>.from(match.roster);

    final idx = roster.indexWhere((r) => r.uid == playerUid);
    if (idx == -1) return;

    roster[idx] = Roster(
      uid: roster[idx].uid,
      displayName: roster[idx].displayName,
      status: RosterStatus.declined,
      waitlistTimestamp: roster[idx].waitlistTimestamp,
      ntrpLevel: roster[idx].ntrpLevel,
    );

    await _matchesRef.doc(matchId).update({
      'roster': roster.map((r) => r.toMap()).toList(),
    });
  }

  // ---------------------------------------------------------------------------
  // JOIN MATCH
  // ---------------------------------------------------------------------------

  static Future<JoinResult> joinMatch({
    required String matchId,
    required String playerUid,
    required String playerDisplayName,
    double? playerNtrpLevel,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return JoinResult.error;

    final match = Match.fromFirestore(doc);

    if (match.roster.any((r) => r.uid == playerUid)) {
      return JoinResult.alreadyInRoster;
    }

    final acceptedCount = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .length;

    if (acceptedCount < match.requiredCount) {
      final newEntry = Roster(
        uid: playerUid,
        displayName: playerDisplayName,
        status: RosterStatus.accepted,
        ntrpLevel: playerNtrpLevel,
      );

      await _matchesRef.doc(matchId).update({
        'roster': FieldValue.arrayUnion([newEntry.toMap()]),
      });

      return JoinResult.accepted;
    }

    final waitlistCount = match.roster
        .where((r) => r.status == RosterStatus.waitlisted)
        .length;

    if (waitlistCount < 1) {
      final newEntry = Roster(
        uid: playerUid,
        displayName: playerDisplayName,
        status: RosterStatus.waitlisted,
        waitlistTimestamp: Timestamp.now(),
        ntrpLevel: playerNtrpLevel,
      );

      await _matchesRef.doc(matchId).update({
        'roster': FieldValue.arrayUnion([newEntry.toMap()]),
      });

      return JoinResult.waitlisted;
    }

    return JoinResult.full;
  }

  // ---------------------------------------------------------------------------
  // REMOVE ME
  // ---------------------------------------------------------------------------

  static Future<void> removeMe({
    required String matchId,
    required String playerUid,
    required String playerDisplayName,
    String? note,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return;

    final match = Match.fromFirestore(doc);
    final roster = List<Roster>.from(match.roster);

    roster.removeWhere((r) => r.uid == playerUid);

    // Auto-promote waitlisted player (earliest timestamp wins)
    final waitlisted =
        roster.where((r) => r.status == RosterStatus.waitlisted).toList()
          ..sort((a, b) {
            final aTime = a.waitlistTimestamp?.millisecondsSinceEpoch ?? 0;
            final bTime = b.waitlistTimestamp?.millisecondsSinceEpoch ?? 0;
            return aTime.compareTo(bTime);
          });

    String? promotedPlayerUid;
    if (waitlisted.isNotEmpty) {
      final promoted = waitlisted.first;
      final idx = roster.indexWhere((r) => r.uid == promoted.uid);
      if (idx != -1) {
        roster[idx] = Roster(
          uid: promoted.uid,
          displayName: promoted.displayName,
          status: RosterStatus.accepted,
          ntrpLevel: promoted.ntrpLevel,
        );
        promotedPlayerUid = promoted.uid;
      }
    }

    await _matchesRef.doc(matchId).update({
      'roster': roster.map((r) => r.toMap()).toList(),
    });

    await NotificationService.notifyOrganizerDropOut(
      match: match,
      matchId: matchId,
      playerName: playerDisplayName,
      note: note,
    );

    if (promotedPlayerUid != null && promotedPlayerUid.isNotEmpty) {
      final promotedName = waitlisted.first.displayName;
      await NotificationService.sendMatchUpdate(
        contact: promotedPlayerUid,
        message:
            "Great news, $promotedName! A spot opened up and you've been moved from the waitlist to the confirmed roster. See you on the court!",
      );
    }
  }
}

enum JoinResult { accepted, waitlisted, full, alreadyInRoster, error }
