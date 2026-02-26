import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';

class NotificationService {
  // ===========================================================================
  // SHARED HELPERS — single source of truth for send, formatting, naming
  // ===========================================================================

  /// Sends a notification via SMS (Twilio) or Email (SendGrid) based on
  /// whether [contact] contains '@'.
  static Future<void> _send({
    required String contact,
    required String subject,
    required String textBody,
    required String htmlBody,
  }) async {
    final isSms = !contact.contains('@');

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': textBody,
      });
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {'subject': subject, 'text': textBody, 'html': htmlBody},
      });
    }
  }

  /// Formats a match date as "6/15/2026 at 9:00 AM".
  static String formatDateTime(Match match) {
    final df = DateFormat('M/d/yyyy');
    final tf = DateFormat('h:mm a');
    return '${df.format(match.matchDate)} at ${tf.format(match.matchDate)}';
  }

  /// Returns just the date portion, e.g. "6/15/2026".
  static String _formatDate(Match match) {
    return DateFormat('M/d/yyyy').format(match.matchDate);
  }

  /// Strips the UI suffix " (You)" from display names before sending externally.
  static String cleanName(String name) => name.replaceAll(' (You)', '');

  /// Builds the standard deep link for a match, optionally with a uid for auto-login.
  static String _matchLink(String matchId, {String? uid}) {
    final base = 'https://www.finapps.com/#/match/$matchId';
    if (uid != null && uid.isNotEmpty) {
      return '$base?uid=${Uri.encodeComponent(uid)}';
    }
    return base;
  }

  /// Standard HTML button style used across all notification emails.
  static String _htmlButton(String href, String label) {
    return '<a href="$href" style="padding: 10px 20px; background-color: #0b224e; '
        'color: white; text-decoration: none; border-radius: 5px;">$label</a>';
  }

  // ===========================================================================
  // PUBLIC METHODS — all callers remain unchanged
  // ===========================================================================

  /// Sends a match invitation to a single player (SMS or Email).
  static Future<void> sendInvite({
    required String contact,
    required Match match,
    required String matchId,
    required String organizerName,
    required bool isSms, // kept for API compatibility; _send auto-detects too
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
      contact: contact,
      subject: 'Tennis Invite: $dateTime',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  /// Notifies a player that they have been removed from a match by the organizer.
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
      contact: contact,
      subject: 'Match Update: Removed from Roster',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  /// Notifies the match organizer that a player has dropped out.
  /// Accepts an optional [note] so the player can explain why they're leaving.
  static Future<void> notifyOrganizerDropOut({
    required Match match,
    required String matchId,
    required String playerName,
    String? note,
  }) async {
    final contact = match.organizerId;
    if (contact.isEmpty) return;

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
      contact: contact,
      subject: 'Match Update: Player Dropped Out',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  /// Sends an urgent recruitment alert that bypasses notification preferences.
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
      contact: contact,
      subject: 'URGENT: Tennis Player Needed!',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }

  /// Sends cancellation notices to all accepted/invited players in a match.
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
      // Skip the organizer themselves and empty uids
      if (player.uid == match.organizerId || player.uid.isEmpty) continue;

      if (player.status == RosterStatus.accepted ||
          player.status == RosterStatus.invited) {
        futures.add(
          _send(
            contact: player.uid,
            subject: 'Match Canceled: $dateStr',
            textBody: textBody,
            htmlBody: htmlBody,
          ),
        );
      }
    }

    await Future.wait(futures, eagerError: false);
  }

  /// Sends a generic match update message to a single contact.
  static Future<void> sendMatchUpdate({
    required String contact,
    required String message,
  }) async {
    await _send(
      contact: contact,
      subject: 'Match Update',
      textBody: message,
      htmlBody: '<p>$message</p>',
    );
  }

  /// Sends a chat notification to a single player when someone posts in match chat.
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
      contact: contact,
      subject: 'New Message in Match Chat',
      textBody: textBody,
      htmlBody: htmlBody,
    );
  }
}
