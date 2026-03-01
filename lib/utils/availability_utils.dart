import 'package:flutter/material.dart' show DateUtils;
import '../models.dart';

enum AvailabilityStatus { available, away, unknown }

class AvailabilityUtils {
  static const _dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  /// Returns the period key for the given DateTime hour, or null for unusual hours.
  static String? periodForTime(DateTime dt) {
    if (dt.hour >= 5 && dt.hour < 12) return 'morning';
    if (dt.hour >= 12 && dt.hour < 17) return 'afternoon';
    if (dt.hour >= 17 && dt.hour < 23) return 'evening';
    return null;
  }

  static String dayKey(DateTime dt) => _dayKeys[dt.weekday - 1];

  /// Returns the player's availability status for the given date/time slot.
  static AvailabilityStatus playerAvailability(User user, DateTime slot) {
    // 1. Blackout check (date-only comparison)
    final slotDate = DateUtils.dateOnly(slot);
    for (final b in user.blackouts) {
      final bStart = DateUtils.dateOnly(b.start);
      final bEnd = DateUtils.dateOnly(b.end);
      if (!slotDate.isBefore(bStart) && !slotDate.isAfter(bEnd)) {
        return AvailabilityStatus.away;
      }
    }
    // 2. If no weekly availability configured, treat as available (opt-out model)
    if (user.weeklyAvailability.isEmpty) return AvailabilityStatus.available;
    // 3. Weekly availability
    final period = periodForTime(slot);
    if (period == null) return AvailabilityStatus.unknown;
    final periods = user.weeklyAvailability[dayKey(slot)];
    if (periods == null || periods.isEmpty) return AvailabilityStatus.unknown;
    return periods.contains(period)
        ? AvailabilityStatus.available
        : AvailabilityStatus.unknown; // partial day set → unknown, not away
  }
}
