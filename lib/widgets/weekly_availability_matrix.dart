import 'package:flutter/material.dart';

class WeeklyAvailabilityMatrix extends StatefulWidget {
  final Map<String, List<String>> initialAvailability;
  final void Function(Map<String, List<String>>) onAvailabilityChanged;

  const WeeklyAvailabilityMatrix({
    super.key,
    required this.initialAvailability,
    required this.onAvailabilityChanged,
  });

  @override
  State<WeeklyAvailabilityMatrix> createState() => _WeeklyAvailabilityMatrixState();
}

class _WeeklyAvailabilityMatrixState extends State<WeeklyAvailabilityMatrix> {
  final List<String> _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final List<String> _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final List<String> _periods = ['morning', 'afternoon', 'evening'];
  
  // Note: Shortened period labels to match the screen shot better, 
  // where it just said "Morn", "Aft", "Eve" and the times below them.
  final List<String> _periodLabels = ['Morn', 'Aft', 'Eve'];
  final List<String> _periodSubLables = ['5am–Noon', 'Noon–5pm', '5pm–11pm'];

  // Map of [day][period] -> bool
  final Map<String, Map<String, bool>> _selections = {};

  @override
  void initState() {
    super.initState();
    _initializeSelections();
  }

  @override
  void didUpdateWidget(WeeklyAvailabilityMatrix oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialAvailability != oldWidget.initialAvailability) {
      _initializeSelections();
    }
  }

  void _initializeSelections() {
    for (var day in _days) {
      _selections[day] = {
        'morning': false,
        'afternoon': false,
        'evening': false,
      };
    }

    // Initialize selections from existing data
    for (var day in _days) {
      if (widget.initialAvailability.containsKey(day)) {
        final periods = widget.initialAvailability[day]!;
        for (var p in _periods) {
          if (periods.contains(p)) {
            _selections[day]![p] = true;
          }
        }
      }
    }
  }

  void _notifyParent() {
    final Map<String, List<String>> result = {};
    for (var day in _days) {
      final activePeriods = <String>[];
      for (var p in _periods) {
        if (_selections[day]![p] == true) activePeriods.add(p);
      }
      if (activePeriods.isNotEmpty) {
        result[day] = activePeriods;
      }
    }
    widget.onAvailabilityChanged(result);
  }

  void _toggleAllForDay(String day, bool? value) {
    if (value == null) return;
    setState(() {
      for (var p in _periods) {
        _selections[day]![p] = value;
      }
    });
    _notifyParent();
  }

  void _toggleAllForPeriod(String period, bool? value) {
    if (value == null) return;
    setState(() {
      for (var day in _days) {
        _selections[day]![period] = value;
      }
    });
    _notifyParent();
  }

  bool _isAllDaySelected(String day) {
    return _periods.every((p) => _selections[day]![p] == true);
  }

  bool _isAllPeriodSelected(String period) {
    return _days.every((d) => _selections[d]![period] == true);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 24,
        headingRowColor: WidgetStateProperty.all(Colors.transparent),
        headingRowHeight: 80, // give space for multi-line labels and checkboxes
        dataRowMaxHeight: 64, // give a bit more breathing room
        dataRowMinHeight: 48,
        dividerThickness: 0, // removed inner grid lines to match screenshot style
        border: const TableBorder(
          horizontalInside: BorderSide.none,
          verticalInside: BorderSide.none,
        ),
        columns: [
          const DataColumn(label: SizedBox.shrink()), // Empty top-left cell
          for (int i = 0; i < _periods.length; i++)
            DataColumn(
              label: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_periodLabels[i], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(_periodSubLables[i], style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  // Checkbox below the labels
                  Checkbox(
                    value: _isAllPeriodSelected(_periods[i]),
                    onChanged: (val) => _toggleAllForPeriod(_periods[i], val),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
        ],
        rows: [
          for (int dIdx = 0; dIdx < _days.length; dIdx++)
            DataRow(
              cells: [
                DataCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_dayLabels[dIdx], style: const TextStyle(fontSize: 13, color: Colors.black87)),
                      const SizedBox(width: 8),
                      Checkbox(
                        value: _isAllDaySelected(_days[dIdx]),
                        onChanged: (val) => _toggleAllForDay(_days[dIdx], val),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                for (int pIdx = 0; pIdx < _periods.length; pIdx++)
                  DataCell(
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: FilterChip(
                          labelPadding: EdgeInsets.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                          label: const SizedBox.shrink(),
                          selectedColor: Colors.purple.shade100,
                          backgroundColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: _selections[_days[dIdx]]![_periods[pIdx]] == true 
                                  ? Colors.transparent 
                                  : Colors.grey.shade400,
                            )
                          ),
                          selected: _selections[_days[dIdx]]![_periods[pIdx]]!,
                          onSelected: (val) {
                            setState(() {
                              _selections[_days[dIdx]]![_periods[pIdx]] = val;
                            });
                            _notifyParent();
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
