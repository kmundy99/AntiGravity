import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

void main() {
  test('SfCalendar appointments filter map', () {
    final now = DateTime.now();
    final appointments = <Appointment>[
      Appointment(
        startTime: DateTime(now.year, now.month, now.day, 10, 0, 0),
        endTime: DateTime(now.year, now.month, now.day, 12, 0, 0),
        subject: 'Boston (2 Spots)',
        isAllDay: false,
      ),
    ];

    final dataSource = _MeetingDataSource(appointments);
    expect(dataSource.appointments!.length, 1);
  });
}

class _MeetingDataSource extends CalendarDataSource {
  _MeetingDataSource(List<Appointment> source) {
    appointments = source;
  }
}
