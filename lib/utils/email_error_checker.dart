import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Checks for recent email delivery failures (e.g. Resend quota exceeded)
/// by reading the delivery status that the Firebase Trigger Email extension
/// writes back to each document in the `mail` collection.
class EmailErrorChecker {
  static DateTime? _lastBannerShown;

  /// Checks recent mail docs for delivery errors.
  /// Returns a user-friendly message if failures are detected, null otherwise.
  static Future<String?> checkForRecentFailures() async {
    try {
      final cutoff = Timestamp.fromDate(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      final errorDocs = await FirebaseFirestore.instance
          .collection('mail')
          .where('delivery.state', isEqualTo: 'ERROR')
          .where('delivery.endTime', isGreaterThan: cutoff)
          .orderBy('delivery.endTime', descending: true)
          .limit(5)
          .get();

      if (errorDocs.docs.isEmpty) return null;

      // Check if errors look like quota/rate limit issues
      for (final doc in errorDocs.docs) {
        final delivery = doc.data()['delivery'] as Map<String, dynamic>?;
        if (delivery == null) continue;

        final error = (delivery['error'] ?? '').toString().toLowerCase();

        if (error.contains('quota') ||
            error.contains('rate limit') ||
            error.contains('429') ||
            error.contains('limit exceeded') ||
            error.contains('too many') ||
            error.contains('sending paused')) {
          return "We've hit our email limit for the month! "
              "Notifications won't go out right now. "
              "Please use the Match Chat to coordinate.";
        }
      }

      // Generic SMTP failures (auth issues, server down, etc.)
      return "Some email notifications couldn't be delivered. "
          "Please use the Match Chat to stay in touch.";
    } catch (_) {
      // Firestore query failed (missing index, offline, etc.) — silently ignore
      return null;
    }
  }

  /// Shows a friendly banner if there are recent email delivery failures.
  /// Rate-limited to at most once per 30 minutes to avoid spamming.
  static Future<void> showBannerIfNeeded(BuildContext context) async {
    // Don't show more than once every 30 minutes
    if (_lastBannerShown != null &&
        DateTime.now().difference(_lastBannerShown!).inMinutes < 30) {
      return;
    }

    final message = await checkForRecentFailures();
    if (message == null) return;
    if (!context.mounted) return;

    _lastBannerShown = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.email_outlined,
          color: Colors.orange.shade700,
          size: 36,
        ),
        title: const Text("Email Notifications Paused"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Got it"),
          ),
        ],
      ),
    );
  }
}
