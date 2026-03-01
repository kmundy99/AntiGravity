import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';

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
  }) async {
    await FirebaseFirestore.instance.collection('mail').add({
      'to': email,
      'message': {'subject': subject, 'text': textBody, 'html': htmlBody},
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
        if (data['notif_active'] == false) return;
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
    final base = 'https://www.finapps.com/#/match/$matchId';
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
  // PUBLIC METHODS
  // ===========================================================================

  /// Sends a match invitation. [contact] is the player's UUID.
  static Future<void> sendInvite({
    required String contact,
    required Match match,
    required String matchId,
    required String organizerName,
    required bool isSms, // kept for API compatibility
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

    final textBody =
        "$orgName invited you to a match on $dateTime! "
        "Location: ${match.location}. "
        "Confirmed players: $playersStr. "
        "Join here: $link";

    final htmlBody =
        """
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
      subject: 'Tennis Invite: $dateTime',
      textBody: textBody,
      htmlBody: htmlBody,
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
