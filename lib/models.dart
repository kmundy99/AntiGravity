import 'package:cloud_firestore/cloud_firestore.dart';

enum AccountStatus { provisional, fully_registered }

class BlackoutPeriod {
  final DateTime start;
  final DateTime end;
  final String? reason;

  BlackoutPeriod({required this.start, required this.end, this.reason});

  factory BlackoutPeriod.fromMap(Map<String, dynamic> map) => BlackoutPeriod(
    start: (map['start'] as Timestamp).toDate(),
    end: (map['end'] as Timestamp).toDate(),
    reason: map['reason'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'start': Timestamp.fromDate(start),
    'end': Timestamp.fromDate(end),
    if (reason != null && reason!.isNotEmpty) 'reason': reason,
  };
}

class User {
  /// Firestore document ID — a stable UUID, NOT the phone/email.
  final String uid;
  final String displayName;
  final String primaryContact;
  final double ntrpLevel;
  final String gender;
  final String address;
  final String email;
  final String phoneNumber;
  final bool notifActive;
  final String notifMode;
  final AccountStatus accountStatus;
  final Map<String, int> circleRatings;
  final Timestamp? createdAt;
  final Timestamp? activatedAt;
  final Map<String, List<String>> weeklyAvailability;
  final List<BlackoutPeriod> blackouts;

  User({
    this.uid = '',
    required this.displayName,
    required this.primaryContact,
    required this.ntrpLevel,
    required this.gender,
    required this.address,
    required this.email,
    this.phoneNumber = '',
    required this.notifActive,
    required this.notifMode,
    required this.accountStatus,
    this.circleRatings = const {},
    this.createdAt,
    this.activatedAt,
    this.weeklyAvailability = const {},
    this.blackouts = const [],
  });

  factory User.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;

    // Fallback to the document ID if primary_contact isn't explicitly defined in the body
    String contact = data['primary_contact'] ?? '';
    if (contact.isEmpty) {
      contact = doc.id;
    }

    return User(
      uid: doc.id, // Firestore doc ID is the stable UUID
      displayName: data['display_name'] ?? '',
      primaryContact: contact,
      ntrpLevel: (data['ntrp_level'] ?? 0.0).toDouble(),
      gender: data['gender'] ?? '',
      address: data['address'] ?? '',
      email: data['email'] ?? '',
      phoneNumber: data['phone_number'] ?? '',
      notifActive: data['notif_active'] ?? true,
      notifMode: data['notif_mode'] ?? 'SMS',
      accountStatus: AccountStatus.values.firstWhere(
        (e) => e.toString() == 'AccountStatus.${data['accountStatus']}',
        orElse: () => AccountStatus.provisional,
      ),
      circleRatings:
          (data['circleRatings'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, value as int),
          ) ??
          {},
      createdAt: data['created_at'] as Timestamp?,
      activatedAt: data['activated_at'] as Timestamp?,
      weeklyAvailability: () {
        final raw = data['weekly_availability'] as Map<String, dynamic>?;
        if (raw == null) return <String, List<String>>{};
        return raw.map(
          (day, periods) => MapEntry(day, List<String>.from(periods as List)),
        );
      }(),
      blackouts:
          (data['blackouts'] as List<dynamic>?)
              ?.map(
                (e) => BlackoutPeriod.fromMap(Map<String, dynamic>.from(e)),
              )
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'display_name': displayName,
      'primary_contact': primaryContact,
      'ntrp_level': ntrpLevel,
      'gender': gender,
      'address': address,
      'email': email,
      'phone_number': phoneNumber,
      'notif_active': notifActive,
      'notif_mode': notifMode,
      'accountStatus': accountStatus.toString().split('.').last,
      'circleRatings': circleRatings,
      if (createdAt != null) 'created_at': createdAt,
      if (activatedAt != null) 'activated_at': activatedAt,
      if (weeklyAvailability.isNotEmpty) 'weekly_availability': weeklyAvailability,
      'blackouts': blackouts.map((b) => b.toMap()).toList(),
    };
  }
}

enum MatchStatus { Draft, Filling, Completed }

class Match {
  final String id;
  final String organizerId;
  final String location;
  final DateTime matchDate;
  final MatchStatus status;
  final List<Roster> roster;
  final int requiredCount;
  final double minNtrp;
  final double maxNtrp;
  final int currentTier;

  Match({
    this.id = '',
    required this.organizerId,
    required this.location,
    required this.matchDate,
    required this.status,
    required this.roster,
    this.requiredCount = 4,
    this.minNtrp = 0.0,
    this.maxNtrp = 7.0,
    this.currentTier = 1,
  });

  factory Match.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return Match(
      id: doc.id,
      organizerId: data['organizerId'] ?? '',
      location: data['location'] ?? '',
      matchDate: (data['match_date'] as Timestamp).toDate(),
      status: MatchStatus.values.firstWhere(
        (e) => e.toString() == 'MatchStatus.${data['status']}',
        orElse: () => MatchStatus.Draft,
      ),
      roster:
          (data['roster'] as List<dynamic>?)
              ?.map((e) => Roster.fromMap(e))
              .toList() ??
          [],
      requiredCount: data['playerLimit'] ?? data['requiredCount'] ?? 4,
      minNtrp: (data['minNtrp'] ?? 0.0).toDouble(),
      maxNtrp: (data['maxNtrp'] ?? 7.0).toDouble(),
      currentTier: data['currentTier'] ?? 1,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'organizerId': organizerId,
      'location': location,
      'match_date': Timestamp.fromDate(matchDate),
      'status': status.toString().split('.').last,
      'roster': roster.map((e) => e.toMap()).toList(),
      'requiredCount': requiredCount,
      'minNtrp': minNtrp,
      'maxNtrp': maxNtrp,
      'currentTier': currentTier,
    };
  }
}

enum RosterStatus { invited, accepted, declined, waitlisted }

class Roster {
  final String uid;
  final String displayName;
  final RosterStatus status;
  final Timestamp? waitlistTimestamp;
  final double? ntrpLevel;

  Roster({
    required this.uid,
    required this.displayName,
    required this.status,
    this.waitlistTimestamp,
    this.ntrpLevel,
  });

  factory Roster.fromMap(Map<String, dynamic> map) {
    return Roster(
      uid: map['uid'] ?? '',
      displayName: map['displayName'] ?? '',
      status: RosterStatus.values.firstWhere(
        (e) => e.toString() == 'RosterStatus.${map['status']}',
        orElse: () => RosterStatus.invited,
      ),
      waitlistTimestamp: map['waitlist_timestamp'] as Timestamp?,
      ntrpLevel: (map['ntrpLevel'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'displayName': displayName,
      'status': status.toString().split('.').last,
      'waitlist_timestamp': waitlistTimestamp,
      if (ntrpLevel != null) 'ntrpLevel': ntrpLevel,
    };
  }
}
