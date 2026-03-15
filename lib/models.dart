import 'package:cloud_firestore/cloud_firestore.dart';

// ignore: constant_identifier_names
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
  final String? createdByUid; // UID of the user who created this provisional account
  final Timestamp? lastLoginAt;
  final bool isAdmin;
  final double defaultDistanceFilter;

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
    this.createdByUid,
    this.lastLoginAt,
    this.isAdmin = false,
    this.defaultDistanceFilter = 10.0,
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
      createdByUid: data['created_by_uid'] as String?,
      lastLoginAt: data['last_login_at'] as Timestamp?,
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
      isAdmin: data['isAdmin'] ?? data['is_admin'] ?? false,
      defaultDistanceFilter: (data['defaultDistanceFilter'] ?? 10.0).toDouble(),
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
      if (isAdmin) 'isAdmin': isAdmin,
      'defaultDistanceFilter': defaultDistanceFilter,
    };
  }
}

// ignore: constant_identifier_names
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

enum ContractStatus { draft, active, completed }

class ContractPlayer {
  final String uid;
  final String displayName;
  final String email;
  final String phone;
  final int paidSlots;
  final String shareLabel; // 'full' | 'half' | 'quarter' | 'custom'
  final String paymentStatus; // 'pending' | 'confirmed'
  final String? referredByUid;
  final String? notes;
  final int playedSlots;

  ContractPlayer({
    required this.uid,
    required this.displayName,
    this.email = '',
    this.phone = '',
    this.paidSlots = 0,
    this.shareLabel = 'custom',
    this.paymentStatus = 'pending',
    this.referredByUid,
    this.notes,
    this.playedSlots = 0,
  });

  factory ContractPlayer.fromMap(Map<String, dynamic> map) => ContractPlayer(
    uid: map['uid'] ?? '',
    displayName: map['display_name'] ?? '',
    email: map['email'] ?? '',
    phone: map['phone'] ?? '',
    paidSlots: map['paid_slots'] ?? 0,
    shareLabel: map['share_label'] ?? 'custom',
    paymentStatus: map['payment_status'] ?? 'pending',
    referredByUid: map['referred_by_uid'] as String?,
    notes: map['notes'] as String?,
    playedSlots: map['played_slots'] ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'display_name': displayName,
    'email': email,
    'phone': phone,
    'paid_slots': paidSlots,
    'share_label': shareLabel,
    'payment_status': paymentStatus,
    if (referredByUid != null) 'referred_by_uid': referredByUid,
    if (notes != null && notes!.isNotEmpty) 'notes': notes,
    'played_slots': playedSlots,
  };

  ContractPlayer copyWith({
    String? uid,
    String? displayName,
    String? email,
    String? phone,
    int? paidSlots,
    String? shareLabel,
    String? paymentStatus,
    String? referredByUid,
    String? notes,
    int? playedSlots,
  }) => ContractPlayer(
    uid: uid ?? this.uid,
    displayName: displayName ?? this.displayName,
    email: email ?? this.email,
    phone: phone ?? this.phone,
    paidSlots: paidSlots ?? this.paidSlots,
    shareLabel: shareLabel ?? this.shareLabel,
    paymentStatus: paymentStatus ?? this.paymentStatus,
    referredByUid: referredByUid ?? this.referredByUid,
    notes: notes ?? this.notes,
    playedSlots: playedSlots ?? this.playedSlots,
  );
}

class Contract {
  final String id;
  final String organizerId;
  final String clubName;
  final String clubAddress;
  final List<int> courtNumbers;
  final int courtsCount;
  final int weekday; // 1=Mon … 7=Sun (DateTime.weekday)
  final int startMinutes; // minutes from midnight
  final int endMinutes;
  final DateTime seasonStart;
  final DateTime seasonEnd;
  final List<DateTime> holidayDates;
  final ContractStatus status;
  final List<ContractPlayer> roster;
  final double totalContractCost; // What the organizer pays for the season
  final double pricePerSlot;      // Cost per individual court-session slot
  final String paymentInfo;       // Payment instructions shown to players
  final String organizerPin;      // Optional PIN to protect organizer actions
  final int notifAvailDaysBefore; // Days before session to send availability request
  final int notifPaymentWeeksBefore; // Weeks before season start to begin payment reminders
  final int notifLineupDaysBefore; // Days before session when lineup is auto-published
  final int notifLineupTimeMinutes; // Time of day for auto-publish, in minutes from midnight
  final int notifAvailTimeMinutes; // Time of day for availability request emails, in minutes from midnight (default 600 = 10am)
  final int notifAvailReminderHoursBefore; // Hours before lineup auto-publish to send non-responder reminder (default 24)
  final String notificationMode; // 'auto' | 'manual'
  final List<String> rosterUids; // Denormalized for Firestore array-contains queries
  final Map<String, Map<String, String>> emailTemplates; // Per-type subject/body overrides keyed by type string

  Contract({
    this.id = '',
    required this.organizerId,
    this.clubName = '',
    this.clubAddress = '',
    this.courtNumbers = const [],
    this.courtsCount = 1,
    this.weekday = 3,
    this.startMinutes = 540,
    this.endMinutes = 630,
    required this.seasonStart,
    required this.seasonEnd,
    this.holidayDates = const [],
    this.status = ContractStatus.draft,
    this.roster = const [],
    this.totalContractCost = 0,
    this.pricePerSlot = 0,
    this.paymentInfo = '',
    this.organizerPin = '',
    this.notifAvailDaysBefore = 7,
    this.notifPaymentWeeksBefore = 4,
    this.notifLineupDaysBefore = 2,
    this.notifLineupTimeMinutes = 600,
    this.notifAvailTimeMinutes = 600,
    this.notifAvailReminderHoursBefore = 24,
    this.notificationMode = 'auto',
    this.rosterUids = const [],
    this.emailTemplates = const {},
  });

  List<DateTime> get sessionDates {
    final dates = <DateTime>[];
    // Work in UTC-midnight dates to avoid DST boundary bugs.
    // DST transitions (e.g. spring-forward) can shift a 23:00 local Sunday to
    // 00:00 local Monday after adding Duration(days:7), silently skipping a session.
    DateTime current = DateTime.utc(seasonStart.year, seasonStart.month, seasonStart.day);
    final endUtc = DateTime.utc(seasonEnd.year, seasonEnd.month, seasonEnd.day);
    while (!current.isAfter(endUtc)) {
      if (current.weekday == weekday) {
        final isHoliday = holidayDates.any(
          (h) =>
              h.year == current.year &&
              h.month == current.month &&
              h.day == current.day,
        );
        if (!isHoliday) dates.add(current);
        current = current.add(const Duration(days: 7));
      } else {
        final daysUntil = (weekday - current.weekday + 7) % 7;
        current = current.add(Duration(days: daysUntil == 0 ? 7 : daysUntil));
      }
    }
    return dates;
  }

  int get totalSessions => sessionDates.length;

  int get spotsPerSession => courtsCount * 4;
  int get totalCourtSlots => spotsPerSession * totalSessions;
  int get committedSlots => roster.fold(0, (acc, p) => acc + p.paidSlots);

  factory Contract.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Contract(
      id: doc.id,
      organizerId: data['organizer_id'] ?? '',
      clubName: data['club_name'] ?? '',
      clubAddress: data['club_address'] ?? '',
      courtNumbers: List<int>.from(data['court_numbers'] ?? []),
      courtsCount: data['courts_count'] ?? 1,
      weekday: data['weekday'] ?? 3,
      startMinutes: data['start_minutes'] ?? 540,
      endMinutes: data['end_minutes'] ?? 630,
      seasonStart: (data['season_start'] as Timestamp).toDate(),
      seasonEnd: (data['season_end'] as Timestamp).toDate(),
      holidayDates:
          (data['holiday_dates'] as List<dynamic>?)
              ?.map((t) => (t as Timestamp).toDate())
              .toList() ??
          [],
      status: ContractStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ContractStatus.draft,
      ),
      roster:
          (data['roster'] as List<dynamic>?)
              ?.map((e) => ContractPlayer.fromMap(Map<String, dynamic>.from(e)))
              .toList() ??
          [],
      totalContractCost: (data['total_contract_cost'] ?? 0).toDouble(),
      pricePerSlot: (data['price_per_slot'] ?? 0).toDouble(),
      paymentInfo: data['payment_info'] ?? '',
      organizerPin: data['organizer_pin'] ?? '',
      notifAvailDaysBefore: data['notif_avail_days_before'] ?? 7,
      notifPaymentWeeksBefore: data['notif_payment_weeks_before'] ?? 4,
      notifLineupDaysBefore: data['notif_lineup_days_before'] ?? 2,
      notifLineupTimeMinutes: data['notif_lineup_time_minutes'] ?? 600,
      notifAvailTimeMinutes: data['notif_avail_time_minutes'] ?? 600,
      notifAvailReminderHoursBefore: data['notif_avail_reminder_hours_before'] ?? 24,
      notificationMode: data['notification_mode'] ?? 'auto',
      rosterUids: List<String>.from(data['roster_uids'] ?? []),
      emailTemplates: () {
        final raw = data['email_templates'] as Map<String, dynamic>?;
        if (raw == null) return <String, Map<String, String>>{};
        return raw.map((k, v) => MapEntry(
          k,
          Map<String, String>.from(v as Map<String, dynamic>? ?? {}),
        ));
      }(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'organizer_id': organizerId,
    'club_name': clubName,
    'club_address': clubAddress,
    'court_numbers': courtNumbers,
    'courts_count': courtsCount,
    'weekday': weekday,
    'start_minutes': startMinutes,
    'end_minutes': endMinutes,
    'season_start': Timestamp.fromDate(seasonStart),
    'season_end': Timestamp.fromDate(seasonEnd),
    'holiday_dates': holidayDates.map((d) => Timestamp.fromDate(d)).toList(),
    'status': status.name,
    'roster': roster.map((p) => p.toMap()).toList(),
    'total_contract_cost': totalContractCost,
    'price_per_slot': pricePerSlot,
    'payment_info': paymentInfo,
    'organizer_pin': organizerPin,
    'notif_avail_days_before': notifAvailDaysBefore,
    'notif_payment_weeks_before': notifPaymentWeeksBefore,
    'notif_lineup_days_before': notifLineupDaysBefore,
    'notif_lineup_time_minutes': notifLineupTimeMinutes,
    'notif_avail_time_minutes': notifAvailTimeMinutes,
    'notif_avail_reminder_hours_before': notifAvailReminderHoursBefore,
    'notification_mode': notificationMode,
    'roster_uids': rosterUids,
    if (emailTemplates.isNotEmpty) 'email_templates': emailTemplates,
  };
}

/// A single contract session document (subcollection `contracts/{id}/sessions/{YYYY-MM-DD}`).
/// [attendance] maps uid → 'played'|'reserve'|'out'|'charged'.
/// [availability] maps uid → 'available'|'backup'|'unavailable'.
/// [assignment] maps uid → 'confirmed'|'reserve'|'out'.
/// [assignmentState] is 'none'|'draft'|'published'.
/// [requestSentAt] records when the organizer last sent an availability request.
class ContractSession {
  final String id; // doc ID = 'YYYY-MM-DD'
  final DateTime date;
  final Map<String, String> attendance; // uid → state
  final Map<String, String> availability; // uid → 'available'|'backup'|'unavailable'
  final Map<String, String> assignment; // uid → 'confirmed'|'reserve'|'out'
  final String assignmentState; // 'none'|'draft'|'published'
  final DateTime? requestSentAt;

  ContractSession({
    required this.id,
    required this.date,
    required this.attendance,
    this.availability = const {},
    this.assignment = const {},
    this.assignmentState = 'none',
    this.requestSentAt,
  });

  factory ContractSession.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final rawAttendance = data['attendance'] as Map<String, dynamic>? ?? {};
    final rawAvailability = data['availability'] as Map<String, dynamic>? ?? {};
    final rawAssignment = data['assignment'] as Map<String, dynamic>? ?? {};
    final sentAt = data['request_sent_at'] as Timestamp?;
    return ContractSession(
      id: doc.id,
      date: (data['date'] as Timestamp).toDate(),
      attendance: rawAttendance.map((k, v) => MapEntry(k, v as String)),
      availability: rawAvailability.map((k, v) => MapEntry(k, v as String)),
      assignment: rawAssignment.map((k, v) => MapEntry(k, v as String)),
      assignmentState: data['assignment_state'] as String? ?? 'none',
      requestSentAt: sentAt?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'date': Timestamp.fromDate(date),
    'attendance': attendance,
    'availability': availability,
    'assignment': assignment,
    'assignment_state': assignmentState,
    if (requestSentAt != null) 'request_sent_at': Timestamp.fromDate(requestSentAt!),
  };

  ContractSession copyWith({
    Map<String, String>? attendance,
    Map<String, String>? availability,
    Map<String, String>? assignment,
    String? assignmentState,
    DateTime? requestSentAt,
  }) => ContractSession(
    id: id,
    date: date,
    attendance: attendance ?? this.attendance,
    availability: availability ?? this.availability,
    assignment: assignment ?? this.assignment,
    assignmentState: assignmentState ?? this.assignmentState,
    requestSentAt: requestSentAt ?? this.requestSentAt,
  );
}

/// A fully-rendered per-player email stored on a ScheduledMessage in approval mode.
class RenderedEmail {
  final String uid;
  final String displayName;
  final String subject;
  final String body;

  const RenderedEmail({
    required this.uid,
    required this.displayName,
    required this.subject,
    required this.body,
  });

  factory RenderedEmail.fromMap(Map<String, dynamic> map) => RenderedEmail(
    uid: map['uid'] ?? '',
    displayName: map['display_name'] ?? '',
    subject: map['subject'] ?? '',
    body: map['body'] ?? '',
  );

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'display_name': displayName,
    'subject': subject,
    'body': body,
  };

  RenderedEmail copyWith({
    String? uid,
    String? displayName,
    String? subject,
    String? body,
  }) {
    return RenderedEmail(
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      subject: subject ?? this.subject,
      body: body ?? this.body,
    );
  }
}

/// A scheduled auto-message (availability request or payment reminder).
/// Stored in the `scheduled_messages` Firestore collection.
/// [recipientsFilter] is applied at send time by the Cloud Function:
///   'all' → send to all recipients
///   'unpaid' → filter to roster players where paymentStatus == 'pending'
///   'no_response' → filter to players who haven't responded to the session's availability request
/// [status]: 'pending' | 'pending_approval' | 'sent' | 'cancelled'
///   'pending_approval' → CF has generated full content in [renderedEmails]; organizer must approve to send
class ScheduledMessage {
  final String id;
  final String contractId;
  final String organizerId;
  final String type; // 'availability_request' | 'availability_reminder' | 'payment_reminder' | 'lineup_publish' | etc.
  final DateTime? sessionDate; // null for payment reminders
  final DateTime? scheduledFor; // null = "on hold"; Cloud Function skips null-scheduled messages
  final String status; // 'pending' | 'pending_approval' | 'sent' | 'cancelled'
  final String subject;
  final String body;
  final List<RecipientInfo> recipients;
  final String recipientsFilter; // 'all' | 'unpaid' | 'no_response'
  final bool autoSendEnabled; // if false, CF generates drafts but never sends (organizer must approve)
  final List<RenderedEmail> renderedEmails; // fully resolved per-player emails (set in pending_approval state)
  final DateTime? generatedAt; // when CF generated the rendered content

  ScheduledMessage({
    this.id = '',
    required this.contractId,
    required this.organizerId,
    required this.type,
    this.sessionDate,
    this.scheduledFor,
    this.status = 'pending',
    required this.subject,
    required this.body,
    required this.recipients,
    this.recipientsFilter = 'all',
    this.autoSendEnabled = true,
    this.renderedEmails = const [],
    this.generatedAt,
  });

  factory ScheduledMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ScheduledMessage(
      id: doc.id,
      contractId: data['contract_id'] ?? '',
      organizerId: data['organizer_id'] ?? '',
      type: data['type'] ?? 'availability_request',
      sessionDate: (data['session_date'] as Timestamp?)?.toDate(),
      scheduledFor: (data['scheduled_for'] as Timestamp?)?.toDate(),
      status: data['status'] ?? 'pending',
      subject: data['subject'] ?? '',
      body: data['body'] ?? '',
      recipients: (data['recipients'] as List<dynamic>?)
          ?.map((e) => RecipientInfo.fromMap(Map<String, dynamic>.from(e)))
          .toList() ?? [],
      recipientsFilter: data['recipients_filter'] ?? 'all',
      autoSendEnabled: data['auto_send_enabled'] as bool? ?? true,
      renderedEmails: (data['rendered_emails'] as List<dynamic>?)
          ?.map((e) => RenderedEmail.fromMap(Map<String, dynamic>.from(e)))
          .toList() ?? [],
      generatedAt: (data['generated_at'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'contract_id': contractId,
    'organizer_id': organizerId,
    'type': type,
    if (sessionDate != null) 'session_date': Timestamp.fromDate(sessionDate!),
    if (scheduledFor != null) 'scheduled_for': Timestamp.fromDate(scheduledFor!),
    'status': status,
    'subject': subject,
    'body': body,
    'recipients': recipients.map((r) => r.toMap()).toList(),
    'recipients_filter': recipientsFilter,
    'auto_send_enabled': autoSendEnabled,
    'rendered_emails': renderedEmails.map((e) => e.toMap()).toList(),
    if (generatedAt != null) 'generated_at': Timestamp.fromDate(generatedAt!),
  };

  ScheduledMessage copyWith({
    String? status,
    String? subject,
    String? body,
    DateTime? scheduledFor,
    bool? autoSendEnabled,
    bool clearScheduledFor = false,
  }) => ScheduledMessage(
    id: id,
    contractId: contractId,
    organizerId: organizerId,
    type: type,
    sessionDate: sessionDate,
    scheduledFor: clearScheduledFor ? null : (scheduledFor ?? this.scheduledFor),
    status: status ?? this.status,
    subject: subject ?? this.subject,
    body: body ?? this.body,
    recipients: recipients,
    recipientsFilter: recipientsFilter,
    autoSendEnabled: autoSendEnabled ?? this.autoSendEnabled,
    renderedEmails: renderedEmails,
    generatedAt: generatedAt,
  );
}

enum RosterStatus { invited, accepted, declined, waitlisted }

// ===========================================================================
// MESSAGING MODELS
// ===========================================================================

enum MessageType { custom, matchInvite, contractInvite, paymentReminder, availabilityRequest, availabilityReminder, subRequest, sessionLineup, paymentConfirmation }

class RecipientInfo {
  final String uid;
  final String displayName;
  const RecipientInfo({required this.uid, required this.displayName});

  factory RecipientInfo.fromMap(Map<String, dynamic> map) => RecipientInfo(
    uid: map['uid'] ?? '',
    displayName: map['display_name'] ?? '',
  );

  Map<String, dynamic> toMap() => {'uid': uid, 'display_name': displayName};
}

class MessageLogEntry {
  String? id;
  final String sentBy;
  final DateTime sentAt;
  final MessageType type;
  final String subject;
  final String body;
  final List<RecipientInfo> recipients;
  final String contextType; // 'general' | 'match' | 'contract'
  final String? contextId;
  final int deliveryCount;
  final DateTime expireAt;

  MessageLogEntry({
    this.id,
    required this.sentBy,
    required this.sentAt,
    required this.type,
    required this.subject,
    required this.body,
    required this.recipients,
    required this.contextType,
    this.contextId,
    required this.deliveryCount,
    required this.expireAt,
  });

  factory MessageLogEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageLogEntry(
      id: doc.id,
      sentBy: data['sent_by'] ?? '',
      sentAt: (data['sent_at'] as Timestamp).toDate(),
      type: MessageType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => MessageType.custom,
      ),
      subject: data['subject'] ?? '',
      body: data['body'] ?? '',
      recipients: (data['recipients'] as List<dynamic>?)
          ?.map((e) => RecipientInfo.fromMap(Map<String, dynamic>.from(e)))
          .toList() ?? [],
      contextType: data['context_type'] ?? 'general',
      contextId: data['context_id'] as String?,
      deliveryCount: data['delivery_count'] ?? 0,
      expireAt: (data['expire_at'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'sent_by': sentBy,
    'sent_at': Timestamp.fromDate(sentAt),
    'type': type.name,
    'subject': subject,
    'body': body,
    'recipients': recipients.map((r) => r.toMap()).toList(),
    'context_type': contextType,
    if (contextId != null) 'context_id': contextId,
    'delivery_count': deliveryCount,
    'expire_at': Timestamp.fromDate(expireAt),
  };
}

class ComposeMessageConfig {
  final String organizerUid;
  final String organizerName;
  final List<MessageType> availableTypes;
  final MessageType initialType;
  final List<RecipientInfo> recipients;
  final String contextType; // 'general' | 'match' | 'contract'
  final String? contextId;
  final Contract? contract;
  final Match? match;
  final DateTime? sessionDate;
  final List<ContractPlayer>? contractRosterPlayers;
  final Map<String, String>? sessionAssignment; // uid → 'confirmed'|'reserve'|'out'
  final Future<void> Function()? postSendAction;

  const ComposeMessageConfig({
    this.organizerUid = '',
    this.organizerName = '',
    required this.availableTypes,
    required this.initialType,
    required this.recipients,
    this.contextType = 'general',
    this.contextId,
    this.contract,
    this.match,
    this.sessionDate,
    this.contractRosterPlayers,
    this.sessionAssignment,
    this.postSendAction,
  });
}

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
