import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../utils/link_utils.dart';

class NotificationService {
  // ===========================================================================
  // SHARED HELPERS
  // ===========================================================================

  static Future<void> _sendSms({
    required String phone,
    required String textBody,
  }) async {
    await FirebaseFirestore.instance.collection('messages').add({
      'to': phone,
      'body': textBody,
    });
  }

  static Future<void> _sendEmail({
    required String email,
    required String subject,
    required String textBody,
    required String htmlBody,
    String? replyToEmail,
  }) async {
    await FirebaseFirestore.instance.collection('mail').add({
      'to': email,
      'message': {'subject': subject, 'text': textBody, 'html': htmlBody},
      if (replyToEmail != null && replyToEmail.isNotEmpty)
        'reply_to': replyToEmail,
    });
  }

  /// Looks up a user by their Firestore UUID, resolves their notification
  /// preferences and contact info, and sends the message via the appropriate
  /// channel(s).
  ///
  /// [uid] is the user's Firestore doc ID (UUID).
  static Future<void> _send({
    required String uid,
    required String subject,
    required String textBody,
    required String htmlBody,
    bool ignoreNotifActive = false,
    String? replyToEmail,
  }) async {
    String? phone;
    String? email;
    String notifMode = 'SMS'; // default guess

    // Look up user preferences by UUID
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        if (!ignoreNotifActive && data['notif_active'] == false) return;
        notifMode = data['notif_mode'] ?? notifMode;

        final primaryContact = data['primary_contact'] ?? '';
        final storedEmail = data['email'] ?? '';

        // Determine available phone number
        if (primaryContact.isNotEmpty && !primaryContact.contains('@')) {
          phone = primaryContact;
        }

        // Determine available email address
        if (storedEmail.isNotEmpty) {
          email = storedEmail;
        } else if (primaryContact.contains('@')) {
          email = primaryContact;
        }

        // Update default guess based on what we found
        if (phone == null && email != null) {
          notifMode = data['notif_mode'] ?? 'Email';
        }
      }
    } catch (_) {
      // Firestore lookup failed — fall through to defaults below
    }

    // If we couldn't determine channels from the doc, we can't send
    if (phone == null && email == null) return;

    // Send via preferred channel(s), falling back if preferred isn't available
    switch (notifMode) {
      case 'SMS':
        if (phone != null) {
          await _sendSms(phone: phone, textBody: textBody);
        } else if (email != null) {
          await _sendEmail(
            email: email,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            replyToEmail: replyToEmail,
          );
        }
        break;
      case 'Email':
        if (email != null) {
          await _sendEmail(
            email: email,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            replyToEmail: replyToEmail,
          );
        } else if (phone != null) {
          await _sendSms(phone: phone, textBody: textBody);
        }
        break;
      case 'Both':
        final futures = <Future>[];
        if (phone != null) {
          futures.add(_sendSms(phone: phone, textBody: textBody));
        }
        if (email != null) {
          futures.add(
            _sendEmail(
              email: email,
              subject: subject,
              textBody: textBody,
              htmlBody: htmlBody,
              replyToEmail: replyToEmail,
            ),
          );
        }
        if (futures.isNotEmpty) {
          await Future.wait(futures, eagerError: false);
        }
        break;
      default:
        if (phone != null) {
          await _sendSms(phone: phone, textBody: textBody);
        } else if (email != null) {
          await _sendEmail(
            email: email,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            replyToEmail: replyToEmail,
          );
        }
    }
  }

  static String formatDateTime(Match match) {
    final df = DateFormat('M/d/yyyy');
    final tf = DateFormat('h:mm a');
    return '${df.format(match.matchDate)} at ${tf.format(match.matchDate)}';
  }

  static String _formatDate(Match match) {
    return DateFormat('M/d/yyyy').format(match.matchDate);
  }

  static String cleanName(String name) => name.replaceAll(' (You)', '');

  /// Builds the standard deep link for a match, optionally with a uid (UUID) for auto-login.
  static String _matchLink(String matchId, {String? uid}) {
    final base = '${LinkUtils.getBaseUrl()}/#/match/$matchId';
    if (uid != null && uid.isNotEmpty) {
      return '$base?uid=${Uri.encodeComponent(uid)}';
    }
    return base;
  }

  static String _htmlButton(String href, String label) {
    return '<a href="$href" style="padding: 10px 20px; background-color: #0b224e; '
        'color: white; text-decoration: none; border-radius: 5px;">$label</a>';
  }

  // ===========================================================================
  // CONTENT BUILDERS (generate without sending)
  // ===========================================================================

  /// Builds the invite email content for preview/editing.
  /// [bodyTemplate] uses `{link}` as a placeholder for the personalized join link.
  static ({String subject, String bodyTemplate}) buildInviteTemplate({
    required Match match,
    required String matchId,
    required String organizerName,
  }) {
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);
    final confirmedPlayers = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .map((r) => cleanName(r.displayName))
        .toList();
    final playersStr = confirmedPlayers.isNotEmpty
        ? confirmedPlayers.join(', ')
        : 'No confirmed players yet';
    final bodyTemplate =
        "$orgName invited you to a match on $dateTime! "
        "Location: ${match.location}. "
        "Confirmed players: $playersStr. "
        "Join here: {link}";
    return (subject: 'Tennis Invite: $dateTime', bodyTemplate: bodyTemplate);
  }

  /// Builds the removal email content for preview/editing.
  static ({String subject, String textBody}) buildRemovalContent({
    required Match match,
    required String organizerName,
    String? reason,
  }) {
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);
    var textBody =
        "You have been removed from the tennis match on $dateTime "
        "organized by $orgName.";
    if (reason != null && reason.isNotEmpty) textBody += " Reason: $reason";
    return (subject: 'Match Update: Removed from Roster', textBody: textBody);
  }

  /// Builds the cancellation email content for preview/editing.
  static ({String subject, String textBody}) buildCancellationContent({
    required Match match,
    required String organizerName,
    required String reason,
  }) {
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);
    final dateStr = _formatDate(match);
    final textBody =
        "Match Canceled! $orgName has canceled the tennis match on $dateTime. "
        "Reason: $reason";
    return (subject: 'Match Canceled: $dateStr', textBody: textBody);
  }

  /// Sends a pre-built (possibly user-edited) message to a single UID.
  static Future<void> sendBuilt({
    required String uid,
    required String subject,
    required String textBody,
  }) async {
    final htmlBody = '<p>${textBody.replaceAll('\n', '<br/>')}</p>';
    await _send(uid: uid, subject: subject, textBody: textBody, htmlBody: htmlBody);
  }

  // ===========================================================================
  // PUBLIC METHODS
  // ===========================================================================

  /// Sends a match invitation. [contact] is the player's UUID.
  /// Pass [customSubject] and [customBodyTemplate] (with `{link}` token) to
  /// override the default generated content.
  static Future<void> sendInvite({
    required String contact,
    required Match match,
    required String matchId,
    required String organizerName,
    required bool isSms, // kept for API compatibility
    String? customSubject,
    String? customBodyTemplate,
  }) async {
    final link = _matchLink(matchId, uid: contact);
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);

    final confirmedPlayers = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .map((r) => cleanName(r.displayName))
        .toList();
    final playersStr = confirmedPlayers.isNotEmpty
        ? confirmedPlayers.join(', ')
        : 'No confirmed players yet';

    final defaultTextBody =
        "$orgName invited you to a match on $dateTime! "
        "Location: ${match.location}. "
        "Confirmed players: $playersStr. "
        "Join here: $link";

    final textBody = customBodyTemplate != null
        ? customBodyTemplate.replaceAll('{link}', link)
        : defaultTextBody;

    final htmlBody = customBodyTemplate != null
        ? '<p>${textBody.replaceAll('\n', '<br/>')}</p>'
        : """
      <h3>You've been invited to a Tennis Match!</h3>
      <p><b>Organizer:</b> $orgName</p>
      <p><b>Date & Time:</b> $dateTime</p>
      <p><b>Location:</b> ${match.location}</p>
      <p><b>Confirmed Players:</b> $playersStr</p>
      <br/>
      <p>${_htmlButton(link, 'View Match Details')}</p>
    """;

    await _send(
      uid: contact,
      subject: customSubject ?? 'Tennis Invite: $dateTime',
      textBody: textBody,
      htmlBody: htmlBody,
      ignoreNotifActive: true, // organizer explicitly invited this person
    );
  }

  static Future<void> sendRemoval({
    required String contact,
    required Match match,
    required String organizerName,
    required bool isSms,
    String? reason,
  }) async {
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);

    var textBody =
        "You have been removed from the tennis match on $dateTime "
        "organized by $orgName.";
    if (reason != null && reason.isNotEmpty) {
      textBody += " Reason: $reason";
    }

    var htmlBody =
        """
      <h3>Match Update</h3>
      <p>You have been removed from the upcoming tennis match.</p>
      <p><b>Organizer:</b> $orgName</p>
      <p><b>Date & Time:</b> $dateTime</p>
      <p><b>Location:</b> ${match.location}</p>
    """;
    if (reason != null && reason.isNotEmpty) {
      htmlBody += "<p><b>Reason for removal:</b> $reason</p>";
    }

    await _send(
      uid: contact,
      subject: 'Match Update: Removed from Roster',
      textBody: textBody,
      htmlBody: htmlBody,
      ignoreNotifActive: true,
    );
  }

  static Future<void> notifyOrganizerDropOut({
    required Match match,
    required String matchId,
    required String playerName,
    String? note,
  }) async {
    final organizerUid = match.organizerId;
    if (organizerUid.isEmpty) return;

    final dateTime = formatDateTime(match);
    final link = _matchLink(matchId);

    var textBody =
        "$playerName has removed themselves from your match on $dateTime.";
    if (note != null && note.isNotEmpty) {
      textBody += " Their note: \"$note\"";
    }
    textBody += " Open the app to recruit a replacement: $link";

    var htmlBody =
        """
      <h3>Match Update: Player Dropped Out</h3>
      <p><b>$playerName</b> has removed themselves from your upcoming match.</p>
    """;
    if (note != null && note.isNotEmpty) {
      htmlBody += "<p><b>Player's note:</b> \"$note\"</p>";
    }
    htmlBody +=
        """
      <p><b>Date & Time:</b> $dateTime</p>
      <p><b>Location:</b> ${match.location}</p>
      <br/>
      <p>${_htmlButton(link, 'Manage Match')}</p>
    """;

    await _send(
      uid: organizerUid,
      subject: 'Match Update: Player Dropped Out',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  static Future<void> sendUrgentRecruit({
    required String contact,
    required String matchId,
    required String organizerName,
  }) async {
    final link = _matchLink(matchId);
    final orgName = cleanName(organizerName);

    final textBody = "URGENT: $orgName needs a player ASAP! Join here: $link";

    final htmlBody =
        '<p><b>URGENT:</b> $orgName needs a player ASAP! '
        '${_htmlButton(link, 'Join Now')}</p>';

    await _send(
      uid: contact,
      subject: 'URGENT: Tennis Player Needed!',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  static Future<void> sendMatchCancellation({
    required List<Roster> roster,
    required Match match,
    required String organizerName,
    required String reason,
  }) async {
    final orgName = cleanName(organizerName);
    final dateTime = formatDateTime(match);
    final dateStr = _formatDate(match);

    final textBody =
        "Match Canceled! $orgName has canceled the tennis match on $dateTime. "
        "Reason: $reason";

    final htmlBody =
        """
      <h3>Match Canceled</h3>
      <p><b>$orgName</b> has canceled the upcoming tennis match.</p>
      <p><b>Reason:</b> $reason</p>
      <br/>
      <p><b>Original Date & Time:</b> $dateTime</p>
      <p><b>Location:</b> ${match.location}</p>
    """;

    final futures = <Future>[];

    for (final player in roster) {
      if (player.uid == match.organizerId || player.uid.isEmpty) continue;

      if (player.status == RosterStatus.accepted ||
          player.status == RosterStatus.invited) {
        futures.add(
          _send(
            uid: player.uid,
            subject: 'Match Canceled: $dateStr',
            textBody: textBody,
            htmlBody: htmlBody,
            ignoreNotifActive: true,
          ),
        );
      }
    }

    await Future.wait(futures, eagerError: false);
  }

  static Future<void> sendMatchUpdate({
    required String contact,
    required String message,
  }) async {
    await _send(
      uid: contact,
      subject: 'Match Update',
      textBody: message,
      htmlBody: '<p>$message</p>',
    );
  }

  /// Returns the default message template for a contract enrollment invite.
  /// The literal string `{link}` is a placeholder that gets replaced with each
  /// player's unique enrollment URL before sending.
  static String contractInviteTemplate({
    required Contract contract,
    required String organizerName,
  }) {
    final orgName = cleanName(organizerName);
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

  /// Sends a contract enrollment invite. If [customBody] is provided it is used
  /// as the message text; otherwise the default template is used. In both cases
  /// the literal `{link}` in the body is replaced with the player's unique URL.
  static Future<void> sendContractInvite({
    required String playerUid,
    required Contract contract,
    required String contractId,
    required String organizerName,
    String? customBody,
  }) async {
    final link = '${LinkUtils.getBaseUrl()}/#/contract/$contractId?uid=${Uri.encodeComponent(playerUid)}';

    // textBody keeps the raw URL for SMS delivery
    final textBody = (customBody ?? contractInviteTemplate(
      contract: contract,
      organizerName: organizerName,
    )).replaceAll('{link}', link);

    // htmlBody strips the raw URL from the prose and uses a button instead
    final htmlProse = textBody
        .replaceAll('Enroll here: $link', '')
        .replaceAll(link, '')
        .trimRight();
    final htmlBody =
        '<p>${htmlProse.replaceAll('\n', '<br/>')}</p>'
        '<br/><p>${_htmlButton(link, 'Enroll Now')}</p>';

    await _send(
      uid: playerUid,
      subject: 'Court Contract Invitation: ${contract.clubName}',
      textBody: textBody,
      htmlBody: htmlBody,
      ignoreNotifActive: true,
    );
  }

  static Future<void> sendContractPin({
    required String organizerUid,
    required String pin,
    required String clubName,
  }) async {
    final textBody = 'Your organizer PIN for the $clubName contract is: $pin';
    final htmlBody =
        '<p>Your organizer PIN for the <b>$clubName</b> contract is:</p>'
        '<h2 style="letter-spacing: 6px; font-family: monospace;">$pin</h2>'
        '<p>Keep this PIN private — it protects your contract management actions.</p>';

    await _send(
      uid: organizerUid,
      subject: 'Your $clubName Contract PIN',
      textBody: textBody,
      htmlBody: htmlBody,
      ignoreNotifActive: true,
    );
  }

  /// Returns the default message template for a session availability request.
  /// The literal string `{link}` is replaced with each player's unique response URL.
  static String availabilityRequestTemplate({
    required Contract contract,
    required DateTime sessionDate,
    required String organizerName,
  }) {
    final orgName = cleanName(organizerName);
    final df = DateFormat('EEEE, MMMM d');
    final dayStr = df.format(sessionDate);

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

  /// Sends an availability request to a single player for a specific session.
  static Future<void> sendAvailabilityRequest({
    required String playerUid,
    required String contractId,
    required DateTime sessionDate,
    required Contract contract,
    required String organizerName,
    String? customBody,
  }) async {
    final dateKey = '${sessionDate.year}-'
        '${sessionDate.month.toString().padLeft(2, '0')}-'
        '${sessionDate.day.toString().padLeft(2, '0')}';
    final link = '${LinkUtils.getBaseUrl()}/#/availability/$contractId/$dateKey'
        '?uid=${Uri.encodeComponent(playerUid)}';

    final textBody = (customBody ?? availabilityRequestTemplate(
      contract: contract,
      sessionDate: sessionDate,
      organizerName: organizerName,
    )).replaceAll('{link}', link);

    final htmlProse = textBody.replaceAll(link, '').trimRight();
    final htmlBody =
        '<p>${htmlProse.replaceAll('\n', '<br/>')}</p>'
        '<br/><p>${_htmlButton(link, 'Respond Now')}</p>';

    await _send(
      uid: playerUid,
      subject: 'Are you available? ${contract.clubName} — '
          '${DateFormat('M/d').format(sessionDate)}',
      textBody: textBody,
      htmlBody: htmlBody,
      ignoreNotifActive: true,
    );
  }

  /// Sends a composed message to a single recipient, substituting
  /// `{playerName}` → recipientDisplayName and `{link}` → the result of
  /// linkBuilder(uid) (if provided). Bypasses `notif_active` by default
  /// because this is an explicit organizer action.
  static Future<void> sendComposed({
    required String recipientUid,
    required String recipientDisplayName,
    required String subject,
    required String body,
    String? Function(String uid)? linkBuilder,
    bool ignoreNotifActive = true,
    String? replyToEmail,
  }) async {
    String resolvedBody = body.replaceAll('{playerName}', recipientDisplayName);
    if (linkBuilder != null) {
      final link = linkBuilder(recipientUid) ?? '';
      resolvedBody = resolvedBody.replaceAll('{link}', link);

      // Build clean HTML: strip raw URL from prose, use a button instead
      final htmlProse = resolvedBody.replaceAll(link, '').trimRight();
      final htmlBody = '<p>${htmlProse.replaceAll('\n', '<br/>')}</p>'
          '${link.isNotEmpty ? '<br/><p>${_htmlButton(link, 'Open')}</p>' : ''}';
      await _send(
        uid: recipientUid,
        subject: subject,
        textBody: resolvedBody,
        htmlBody: htmlBody,
        ignoreNotifActive: ignoreNotifActive,
        replyToEmail: replyToEmail,
      );
    } else {
      await _send(
        uid: recipientUid,
        subject: subject,
        textBody: resolvedBody,
        htmlBody: '<p>${resolvedBody.replaceAll('\n', '<br/>')}</p>',
        ignoreNotifActive: ignoreNotifActive,
        replyToEmail: replyToEmail,
      );
    }
  }

  static Future<void> sendChatNotification({
    required String contact,
    required String matchId,
    required String senderName,
    required String messagePreview,
  }) async {
    final link = _matchLink(matchId);

    final textBody =
        "$senderName just posted in the Match Chat:\n\n"
        "'$messagePreview'\n\n"
        "Open AntiGravity Tennis to reply!";

    final htmlBody =
        '<p><b>$senderName</b> posted in the Match Chat:</p>'
        '<p>"$messagePreview"</p>'
        '<p>${_htmlButton(link, 'View Chat')}</p>';

    await _send(
      uid: contact,
      subject: 'New Message in Match Chat',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }
}
