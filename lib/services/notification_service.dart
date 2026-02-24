import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';

class NotificationService {
  static Future<void> sendInvite({
    required String contact,
    required Match match,
    required String matchId,
    required String organizerName,
    required bool isSms,
  }) async {
    final encodedUid = Uri.encodeComponent(contact);
    final link = "https://lexingtontennis.app/match/$matchId?uid=$encodedUid";

    // Clean up organizer name
    final cleanOrganizerName = organizerName.replaceAll(' (You)', '');

    // Format the date/time (e.g., "10/24/2026 at 9:00 AM")
    final dateStr =
        "${match.matchDate.month}/${match.matchDate.day}/${match.matchDate.year}";
    final timeStr =
        "${match.matchDate.hour > 12 ? match.matchDate.hour - 12 : (match.matchDate.hour == 0 ? 12 : match.matchDate.hour)}:${match.matchDate.minute.toString().padLeft(2, '0')} ${match.matchDate.hour >= 12 ? 'PM' : 'AM'}";

    // Construct the confirmed players list
    final confirmedPlayers = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .map((r) => r.displayName.replaceAll(' (You)', ''))
        .toList();
    final playersStr = confirmedPlayers.isNotEmpty
        ? confirmedPlayers.join(', ')
        : 'No confirmed players yet';

    final textBody =
        "$cleanOrganizerName invited you to a match on $dateStr at $timeStr! Location: ${match.location}. Confirmed players: $playersStr. Join here: $link";

    final htmlBody =
        """
      <h3>You've been invited to a Tennis Match!</h3>
      <p><b>Organizer:</b> $cleanOrganizerName</p>
      <p><b>Date & Time:</b> $dateStr at $timeStr</p>
      <p><b>Location:</b> ${match.location}</p>
      <p><b>Confirmed Players:</b> $playersStr</p>
      <br/>
      <p><a href="$link" style="padding: 10px 20px; background-color: #0b224e; color: white; text-decoration: none; border-radius: 5px;">View Match Details</a></p>
    """;

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': textBody,
      });
      print("SMS trigger created for $contact");
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'Tennis Invite: $dateStr at $timeStr',
          'text': textBody,
          'html': htmlBody,
        },
      });
      print("Email trigger created for $contact");
    }
  }

  static Future<void> sendRemoval({
    required String contact,
    required Match match,
    required String organizerName,
    required bool isSms,
    String? reason,
  }) async {
    final cleanOrganizerName = organizerName.replaceAll(' (You)', '');
    final dateStr =
        "${match.matchDate.month}/${match.matchDate.day}/${match.matchDate.year}";
    final timeStr =
        "${match.matchDate.hour > 12 ? match.matchDate.hour - 12 : (match.matchDate.hour == 0 ? 12 : match.matchDate.hour)}:${match.matchDate.minute.toString().padLeft(2, '0')} ${match.matchDate.hour >= 12 ? 'PM' : 'AM'}";

    var textBody =
        "You have been removed from the tennis match on $dateStr at $timeStr organized by $cleanOrganizerName.";
    if (reason != null && reason.isNotEmpty) {
      textBody += " Reason: $reason";
    }

    var htmlBody =
        """
      <h3>Match Update</h3>
      <p>You have been removed from the upcoming tennis match.</p>
      <p><b>Organizer:</b> $cleanOrganizerName</p>
      <p><b>Date & Time:</b> $dateStr at $timeStr</p>
      <p><b>Location:</b> ${match.location}</p>
    """;
    if (reason != null && reason.isNotEmpty) {
      htmlBody += "<p><b>Reason for removal:</b> $reason</p>";
    }

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': textBody,
      });
      print("SMS removal trigger created for $contact");
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'Match Update: Removed from Roster',
          'text': textBody,
          'html': htmlBody,
        },
      });
      print("Email removal trigger created for $contact");
    }
  }

  static Future<void> notifyOrganizerDropOut({
    required Match match,
    required String matchId,
    required String playerName,
  }) async {
    final contact = match.organizerId;
    if (contact.isEmpty || contact.startsWith('shadow_')) return;

    final isSms = !contact.contains('@');
    final dateStr =
        "${match.matchDate.month}/${match.matchDate.day}/${match.matchDate.year}";
    final timeStr =
        "${match.matchDate.hour > 12 ? match.matchDate.hour - 12 : (match.matchDate.hour == 0 ? 12 : match.matchDate.hour)}:${match.matchDate.minute.toString().padLeft(2, '0')} ${match.matchDate.hour >= 12 ? 'PM' : 'AM'}";
    final link = "https://lexingtontennis.app/match/$matchId";

    final textBody =
        "$playerName has removed themselves from your match on $dateStr at $timeStr. Open the app to recruit a replacement: $link";

    final htmlBody =
        """
      <h3>Match Update: Player Dropped Out</h3>
      <p><b>$playerName</b> has removed themselves from your upcoming match.</p>
      <p><b>Date & Time:</b> $dateStr at $timeStr</p>
      <p><b>Location:</b> ${match.location}</p>
      <br/>
      <p><a href="$link" style="padding: 10px 20px; background-color: #0b224e; color: white; text-decoration: none; border-radius: 5px;">Manage Match</a></p>
    """;

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': textBody,
      });
      print("SMS drop-out trigger created for $contact");
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'Match Update: Player Dropped Out',
          'text': textBody,
          'html': htmlBody,
        },
      });
      print("Email drop-out trigger created for $contact");
    }
  }

  static Future<void> sendUrgentRecruit({
    required String contact,
    required String matchId,
    required String organizerName,
  }) async {
    // Bypasses notification preferences for Tier 1 transactional alerts
    final link = "https://lexingtontennis.app/match/$matchId";
    final message =
        "URGENT: $organizerName needs a player ASAP! Join here: $link";
    final isSms = !contact.contains('@');

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': message,
      });
      print("Urgent SMS trigger created for $contact");
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'URGENT: Tennis Player Needed!',
          'text': message,
          'html':
              '<p><b>URGENT:</b> $organizerName needs a player ASAP! <a href="$link">Join here</a></p>',
        },
      });
      print("Urgent Email trigger created for $contact");
    }
  }

  static Future<void> sendMatchCancellation({
    required List<Roster> roster,
    required Match match,
    required String organizerName,
    required String reason,
  }) async {
    final cleanOrganizerName = organizerName.replaceAll(' (You)', '');
    final dateStr =
        "${match.matchDate.month}/${match.matchDate.day}/${match.matchDate.year}";
    final timeStr =
        "${match.matchDate.hour > 12 ? match.matchDate.hour - 12 : (match.matchDate.hour == 0 ? 12 : match.matchDate.hour)}:${match.matchDate.minute.toString().padLeft(2, '0')} ${match.matchDate.hour >= 12 ? 'PM' : 'AM'}";

    final textBody =
        "Match Canceled! $cleanOrganizerName has canceled the tennis match on $dateStr at $timeStr. Reason: $reason";

    final htmlBody =
        """
      <h3>Match Canceled</h3>
      <p><b>$cleanOrganizerName</b> has canceled the upcoming tennis match.</p>
      <p><b>Reason:</b> $reason</p>
      <br/>
      <p><b>Original Date & Time:</b> $dateStr at $timeStr</p>
      <p><b>Location:</b> ${match.location}</p>
    """;

    for (final player in roster) {
      if (player.uid == match.organizerId ||
          player.uid.isEmpty ||
          player.uid.startsWith('shadow_')) {
        continue;
      }

      if (player.status == RosterStatus.accepted ||
          player.status == RosterStatus.invited) {
        final isSms = !player.uid.contains('@');

        if (isSms) {
          await FirebaseFirestore.instance.collection('messages').add({
            'to': player.uid,
            'body': textBody,
          });
        } else {
          await FirebaseFirestore.instance.collection('mail').add({
            'to': player.uid,
            'message': {
              'subject': 'Match Canceled: $dateStr',
              'text': textBody,
              'html': htmlBody,
            },
          });
        }
      }
    }
  }

  static Future<void> sendMatchUpdate({
    required String contact,
    required String message,
  }) async {
    final isSms = !contact.contains('@');
    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': message,
      });
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'Match Update',
          'text': message,
          'html': '<p>$message</p>',
        },
      });
    }
  }

  static Future<void> sendChatNotification({
    required String contact,
    required String matchId,
    required String senderName,
    required String messagePreview,
  }) async {
    final link = "https://lexingtontennis.app/match/$matchId";
    final message =
        "$senderName just posted in the Match Chat:\\n\\n'$messagePreview'\\n\\nOpen AntiGravity Tennis to reply!";
    final isSms = !contact.contains('@');

    if (isSms) {
      await FirebaseFirestore.instance.collection('messages').add({
        'to': contact,
        'body': message,
      });
    } else {
      await FirebaseFirestore.instance.collection('mail').add({
        'to': contact,
        'message': {
          'subject': 'New Message in Match Chat',
          'text': message,
          'html': '<p>$message <a href="$link">View here</a></p>',
        },
      });
    }
  }
}
