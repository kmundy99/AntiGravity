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
}
