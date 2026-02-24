import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

void main() {
  testWidgets('SfCalendar test', (WidgetTester tester) async {
    final now = DateTime.now();
    final appointments = <Appointment>[
      Appointment(
        startTime: now.subtract(const Duration(hours: 1)),
        endTime: now.add(const Duration(hours: 1)),
        subject: 'TEST BLOCK',
        color: Colors.blue,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SfCalendar(
            view: CalendarView.month,
            dataSource: _MeetingDataSource(appointments),
            monthViewSettings: const MonthViewSettings(
              showAgenda: false,
              appointmentDisplayMode: MonthAppointmentDisplayMode.appointment,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    
    expect(find.text('TEST BLOCK'), findsWidgets);
  });
}

class _MeetingDataSource extends CalendarDataSource {
  _MeetingDataSource(List<Appointment> source) {
    appointments = source;
  }
}
