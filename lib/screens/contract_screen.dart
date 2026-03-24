import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';
import '../utils/message_templates.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'compose_message_screen.dart';
import 'contract_setup_screen.dart';
import 'contract_session_grid_screen.dart';
import 'select_players_screen.dart';
import 'sent_messages_screen.dart';
import 'session_email_queue_screen.dart';

class ContractScreen extends StatefulWidget {
  final String currentUserUid;
  final String organizerName;
  final String organizerEmail;
  /// 4-digit PIN stored on the user doc; '' = no gate.
  final String organizerPin;
  /// Contracts the current user is enrolled in as a player (not as organizer).
  final List<Contract> playerContracts;
  const ContractScreen({
    super.key,
    required this.currentUserUid,
    this.organizerName = '',
    this.organizerEmail = '',
    this.organizerPin = '',
    this.playerContracts = const [],
  });

  @override
  State<ContractScreen> createState() => _ContractScreenState();
}

class _ContractScreenState extends State<ContractScreen> {
  final _firebaseService = FirebaseService();
  final Set<String> _selectedPlayerUids = {};

  late Stream<List<Contract>> _contractStream;
  late Stream<List<ScheduledMessage>> _messagesStream;
  int _selectedSeasonalIndex = 0;
  int _selectedTeamIndex = 0;
  bool _isSyncing = false;
  String _syncStatusMsg = ''; // shown below the Sync button during the two-step process
  bool _isRefreshingDirectory = false;
  final Set<String> _fetchingRatings = {};
  final Map<String, double> _powerRatings = {};

  @override
  void initState() {
    super.initState();
    _initStreams();
  }

  @override
  void didUpdateWidget(covariant ContractScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUserUid != widget.currentUserUid) {
      _initStreams();
    }
  }

  void _initStreams() {
    _contractStream = _firebaseService.getContractsByOrganizer(widget.currentUserUid);
    _messagesStream = _firebaseService.getScheduledMessagesStream(widget.currentUserUid);
  }

  // PIN gate state
  bool _pinVerified = false;
  bool _pinVisible = false;
  String? _pinError;
  bool _pinFocusRequested = false;
  final _pinEntryCtrl = TextEditingController();
  final _pinFocusNode = FocusNode();

  @override
  void dispose() {
    _pinEntryCtrl.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  static const _weekdayNames = [
    '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  String _formatTime(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final suffix = h < 12 ? 'AM' : 'PM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:${m.toString().padLeft(2, '0')} $suffix';
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Add players via the shared SelectPlayersScreen ───────────────
  Future<void> _addPlayers(Contract contract) async {
    final List<User>? selected = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelectPlayersScreen(
          currentUserUid: widget.currentUserUid,
          alreadyInRosterUids: contract.roster.map((p) => p.uid).toList(),
          targetLocation: contract.clubAddress,
        ),
      ),
    );

    if (!mounted || selected == null || selected.isEmpty) return;

    final newEntries = selected.map((u) => ContractPlayer(
      uid: u.uid,
      displayName: u.displayName,
      email: u.email,
      phone: u.phoneNumber,
    )).toList();

    await _saveRoster(contract, [...contract.roster, ...newEntries]);
  }

  Future<void> _showPlayerDetailDialog({
    required Contract contract,
    required ContractPlayer existing,
  }) async {
    int slots = existing.paidSlots;
    String paymentStatus = existing.paymentStatus;
    final slotsCtrl = TextEditingController(text: '$slots');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final cost = contract.pricePerSlot > 0 ? slots * contract.pricePerSlot : 0.0;
          return AlertDialog(
            title: Text(existing.displayName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Slots:'),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: slotsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setDialogState(() => slots = int.tryParse(v) ?? 0),
                      ),
                    ),
                    if (contract.pricePerSlot > 0) ...[
                      const SizedBox(width: 12),
                      Text(
                        '= ${_formatCurrency(cost)}',
                        style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),
                const Text('Payment status:'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('Pending'),
                      selected: paymentStatus == 'pending',
                      onSelected: (_) => setDialogState(() => paymentStatus = 'pending'),
                      selectedColor: Colors.amber.shade200,
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Confirmed'),
                      selected: paymentStatus == 'confirmed',
                      onSelected: (_) => setDialogState(() => paymentStatus = 'confirmed'),
                      selectedColor: Colors.green.shade200,
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final updated = existing.copyWith(
                    paidSlots: slots,
                    paymentStatus: paymentStatus,
                  );
                  final updatedRoster = contract.roster
                      .map((p) => p.uid == existing.uid ? updated : p)
                      .toList();
                  await _saveRoster(contract, updatedRoster);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    slotsCtrl.dispose();
  }

  Future<void> _deleteContract(Contract contract, {required bool isTeam}) async {
    final label = isTeam ? 'team' : 'contract';
    final name = contract.clubName.isNotEmpty ? contract.clubName : 'Unnamed';
    final isDraft = contract.status == ContractStatus.draft;

    if (!isDraft) {
      // Require explicit confirmation for active / completed contracts.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete $label?'),
          content: Text(
            '"$name" is not in Draft status.\n\n'
            'Deleting it will permanently remove all sessions, rosters, and '
            'scheduled messages. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await _firebaseService.deleteContract(contract.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$name" deleted.'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _transferOwnership(Contract contract) async {
    final searchCtrl = TextEditingController();
    User? selected;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        // Declared here so they survive StatefulBuilder rebuilds
        List<User> results = [];
        bool searching = false;

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            Future<void> doSearch(String q) async {
              if (q.trim().isEmpty) {
                setDialogState(() { results = []; searching = false; });
                return;
              }
              setDialogState(() => searching = true);
              final found = await _firebaseService.searchUsers(q.trim());
              setDialogState(() { results = found; searching = false; });
            }

            return AlertDialog(
              title: const Text('Transfer Ownership'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Search for a user to become the new contract organizer.',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Search by name or email',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: doSearch,
                  ),
                  const SizedBox(height: 8),
                  if (searching)
                    const Center(child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )),
                  if (!searching && results.isNotEmpty)
                    SizedBox(
                      height: 200,
                      child: ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (_, i) {
                          final u = results[i];
                          final isSelected = selected?.uid == u.uid;
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.blue.shade100,
                              child: Text(
                                u.displayName.isNotEmpty ? u.displayName[0].toUpperCase() : '?',
                                style: TextStyle(color: Colors.blue.shade900, fontSize: 13),
                              ),
                            ),
                            title: Text(u.displayName),
                            subtitle: Text(u.email.isNotEmpty ? u.email : u.primaryContact,
                                style: const TextStyle(fontSize: 11)),
                            selected: isSelected,
                            selectedTileColor: Colors.blue.shade50,
                            onTap: () => setDialogState(() => selected = u),
                          );
                        },
                      ),
                    ),
                  if (selected != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green.shade700, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Transfer to: ${selected!.displayName}',
                              style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: selected == null ? null : () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white),
                child: const Text('Transfer'),
              ),
            ],
          );
        },
      );
      },
    );

    searchCtrl.dispose();

    if (confirmed == true && selected != null) {
      await _firebaseService.transferContractOwnership(contract.id, selected!.uid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ownership transferred to ${selected!.displayName}')),
        );
      }
    }
  }

  Future<void> _saveRoster(Contract contract, List<ContractPlayer> roster) async {
    await _firebaseService.updateContract(contract.id, {
      'roster': roster.map((p) => p.toMap()).toList(),
      'roster_uids': roster.map((p) => p.uid).toList(),
    });
  }

  Future<void> _removePlayer(Contract contract, ContractPlayer player) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Player?'),
        content: Text('Remove ${player.displayName} from this contract?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final updated = contract.roster.where((p) => p.uid != player.uid).toList();
      await _saveRoster(contract, updated);
    }
  }

  Future<void> _togglePayment(Contract contract, ContractPlayer player) async {
    final newStatus = player.paymentStatus == 'confirmed' ? 'pending' : 'confirmed';
    final updated = contract.roster
        .map((p) => p.uid == player.uid ? p.copyWith(paymentStatus: newStatus) : p)
        .toList();
    await _saveRoster(contract, updated);

    if (newStatus == 'confirmed' && contract.notificationMode == 'auto') {
      final config = ComposeMessageConfig(
        organizerUid: widget.currentUserUid,
        organizerName: widget.organizerName,
        availableTypes: const [MessageType.paymentConfirmation],
        initialType: MessageType.paymentConfirmation,
        recipients: [RecipientInfo(uid: player.uid, displayName: player.displayName)],
        contextType: 'contract',
        contextId: contract.id,
        contract: contract,
      );
      final subject = MessageTemplates.defaultSubject(MessageType.paymentConfirmation, config);
      final body = MessageTemplates.defaultBody(MessageType.paymentConfirmation, config);
      unawaited(NotificationService.sendComposed(
        recipientUid: player.uid,
        recipientDisplayName: player.displayName,
        subject: subject,
        body: body,
        replyToEmail: widget.organizerEmail,
      ));
      unawaited(_firebaseService.logMessage(MessageLogEntry(
        sentBy: widget.currentUserUid,
        sentAt: DateTime.now(),
        type: MessageType.paymentConfirmation,
        subject: subject,
        body: body,
        recipients: config.recipients,
        contextType: 'contract',
        contextId: contract.id,
        deliveryCount: 1,
        expireAt: DateTime.now().add(const Duration(days: 90)),
      )));
    }
  }


  String _formatCurrency(double amount) => '\$${amount.toStringAsFixed(2)}';

  /// Lowercase and strip all non-alphanumeric characters — mirrors the Python
  /// _slugify() in scraper/writer.py so Dart queries match Firestore slug fields.
  /// e.g. "Woburn Racquet Club - Blue" → "woburnracquetclubblue"
  static String _slugify(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Parses "10:00 AM", "10:00", "10AM", "10 AM" → minutes from midnight.
  /// Returns null if the string can't be parsed.
  static int? _parseTimeToMinutes(String raw) {
    final s = raw.trim().toUpperCase();
    final isPm = s.contains('PM');
    final isAm = s.contains('AM');
    final digits = s.replaceAll(RegExp(r'[^0-9:]'), '');
    final parts = digits.split(':');
    final hour = int.tryParse(parts[0]);
    if (hour == null) return null;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    int h = hour;
    if (isPm && hour != 12) h = hour + 12;
    if (isAm && hour == 12) h = 0;
    return h * 60 + minute;
  }

  Future<void> _syncSchedule(Contract contract) async {
    final myTeam = contract.clubName.trim();
    if (myTeam.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No team name set — edit the contract Club Name first.')),
      );
      return;
    }
    final slug = _slugify(myTeam);
    if (slug.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Team name has no usable characters after slugifying.')),
      );
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatusMsg = 'Step 1 of 2: Scraping latest matches from the league site…';
    });

    try {
      final db = FirebaseFirestore.instance;

      // ── Step 1: Call the Cloud Function to scrape fresh data for this team. ──
      // Pass teamUrl for precision (avoids cross-division contamination when
      // the same club name plays in multiple divisions).
      // Falls through to cached Firestore data on CF error.
      final teamUrl = contract.teamUrl;
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'refresh_team_schedules',
          options: HttpsCallableOptions(timeout: const Duration(minutes: 8)),
        );
        final cfPayload = teamUrl.isNotEmpty
            ? {'teamUrl': teamUrl, 'teamName': myTeam}
            : {'teamName': myTeam};
        await callable.call(cfPayload);
      } catch (cfErr) {
        debugPrint('CF refresh_team_schedules error (continuing with cached data): $cfErr');
      }

      if (!mounted) return;
      setState(() => _syncStatusMsg = 'Step 2 of 2: Importing sessions into contract…');

      // ── Step 2: Query Firestore for this team's matches. ──
      // Prefer querying by team_url (precise, set by new scraper).
      // Fall back to slug-based dual query for older cached data.
      final seen = <String>{};
      final matches = <Map<String, dynamic>>[];

      if (teamUrl.isNotEmpty) {
        final urlSnap = await db
            .collection('league_matches')
            .where('team_url', isEqualTo: teamUrl)
            .get();
        for (final doc in urlSnap.docs) {
          if (seen.add(doc.id)) matches.add(doc.data());
        }
      }

      // If team_url query returned nothing, fall back to slug-based query
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
            SnackBar(
              content: Text(
                'No matches found for "$myTeam" in league_matches. '
                'The cloud scraper may still be running — try again in a minute.',
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      // ── Derive season bounds and weekday from the actual match data. ──
      // This makes the contract fully data-driven: season_start/end and
      // weekday are written back to Firestore so the UI reflects reality.
      String? minDate;
      String? maxDate;
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
        await db.collection('contracts').doc(contract.id).update({
          'season_start': Timestamp.fromDate(
              DateTime.utc(int.parse(sp[0]), int.parse(sp[1]), int.parse(sp[2]))),
          'season_end': Timestamp.fromDate(
              DateTime.utc(int.parse(ep[0]), int.parse(ep[1]), int.parse(ep[2]))),
          if (derivedWeekday != null) 'weekday': derivedWeekday,
        });
      }

      // Batch all session writes for efficiency.
      final batch = db.batch();
      int syncCount = 0;

      for (final m in matches) {
        // match_date is always stored as YYYY-MM-DD string by the scraper.
        final matchDateStr = m['match_date'] as String?;
        if (matchDateStr == null) continue;

        // Use the raw YYYY-MM-DD string directly as the doc ID — no DateTime
        // conversion to avoid local-timezone offset shifting the date.
        final dateId = matchDateStr;
        final parts = matchDateStr.split('-');
        if (parts.length != 3) continue;
        final yr = int.tryParse(parts[0]);
        final mo = int.tryParse(parts[1]);
        final dy = int.tryParse(parts[2]);
        if (yr == null || mo == null || dy == null) continue;

        final homeTeam = (m['home_team'] as String? ?? '').trim();
        final awayTeam = (m['away_team'] as String? ?? '').trim();
        // Use the stored slug field for the isHome check so punctuation
        // differences in the raw team strings can't flip the result.
        final isHome = (m['home_team_slug'] as String? ?? _slugify(homeTeam)) == slug;
        final opponent = isHome ? awayTeam : homeTeam;

        // All keys must be snake_case to match ContractSession.fromFirestore.
        final sessionData = <String, dynamic>{
          'date': Timestamp.fromDate(DateTime.utc(yr, mo, dy)),
          'is_home': isHome,
          if (opponent.isNotEmpty) 'opponent_name': opponent,
        };

        final venue = (m['location'] as String?)?.trim();
        if (venue != null && venue.isNotEmpty) {
          sessionData['location_override'] = venue;
        }

        final startTimeStr = (m['start_time'] as String?)?.trim();
        if (startTimeStr != null && startTimeStr.isNotEmpty) {
          final mins = _parseTimeToMinutes(startTimeStr);
          if (mins != null) sessionData['start_minutes_override'] = mins;
        }

        final sessionRef = db
            .collection('contracts')
            .doc(contract.id)
            .collection('sessions')
            .doc(dateId);
        batch.set(sessionRef, sessionData, SetOptions(merge: true));
        syncCount++;
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Schedule synced: $syncCount matches imported.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSyncing = false; _syncStatusMsg = ''; });
    }
  }

  /// Calls the refresh_team_names Cloud Function to re-scrape the league site
  /// and rebuild the league_teams collection (deduped by team_slug doc ID).
  Future<void> _refreshTeamDirectory() async {
    setState(() => _isRefreshingDirectory = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'refresh_team_names',
        options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
      );
      await callable.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Team directory refreshed.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Refresh failed: [${e.code}] ${e.message}'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Refresh failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshingDirectory = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // User-level PIN gate — shown before any contract data loads.
    if (!_pinVerified) {
      return widget.organizerPin.isNotEmpty
          ? _buildPinGate()
          : _buildCreatePinGate();
    }

    return StreamBuilder<List<Contract>>(
      stream: _contractStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final contracts = snapshot.data ?? [];

        if (contracts.isEmpty) {
          return _buildEmptyState();
        }

        final seasonal = contracts.where((c) => c.contractType == 'contract').toList();
        final teams = contracts.where((c) => c.contractType == 'team').toList();

        return DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Material(
                color: Colors.white,
                elevation: 1,
                child: TabBar(
                  tabs: [
                    Tab(
                      icon: const Icon(Icons.assignment_outlined, size: 18),
                      text: seasonal.isEmpty
                          ? 'Seasonal'
                          : 'Seasonal (${seasonal.length})',
                    ),
                    Tab(
                      icon: const Icon(Icons.emoji_events_outlined, size: 18),
                      text: teams.isEmpty ? 'Leagues' : 'Leagues (${teams.length})',
                    ),
                  ],
                  labelColor: Colors.indigo.shade800,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: Colors.indigo.shade800,
                  labelStyle:
                      const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildTabContent(seasonal, isTeam: false),
                    _buildTabContent(teams, isTeam: true),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTabContent(List<Contract> contracts, {required bool isTeam}) {
    if (contracts.isEmpty) {
      return _buildEmptyTabState(isTeam: isTeam);
    }

    final idxRef = isTeam ? _selectedTeamIndex : _selectedSeasonalIndex;
    final idx = idxRef.clamp(0, contracts.length - 1);
    if (idx != idxRef) {
      WidgetsBinding.instance.addPostFrameCallback((_) => setState(() {
        if (isTeam) {
          _selectedTeamIndex = idx;
        } else {
          _selectedSeasonalIndex = idx;
        }
      }));
    }
    final contract = contracts[idx];
    _hydrateRatings(contract);
    return _buildContractView(contract, contracts, isTeam: isTeam);
  }

  Widget _buildEmptyTabState({required bool isTeam}) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isTeam ? Icons.emoji_events_outlined : Icons.assignment_outlined,
                size: 64,
                color: Colors.blue.shade200,
              ),
              const SizedBox(height: 16),
              Text(
                isTeam ? 'No League Teams yet' : 'No Seasonal Contracts yet',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                isTeam
                    ? 'Create a team to track matches, lineups, and rosters.'
                    : 'Set up a contract to manage your seasonal court sessions.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: Text(isTeam ? 'New Team' : 'New Contract'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContractSetupScreen(
                      organizerId: widget.currentUserUid,
                      organizerName: widget.organizerName,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _hydrateRatings(Contract contract) {
    final missing = contract.roster
        .where((p) =>
            p.powerRating == null &&
            !_powerRatings.containsKey(p.uid) &&
            !_fetchingRatings.contains(p.uid))
        .map((p) => p.uid)
        .toList();
    if (missing.isEmpty) return;
    _fetchingRatings.addAll(missing);
    _firebaseService.fetchPowerRatings(missing).then((ratings) {
      if (mounted) setState(() => _powerRatings.addAll(ratings));
    });
  }

  Widget _buildContractPicker(List<Contract> contracts, {required bool isTeam}) {
    final selectedIdx = isTeam ? _selectedTeamIndex : _selectedSeasonalIndex;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(contracts.length, (i) {
          final c = contracts[i];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(c.clubName.isNotEmpty ? c.clubName : (isTeam ? 'Team ${i + 1}' : 'Contract ${i + 1}')),
              selected: i == selectedIdx,
              onSelected: (_) => setState(() {
                if (isTeam) {
                  _selectedTeamIndex = i;
                } else {
                  _selectedSeasonalIndex = i;
                }
              }),
              selectedColor: Colors.indigo.shade100,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildEmptyState() {
    final enrolled = widget.playerContracts;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // ── Enrolled contracts (player view) ───────────────────────
        if (enrolled.isNotEmpty) ...[
          Text(
            'My Enrolled Contracts',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.indigo.shade800,
            ),
          ),
          const SizedBox(height: 12),
          ...enrolled.map((c) => _buildEnrolledContractCard(c)),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),
        ],
        // ── Organizer empty state ───────────────────────────────────
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.assignment_outlined, size: 80, color: Colors.blue.shade200),
              const SizedBox(height: 24),
              const Text(
                'Set Up Your Contract',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Manage your seasonal court contract, player roster, and slot assignments all in one place.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Get Started'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContractSetupScreen(
                      organizerId: widget.currentUserUid,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEnrolledContractCard(Contract c) {
    const weekdayNames = [
      '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    final weekday = c.weekday >= 1 && c.weekday <= 7
        ? weekdayNames[c.weekday]
        : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.indigo.shade50,
          child: Icon(Icons.sports_tennis, color: Colors.indigo.shade700, size: 20),
        ),
        title: Text(
          c.clubName.isNotEmpty ? c.clubName : 'Unnamed Contract',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          weekday.isNotEmpty
              ? '$weekday · ${c.totalSessions} sessions'
              : '${c.totalSessions} sessions',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: ElevatedButton.icon(
          icon: const Icon(Icons.grid_on, size: 14),
          label: const Text('Session Grid'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo.shade700,
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12),
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ContractSessionGridScreen(
                contract: c,
                currentUserUid: widget.currentUserUid,
                readOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinGate() {
    // Request focus exactly once — avoids the Android keyboard flicker caused by
    // autofocus inside a StreamBuilder that rebuilds on Firestore updates.
    if (!_pinFocusRequested) {
      _pinFocusRequested = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _pinFocusNode.requestFocus();
      });
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outlined, size: 64, color: Colors.blue.shade200),
            const SizedBox(height: 16),
            const Text(
              'Organizer Access',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter your organizer PIN to continue.',
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 260,
              child: Pinput(
                controller: _pinEntryCtrl,
                focusNode: _pinFocusNode,
                length: 4,
                obscureText: !_pinVisible,
                keyboardType: TextInputType.number,
                autofillHints: const [],
                onCompleted: (_) => _checkPin(),
                onSubmitted: (_) => _checkPin(),
                defaultPinTheme: PinTheme(
                  width: 50,
                  height: 60,
                  textStyle: const TextStyle(fontSize: 22, color: Colors.black87),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                ),
                focusedPinTheme: PinTheme(
                  width: 50,
                  height: 60,
                  textStyle: const TextStyle(fontSize: 22, color: Colors.black87),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade600, width: 2),
                  ),
                ),
                errorPinTheme: PinTheme(
                  width: 50,
                  height: 60,
                  textStyle: const TextStyle(fontSize: 22, color: Colors.black87),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red, width: 2),
                  ),
                ),
              ),
            ),
            if (_pinError != null) ...[
              const SizedBox(height: 8),
              Text(
                _pinError!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: 260,
              child: ElevatedButton(
                onPressed: () => _checkPin(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _checkPin() {
    if (_pinEntryCtrl.text == widget.organizerPin) {
      setState(() {
        _pinVerified = true;
        _pinError = null;
        _pinEntryCtrl.clear();
      });
    } else {
      setState(() => _pinError = 'Incorrect PIN — try again');
    }
  }

  Widget _buildCreatePinGate() {
    if (!_pinFocusRequested) {
      _pinFocusRequested = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _pinFocusNode.requestFocus();
      });
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_open_outlined, size: 64, color: Colors.indigo.shade200),
            const SizedBox(height: 16),
            const Text(
              'Create an Organizer PIN',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Set a 4-digit PIN to protect your organizer management screen. '
              'Only you will need to enter it.',
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 260,
              child: Pinput(
                controller: _pinEntryCtrl,
                focusNode: _pinFocusNode,
                length: 4,
                obscureText: !_pinVisible,
                keyboardType: TextInputType.number,
                autofillHints: const [],
                defaultPinTheme: PinTheme(
                  width: 50,
                  height: 60,
                  textStyle: const TextStyle(fontSize: 22, color: Colors.black87),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                ),
                focusedPinTheme: PinTheme(
                  width: 50,
                  height: 60,
                  textStyle: const TextStyle(fontSize: 22, color: Colors.black87),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.indigo.shade600, width: 2),
                  ),
                ),
              ),
            ),
            if (_pinError != null) ...[
              const SizedBox(height: 8),
              Text(
                _pinError!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: 260,
              child: ElevatedButton(
                onPressed: () => _savePin(_pinEntryCtrl.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo.shade800,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Set PIN'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _pinVerified = true),
              child: Text('Skip for now',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _savePin(String pin) async {
    if (pin.length != 4) {
      setState(() => _pinError = 'Enter a 4-digit PIN');
      return;
    }
    await _firebaseService.saveOrganizerPin(widget.currentUserUid, pin);
    if (mounted) {
      setState(() {
        _pinVerified = true;
        _pinError = null;
        _pinEntryCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN saved — you\'re now unlocked')),
      );
    }
  }

  Widget _buildContractView(Contract contract, List<Contract> allContracts, {required bool isTeam}) {
    final sessions = contract.totalSessions;
    final spots = contract.spotsPerSession;
    final total = contract.totalCourtSlots;
    final committed = contract.committedSlots;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Top action row ────────────────────────────────────────
        Row(
          children: [
            if (allContracts.length > 1)
              Expanded(child: _buildContractPicker(allContracts, isTeam: isTeam))
            else
              const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: Text(isTeam ? 'New Team' : 'New Contract'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ContractSetupScreen(
                    organizerId: widget.currentUserUid,
                    organizerName: widget.organizerName,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // ── Summary card ──────────────────────────────────────────
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        contract.clubName.isNotEmpty ? contract.clubName : 'Unnamed Club',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                    _statusChip(contract.status),
                  ],
                ),
                if (contract.clubAddress.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(contract.clubAddress, style: const TextStyle(color: Colors.grey)),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _infoChip(Icons.calendar_today, _weekdayNames[contract.weekday]),
                    _infoChip(Icons.access_time,
                        '${_formatTime(contract.startMinutes)}–${_formatTime(contract.endMinutes)}'),
                    _infoChip(Icons.event, '${_formatDate(contract.seasonStart)} → ${_formatDate(contract.seasonEnd)}'),
                    _infoChip(Icons.sports_tennis, '$sessions sessions'),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Edit Contract Details'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ContractSetupScreen(
                            existingContract: contract,
                            organizerName: widget.organizerName,
                          ),
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.grid_on, size: 16),
                      label: const Text('Session Grid'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ContractSessionGridScreen(
                            contract: contract,
                            currentUserUid: widget.currentUserUid,
                            organizerName: widget.organizerName,
                          ),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('Message History'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SentMessagesScreen(
                            organizerUid: widget.currentUserUid,
                            contextId: contract.id,
                          ),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: const Text('Transfer Ownership'),
                      onPressed: () => _transferOwnership(contract),
                    ),
                    TextButton.icon(
                      icon: Icon(Icons.delete_outline, size: 16, color: Colors.red.shade700),
                      label: Text(
                        'Delete ${isTeam ? 'Team' : 'Contract'}',
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                      onPressed: () => _deleteContract(contract, isTeam: isTeam),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        if (!isTeam) ...[
          const SizedBox(height: 16),

          // ── Capacity indicator ──────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$committed of $total slots committed',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '$sessions sessions × $spots spots/session',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: total > 0 ? (committed / total).clamp(0.0, 1.0) : 0,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      color: committed >= total ? Colors.red : Colors.blue.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 16),

        // ── Session Emails ────────────────────────────────────────
        _buildScheduledMessagesCard(contract),

        const SizedBox(height: 16),

        // ── Roster header ─────────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Players (${contract.roster.length})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add, size: 16),
              label: const Text('Add Player'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _addPlayers(contract),
            ),
          ],
        ),

        if (contract.roster.isNotEmpty) ...[
          const SizedBox(height: 8),
          // ── Select-all + bulk send ───────────────────────────────
          Row(
            children: [
              Checkbox(
                tristate: true,
                value: _selectedPlayerUids.isEmpty
                    ? false
                    : contract.roster.every((p) => _selectedPlayerUids.contains(p.uid))
                        ? true
                        : null,
                onChanged: (_) => setState(() {
                  if (contract.roster.every((p) => _selectedPlayerUids.contains(p.uid))) {
                    _selectedPlayerUids.clear();
                  } else {
                    _selectedPlayerUids.addAll(contract.roster.map((p) => p.uid));
                  }
                }),
              ),
              const Text('Select all'),
              if (_selectedPlayerUids.isNotEmpty) ...[
                const SizedBox(width: 6),
                Chip(
                  label: Text('${_selectedPlayerUids.length} selected'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Colors.blue.shade50,
                  labelStyle: TextStyle(color: Colors.blue.shade800, fontSize: 12),
                ),
              ],
              const Spacer(),
              ElevatedButton.icon(
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Compose Message'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectedPlayerUids.isEmpty
                      ? Colors.grey.shade300
                      : Colors.blue.shade700,
                  foregroundColor: _selectedPlayerUids.isEmpty
                      ? Colors.grey.shade600
                      : Colors.white,
                ),
                onPressed: _selectedPlayerUids.isEmpty
                    ? null
                    : () {
                        final selected = contract.roster
                            .where((p) => _selectedPlayerUids.contains(p.uid))
                            .toList();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ComposeMessageScreen(
                              config: ComposeMessageConfig(
                                organizerUid: widget.currentUserUid,
                                organizerName: widget.organizerName,
                                availableTypes: const [
                                  MessageType.contractInvite,
                                  MessageType.paymentReminder,
                                  MessageType.subRequest,
                                ],
                                initialType: MessageType.contractInvite,
                                recipients: selected.map((p) => RecipientInfo(
                                  uid: p.uid,
                                  displayName: p.displayName,
                                )).toList(),
                                contextType: 'contract',
                                contextId: contract.id,
                                contract: contract,
                                contractRosterPlayers: contract.roster,
                              ),
                            ),
                          ),
                        );
                      },
              ),
            ],
          ),
        ],

        const SizedBox(height: 8),

        if (contract.roster.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('No players yet. Tap "Add Player" to get started.',
                  style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          ...(contract.roster.toList()..sort((a, b) => a.displayName.compareTo(b.displayName)))
              .map((player) => _buildPlayerTile(contract, player)),
      ],
    );
  }

  Widget _buildScheduledMessagesCard(Contract contract) {
    return StreamBuilder<List<ScheduledMessage>>(
      stream: _messagesStream,
      builder: (context, snapshot) {
        final all = snapshot.data ?? [];

        final approvalMsgs = all
            .where((m) => m.status == 'pending_approval' && m.contractId == contract.id)
            .toList();
        final pendingMsgs = all
            .where((m) => m.status == 'pending' && m.contractId == contract.id)
            .toList();

        if (approvalMsgs.isEmpty && pendingMsgs.isEmpty) return const SizedBox.shrink();

        // Count unique upcoming session dates
        final sessionDates = {...approvalMsgs, ...pendingMsgs}
            .where((m) => m.sessionDate != null)
            .map((m) => '${m.sessionDate!.year}-'
                '${m.sessionDate!.month.toString().padLeft(2, '0')}-'
                '${m.sessionDate!.day.toString().padLeft(2, '0')}')
            .toSet();

        final hasReviewReady = approvalMsgs.isNotEmpty;

        return Card(
          shape: hasReviewReady
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.orange.shade300, width: 1.5),
                )
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SessionEmailQueueScreen(
                  organizerUid: widget.currentUserUid,
                  contract: contract,
                  organizerEmail: widget.organizerEmail,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    hasReviewReady
                        ? Icons.mark_email_unread_outlined
                        : Icons.email_outlined,
                    size: 20,
                    color: hasReviewReady ? Colors.orange.shade700 : Colors.blueGrey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasReviewReady
                              ? 'Session Emails — Review Required'
                              : 'Session Emails',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: hasReviewReady ? Colors.orange.shade800 : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasReviewReady
                              ? '${approvalMsgs.length} email group${approvalMsgs.length != 1 ? "s" : ""} ready to review and send'
                              : '${sessionDates.length} upcoming session date${sessionDates.length != 1 ? "s" : ""} — tap to generate previews',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }


  Widget _buildPlayerTile(Contract contract, ContractPlayer player) {
    final isTeam = contract.contractType == 'team';
    final confirmed = player.paymentStatus == 'confirmed';
    final amountOwed = (!isTeam && contract.pricePerSlot > 0)
        ? player.paidSlots * contract.pricePerSlot
        : null;

    final isSelected = _selectedPlayerUids.contains(player.uid);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selectedPlayerUids.add(player.uid);
                } else {
                  _selectedPlayerUids.remove(player.uid);
                }
              }),
              visualDensity: VisualDensity.compact,
            ),
            CircleAvatar(
              backgroundColor: Colors.blue.shade100,
              child: Text(
                player.displayName.isNotEmpty ? player.displayName[0].toUpperCase() : '?',
                style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        title: Builder(builder: (context) {
          final pr = player.powerRating ?? _powerRatings[player.uid];
          return Row(
            children: [
              Flexible(child: Text(player.displayName)),
              if (pr != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'PR ${pr.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade700, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          );
        }),
        subtitle: Text(
          amountOwed != null
              ? '${player.paidSlots} sessions · ${_formatCurrency(amountOwed)}'
              : '${player.paidSlots} sessions',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isTeam) ...[
              FilterChip(
                label: Text(confirmed ? 'Paid' : 'Unpaid',
                    style: const TextStyle(fontSize: 12)),
                selected: confirmed,
                onSelected: (_) => _togglePayment(contract, player),
                selectedColor: Colors.green.shade100,
                backgroundColor: Colors.amber.shade50,
                checkmarkColor: Colors.green.shade700,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: Icon(Icons.notifications_outlined,
                    size: 18, color: Colors.blue.shade400),
                visualDensity: VisualDensity.compact,
                tooltip: 'Send notification',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ComposeMessageScreen(
                    config: ComposeMessageConfig(
                      organizerUid: widget.currentUserUid,
                      organizerName: widget.organizerName,
                      availableTypes: const [
                        MessageType.paymentReminder,
                        MessageType.contractInvite,
                        MessageType.subRequest,
                      ],
                      initialType: MessageType.paymentReminder,
                      recipients: [RecipientInfo(uid: player.uid, displayName: player.displayName)],
                      contextType: 'contract',
                      contextId: contract.id,
                      contract: contract,
                      contractRosterPlayers: contract.roster,
                    ),
                  ),
                ),
              ),
            ),
            ], // end if (!isTeam)
            IconButton(
              icon: Icon(Icons.person_remove_outlined,
                  size: 18, color: Colors.red.shade300),
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove player',
              onPressed: () => _removePlayer(contract, player),
            ),
          ],
        ),
        onTap: () => _showPlayerDetailDialog(
          contract: contract,
          existing: player,
        ),
      ),
    );
  }

  Widget _statusChip(ContractStatus status) {
    final color = switch (status) {
      ContractStatus.draft => Colors.grey,
      ContractStatus.active => Colors.green,
      ContractStatus.completed => Colors.blue,
    };
    return Chip(
      label: Text(status.name.toUpperCase()),
      backgroundColor: color.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _infoChip(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: Colors.blueGrey),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 13, color: Colors.blueGrey)),
    ],
  );

}
