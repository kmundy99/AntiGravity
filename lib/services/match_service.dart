import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import 'notification_service.dart';

class MatchService {
  static final _matchesRef = FirebaseFirestore.instance.collection('matches');

  // ---------------------------------------------------------------------------
  // RECRUITMENT (existing, now with awaited notifications)
  // ---------------------------------------------------------------------------

  /// Unifies the recruitment flow by handling deduplication, role assignment,
  /// database updates, and email/SMS trigger generation in a single pass.
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
      final contactId = recruit.primaryContact;
      if (contactId.isEmpty) continue;
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

    // Write to Firestore
    final mapsToAdd = newRosterEntries.map((r) => r.toMap()).toList();
    await _matchesRef.doc(matchId).update({
      'roster': FieldValue.arrayUnion(mapsToAdd),
    });

    // Dispatch notifications — await all so errors aren't swallowed
    final futures = <Future>[];
    for (final entry in newRosterEntries) {
      futures.add(
        NotificationService.sendInvite(
          contact: entry.uid,
          match: match,
          matchId: matchId,
          organizerName: organizerName,
          isSms: !entry.uid.contains('@'),
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
  // ACCEPT INVITE — player moves from `invited` → `accepted`
  // ---------------------------------------------------------------------------

  /// Accepts a pending invite for [playerUid] in match [matchId].
  /// Reads the current roster from Firestore, flips the status, and writes back.
  /// Returns `true` if the accept succeeded, `false` if the match was full or
  /// the player wasn't found in the roster.
  static Future<bool> acceptInvite({
    required String matchId,
    required String playerUid,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return false;

    final match = Match.fromFirestore(doc);
    final roster = List<Roster>.from(match.roster);

    final idx = roster.indexWhere((r) => r.uid == playerUid);
    if (idx == -1) return false; // not in roster

    // Check capacity before accepting
    final acceptedCount = roster
        .where((r) => r.status == RosterStatus.accepted)
        .length;
    if (acceptedCount >= match.requiredCount) {
      // Match is full — could offer waitlist instead
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
  // DECLINE INVITE — player moves from `invited` → `declined` (preserves record)
  // ---------------------------------------------------------------------------

  /// Declines a pending invite for [playerUid].
  /// Sets status to `declined` instead of deleting, so the player isn't
  /// accidentally re-invited and we keep an audit trail.
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
  // JOIN MATCH — a non-invited player adds themselves (from calendar feed)
  // ---------------------------------------------------------------------------

  /// Adds a player who was NOT previously invited. Enforces capacity limit.
  /// Returns a [JoinResult] indicating success, full, or waitlisted.
  static Future<JoinResult> joinMatch({
    required String matchId,
    required String playerUid,
    required String playerDisplayName,
    double? playerNtrpLevel,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return JoinResult.error;

    final match = Match.fromFirestore(doc);

    // Guard: already in roster?
    if (match.roster.any((r) => r.uid == playerUid)) {
      return JoinResult.alreadyInRoster;
    }

    final acceptedCount = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .length;

    if (acceptedCount < match.requiredCount) {
      // Slot available — join as accepted
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

    // Match is full — check waitlist availability (N+1 rule: exactly 1 waitlist spot)
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
  // REMOVE ME — an accepted player opts out; triggers waitlist promotion
  // ---------------------------------------------------------------------------

  /// Removes the current player from the roster, notifies the organizer,
  /// and auto-promotes a waitlisted player if one exists.
  static Future<void> removeMe({
    required String matchId,
    required String playerUid,
    required String playerDisplayName,
  }) async {
    final doc = await _matchesRef.doc(matchId).get();
    if (!doc.exists) return;

    final match = Match.fromFirestore(doc);
    final roster = List<Roster>.from(match.roster);

    // Remove the player
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

    // Write the updated roster
    await _matchesRef.doc(matchId).update({
      'roster': roster.map((r) => r.toMap()).toList(),
    });

    // Notify organizer about the drop-out
    await NotificationService.notifyOrganizerDropOut(
      match: match,
      matchId: matchId,
      playerName: playerDisplayName,
    );

    // If someone was promoted from waitlist, notify them too
    if (promotedPlayerUid != null && promotedPlayerUid.isNotEmpty) {
      final isSms = !promotedPlayerUid.contains('@');
      final promotedName = waitlisted.first.displayName;
      await NotificationService.sendMatchUpdate(
        contact: promotedPlayerUid,
        message:
            "Great news, $promotedName! A spot opened up and you've been moved from the waitlist to the confirmed roster. See you on the court!",
      );
    }
  }
}

/// Result of a [MatchService.joinMatch] attempt.
enum JoinResult { accepted, waitlisted, full, alreadyInRoster, error }
