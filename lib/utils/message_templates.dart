import '../models.dart';
import 'package:intl/intl.dart';
import 'link_utils.dart';

class MessageTemplates {
  static String displayName(MessageType type) => switch (type) {
    MessageType.custom => 'Custom Message',
    MessageType.matchInvite => 'Match Invite',
    MessageType.contractInvite => 'Contract Invite',
    MessageType.paymentReminder => 'Payment Reminder',
    MessageType.availabilityRequest => 'Availability Request',
    MessageType.availabilityReminder => 'Availability Reminder',
    MessageType.subRequest => 'Sub Request',
    MessageType.sessionLineup => 'Session Lineup',
    MessageType.paymentConfirmation => 'Payment Confirmation',
  };

  /// Whether this message type includes a per-player link ({link} placeholder).
  static bool usesLink(MessageType type) => switch (type) {
    MessageType.matchInvite => true,
    MessageType.contractInvite => true,
    MessageType.availabilityRequest => true,
    MessageType.availabilityReminder => true,
    MessageType.subRequest => true,
    MessageType.sessionLineup => true,
    _ => false,
  };

  static String defaultSubject(MessageType type, ComposeMessageConfig c) {
    switch (type) {
      case MessageType.matchInvite:
        if (c.match != null) {
          final df = DateFormat('M/d/yyyy');
          final tf = DateFormat('h:mm a');
          final dt = '${df.format(c.match!.matchDate)} at ${tf.format(c.match!.matchDate)}';
          return 'Tennis Invite: $dt';
        }
        return 'Tennis Match Invitation';
      case MessageType.contractInvite:
        final club = c.contract?.clubName ?? 'Court Contract';
        return 'Court Contract Invitation: $club';
      case MessageType.paymentReminder:
        final club = c.contract?.clubName ?? 'Court Contract';
        return 'Payment Reminder: $club';
      case MessageType.availabilityRequest:
        final club = c.contract?.clubName ?? 'Session';
        final dateStr = c.sessionDate != null
            ? DateFormat('M/d').format(c.sessionDate!)
            : '';
        return 'Are you available? $club${dateStr.isNotEmpty ? ' — $dateStr' : ''}';
      case MessageType.availabilityReminder:
        final club2 = c.contract?.clubName ?? 'Session';
        final dateStr2 = c.sessionDate != null
            ? DateFormat('M/d').format(c.sessionDate!)
            : '';
        return 'Reminder — availability needed: $club2${dateStr2.isNotEmpty ? ' — $dateStr2' : ''}';
      case MessageType.subRequest:
        return 'Sub Needed — Can You Fill In?';
      case MessageType.sessionLineup:
        final club = c.contract?.clubName ?? 'Session';
        final dateStr = c.sessionDate != null
            ? DateFormat('M/d').format(c.sessionDate!)
            : '';
        return 'Lineup for $club${dateStr.isNotEmpty ? ' — $dateStr' : ''}';
      case MessageType.paymentConfirmation:
        final club = c.contract?.clubName ?? 'Court Contract';
        return 'Payment confirmed: $club';
      case MessageType.custom:
        return '';
    }
  }

  static String defaultBody(MessageType type, ComposeMessageConfig c) {
    switch (type) {
      case MessageType.matchInvite:
        return _matchInviteBody(c);
      case MessageType.contractInvite:
        return _contractInviteBody(c);
      case MessageType.paymentReminder:
        return _paymentReminderBody(c);
      case MessageType.availabilityRequest:
        return _availabilityRequestBody(c);
      case MessageType.availabilityReminder:
        return _availabilityReminderBody(c);
      case MessageType.subRequest:
        return _subRequestBody(c);
      case MessageType.sessionLineup:
        return _sessionLineupBody(c);
      case MessageType.paymentConfirmation:
        return _paymentConfirmationBody(c);
      case MessageType.custom:
        return '';
    }
  }

  // ── Template bodies ────────────────────────────────────────────────────────

  static String _matchInviteBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    if (c.match == null) {
      return '$orgName invited you to a tennis match! Join here: {link}';
    }
    final df = DateFormat('M/d/yyyy');
    final tf = DateFormat('h:mm a');
    final dt = '${df.format(c.match!.matchDate)} at ${tf.format(c.match!.matchDate)}';
    return '$orgName invited you to a match on $dt! '
        'Location: ${c.match!.location}. '
        'Join here: {link}';
  }

  static String _contractInviteBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    if (c.contract == null) {
      return '$orgName has invited you to join a court contract. Enroll here: {link}';
    }
    final contract = c.contract!;
    const weekdayNames = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final weekdayName = weekdayNames[contract.weekday];

    String fmtTime(int minutes) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${m.toString().padLeft(2, '0')} $suffix';
    }
    String fmtDate(DateTime d) => '${d.month}/${d.day}/${d.year}';

    final startStr = fmtTime(contract.startMinutes);
    final endStr = fmtTime(contract.endMinutes);
    final seasonStr = '${fmtDate(contract.seasonStart)} – ${fmtDate(contract.seasonEnd)}';
    final priceStr = contract.pricePerSlot > 0
        ? '\$${contract.pricePerSlot.toStringAsFixed(2)}/slot'
        : 'TBD';

    return '$orgName has invited you to join the ${contract.clubName} court contract. '
        'Schedule: ${weekdayName}s $startStr–$endStr, $seasonStr. '
        'Price: $priceStr. '
        'Enroll here: {link}';
  }

  static String _paymentReminderBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    final club = c.contract?.clubName ?? 'the court contract';

    // For single-recipient sends, try to include specific amount
    if (c.recipients.length == 1 && c.contract != null && c.contractRosterPlayers != null) {
      final uid = c.recipients.first.uid;
      final cp = c.contractRosterPlayers!.firstWhere(
        (p) => p.uid == uid,
        orElse: () => ContractPlayer(uid: uid, displayName: c.recipients.first.displayName),
      );
      if (cp.paidSlots > 0 && c.contract!.pricePerSlot > 0) {
        final total = cp.paidSlots * c.contract!.pricePerSlot;
        return 'Hi {playerName}, this is a reminder from $orgName that your payment for $club is due. '
            'Amount: \$${total.toStringAsFixed(2)} for ${cp.paidSlots} session(s) at \$${c.contract!.pricePerSlot.toStringAsFixed(2)}/slot. '
            '${c.contract!.paymentInfo.isNotEmpty ? c.contract!.paymentInfo : 'Please reach out to arrange payment.'}';
      }
    }

    return 'Hi {playerName}, this is a friendly reminder from $orgName that your payment for $club is due. '
        'Please reach out to arrange payment.';
  }

  static String _availabilityRequestBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    if (c.contract == null || c.sessionDate == null) {
      return '$orgName is checking availability for an upcoming session. '
          'Please let us know if you can make it: {link}';
    }
    final contract = c.contract!;
    final df = DateFormat('EEEE, MMMM d');
    final dayStr = df.format(c.sessionDate!);

    String fmtTime(int minutes) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${m.toString().padLeft(2, '0')} $suffix';
    }

    final timeStr = '${fmtTime(contract.startMinutes)}–${fmtTime(contract.endMinutes)}';
    return '$orgName is checking availability for ${contract.clubName} on $dayStr ($timeStr). '
        'Please let us know if you can make it: {link}';
  }

  static String _availabilityReminderBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    if (c.contract == null || c.sessionDate == null) {
      return 'Hi {playerName}, this is a reminder from $orgName — please enter your availability for the upcoming session before the deadline: {link}';
    }
    final contract = c.contract!;
    final df = DateFormat('EEEE, MMMM d');
    final dayStr = df.format(c.sessionDate!);

    String fmtTime(int minutes) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${m.toString().padLeft(2, '0')} $suffix';
    }

    final lineupTime = fmtTime(contract.notifLineupTimeMinutes);
    final lineupDate = DateFormat('MMM d').format(c.sessionDate!.subtract(
      Duration(days: contract.notifLineupDaysBefore),
    ));
    return 'Hi {playerName}, this is a reminder from $orgName — your availability for ${contract.clubName} on $dayStr has not been received yet. '
        'If we don\'t hear from you by $lineupDate at $lineupTime, you will be marked as Out for this session. '
        'Please respond here: {link}';
  }

  static String _sessionLineupBody(ComposeMessageConfig c) {
    if (c.contract == null || c.sessionDate == null || c.sessionAssignment == null) {
      return 'Hi {playerName}, here is the lineup for your upcoming session.';
    }
    final contract = c.contract!;
    final assignment = c.sessionAssignment!;
    final roster = contract.roster;

    final df = DateFormat('EEEE, MMMM d');
    final dayStr = df.format(c.sessionDate!);

    String fmtTime(int minutes) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${m.toString().padLeft(2, '0')} $suffix';
    }

    final timeStr = fmtTime(contract.startMinutes);
    final confirmed = roster.where((p) => assignment[p.uid]?['status'] == 'confirmed').toList();
    final reserves = roster.where((p) => assignment[p.uid]?['status'] == 'reserve').toList();
    final out = roster.where((p) => assignment[p.uid]?['status'] == 'out').toList();

    final buf = StringBuffer();
    buf.writeln("Hi {playerName}, here's the lineup for ${contract.clubName} on $dayStr ($timeStr):");
    buf.writeln();
    buf.writeln('Playing (${confirmed.length}/${contract.spotsPerSession}):');
    for (final p in confirmed) { buf.writeln('- ${p.displayName}'); }
    if (reserves.isNotEmpty) {
      buf.writeln();
      buf.writeln('Reserve:');
      for (final p in reserves) { buf.writeln('- ${p.displayName}'); }
    }
    if (out.isNotEmpty) {
      buf.writeln();
      buf.writeln('Not assigned:');
      for (final p in out) { buf.writeln('- ${p.displayName}'); }
    }
    buf.writeln();
    buf.writeln('See you on the court!');
    buf.writeln();
    buf.write('To manage your spot: {link}');
    return buf.toString();
  }

  static String _paymentConfirmationBody(ComposeMessageConfig c) {
    final club = c.contract?.clubName ?? 'the contract';
    return "Hi {playerName}, your payment for the $club contract has been received and confirmed. You're all set for the season!";
  }

  static String _subRequestBody(ComposeMessageConfig c) {
    final orgName = _cleanName(c.organizerName);
    if (c.match != null) {
      final df = DateFormat('M/d/yyyy');
      final tf = DateFormat('h:mm a');
      final dt = '${df.format(c.match!.matchDate)} at ${tf.format(c.match!.matchDate)}';
      return '$orgName is looking for a sub for a match on $dt at ${c.match!.location}. '
          'Can you fill in? {link}';
    }
    if (c.contract != null && c.sessionDate != null) {
      final df = DateFormat('EEEE, MMMM d');
      final dayStr = df.format(c.sessionDate!);
      return '$orgName is looking for a sub at ${c.contract!.clubName} on $dayStr. '
          'Can you fill in? {link}';
    }
    return '$orgName is looking for a sub. Can you fill in? {link}';
  }

  // ── Link builders ──────────────────────────────────────────────────────────

  /// Returns a link builder function for the given type and config.
  /// Returns null if the type doesn't use links.
  static String? Function(String uid)? linkBuilder(MessageType type, ComposeMessageConfig c) {
    switch (type) {
      case MessageType.matchInvite:
      case MessageType.subRequest:
        if (c.contextId != null) {
          return (uid) =>
              '${LinkUtils.getBaseUrl()}/#/match/${c.contextId}?uid=${Uri.encodeComponent(uid)}';
        }
        return null;
      case MessageType.contractInvite:
        if (c.contextId != null) {
          return (uid) =>
              '${LinkUtils.getBaseUrl()}/#/contract/${c.contextId}?uid=${Uri.encodeComponent(uid)}';
        }
        return null;
      case MessageType.availabilityRequest:
      case MessageType.availabilityReminder:
        if (c.contextId != null && c.sessionDate != null) {
          final dateKey = '${c.sessionDate!.year}-'
              '${c.sessionDate!.month.toString().padLeft(2, '0')}-'
              '${c.sessionDate!.day.toString().padLeft(2, '0')}';
          return (uid) =>
              '${LinkUtils.getBaseUrl()}/#/availability/${c.contextId}/$dateKey?uid=${Uri.encodeComponent(uid)}';
        }
        return null;
      case MessageType.sessionLineup:
        if (c.contextId != null && c.sessionDate != null) {
          final dateKey = '${c.sessionDate!.year}-'
              '${c.sessionDate!.month.toString().padLeft(2, '0')}-'
              '${c.sessionDate!.day.toString().padLeft(2, '0')}';
          return (uid) =>
              '${LinkUtils.getBaseUrl()}/#/session/${c.contextId}/$dateKey/manage?uid=${Uri.encodeComponent(uid)}';
        }
        return null;
      case MessageType.paymentReminder:
      case MessageType.paymentConfirmation:
      case MessageType.custom:
        return null;
    }
  }

  static String _cleanName(String name) => name.replaceAll(' (You)', '');
}
