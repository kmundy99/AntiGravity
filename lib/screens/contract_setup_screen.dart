import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:http/http.dart' as http;
import 'package:pinput/pinput.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import '../models.dart';
import '../secrets.dart';
import '../services/firebase_service.dart';
import '../services/location_service.dart';
import '../utils/message_templates.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

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
  final _notifAvailReminderHoursCtrl = TextEditingController(text: '24');
  TimeOfDay _notifLineupTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _notifAvailTime = const TimeOfDay(hour: 10, minute: 0);
  bool _notificationModeAuto = true; // true = auto-send, false = auto-create only
  String _lineupMode = 'percent_played';
  String _contractType = 'contract'; // 'contract' | 'team'
  bool _typeChosen = false; // true once the user picks a type (or when editing)
  Map<String, Map<String, String>> _emailTemplates = {};
  bool _pinVisible = false;
  String _clubAddress = '';
  String _teamUrl = '';
  TextEditingController? _addressController;
  TextEditingController? _teamSearchController;
  List<int> _courtNumbers = [];
  int _courtsCount = 1;
  int _weekday = 3; // Wednesday default
  TimeOfDay _startTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 10, minute: 30);
  DateTime _seasonStart = DateTime(DateTime.now().year, 9, 1);
  DateTime _seasonEnd = DateTime(DateTime.now().year + 1, 5, 31);
  List<DateTime> _holidayDates = [];
  bool _isSaving = false;
  bool _isSyncing = false;
  ContractStatus _status = ContractStatus.draft;

  // Cascading league selector state (team contracts only)
  String _leagueName = '';
  String _divisionName = '';
  List<String> _availableLeagues = [];
  List<String> _availableDivisions = [];

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
      _notifAvailReminderHoursCtrl.text = '${c.notifAvailReminderHoursBefore}';
      _notifLineupTime = TimeOfDay(
        hour: c.notifLineupTimeMinutes ~/ 60,
        minute: c.notifLineupTimeMinutes % 60,
      );
      _notifAvailTime = TimeOfDay(
        hour: c.notifAvailTimeMinutes ~/ 60,
        minute: c.notifAvailTimeMinutes % 60,
      );
      _notificationModeAuto = c.notificationMode != 'manual';
      _emailTemplates = c.emailTemplates.map(
        (k, v) => MapEntry(k, Map<String, String>.from(v)),
      );
      _status = c.status;
      _lineupMode = c.lineupMode;
      _contractType = c.contractType;
      _teamUrl = c.teamUrl;
      _leagueName = c.leagueName;
      _divisionName = c.divisionName;
      _typeChosen = true; // already established — skip type picker
    }
    // Pre-load league list when editing a team contract
    if (_contractType == 'team') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _loadLeagues();
        if (_leagueName.isNotEmpty) await _loadDivisions(_leagueName);
      });
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
    _notifAvailReminderHoursCtrl.dispose();
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

  Future<void> _loadLeagues() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('league_teams').get();
      final names = snap.docs
          .map((d) => (d.data()['league_name'] as String?) ?? '')
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (mounted) setState(() => _availableLeagues = names);
    } catch (e) {
      debugPrint('Error loading leagues: $e');
    }
  }

  Future<void> _loadDivisions(String leagueName) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('league_teams')
          .where('league_name', isEqualTo: leagueName)
          .get();
      final names = snap.docs
          .map((d) => (d.data()['division_name'] as String?) ?? '')
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (mounted) setState(() => _availableDivisions = names);
    } catch (e) {
      debugPrint('Error loading divisions: $e');
    }
  }

  Future<List<LeagueTeam>> _fetchTeamSuggestions(String input) async {
    try {
      Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection('league_teams');
      // Filter by league+division when set (new hierarchical data)
      if (_leagueName.isNotEmpty) {
        q = q.where('league_name', isEqualTo: _leagueName);
      }
      if (_divisionName.isNotEmpty) {
        q = q.where('division_name', isEqualTo: _divisionName);
      }
      final snapshot = await q.get();
      final lq = input.toLowerCase();
      return snapshot.docs
          .map((doc) => LeagueTeam.fromFirestore(doc))
          .where((t) => t.name.isNotEmpty && (input.isEmpty || t.name.toLowerCase().contains(lq)))
          .take(20)
          .toList();
    } catch (e) {
      debugPrint('Error fetching teams: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchPlaceSuggestions(String input) async {
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
            .map((s) => {
                  'text': s['placePrediction']['text']['text'] as String,
                  'placeId': s['placePrediction']['placeId'] as String,
                })
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

  static String _slugify(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<void> _importMatchSchedule() async {
    final contractId = widget.existingContract?.id ?? '';
    final teamName = _clubNameCtrl.text.trim();
    if (contractId.isEmpty || teamName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the team first, then import.')),
      );
      return;
    }

    setState(() => _isSyncing = true);

    try {
      final db = FirebaseFirestore.instance;

      // Step 1: scrape fresh data via Cloud Function.
      // Pass teamUrl for precision when available (avoids cross-division matches).
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'refresh_team_schedules',
          options: HttpsCallableOptions(timeout: const Duration(minutes: 8)),
        );
        final cfPayload = _teamUrl.isNotEmpty
            ? {'teamUrl': _teamUrl, 'teamName': teamName}
            : {'teamName': teamName};
        await callable.call(cfPayload);
      } catch (cfErr) {
        debugPrint('CF error (continuing with cached data): $cfErr');
      }

      // Step 2: query league_matches. Prefer team_url (precise), fall back to slug.
      final slug = _slugify(teamName);
      final seen = <String>{};
      final matches = <Map<String, dynamic>>[];

      if (_teamUrl.isNotEmpty) {
        final urlSnap = await db
            .collection('league_matches')
            .where('team_url', isEqualTo: _teamUrl)
            .get();
        for (final doc in urlSnap.docs) {
          if (seen.add(doc.id)) matches.add(doc.data());
        }
      }

      if (matches.isEmpty) {
        final homeSnaps = await db
            .collection('league_matches')
            .where('home_team_slug', isEqualTo: slug)
            .get();
        final awaySnaps = await db
            .collection('league_matches')
            .where('away_team_slug', isEqualTo: slug)
            .get();
        for (final doc in [...homeSnaps.docs, ...awaySnaps.docs]) {
          final data = doc.data();
          final key = (data['match_url'] as String?)?.isNotEmpty == true
              ? data['match_url'] as String
              : doc.id;
          if (seen.add(key)) matches.add(data);
        }
      }

      if (matches.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No matches found. Run "Refresh Team Directory" first.')),
          );
        }
        return;
      }

      // Derive season bounds and weekday from data.
      String? minDate, maxDate;
      int? derivedWeekday;
      for (final m in matches) {
        final d = m['match_date'] as String?;
        if (d == null || d.isEmpty) continue;
        if (minDate == null || d.compareTo(minDate) < 0) minDate = d;
        if (maxDate == null || d.compareTo(maxDate) > 0) maxDate = d;
        if (derivedWeekday == null) {
          final p = d.split('-');
          if (p.length == 3) {
            final yr = int.tryParse(p[0]);
            final mo = int.tryParse(p[1]);
            final dy = int.tryParse(p[2]);
            if (yr != null && mo != null && dy != null) {
              derivedWeekday = DateTime.utc(yr, mo, dy).weekday;
            }
          }
        }
      }

      if (minDate != null && maxDate != null) {
        final sp = minDate.split('-');
        final ep = maxDate.split('-');
        final sDate = DateTime.utc(int.parse(sp[0]), int.parse(sp[1]), int.parse(sp[2]));
        final eDate = DateTime.utc(int.parse(ep[0]), int.parse(ep[1]), int.parse(ep[2]));
        await db.collection('contracts').doc(contractId).update({
          'season_start': Timestamp.fromDate(sDate),
          'season_end': Timestamp.fromDate(eDate),
          if (derivedWeekday != null) 'weekday': derivedWeekday,
        });
        if (mounted) {
          setState(() {
            _seasonStart = sDate;
            _seasonEnd = eDate;
            if (derivedWeekday != null) _weekday = derivedWeekday!;
          });
        }
      }

      // Write ContractSession docs.
      final batch = db.batch();
      int count = 0;
      for (final m in matches) {
        final matchDateStr = m['match_date'] as String?;
        if (matchDateStr == null) continue;
        final parts = matchDateStr.split('-');
        if (parts.length != 3) continue;
        final yr = int.tryParse(parts[0]);
        final mo = int.tryParse(parts[1]);
        final dy = int.tryParse(parts[2]);
        if (yr == null || mo == null || dy == null) continue;

        final homeTeam = (m['home_team'] as String? ?? '').trim();
        final awayTeam = (m['away_team'] as String? ?? '').trim();
        final isHome = (m['home_team_slug'] as String? ?? _slugify(homeTeam)) == slug;
        final opponent = isHome ? awayTeam : homeTeam;

        final sessionData = <String, dynamic>{
          'date': Timestamp.fromDate(DateTime.utc(yr, mo, dy)),
          'is_home': isHome,
          if (opponent.isNotEmpty) 'opponent_name': opponent,
        };
        final venue = (m['location'] as String?)?.trim();
        if (venue != null && venue.isNotEmpty) sessionData['location_override'] = venue;
        final startStr = (m['start_time'] as String?)?.trim();
        if (startStr != null && startStr.isNotEmpty) {
          final s = startStr.toUpperCase();
          final digits = s.replaceAll(RegExp(r'[^0-9:]'), '');
          final p = digits.split(':');
          final hour = int.tryParse(p[0]);
          if (hour != null) {
            final minute = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0;
            int h = hour;
            if (s.contains('PM') && hour != 12) h = hour + 12;
            if (s.contains('AM') && hour == 12) h = 0;
            sessionData['start_minutes_override'] = h * 60 + minute;
          }
        }

        batch.set(
          db.collection('contracts').doc(contractId).collection('sessions').doc(matchDateStr),
          sessionData,
          SetOptions(merge: true),
        );
        count++;
      }
      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Schedule imported: $count matches.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

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
      final notifAvailTimeMinutes = _notifAvailTime.hour * 60 + _notifAvailTime.minute;
      final notifAvailReminderHours = int.tryParse(_notifAvailReminderHoursCtrl.text) ?? 24;
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
        notifAvailTimeMinutes: notifAvailTimeMinutes,
        notifAvailReminderHoursBefore: notifAvailReminderHours,
        notificationMode: _notificationModeAuto ? 'auto' : 'manual',
        emailTemplates: _emailTemplates,
        lineupMode: _lineupMode,
        contractType: _contractType,
        teamUrl: _teamUrl,
        leagueName: _leagueName,
        divisionName: _divisionName,
      );

      String savedId;
      if (existing != null) {
        await _firebaseService.updateContract(existing.id, contract.toFirestore());
        savedId = existing.id;
      } else {
        savedId = await _firebaseService.createContract(contract);
      }

      // Generate scheduled messages whenever contract is active (both auto and manual modes).
      // autoSendEnabled controls whether the Cloud Function fires them automatically.
      if (contract.status == ContractStatus.active && savedId.isNotEmpty) {
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

  /// Returns the custom template body/subject for [typeKey] if set, else the default.
  String _tmplSubject(String typeKey, MessageType msgType, ComposeMessageConfig config) {
    final override = _emailTemplates[typeKey]?['subject'] ?? '';
    return override.isNotEmpty ? override : MessageTemplates.defaultSubject(msgType, config);
  }

  String _tmplBody(String typeKey, MessageType msgType, ComposeMessageConfig config) {
    final override = _emailTemplates[typeKey]?['body'] ?? '';
    return override.isNotEmpty ? override : MessageTemplates.defaultBody(msgType, config);
  }

  Future<void> _generateScheduledMessages(String contractId, Contract contract) async {
    final organizerId = contract.organizerId;
    final organizerName = widget.organizerName;
    final autoSend = contract.notificationMode == 'auto';
    final recipients = contract.roster
        .map((p) => RecipientInfo(uid: p.uid, displayName: p.displayName))
        .toList();

    final messages = <ScheduledMessage>[];

    for (final sessionDate in contract.sessionDates) {
      // ── Availability request ──────────────────────────────────────────────
      final availAt = DateTime(
        sessionDate.year, sessionDate.month, sessionDate.day,
        contract.notifAvailTimeMinutes ~/ 60,
        contract.notifAvailTimeMinutes % 60,
      ).subtract(Duration(days: contract.notifAvailDaysBefore));
      if (!availAt.isBefore(DateTime.now())) {
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
          scheduledFor: availAt,
          subject: _applyTokens(
            _tmplSubject('availability_request', MessageType.availabilityRequest, config),
            organizerName: organizerName,
            clubName: contract.clubName,
            sessionDate: sessionDate,
            startMinutes: contract.startMinutes,
            endMinutes: contract.endMinutes,
          ),
          body: _applyTokens(
            _tmplBody('availability_request', MessageType.availabilityRequest, config),
            organizerName: organizerName,
            clubName: contract.clubName,
            sessionDate: sessionDate,
            startMinutes: contract.startMinutes,
            endMinutes: contract.endMinutes,
          ),
          recipients: recipients,
          recipientsFilter: 'no_response',
          autoSendEnabled: autoSend,
        ));
      }

      // ── Lineup auto-publish ───────────────────────────────────────────────
      final lineupAt = DateTime(
        sessionDate.year, sessionDate.month, sessionDate.day,
        contract.notifLineupTimeMinutes ~/ 60,
        contract.notifLineupTimeMinutes % 60,
      ).subtract(Duration(days: contract.notifLineupDaysBefore));
      if (!lineupAt.isBefore(DateTime.now())) {
        final lineupConfig = ComposeMessageConfig(
          organizerUid: organizerId,
          organizerName: organizerName,
          availableTypes: const [MessageType.sessionLineup],
          initialType: MessageType.sessionLineup,
          recipients: recipients,
          contextType: 'contract',
          contextId: contractId,
          contract: contract,
          sessionDate: sessionDate,
        );
        messages.add(ScheduledMessage(
          contractId: contractId,
          organizerId: organizerId,
          type: 'lineup_publish',
          sessionDate: sessionDate,
          scheduledFor: lineupAt,
          subject: _applyTokens(
            _tmplSubject('lineup_publish', MessageType.sessionLineup, lineupConfig),
            organizerName: organizerName,
            clubName: contract.clubName,
            sessionDate: sessionDate,
          ),
          // body is ignored for lineup_publish — Cloud Function generates it
          body: _tmplBody('lineup_publish', MessageType.sessionLineup, lineupConfig),
          recipients: recipients,
          recipientsFilter: 'all',
          autoSendEnabled: autoSend,
        ));

        // ── Availability reminder (N hours before lineup) ─────────────────
        final reminderAt = lineupAt.subtract(
          Duration(hours: contract.notifAvailReminderHoursBefore),
        );
        if (!reminderAt.isBefore(DateTime.now())) {
          final reminderConfig = ComposeMessageConfig(
            organizerUid: organizerId,
            organizerName: organizerName,
            availableTypes: const [MessageType.availabilityReminder],
            initialType: MessageType.availabilityReminder,
            recipients: recipients,
            contextType: 'contract',
            contextId: contractId,
            contract: contract,
            sessionDate: sessionDate,
          );
          messages.add(ScheduledMessage(
            contractId: contractId,
            organizerId: organizerId,
            type: 'availability_reminder',
            sessionDate: sessionDate,
            scheduledFor: reminderAt,
            subject: _applyTokens(
              _tmplSubject('availability_reminder', MessageType.availabilityReminder, reminderConfig),
              organizerName: organizerName,
              clubName: contract.clubName,
              sessionDate: sessionDate,
            ),
            body: _applyTokens(
              _tmplBody('availability_reminder', MessageType.availabilityReminder, reminderConfig),
              organizerName: organizerName,
              clubName: contract.clubName,
              sessionDate: sessionDate,
              lineupAt: lineupAt,
            ),
            recipients: recipients,
            recipientsFilter: 'no_response',
            autoSendEnabled: autoSend,
          ));
        }
      }
    }

    // ── Weekly payment reminders ──────────────────────────────────────────────
    final paymentConfig = ComposeMessageConfig(
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
    final paySubject = _applyTokens(
      _tmplSubject('payment_reminder', MessageType.paymentReminder, paymentConfig),
      organizerName: organizerName,
      clubName: contract.clubName,
    );
    final payBody = _applyTokens(
      _tmplBody('payment_reminder', MessageType.paymentReminder, paymentConfig),
      organizerName: organizerName,
      clubName: contract.clubName,
    );

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
        messages.add(ScheduledMessage(
          contractId: contractId,
          organizerId: organizerId,
          type: 'payment_reminder',
          scheduledFor: reminderDate,
          subject: paySubject,
          body: payBody,
          recipients: recipients,
          recipientsFilter: 'unpaid',
          autoSendEnabled: autoSend,
        ));
      }
      reminderDate = reminderDate.add(const Duration(days: 7));
    }

    await _firebaseService.saveScheduledMessages(contractId, messages);
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _templateTypes = [
    ('availability_request', 'Availability Request'),
    ('availability_reminder', 'Availability Reminder'),
    ('payment_reminder', 'Payment Reminder'),
    ('lineup_publish', 'Lineup Notification'),
  ];

  /// Token-based default templates for the setup screen.
  ///
  /// Early-bound tokens (substituted at message-generation time):
  ///   {organizerName}  your display name
  ///   {clubName}       contract club name
  ///   {sessionDate}    e.g. "Sunday, March 15"
  ///   {sessionTime}    e.g. "12:00 PM–2:00 PM"
  ///   {lineupDate}     date by which availability must be entered (reminder only)
  ///   {lineupTime}     time of the lineup cutoff (reminder only)
  ///
  /// Late-bound tokens (substituted at send time):
  ///   {playerName}     each recipient's display name
  ///   {link}           per-player action link
  (String subject, String body) _defaultTemplateText(String typeKey) =>
      switch (typeKey) {
        'availability_request' => (
          'Are you available? {clubName} — {sessionDate}',
          '{organizerName} is checking availability for {clubName} on {sessionDate} ({sessionTime}). '
          'Please let us know if you can make it: {link}',
        ),
        'availability_reminder' => (
          'Reminder — availability needed: {clubName} — {sessionDate}',
          'Hi {playerName}, this is a reminder from {organizerName} — your availability for '
          '{clubName} on {sessionDate} has not been received yet. '
          'If we don\'t hear from you by {lineupDate} at {lineupTime}, you will be marked as Out. '
          'Please respond here: {link}',
        ),
        'payment_reminder' => (
          'Payment Reminder: {clubName}',
          'Hi {playerName}, this is a friendly reminder from {organizerName} that your '
          'payment for {clubName} is due. Please reach out to arrange payment.',
        ),
        _ => ( // lineup_publish — body is auto-generated by the Cloud Function
          'Lineup for {clubName} — {sessionDate}',
          '(The full lineup with player names is generated automatically when this message fires. '
          'You can customise the subject line above; the body is not used.)',
        ),
      };

  /// Substitutes early-bound tokens in a subject or body string.
  /// Late-bound tokens ({playerName}, {link}) are left for send time.
  String _applyTokens(
    String text, {
    required String organizerName,
    required String clubName,
    DateTime? sessionDate,
    int? startMinutes,
    int? endMinutes,
    DateTime? lineupAt,
  }) {
    String fmtMinutes(int m) {
      final h = m ~/ 60, min = m % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${min.toString().padLeft(2, '0')} $suffix';
    }

    var s = text
        .replaceAll('{organizerName}', organizerName)
        .replaceAll('{clubName}', clubName);

    if (sessionDate != null) {
      s = s.replaceAll(
          '{sessionDate}', DateFormat('EEEE, MMMM d').format(sessionDate));
    }
    if (startMinutes != null && endMinutes != null) {
      s = s.replaceAll(
          '{sessionTime}', '${fmtMinutes(startMinutes)}–${fmtMinutes(endMinutes)}');
    }
    if (lineupAt != null) {
      s = s
          .replaceAll('{lineupDate}', DateFormat('MMM d').format(lineupAt))
          .replaceAll('{lineupTime}', DateFormat('h:mm a').format(lineupAt));
    }
    return s;
  }

  List<Widget> _buildEmailTemplateTiles(BuildContext context) {
    return _templateTypes.map(((String typeKey, String label) rec) {
      final typeKey = rec.$1;
      final label = rec.$2;
      final (defaultSubject, defaultBody) = _defaultTemplateText(typeKey);
      final subjectCtrl = TextEditingController(
        text: _emailTemplates[typeKey]?['subject'] ?? defaultSubject,
      );
      final bodyCtrl = TextEditingController(
        text: _emailTemplates[typeKey]?['body'] ?? defaultBody,
      );

      return Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ExpansionTile(
          title: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: Text(
            (_emailTemplates[typeKey]?['subject']?.isNotEmpty == true)
                ? 'Custom template set'
                : 'Using default template',
            style: TextStyle(
              fontSize: 11,
              color: (_emailTemplates[typeKey]?['subject']?.isNotEmpty == true)
                  ? Colors.blue.shade700
                  : Colors.grey,
            ),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: subjectCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      hintText: 'Leave blank to use default',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) {
                      setState(() {
                        _emailTemplates[typeKey] = {
                          ...(_emailTemplates[typeKey] ?? {}),
                          'subject': v,
                        };
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: bodyCtrl,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Body',
                      hintText: 'Use {organizerName}, {clubName}, {sessionDate}, {sessionTime}, {playerName}, {link} as tokens.',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      setState(() {
                        _emailTemplates[typeKey] = {
                          ...(_emailTemplates[typeKey] ?? {}),
                          'body': v,
                        };
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reset to default', style: TextStyle(fontSize: 12)),
                    onPressed: () {
                      final (ds, db) = _defaultTemplateText(typeKey);
                      setState(() {
                        _emailTemplates.remove(typeKey);
                        subjectCtrl.text = ds;
                        bodyCtrl.text = db;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingContract != null;

    // New contract: show type picker before the form
    if (!isEditing && !_typeChosen) {
      return _buildTypePicker();
    }

    final isTeam = _contractType == 'team';
    final sessions = _totalSessions;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing
            ? (isTeam ? 'Edit Team' : 'Edit Contract')
            : (isTeam ? 'Set Up Team' : 'Set Up Contract')),
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
          if (isTeam) ...[
            // ── Step 1: League ─────────────────────────────────────────────
            if (_availableLeagues.isEmpty)
              OutlinedButton.icon(
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('Load Leagues'),
                onPressed: _loadLeagues,
              )
            else
              DropdownButtonFormField<String>(
                value: _leagueName.isEmpty ? null : _leagueName,
                decoration: const InputDecoration(
                  labelText: 'League',
                  prefixIcon: Icon(Icons.emoji_events_outlined),
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Select league'),
                items: _availableLeagues
                    .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                    .toList(),
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _leagueName = val;
                    _divisionName = '';
                    _availableDivisions = [];
                    _teamUrl = '';
                    _clubNameCtrl.clear();
                    _teamSearchController?.clear();
                  });
                  _loadDivisions(val);
                },
              ),
            const SizedBox(height: 12),
            // ── Step 2: Division ───────────────────────────────────────────
            DropdownButtonFormField<String>(
              value: _divisionName.isEmpty ? null : _divisionName,
              decoration: InputDecoration(
                labelText: 'Division',
                prefixIcon: const Icon(Icons.layers_outlined),
                border: const OutlineInputBorder(),
                disabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              hint: Text(_leagueName.isEmpty ? 'Pick a league first' : 'Select division'),
              items: _availableDivisions
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: _leagueName.isEmpty
                  ? null
                  : (val) {
                      if (val == null) return;
                      setState(() {
                        _divisionName = val;
                        _teamUrl = '';
                        _clubNameCtrl.clear();
                        _teamSearchController?.clear();
                      });
                    },
            ),
            const SizedBox(height: 12),
            // ── Step 3: Team search ────────────────────────────────────────
            TypeAheadField<LeagueTeam>(
              suggestionsCallback: _fetchTeamSuggestions,
              itemBuilder: (context, team) => ListTile(
                leading: const Icon(Icons.sports_tennis),
                title: Text(team.name),
                subtitle: Text(team.divisionName.isNotEmpty
                    ? '${team.leagueName} • ${team.divisionName}'
                    : team.leagueName),
              ),
              onSelected: (team) {
                setState(() {
                  _teamSearchController?.text = team.name;
                  _clubNameCtrl.text = team.name;
                  _teamUrl = team.url;
                  if (team.leagueName.isNotEmpty) _leagueName = team.leagueName;
                  if (team.divisionName.isNotEmpty) _divisionName = team.divisionName;
                  if (team.homeClubAddress != null && team.homeClubAddress!.isNotEmpty) {
                    _clubAddress = team.homeClubAddress!;
                    _addressController?.text = team.homeClubAddress!;
                  }
                });
              },
              builder: (context, controller, focusNode) {
                _teamSearchController = controller;
                if (_clubNameCtrl.text.isNotEmpty && controller.text.isEmpty) {
                  controller.text = _clubNameCtrl.text;
                }
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: _divisionName.isNotEmpty,
                  onChanged: (val) {
                    _clubNameCtrl.text = val;
                    _teamUrl = '';
                  },
                  decoration: InputDecoration(
                    labelText: _divisionName.isEmpty
                        ? 'Pick a division first'
                        : 'Search Team Name',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                );
              },
            ),
          ] else
            TextField(
              controller: _clubNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Club Name',
                prefixIcon: Icon(Icons.business),
                border: OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 12),
          TypeAheadField<Map<String, String>>(
            suggestionsCallback: _fetchPlaceSuggestions,
            itemBuilder: (context, suggestion) => ListTile(
              leading: const Icon(Icons.place),
              title: Text(suggestion['text']!),
            ),
            onSelected: (suggestion) async {
              final display = suggestion['text']!;
              final placeId = suggestion['placeId']!;
              _addressController?.text = display;
              setState(() => _clubAddress = display);
              final formatted = await LocationService.fetchFormattedAddress(placeId, placesApiKey);
              if (formatted != null && mounted) {
                setState(() => _clubAddress = formatted);
              }
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
          // Court numbers multi-select chips (contracts only)
          if (!isTeam) ...[
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
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.table_rows),
            title: Text(isTeam ? 'Number of Lines' : 'Number of Courts'),
            trailing: isTeam
                ? DropdownButton<int>(
                    value: _courtsCount,
                    items: List.generate(8, (i) => i + 1)
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n lines')))
                        .toList(),
                    onChanged: (v) => setState(() => _courtsCount = v!),
                  )
                : DropdownButton<int>(
                    value: _courtsCount,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 court')),
                      DropdownMenuItem(value: 2, child: Text('2 courts')),
                    ],
                    onChanged: (v) => setState(() => _courtsCount = v!),
                  ),
          ),

          // ── IMPORT SCHEDULE (team contracts only) ─────────────────
          if (isTeam && widget.existingContract != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  icon: _isSyncing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_rounded, size: 16),
                  label: Text(_isSyncing ? 'Importing…' : 'Import Schedule'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _isSyncing ? null : _importMatchSchedule,
                ),
                if (!_isSyncing && widget.existingContract != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${_formatDate(_seasonStart)} → ${_formatDate(_seasonEnd)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],

          const Divider(height: 32),

          // ── SCHEDULE ──────────────────────────────────────────────
          if (!isTeam) ...[
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
            // Start/End time is a per-match override for teams, not a fixed schedule
            Row(
              children: [
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.access_time),
                    title: const Text('Default Start'),
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
                    title: const Text('Default End'),
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
          ],
          if (isTeam)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Match start/end times are set per match in the Session Grid.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),

          const Divider(height: 32),

          // ── SEASON ────────────────────────────────────────────────
          const Text(
            'SEASON',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          if (isTeam) ...[
            // For team contracts dates are data-driven — set by Sync Schedule.
            Container(
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      leading: Icon(Icons.calendar_today, color: Colors.grey.shade500),
                      title: Text('Season Start',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                      subtitle: Text(_formatDate(_seasonStart),
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                  ),
                  Expanded(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      leading: Icon(Icons.calendar_month, color: Colors.grey.shade500),
                      title: Text('Season End',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                      subtitle: Text(_formatDate(_seasonEnd),
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Dates and day of week are automatically set when you Sync Schedule.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ] else
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
          if (sessions > 0 && !isTeam) ...[
            const SizedBox(height: 8),
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This season has $sessions matches'
                      ' (weekly ${_weekdayNames[_weekday]}s, excluding holidays)',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (!isTeam) ...[
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
                  ],
                ),
              ),
            ),
          ],

          const Divider(height: 32),

          if (!isTeam) ...[
            // ── PRICING ─────────────────────────────────────────────
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

            // ── PAYMENT ─────────────────────────────────────────────
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
          ],

          // ── SECURITY (contracts only — teams use global PIN) ──────
          if (!isTeam) ...[
            const Text(
              'SECURITY',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 12.0, right: 16.0),
                  child: Icon(Icons.lock_outline, color: Colors.grey),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Pinput(
                        controller: _pinCtrl,
                        length: 4,
                        obscureText: !_pinVisible,
                        keyboardType: TextInputType.number,
                        defaultPinTheme: PinTheme(
                          width: 45,
                          height: 55,
                          textStyle: const TextStyle(fontSize: 20, color: Colors.black87),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                        ),
                        focusedPinTheme: PinTheme(
                          width: 45,
                          height: 55,
                          textStyle: const TextStyle(fontSize: 20, color: Colors.black87),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade600, width: 2),
                          ),
                        ),
                        validator: (s) {
                          return (s != null && s.isNotEmpty && s.length < 4) ? 'Enter 4 digits' : null;
                        },
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => setState(() => _pinVisible = !_pinVisible),
                        icon: Icon(_pinVisible ? Icons.visibility_off : Icons.visibility, size: 16),
                        label: Text(_pinVisible ? 'Hide PIN' : 'Show PIN', style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'If set, this 4-digit PIN is required to manage the contract. Players are not affected.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Divider(height: 32),
          ],

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
                ? 'Draft: contract is not yet visible to players. No emails are created.'
                : _status == ContractStatus.active
                    ? 'Active: scheduled emails are created when you save. Use the notification mode below to control whether they auto-send.'
                    : 'Completed: season is over. No new emails will be scheduled.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const Divider(height: 32),

          // ── LINEUP MODE ───────────────────────────────────────────
          const Text(
            'LINEUP MODE',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'percent_played',
                label: Text('Fairness'),
                icon: Icon(Icons.balance, size: 16),
              ),
              ButtonSegment(
                value: 'competitive',
                label: Text('Competitive'),
                icon: Icon(Icons.emoji_events_outlined, size: 16),
              ),
            ],
            selected: {_lineupMode},
            onSelectionChanged: (s) => setState(() => _lineupMode = s.first),
            style: const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _lineupMode == 'percent_played'
                ? 'Fairness: players are assigned based on how often they have played.'
                : 'Competitive: players are assigned to lines (1–4) based on skill level.',
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
                  ],
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Auto-send')),
                  ButtonSegment(value: false, label: Text('Hold sends')),
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
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _notificationModeAuto
                  ? 'Auto-create emails and auto-send emails at scheduled times.'
                  : 'Auto-create emails, but do not auto-send. Emails appear in Notifications — you control when they go out.',
              style: TextStyle(fontSize: 12, color: _notificationModeAuto ? Colors.grey : Colors.orange),
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
              ActionChip(
                avatar: const Icon(Icons.access_time, size: 16),
                label: Text(_notifAvailTime.format(context)),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: _notifAvailTime,
                  );
                  if (t != null) setState(() => _notifAvailTime = t);
                },
              ),
              if (!isTeam) ...[
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
                    labelText: 'Auto-lineup notification',
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
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _notifAvailReminderHoursCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Avail. reminder',
                    suffixText: 'hrs before lineup',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Availability reminder goes only to players who haven\'t responded yet — warns them they\'ll be marked Out if no response by lineup time. Payment reminders repeat weekly; only sent to unpaid players.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const Divider(height: 32),

          if (!isTeam) ...[
            // ── EMAIL TEMPLATES ─────────────────────────────────────
            const Text(
              'EMAIL TEMPLATES',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            const Text(
              'Customize the wording of auto-generated emails. The defaults are shown below — edit freely.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Tokens auto-filled when messages are created:\n'
                '  {organizerName}  your display name\n'
                '  {clubName}       club/contract name\n'
                '  {sessionDate}    e.g. "Sunday, March 15"\n'
                '  {sessionTime}    e.g. "12:00 PM–2:00 PM"\n'
                '  {lineupDate} / {lineupTime}   reminder cutoff\n\n'
                'Tokens filled at send time (one per recipient):\n'
                '  {playerName}     recipient\'s name\n'
                '  {link}           tap-to-respond link',
                style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.blueGrey),
              ),
            ),
            const SizedBox(height: 8),
            ..._buildEmailTemplateTiles(context),
            const Divider(height: 32),
          ],

          const SizedBox(height: 16),

          // ── IMPORT SCHEDULE (teams only, when editing) ─────────────
          if (isTeam && isEditing) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: _isSyncing
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync, size: 18),
                label: Text(_isSyncing ? 'Importing…' : 'Import Match Schedule'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: Colors.orange.shade700),
                  foregroundColor: Colors.orange.shade800,
                ),
                onPressed: _isSyncing ? null : _importMatchSchedule,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Scrapes the latest schedule from the league site and populates session dates automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          ],

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
                  : Text(isEditing
                        ? (isTeam ? 'Update Team' : 'Update Contract')
                        : (isTeam ? 'Save Team' : 'Save Contract')),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildTypePicker() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'What are you creating?',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose a type to get started. This determines which features are shown.',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _typeCard(
                    type: 'contract',
                    icon: Icons.assignment_outlined,
                    title: 'Seasonal Contract',
                    description: 'Fixed venue, recurring sessions, fairness-based slot assignment, player payments.',
                    color: Colors.blue.shade800,
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _typeCard(
                    type: 'team',
                    icon: Icons.emoji_events_outlined,
                    title: 'League Team',
                    description: 'Variable venues, competitive lineup by line (1–4), no payment tracking.',
                    color: Colors.indigo.shade700,
                  )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeCard({
    required String type,
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _contractType = type;
          _typeChosen = true;
          if (type == 'team') _lineupMode = 'competitive';
        });
        if (type == 'team' && _availableLeagues.isEmpty) _loadLeagues();
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 8),
            Text(description,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
