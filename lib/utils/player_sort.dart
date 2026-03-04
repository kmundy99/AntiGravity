import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';

/// Sorts player documents: current user first, then by circle number
/// (unassigned last), then alphabetically by display name.
int sortPlayerDocs(
  QueryDocumentSnapshot a,
  QueryDocumentSnapshot b, {
  required String currentUserUid,
  required Map<String, int> circleRatings,
}) {
  if (a.id == currentUserUid) return -1;
  if (b.id == currentUserUid) return 1;

  final aCircle = circleRatings[a.id] ?? 999;
  final bCircle = circleRatings[b.id] ?? 999;

  if (aCircle != bCircle) return aCircle.compareTo(bCircle);

  final aUser = User.fromFirestore(a);
  final bUser = User.fromFirestore(b);
  return aUser.displayName.toLowerCase().compareTo(
    bUser.displayName.toLowerCase(),
  );
}
