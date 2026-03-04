import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:convert';
import '../models.dart';
import '../secrets.dart';
import '../services/firebase_service.dart';
import '../utils/message_templates.dart';

class ContractSetupScreen extends StatefulWidget {
  final String? contractId;
  final Contract? existingContract;
  final String organizerId;
  final String organizerName;

  const ContractSetupScreen({
    super.key,
    this.contractId,
    this.existingContract,
    this.organizerId = '',
    this.organizerName = '',
  });

  @override
  State<ContractSetupScreen> createState() => _ContractSetupScreenState();
}

class _ContractSetupScreenState extends State<ContractSetupScreen> {
  final _clubNameCtrl = TextEditingController();
  final _totalCostCtrl = TextEditingController();
  final _pricePerSlotCtrl = TextEditingController();
  final _paymentInfoCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _notifAvailDaysCtrl = TextEditingController(text: '7');
  final _notifPaymentWeeksCtrl = TextEditingController(text: '4');
  final _notifLineupDaysCtrl = TextEditingController(text: '2');
  TimeOfDay _notifLineupTime = const TimeOfDay(hour: 10, minute: 0);
  bool _notificationModeAuto = true; // true = auto, false = manual
  bool _pinVisible = false;
  String _clubAddress = '';
  TextEditingController? _addressController;
  List<int> _courtNumbers = [];
  int _courtsCount = 1;
  int _weekday = 3; // Wednesday default
  TimeOfDay _startTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 10, minute: 30);
  DateTime _seasonStart = DateTime(DateTime.now().year, 9, 1);
  DateTime _seasonEnd = DateTime(DateTime.now().year + 1, 5, 31);
  List<DateTime> _holidayDates = [];
  bool _isSaving = false;
  ContractStatus _status = ContractStatus.draft;

  final _firebaseService = FirebaseService();

  static const _weekdayNames = [
    '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  @override
  void initState() {
    super.initState();
    final c = widget.existingContract;
    if (c != null) {
      _clubNameCtrl.text = c.clubName;
      _clubAddress = c.clubAddress;
      _courtNumbers = List.from(c.courtNumbers);
      _courtsCount = c.courtsCount;
      _weekday = c.weekday;
      _startTime = _minutesToTimeOfDay(c.startMinutes);
      _endTime = _minutesToTimeOfDay(c.endMinutes);
      _seasonStart = c.seasonStart;
      _seasonEnd = c.seasonEnd;
      _holidayDates = List.from(c.holidayDates);
      if (c.totalContractCost > 0) _totalCostCtrl.text = c.totalContractCost.toStringAsFixed(2);
      if (c.pricePerSlot > 0) _pricePerSlotCtrl.text = c.pricePerSlot.toStringAsFixed(2);
      _paymentInfoCtrl.text = c.paymentInfo;
      _pinCtrl.text = c.organizerPin;
      _notifAvailDaysCtrl.text = '${c.notifAvailDaysBefore}';
      _notifPaymentWeeksCtrl.text = '${c.notifPaymentWeeksBefore}';
      _notifLineupDaysCtrl.text = '${c.notifLineupDaysBefore}';
      _notifLineupTime = TimeOfDay(
        hour: c.notifLineupTimeMinutes ~/ 60,
        minute: c.notifLineupTimeMinutes % 60,
      );
      _notificationModeAuto = c.notificationMode != 'manual';
      _status = c.status;
    }
  }

  @override
  void dispose() {
    _clubNameCtrl.dispose();
    _totalCostCtrl.dispose();
    _pricePerSlotCtrl.dispose();
    _paymentInfoCtrl.dispose();
    _pinCtrl.dispose();
    _notifAvailDaysCtrl.dispose();
    _notifPaymentWeeksCtrl.dispose();
    _notifLineupDaysCtrl.dispose();
    super.dispose();
  }

  void _onTotalCostChanged(String val) {
    final cost = double.tryParse(val);
    final slots = _totalCourtSlots;
    if (cost != null && slots > 0) {
      _pricePerSlotCtrl.text = (cost / slots).toStringAsFixed(2);
    }
  }

  void _onPricePerSlotChanged(String val) {
    final price = double.tryParse(val);
    final slots = _totalCourtSlots;
    if (price != null && slots > 0) {
      _totalCostCtrl.text = (price * slots).toStringAsFixed(2);
    }
  }

  TimeOfDay _minutesToTimeOfDay(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  int _timeOfDayToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<List<String>> _fetchPlaceSuggestions(String input) async {
    if (input.isEmpty) return [];
    try {
      final response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': placesApiKey,
        },
        body: jsonEncode({'input': input}),
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final suggestions = json['suggestions'] as List? ?? [];
        return suggestions
            .where((s) => s['placePrediction'] != null)
            .map((s) => s['placePrediction']['text']['text'] as String)
            .toList();
      }
    } catch (e) {
      debugPrint('Places autocomplete error: $e');
    }
    return [];
  }

  // Computed values for display
  int get _totalSessions {
    if (_seasonStart.isAfter(_seasonEnd)) return 0;
    int count = 0;
    DateTime current = _seasonStart;
    // Advance to first matching weekday
    while (current.weekday != _weekday && !current.isAfter(_seasonEnd)) {
      current = current.add(const Duration(days: 1));
    }
    while (!current.isAfter(_seasonEnd)) {
      final isHoliday = _holidayDates.any(
        (h) => h.year == current.year && h.month == current.month && h.day == current.day,
      );
      if (!isHoliday) count++;
      current = current.add(const Duration(days: 7));
    }
    return count;
  }

  int get _spotsPerSession => _courtsCount * 4;
  int get _totalCourtSlots => _spotsPerSession * _totalSessions;

  Future<void> _save() async {
    if (_clubNameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Club name is required')),
      );
      return;
    }
    if (_seasonStart.isAfter(_seasonEnd)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Season start must be before season end')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final existing = widget.existingContract;
      final notifAvailDays = int.tryParse(_notifAvailDaysCtrl.text) ?? 7;
      final notifPaymentWeeks = int.tryParse(_notifPaymentWeeksCtrl.text) ?? 4;
      final notifLineupDays = int.tryParse(_notifLineupDaysCtrl.text) ?? 2;
      final notifLineupTimeMinutes = _notifLineupTime.hour * 60 + _notifLineupTime.minute;
      var roster = List<ContractPlayer>.from(existing?.roster ?? []);

      // Auto-add organizer to roster if not already present
      final organizerId = existing?.organizerId ?? widget.organizerId;
      if (!roster.any((p) => p.uid == organizerId)) {
        final organizerUser = await _firebaseService.getUser(organizerId);
        if (organizerUser != null) {
          roster.insert(0, ContractPlayer(
            uid: organizerUser.uid,
            displayName: organizerUser.displayName,
            email: organizerUser.email,
            phone: organizerUser.phoneNumber.isNotEmpty
                ? organizerUser.phoneNumber
                : organizerUser.primaryContact,
          ));
        }
      }
      final contract = Contract(
        id: existing?.id ?? '',
        organizerId: existing?.organizerId ?? widget.organizerId,
        clubName: _clubNameCtrl.text.trim(),
        clubAddress: _clubAddress,
        courtNumbers: _courtNumbers,
        courtsCount: _courtsCount,
        weekday: _weekday,
        startMinutes: _timeOfDayToMinutes(_startTime),
        endMinutes: _timeOfDayToMinutes(_endTime),
        seasonStart: _seasonStart,
        seasonEnd: _seasonEnd,
        holidayDates: _holidayDates,
        status: _status,
        roster: roster,
        rosterUids: roster.map((p) => p.uid).toList(),
        totalContractCost: double.tryParse(_totalCostCtrl.text) ?? 0,
        pricePerSlot: double.tryParse(_pricePerSlotCtrl.text) ?? 0,
        paymentInfo: _paymentInfoCtrl.text.trim(),
        organizerPin: _pinCtrl.text.trim(),
        notifAvailDaysBefore: notifAvailDays,
        notifPaymentWeeksBefore: notifPaymentWeeks,
        notifLineupDaysBefore: notifLineupDays,
        notifLineupTimeMinutes: notifLineupTimeMinutes,
        notificationMode: _notificationModeAuto ? 'auto' : 'manual',
      );

      String savedId;
      if (existing != null) {
        await _firebaseService.updateContract(existing.id, contract.toFirestore());
        savedId = existing.id;
      } else {
        savedId = await _firebaseService.createContract(contract);
      }

      // Generate auto-scheduled messages if contract is active and in auto mode
      if (contract.status == ContractStatus.active &&
          contract.notificationMode == 'auto' &&
          savedId.isNotEmpty) {
        await _generateScheduledMessages(savedId, contract);
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving contract: $e')),
        );
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _generateScheduledMessages(String contractId, Contract contract) async {
    final organizerId = contract.organizerId;
    final organizerName = widget.organizerName;
    final recipients = contract.roster
        .map((p) => RecipientInfo(uid: p.uid, displayName: p.displayName))
        .toList();

    final messages = <ScheduledMessage>[];

    // One availability_request per session
    for (final sessionDate in contract.sessionDates) {
      final scheduledFor = DateTime(
        sessionDate.year, sessionDate.month, sessionDate.day,
        9, 0,
      ).subtract(Duration(days: contract.notifAvailDaysBefore));
      if (scheduledFor.isBefore(DateTime.now())) continue; // skip past dates

      final config = ComposeMessageConfig(
        organizerUid: organizerId,
        organizerName: organizerName,
        availableTypes: const [MessageType.availabilityRequest],
        initialType: MessageType.availabilityRequest,
        recipients: recipients,
        contextType: 'contract',
        contextId: contractId,
        contract: contract,
        sessionDate: sessionDate,
      );
      messages.add(ScheduledMessage(
        contractId: contractId,
        organizerId: organizerId,
        type: 'availability_request',
        sessionDate: sessionDate,
        scheduledFor: scheduledFor,
        subject: MessageTemplates.defaultSubject(MessageType.availabilityRequest, config),
        body: MessageTemplates.defaultBody(MessageType.availabilityRequest, config),
        recipients: recipients,
        recipientsFilter: 'no_response',
      ));

      // lineup_publish per session
      final lineupAt = DateTime(
        sessionDate.year, sessionDate.month, sessionDate.day,
        contract.notifLineupTimeMinutes ~/ 60,
        contract.notifLineupTimeMinutes % 60,
      ).subtract(Duration(days: contract.notifLineupDaysBefore));
      if (!lineupAt.isBefore(DateTime.now())) {
        messages.add(ScheduledMessage(
          contractId: contractId,
          organizerId: organizerId,
          type: 'lineup_publish',
          sessionDate: sessionDate,
          scheduledFor: lineupAt,
          subject: 'Lineup published for your tennis session',
          body: 'Hi {playerName}, the lineup for '
              '${DateFormat('MMM d').format(sessionDate)} has been set. '
              'To manage your spot: {link}',
          recipients: recipients,
          recipientsFilter: 'all',
        ));
      }
    }

    // Weekly payment_reminder from N weeks before season start until 1 week before
    final firstReminder = DateTime(
      contract.seasonStart.year, contract.seasonStart.month, contract.seasonStart.day,
      9, 0,
    ).subtract(Duration(days: contract.notifPaymentWeeksBefore * 7));
    final lastReminder = DateTime(
      contract.seasonStart.year, contract.seasonStart.month, contract.seasonStart.day,
      9, 0,
    ).subtract(const Duration(days: 7));

    DateTime reminderDate = firstReminder;
    while (!reminderDate.isAfter(lastReminder)) {
      if (!reminderDate.isBefore(DateTime.now())) {
        final config = ComposeMessageConfig(
          organizerUid: organizerId,
          organizerName: organizerName,
          availableTypes: const [MessageType.paymentReminder],
          initialType: MessageType.paymentReminder,
          recipients: recipients,
          contextType: 'contract',
          contextId: contractId,
          contract: contract,
          contractRosterPlayers: contract.roster,
        );
        messages.add(ScheduledMessage(
          contractId: contractId,
          organizerId: organizerId,
          type: 'payment_reminder',
          scheduledFor: reminderDate,
          subject: MessageTemplates.defaultSubject(MessageType.paymentReminder, config),
          body: MessageTemplates.defaultBody(MessageType.paymentReminder, config),
          recipients: recipients,
          recipientsFilter: 'unpaid',
        ));
      }
      reminderDate = reminderDate.add(const Duration(days: 7));
    }

    await _firebaseService.saveScheduledMessages(contractId, messages);
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingContract != null;
    final sessions = _totalSessions;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Contract' : 'Set Up Contract'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── CLUB & COURT ──────────────────────────────────────────
          const Text(
            'CLUB & COURT',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _clubNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Club Name',
              prefixIcon: Icon(Icons.business),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TypeAheadField<String>(
            suggestionsCallback: _fetchPlaceSuggestions,
            itemBuilder: (context, suggestion) => ListTile(
              leading: const Icon(Icons.place),
              title: Text(suggestion),
            ),
            onSelected: (suggestion) {
              setState(() => _clubAddress = suggestion);
              _addressController?.text = suggestion;
            },
            builder: (context, controller, focusNode) {
              _addressController = controller;
              if (_clubAddress.isNotEmpty && controller.text.isEmpty) {
                controller.text = _clubAddress;
              }
              return TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: (val) => _clubAddress = val,
                decoration: const InputDecoration(
                  labelText: 'Club Address',
                  hintText: 'Search address...',
                  prefixIcon: Icon(Icons.map),
                  border: OutlineInputBorder(),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          // Court numbers multi-select chips
          const Text('Court Numbers', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: List.generate(10, (i) {
              final n = i + 1;
              final selected = _courtNumbers.contains(n);
              return FilterChip(
                label: Text('$n'),
                selected: selected,
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _courtNumbers.add(n);
                      _courtNumbers.sort();
                    } else {
                      _courtNumbers.remove(n);
                    }
                  });
                },
              );
            }),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.table_rows),
            title: const Text('Number of Courts'),
            trailing: DropdownButton<int>(
              value: _courtsCount,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 court')),
                DropdownMenuItem(value: 2, child: Text('2 courts')),
              ],
              onChanged: (v) => setState(() => _courtsCount = v!),
            ),
          ),

          const Divider(height: 32),

          // ── SCHEDULE ──────────────────────────────────────────────
          const Text(
            'SCHEDULE',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.date_range),
            title: const Text('Day of Week'),
            trailing: DropdownButton<int>(
              value: _weekday,
              items: List.generate(7, (i) {
                final d = i + 1;
                return DropdownMenuItem(value: d, child: Text(_weekdayNames[d]));
              }),
              onChanged: (v) => setState(() => _weekday = v!),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time),
                  title: const Text('Start'),
                  subtitle: Text(_startTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: _startTime,
                    );
                    if (t != null) setState(() => _startTime = t);
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time_filled),
                  title: const Text('End'),
                  subtitle: Text(_endTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: _endTime,
                    );
                    if (t != null) setState(() => _endTime = t);
                  },
                ),
              ),
            ],
          ),

          const Divider(height: 32),

          // ── SEASON ────────────────────────────────────────────────
          const Text(
            'SEASON',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Season Start'),
                  subtitle: Text(_formatDate(_seasonStart)),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _seasonStart,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2040),
                    );
                    if (d != null) setState(() => _seasonStart = d);
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month),
                  title: const Text('Season End'),
                  subtitle: Text(_formatDate(_seasonEnd)),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _seasonEnd,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2040),
                    );
                    if (d != null) setState(() => _seasonEnd = d);
                  },
                ),
              ),
            ],
          ),
          if (sessions > 0) ...[
            const SizedBox(height: 8),
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This season has $sessions sessions'
                      ' (weekly ${_weekdayNames[_weekday]}s, excluding holidays)',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Total court capacity: $_totalCourtSlots slots'
                      ' ($sessions sessions × $_spotsPerSession spots/session)',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Full share = $sessions sessions  |  '
                      'Half = ${sessions ~/ 2}  |  '
                      'Quarter = ${sessions ~/ 4}',
                      style: const TextStyle(color: Colors.blueGrey),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const Divider(height: 32),

          // ── PRICING ───────────────────────────────────────────────
          const Text(
            'PRICING',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _totalCostCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Total Contract Cost',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _onTotalCostChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pricePerSlotCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Price per Slot',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _onPricePerSlotChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Enter either value — the other is calculated automatically.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const Divider(height: 32),

          // ── PAYMENT ───────────────────────────────────────────────
          const Text(
            'PAYMENT',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _paymentInfoCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Payment Instructions',
              hintText: 'e.g. Venmo @organizer-handle, or bank transfer details',
              border: OutlineInputBorder(),
            ),
          ),

          const Divider(height: 32),

          // ── SECURITY ──────────────────────────────────────────────
          const Text(
            'SECURITY',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            obscureText: !_pinVisible,
            maxLength: 8,
            decoration: InputDecoration(
              labelText: 'Organizer PIN',
              hintText: 'Optional — 4 to 8 digits',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              counterText: '',
              suffixIcon: IconButton(
                icon: Icon(_pinVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _pinVisible = !_pinVisible),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'If set, this PIN is required to manage the contract (confirm payments, remove players, etc.). Players are not affected.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const Divider(height: 32),

          // ── HOLIDAY DATES ─────────────────────────────────────────
          const Text(
            'HOLIDAY DATES (OPEN PLAY — EXCLUDED FROM SEASON)',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ..._holidayDates.map(
                (d) => Chip(
                  label: Text(_formatDate(d)),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => setState(() => _holidayDates.remove(d)),
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Add Holiday'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _seasonStart,
                    firstDate: _seasonStart,
                    lastDate: _seasonEnd,
                  );
                  if (d != null && !_holidayDates.any(
                    (h) => h.year == d.year && h.month == d.month && h.day == d.day,
                  )) {
                    setState(() {
                      _holidayDates.add(d);
                      _holidayDates.sort();
                    });
                  }
                },
              ),
            ],
          ),

          const Divider(height: 32),

          // ── STATUS ────────────────────────────────────────────────
          const Text(
            'CONTRACT STATUS',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          SegmentedButton<ContractStatus>(
            segments: const [
              ButtonSegment(
                value: ContractStatus.draft,
                label: Text('Draft'),
                icon: Icon(Icons.edit_outlined, size: 16),
              ),
              ButtonSegment(
                value: ContractStatus.active,
                label: Text('Active'),
                icon: Icon(Icons.check_circle_outline, size: 16),
              ),
              ButtonSegment(
                value: ContractStatus.completed,
                label: Text('Completed'),
                icon: Icon(Icons.archive_outlined, size: 16),
              ),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
          const SizedBox(height: 4),
          Text(
            _status == ContractStatus.draft
                ? 'Draft: contract is not yet visible to players. No messages are scheduled.'
                : _status == ContractStatus.active
                    ? 'Active: auto-messages will be scheduled on save.'
                    : 'Completed: season is over. No new messages will be scheduled.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const Divider(height: 32),

          // ── NOTIFICATIONS ─────────────────────────────────────────
          const Text(
            'NOTIFICATIONS',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Notification mode'),
                    Text(
                      'Manual: no auto-scheduled messages. You compose and send everything yourself.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Auto')),
                  ButtonSegment(value: false, label: Text('Manual')),
                ],
                selected: {_notificationModeAuto},
                onSelectionChanged: (v) => setState(() => _notificationModeAuto = v.first),
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!_notificationModeAuto)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'In manual mode, you can still use Compose Message to send emails/SMS, and slot assignment still works. Auto-scheduled messages will not be created.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _notifAvailDaysCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Availability request',
                    suffixText: 'days before',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _notifPaymentWeeksCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Payment reminders',
                    suffixText: 'weeks before start',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _notifLineupDaysCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Auto-assign lineup',
                    suffixText: 'days before',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ActionChip(
                avatar: const Icon(Icons.access_time, size: 16),
                label: Text(_notifLineupTime.format(context)),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: _notifLineupTime,
                  );
                  if (t != null) setState(() => _notifLineupTime = t);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Payment reminders repeat weekly until the season starts. Only sent to unpaid players.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const SizedBox(height: 32),

          // ── SUBMIT ────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _isSaving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(isEditing ? 'Update Contract' : 'Save Contract'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
