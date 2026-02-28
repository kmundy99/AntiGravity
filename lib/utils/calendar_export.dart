import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';

class CalendarExport {
  /// Opens Google Calendar with the match pre-filled. User just taps "Save".
  static Future<void> addToGoogleCalendar(
    BuildContext context,
    Match match,
  ) async {
    final start = _formatGoogleDate(match.matchDate);
    final end = _formatGoogleDate(
      match.matchDate.add(const Duration(hours: 1, minutes: 30)),
    );

    final confirmedNames = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .map((r) => r.displayName)
        .join(', ');

    final details =
        'Tennis Match via AntiGravity Tennis\n'
        'Players: $confirmedNames';

    final uri = Uri.https('calendar.google.com', '/calendar/render', {
      'action': 'TEMPLATE',
      'text': 'Tennis: ${match.location}',
      'dates': '$start/$end',
      'location': match.location,
      'details': details,
    });

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Google Calendar')),
        );
      }
    }
  }

  /// Generates a .ics file and opens it via data URI.
  /// iOS/macOS opens Apple Calendar, Outlook picks it up on Windows,
  /// and browsers download it.
  static Future<void> downloadIcsFile(BuildContext context, Match match) async {
    final icsContent = _generateIcs(match);
    final encoded = Uri.encodeComponent(icsContent);
    final dataUri = Uri.parse('data:text/calendar;charset=utf-8,$encoded');

    if (!await launchUrl(dataUri)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open calendar file')),
        );
      }
    }
  }

  /// Formats a DateTime as Google Calendar's required format: 20260305T140000Z
  static String _formatGoogleDate(DateTime dt) {
    final utc = dt.toUtc();
    return '${utc.year}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        'T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '00Z';
  }

  /// Generates a standard .ics (iCalendar) file string.
  static String _generateIcs(Match match) {
    final start = _formatIcsDate(match.matchDate);
    final end = _formatIcsDate(
      match.matchDate.add(const Duration(hours: 1, minutes: 30)),
    );

    final confirmedNames = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .map((r) => r.displayName)
        .join(', ');

    final description =
        'Tennis Match via AntiGravity Tennis\\n'
        'Players: $confirmedNames';

    // Escape special characters for iCalendar format
    final escapedLocation = match.location
        .replaceAll(',', '\\,')
        .replaceAll(';', '\\;');

    return 'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//AntiGravity Tennis//EN\r\n'
        'BEGIN:VEVENT\r\n'
        'DTSTART:$start\r\n'
        'DTEND:$end\r\n'
        'SUMMARY:Tennis: ${match.location}\r\n'
        'LOCATION:$escapedLocation\r\n'
        'DESCRIPTION:$description\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';
  }

  /// Formats a DateTime as iCalendar format: 20260305T140000Z
  static String _formatIcsDate(DateTime dt) {
    final utc = dt.toUtc();
    return '${utc.year}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        'T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}'
        'Z';
  }
}
