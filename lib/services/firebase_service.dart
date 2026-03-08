import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';

class FirebaseService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> saveUser(User user, String phone) async {
    await _db
        .collection('users')
        .doc(phone)
        .set(user.toFirestore(), SetOptions(merge: true));
  }

  Future<User?> getUser(String phone) async {
    final doc = await _db.collection('users').doc(phone).get();
    if (doc.exists) {
      return User.fromFirestore(doc);
    }
    return null;
  }

  Future<void> createMatch(Match match) async {
    await _db.collection('matches').add(match.toFirestore());
  }

  Stream<List<Match>> getMatchesStream() {
    return _db.collection('matches').orderBy('match_date').snapshots().map((
      snapshot,
    ) {
      return snapshot.docs.map((doc) => Match.fromFirestore(doc)).toList();
    });
  }

  Stream<List<User>> getAllUsersStream() {
    return _db.collection('users').snapshots().map(
      (snap) => snap.docs.map((d) => User.fromFirestore(d)).toList(),
    );
  }

  Future<String> createContract(Contract contract) async {
    final ref = await _db.collection('contracts').add(contract.toFirestore());
    return ref.id;
  }

  Future<void> updateContract(String id, Map<String, dynamic> fields) async {
    await _db.collection('contracts').doc(id).update(fields);
  }

  Stream<Contract?> getContractByOrganizer(String organizerUid) {
    return _db
        .collection('contracts')
        .where('organizer_id', isEqualTo: organizerUid)
        .limit(1)
        .snapshots()
        .map((snap) {
          if (snap.docs.isEmpty) return null;
          return Contract.fromFirestore(snap.docs.first);
        });
  }

  Stream<Contract?> getContractStream(String contractId) {
    return _db
        .collection('contracts')
        .doc(contractId)
        .snapshots()
        .map((snap) => snap.exists ? Contract.fromFirestore(snap) : null);
  }

  Stream<List<ContractSession>> getSessionsStream(String contractId) {
    return _db
        .collection('contracts')
        .doc(contractId)
        .collection('sessions')
        .orderBy('date')
        .snapshots()
        .map((snap) => snap.docs.map(ContractSession.fromFirestore).toList());
  }

  Future<void> upsertSession(String contractId, ContractSession session) async {
    await _db
        .collection('contracts')
        .doc(contractId)
        .collection('sessions')
        .doc(session.id)
        .set(session.toFirestore(), SetOptions(merge: true));
  }

  /// Removes a single uid key from a session's attendance map.
  /// Must use FieldValue.delete() — set(merge:true) cannot remove map keys.
  Future<void> clearAttendanceEntry(
      String contractId, String sessionId, String uid) async {
    await _db
        .collection('contracts')
        .doc(contractId)
        .collection('sessions')
        .doc(sessionId)
        .update({'attendance.$uid': FieldValue.delete()});
  }

  Future<void> logMessage(MessageLogEntry entry) async {
    final now = DateTime.now();
    final data = entry.toFirestore();
    data['sent_at'] = Timestamp.fromDate(now);
    data['expire_at'] = Timestamp.fromDate(now.add(const Duration(days: 90)));
    await _db.collection('message_log').add(data);
  }

  Stream<List<MessageLogEntry>> getSentMessagesStream(
    String sentBy, {
    String? contextId,
  }) {
    Query query = _db
        .collection('message_log')
        .where('sent_by', isEqualTo: sentBy)
        .orderBy('sent_at', descending: true);
    if (contextId != null) {
      query = query.where('context_id', isEqualTo: contextId);
    }
    return query.snapshots().map(
      (snap) => snap.docs.map(MessageLogEntry.fromFirestore).toList(),
    );
  }

  // ── Scheduled Messages ──────────────────────────────────────────────────────

  Stream<List<ScheduledMessage>> getScheduledMessagesStream(String organizerId) {
    return _db
        .collection('scheduled_messages')
        .where('organizer_id', isEqualTo: organizerId)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map(ScheduledMessage.fromFirestore).toList();
          list.sort((a, b) {
            if (a.scheduledFor == null && b.scheduledFor == null) return 0;
            if (a.scheduledFor == null) return 1;
            if (b.scheduledFor == null) return -1;
            return a.scheduledFor!.compareTo(b.scheduledFor!);
          });
          return list;
        });
  }

  /// Cancels all existing pending scheduled messages for [contractId],
  /// then batch-writes [messages].
  Future<void> saveScheduledMessages(
    String contractId,
    List<ScheduledMessage> messages,
  ) async {
    final batch = _db.batch();

    // Cancel existing pending messages for this contract
    // Single-field query only — no composite index required
    final existing = await _db
        .collection('scheduled_messages')
        .where('contract_id', isEqualTo: contractId)
        .get();
    for (final doc in existing.docs) {
      final s = doc.data()['status'];
      if (s == 'pending' || s == 'pending_approval') {
        batch.update(doc.reference, {'status': 'cancelled'});
      }
    }

    // Write new messages
    for (final msg in messages) {
      final ref = _db.collection('scheduled_messages').doc();
      batch.set(ref, msg.toFirestore());
    }

    await batch.commit();
  }

  Future<void> updateScheduledMessage(String id, Map<String, dynamic> fields) async {
    await _db.collection('scheduled_messages').doc(id).update(fields);
  }

  Future<void> deleteScheduledMessage(String id) async {
    await _db.collection('scheduled_messages').doc(id).delete();
  }

  /// Resets all `pending_approval` ScheduledMessage docs for a given contract + session date key
  /// back to `pending` status, clearing rendered content. This allows regeneration.
  Future<void> deleteApprovalDraftsForSession(String contractId, String sessionDateKey, {String? messageType}) async {
    final snap = await _db
        .collection('scheduled_messages')
        .where('contract_id', isEqualTo: contractId)
        .get();
    final batch = _db.batch();
    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['status'] != 'pending_approval') continue;
      if (messageType != null && data['type'] != messageType) continue;
      final sd = (data['session_date'] as Timestamp?)?.toDate().toUtc();
      if (sd == null) continue;
      final key = '${sd.year}-${sd.month.toString().padLeft(2, '0')}-${sd.day.toString().padLeft(2, '0')}';
      if (key == sessionDateKey) {
        batch.update(doc.reference, {
          'status': 'pending',
          'rendered_emails': FieldValue.delete(),
          'generated_at': FieldValue.delete(),
        });
      }
    }
    await batch.commit();
  }

  Future<List<User>> searchUsers(String query) async {
    final snap = await _db.collection('users').get();
    final lq = query.toLowerCase();
    return snap.docs
        .map(User.fromFirestore)
        .where((u) =>
            u.displayName.toLowerCase().contains(lq) ||
            u.email.toLowerCase().contains(lq))
        .toList();
  }

  Future<void> transferContractOwnership(
      String contractId, String newOrganizerUid) async {
    await _db.collection('contracts').doc(contractId).update({
      'organizer_id': newOrganizerUid,
    });
  }

  // ── Player Contract Lookup ──────────────────────────────────────────────────

  /// Returns all contracts where the given player UID is in [roster_uids].
  /// Requires a Firestore composite index on (roster_uids array-contains).
  Stream<List<Contract>> getContractsByPlayer(String playerUid) {
    return _db
        .collection('contracts')
        .where('roster_uids', arrayContains: playerUid)
        .snapshots()
        .map((snap) => snap.docs.map(Contract.fromFirestore).toList());
  }
}
