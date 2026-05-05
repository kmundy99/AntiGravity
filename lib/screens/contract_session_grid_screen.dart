import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../utils/feedback_utils.dart';
import 'compose_message_screen.dart';
import 'slot_assignment_screen.dart';

class ContractSessionGridLoaderScreen extends StatelessWidget {
  final String contractId;
  final String sessionDate;

  const ContractSessionGridLoaderScreen({
    super.key,
    required this.contractId,
    required this.sessionDate,
  });

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();
    return StreamBuilder<Contract?>(
      stream: firebase.getContractStream(contractId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final contract = snapshot.data;
        if (contract == null) {
          return const Scaffold(
            body: Center(child: Text('Contract not found')),
          );
        }
        return ContractSessionGridScreen(
          contract: contract,
          currentUserUid: 'read_only_user', // dummy uid since it's read only
          readOnly: true,
        );
      },
    );
  }
}


// Column widths for the fixed stats panel (total: 300px)
const double _colName = 140;
const double _colPR = 50;
const double _colPaid = 35;
const double _colPlayed = 45;
const double _colPct = 45;
const double _colLeft = 35;
const double _statsWidth = _colName + _colPaid + _colPlayed + _colPct + _colLeft; // 300

// Width of each session column
const double _sessionColWidth = 48;
const double _rowHeight = 48;
const double _headerHeight = 52;

class ContractSessionGridScreen extends StatefulWidget {
  final Contract contract;
  final String currentUserUid;
  final String organizerName;
  /// When true the grid is view-only: cells are not editable and the organizer
  /// actions (Send to N, Assign Slots) are hidden.
  final bool readOnly;

  const ContractSessionGridScreen({
    super.key,
    required this.contract,
    required this.currentUserUid,
    this.organizerName = '',
    this.readOnly = false,
  });

  @override
  State<ContractSessionGridScreen> createState() => _ContractSessionGridScreenState();
}

class _ContractSessionGridScreenState extends State<ContractSessionGridScreen> {
  final _firebase = FirebaseService();
  final Set<String> _fetchingRatings = {};
  final Map<String, double> _powerRatings = {};
  DateTime? _ratingsUpdatedAt;

  bool get _isTeam => widget.contract.contractType == 'team';
  // In team mode: Player + Rating + Played columns.
  double get _activeStatsWidth =>
      _isTeam ? _colName + _colPR + _colPlayed : _statsWidth;
  // Team headers need more room: date + opponent + time + location + H/A badge.
  double get _activeHeaderHeight => _isTeam ? 110.0 : _headerHeight;

  // Two separate vertical controllers, kept in sync, so EITHER panel can scroll
  final _statsVScroll = ScrollController();
  final _sessionVScroll = ScrollController();
  bool _vSyncing = false;

  // Shared horizontal scroll controller so the header and body scroll together
  final _hScrollController = ScrollController();

  // ── Quick-fill mode ────────────────────────────────────────────────
  // GlobalKey on the session panel Listener so we can convert global
  // pointer positions into (row, col) cell indices.
  final _sessionPanelKey = GlobalKey();
  bool _quickFillMode = false;
  bool _isRefreshingRatings = false;
  String? _dragPaintState;  // state applied to every cell touched in this drag
  int?    _lastDragRow;     // last row painted — skip re-painting same cell
  int?    _lastDragCol;
  int?    _dragStartRow;    // where the drag originated (to paint on first move)
  int?    _dragStartCol;
  bool    _dragOccurred = false; // true once pointer moves off the start cell

  // Freeze the row order while quick-fill is active so rows don't jump as
  // attendance changes alter the played-% sort.
  List<ContractSession> _latestSessions = [];
  List<ContractPlayer>? _frozenRoster;

  /// Cycles to the next state when tapping in quick-fill mode.
  /// blank → played → out → clear (remove) → played …
  String _nextCycleState(String? current) => switch (current) {
    'played'  => 'out',
    'out'     => 'clear',
    'reserve' => 'played',
    'charged' => 'out',
    _         => 'played',
  };

  /// Converts a global pointer position to (row, col) cell indices within the
  /// session grid, accounting for both scroll offsets. Returns null if the
  /// position is outside the cell area (e.g. in the header row).
  ({int row, int col})? _cellAt(
    Offset globalPos,
    List<ContractPlayer> roster,
    List<DateTime> sessionDates,
  ) {
    final box = _sessionPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final origin = box.localToGlobal(Offset.zero);
    final relX = globalPos.dx - origin.dx + _hScrollController.offset;
    final relY = globalPos.dy - origin.dy - _activeHeaderHeight + _sessionVScroll.offset;
    if (relX < 0 || relY < 0) return null;
    final col = relX ~/ _sessionColWidth;
    final row = relY ~/ _rowHeight;
    if (col >= sessionDates.length || row >= roster.length) return null;
    return (row: row, col: col);
  }

  /// Applies [newState] to the attendance cell for [uid] on [sessionDate].
  /// Also keeps the denormalized `playedSlots` counter on the roster in sync.
  /// Fire-and-forget safe — call with unawaited() during drag.
  Future<void> _applyAttendanceChange({
    required String uid,
    required DateTime sessionDate,
    required List<ContractSession> sessions,
    required String newState,
  }) async {
    final key = _dateKey(sessionDate);
    final existing = sessions.firstWhere(
      (s) => s.id == key,
      orElse: () => ContractSession(id: key, date: sessionDate, attendance: {}),
    );
    final currentState = existing.attendance[uid];
    if (currentState == newState) return; // nothing to do

    if (newState == 'clear') {
      // FieldValue.delete() is required — set(merge:true) cannot remove map keys
      await _firebase.clearAttendanceEntry(widget.contract.id, existing.id, uid);
    } else {
      final updatedAttendance = Map<String, String>.from(existing.attendance)
        ..[uid] = newState;
      await _firebase.upsertSession(widget.contract.id, existing.copyWith(attendance: updatedAttendance));
    }

    // Keep playedSlots in sync
    final wasPlayed  = currentState == 'played' || currentState == 'charged';
    final willBePlayed = newState == 'played' || newState == 'charged';
    if (wasPlayed != willBePlayed) {
        final delta = willBePlayed ? 1 : -1;
        final updatedRoster = widget.contract.roster.map((p) {
        if (p.uid != uid) return p;
        return p.copyWith(playedSlots: (p.playedSlots + delta).clamp(0, p.paidSlots * 2));
        }).toList();
      await _firebase.updateContract(widget.contract.id, {
        'roster': updatedRoster.map((p) => p.toMap()).toList(),
      });
    }
  }

  // Sort state: null = default (played% ascending)
  // Values: 'name' | 'paid' | 'played' | 'pct' | 'left' | 'date:YYYY-MM-DD'
  String? _sortColumn;
  bool _sortAscending = true;

  void _setSort(String column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  /// Numeric order for sorting players by their attendance state in a session.
  int _attendanceOrder(String? state) => switch (state) {
    'available' => 0,
    'played'  => 0, // Legacy support
    'reserve' => 1,
    'charged' => 2,
    'out'     => 3,
    _         => 4,
  };

  /// Format a DateTime as 'YYYY-MM-DD' (used as session doc IDs)
  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _monthAbbr = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _fmtMinsShort(int m) {
    final h = m ~/ 60;
    final min = m % 60;
    final suffix = h < 12 ? 'a' : 'p';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return min == 0 ? '$h12$suffix' : '$h12:${min.toString().padLeft(2,'0')}$suffix';
  }

  static String _fmtMinsFull(int m) {
    final h = m ~/ 60;
    final min = m % 60;
    final suffix = h < 12 ? 'AM' : 'PM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${min.toString().padLeft(2, '0')} $suffix';
  }

  int _playedCount(String uid, List<ContractSession> sessions) => sessions
      .where((s) => s.attendance[uid] == 'played' || s.attendance[uid] == 'charged')
      .length;

  List<String>? _cachedSortOrder;
  String? _lastSortCol;
  bool _lastSortAsc = true;
  int _lastRosterLen = -1;

  /// Sort players according to the active sort column.
  /// Default (no column selected): ascending by Played % with name tiebreaker.
  List<ContractPlayer> _sortedRoster(List<ContractSession> sessions) {
    if (_quickFillMode && _frozenRoster != null) return _frozenRoster!;

    final roster = List<ContractPlayer>.from(widget.contract.roster);

    // Use cached sort order to prevent reordering jumpiness on cell edits
    if (_cachedSortOrder != null &&
        _lastSortCol == _sortColumn &&
        _lastSortAsc == _sortAscending &&
        _lastRosterLen == roster.length) {
      final orderMap = { for (int i=0; i<_cachedSortOrder!.length; i++) _cachedSortOrder![i]: i };
      roster.sort((a,b) => (orderMap[a.uid] ?? 999).compareTo(orderMap[b.uid] ?? 999));
      return roster;
    }

    _lastSortCol = _sortColumn;
    _lastSortAsc = _sortAscending;
    _lastRosterLen = roster.length;

    roster.sort((a, b) {
      int result;
      final col = _sortColumn;
      if (col == null) {
        // Default: ascending played% — most owed first
        final pA = a.paidSlots > 0 ? _playedCount(a.uid, sessions) / a.paidSlots : 0.0;
        final pB = b.paidSlots > 0 ? _playedCount(b.uid, sessions) / b.paidSlots : 0.0;
        result = pA.compareTo(pB);
        if (result == 0) result = a.displayName.compareTo(b.displayName);
        return result; // default sort ignores _sortAscending
      } else if (col == 'name') {
        result = a.displayName.compareTo(b.displayName);
      } else if (col == 'paid') {
        result = a.paidSlots.compareTo(b.paidSlots);
      } else if (col == 'played') {
        result = _playedCount(a.uid, sessions).compareTo(_playedCount(b.uid, sessions));
      } else if (col == 'pct') {
        final pA = a.paidSlots > 0 ? _playedCount(a.uid, sessions) / a.paidSlots : 0.0;
        final pB = b.paidSlots > 0 ? _playedCount(b.uid, sessions) / b.paidSlots : 0.0;
        result = pA.compareTo(pB);
      } else if (col == 'left') {
        final lA = (a.paidSlots - _playedCount(a.uid, sessions)).clamp(0, a.paidSlots);
        final lB = (b.paidSlots - _playedCount(b.uid, sessions)).clamp(0, b.paidSlots);
        result = lA.compareTo(lB);
      } else if (col.startsWith('date:')) {
        final dateKey = col.substring(5);
        final sess = sessions.firstWhere(
          (s) => s.id == dateKey,
          orElse: () => ContractSession(id: dateKey, date: DateTime.now(), attendance: {}),
        );
        result = _attendanceOrder(sess.attendance[a.uid])
            .compareTo(_attendanceOrder(sess.attendance[b.uid]));
      } else {
        result = 0;
      }
      if (result == 0) result = a.displayName.compareTo(b.displayName);
      return _sortAscending ? result : -result;
    });

    _cachedSortOrder = roster.map((p) => p.uid).toList();
    return roster;
  }

  Future<void> _onCellTap({
    required BuildContext cellContext,
    required String uid,
    required DateTime sessionDate,
    required List<ContractSession> sessions,
  }) async {
    final isTeam = _isTeam;
    final lineCount = widget.contract.courtsCount; // for team = number of lines

    final key = _dateKey(sessionDate);
    final existing = sessions.firstWhere(
      (s) => s.id == key,
      orElse: () => ContractSession(id: key, date: sessionDate, attendance: {}),
    );
    final currentState = existing.attendance[uid];

    final RenderBox box = cellContext.findRenderObject() as RenderBox;
    final Offset pos = box.localToGlobal(Offset.zero);

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy + _rowHeight, pos.dx + _sessionColWidth, pos.dy + _rowHeight * 2),
      items: [
        const PopupMenuItem(
            value: 'available',
            child: Row(children: [_ColorDot(Colors.green), SizedBox(width: 8), Text('Available')])),
        // Team mode: Line 1–N instead of generic Played
        if (isTeam)
          ...List.generate(
            lineCount,
            (i) => PopupMenuItem(
              value: 'line:${i + 1}',
              child: Row(children: [
                _ColorDot(Colors.indigo.shade400),
                const SizedBox(width: 8),
                Text('Line ${i + 1}'),
              ]),
            ),
          )
        else
          const PopupMenuItem(
              value: 'played',
              child: Row(children: [_ColorDot(Colors.green), SizedBox(width: 8), Text('Played')])),
        const PopupMenuItem(
            value: 'reserve',
            child: Row(children: [_ColorDot(Colors.amber), SizedBox(width: 8), Text('Reserve')])),
        const PopupMenuItem(
            value: 'out',
            child: Row(children: [_ColorDot(Colors.grey), SizedBox(width: 8), Text('Out')])),
        // Charged only for seasonal contracts
        if (!isTeam)
          const PopupMenuItem(
              value: 'charged',
              child: Row(children: [_ColorDot(Colors.red), SizedBox(width: 8), Text('Charged')])),
        if (currentState != null)
          const PopupMenuItem(
              value: 'clear',
              child: Row(children: [_ColorDot(Colors.white, bordered: true), SizedBox(width: 8), Text('Clear')])),
      ],
    );

    if (result == null || !mounted) return;

    if (result.startsWith('line:')) {
      final line = int.parse(result.substring(5));
      await _applyLineAssignment(
          uid: uid, sessionDate: sessionDate, sessions: sessions, line: line);
    } else {
      await _applyAttendanceChange(
          uid: uid, sessionDate: sessionDate, sessions: sessions, newState: result);
    }
  }

  /// Writes attendance='played' AND assignment={status:confirmed, line:X} atomically.
  Future<void> _applyLineAssignment({
    required String uid,
    required DateTime sessionDate,
    required List<ContractSession> sessions,
    required int line,
  }) async {
    final key = _dateKey(sessionDate);
    final existing = sessions.firstWhere(
      (s) => s.id == key,
      orElse: () => ContractSession(id: key, date: sessionDate, attendance: {}),
    );

    final updatedAttendance = Map<String, String>.from(existing.attendance)
      ..[uid] = 'played';
    final updatedAssignment = Map<String, Map<String, dynamic>>.from(existing.assignment)
      ..[uid] = {'status': 'confirmed', 'line': line};
    // If there was no prior assignment state, promote to draft so it shows in the grid
    final newAssignmentState =
        existing.assignmentState == 'none' ? 'draft' : existing.assignmentState;

    await _firebase.upsertSession(
      widget.contract.id,
      existing.copyWith(
        attendance: updatedAttendance,
        assignment: updatedAssignment,
        assignmentState: newAssignmentState,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _statsVScroll.addListener(() {
      if (_vSyncing) return;
      _vSyncing = true;
      if (_sessionVScroll.hasClients) _sessionVScroll.jumpTo(_statsVScroll.offset);
      _vSyncing = false;
    });
    _sessionVScroll.addListener(() {
      if (_vSyncing) return;
      _vSyncing = true;
      if (_statsVScroll.hasClients) _statsVScroll.jumpTo(_sessionVScroll.offset);
      _vSyncing = false;
    });
    _hydrateRatings();
  }

  void _hydrateRatings() {
    final missing = widget.contract.roster
        .where((p) =>
            p.powerRating == null &&
            !_powerRatings.containsKey(p.uid) &&
            !_fetchingRatings.contains(p.uid))
        .map((p) => p.uid)
        .toList();
    if (missing.isEmpty) return;
    _fetchingRatings.addAll(missing);
    Future.wait([
      _firebase.fetchPowerRatings(missing),
      _firebase.fetchRatingsUpdatedAt(missing),
    ]).then((results) {
      if (!mounted) return;
      setState(() {
        _powerRatings.addAll(results[0] as Map<String, double>);
        final ts = results[1] as DateTime?;
        if (ts != null && (_ratingsUpdatedAt == null || ts.isAfter(_ratingsUpdatedAt!))) {
          _ratingsUpdatedAt = ts;
        }
      });
    });
  }

  @override
  void dispose() {
    _statsVScroll.dispose();
    _sessionVScroll.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contract = widget.contract;
    final today = DateTime.now();
    final todayKey = _dateKey(today);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${contract.clubName.isNotEmpty ? contract.clubName : "Contract"} — Session Grid',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: 'Provide Feedback / Report Idea',
            onPressed: () => showFeedbackModal(
              context,
              widget.currentUserUid,
              null,
              'Session Grid',
            ),
          ),
          if (!widget.readOnly) ...[
            if (_isTeam)
            _isRefreshingRatings
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  )
                : IconButton(
                    icon: const Icon(Icons.star_rate),
                    tooltip: 'Refresh Player Ratings',
                    onPressed: () async {
                      setState(() => _isRefreshingRatings = true);
                      try {
                        final callable = FirebaseFunctions.instance.httpsCallable(
                          'refresh_player_ratings',
                          options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
                        );
                        await callable.call({'teamName': widget.contract.clubName.trim()});
                        // Re-fetch all roster ratings so the grid updates in real time.
                        final uids = widget.contract.roster.map((p) => p.uid).toList();
                        final results = await Future.wait([
                          _firebase.fetchPowerRatings(uids),
                          _firebase.fetchRatingsUpdatedAt(uids),
                        ]);
                        if (mounted) {
                          setState(() {
                            _powerRatings
                              ..clear()
                              ..addAll(results[0] as Map<String, double>);
                            _ratingsUpdatedAt = results[1] as DateTime?;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Player ratings updated.'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Ratings refresh failed: $e'),
                                backgroundColor: Colors.red),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _isRefreshingRatings = false);
                      }
                    },
                  ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              avatar: Icon(
                _quickFillMode ? Icons.edit : Icons.edit_outlined,
                size: 16,
                color: _quickFillMode ? Colors.white : null,
              ),
              label: Text(_quickFillMode ? 'Quick-fill ON' : 'Quick-fill'),
              selected: _quickFillMode,
              onSelected: (_) => setState(() {
                _quickFillMode = !_quickFillMode;
                if (_quickFillMode) {
                  // Snapshot the current sort order so rows don't jump during editing
                  _frozenRoster = _sortedRoster(_latestSessions);
                } else {
                  _frozenRoster = null;
                }
                _dragPaintState = null;
                _lastDragRow = null;
                _lastDragCol = null;
                _dragOccurred = false;
              }),
              selectedColor: Colors.orange.shade700,
              labelStyle: TextStyle(
                color: _quickFillMode ? Colors.white : null,
                fontSize: 12,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
          ],
        ],
      ),
      body: StreamBuilder<List<ContractSession>>(
        stream: _firebase.getSessionsStream(contract.id),
        builder: (context, snapshot) {
          final sessions = snapshot.data ?? [];
          _latestSessions = sessions;
          
          // For team contracts the grid is purely data-driven: only dates that
          // have an actual ContractSession document (written by Sync Schedule)
          // are shown. No calculated dates are mixed in.
          final List<DateTime> finalSessionDates;
          if (contract.contractType == 'team') {
            finalSessionDates = sessions
                .map((s) => DateTime.parse(s.id))
                .toList()..sort();
          } else {
            finalSessionDates = contract.sessionDates;
          }

          final roster = _quickFillMode
              ? (_frozenRoster ?? _sortedRoster(sessions))
              : _sortedRoster(sessions);

          return Column(
            children: [
              _buildSummaryBar(contract, today),
              if (_quickFillMode)
                Container(
                  color: Colors.orange.shade50,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app, size: 14, color: Colors.orange.shade800),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Tap to cycle: blank → P → O → clear. '
                          'Drag across cells to paint. '
                          'Horiz. scroll paused — toggle off to scroll.',
                          style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _buildGrid(
                  roster: roster,
                  sessionDates: finalSessionDates,
                  sessions: sessions,
                  todayKey: todayKey,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummaryBar(Contract contract, DateTime today) {
    final start = contract.seasonStart;
    final end = contract.seasonEnd;
    String fmt(DateTime d) => '${_monthAbbr[d.month]} ${d.day}, ${d.year}';
    return Container(
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '${fmt(start)} – ${fmt(end)}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(width: 16),
          Text(
            '${contract.totalSessions} sessions',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            'Today: ${fmt(today)}',
            style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid({
    required List<ContractPlayer> roster,
    required List<DateTime> sessionDates,
    required List<ContractSession> sessions,
    required String todayKey,
  }) {
    if (roster.isEmpty) {
      return const Center(child: Text('No players in roster yet.', style: TextStyle(color: Colors.grey)));
    }

    final Map<String, ContractSession> sessionsByDate = {
      for (final s in sessions) s.id: s,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Fixed stats panel ──────────────────────────────────────
        SizedBox(
          width: _activeStatsWidth,
          child: Column(
            children: [
              _buildStatsHeader(),
              Expanded(
                child: ListView.builder(
                  controller: _statsVScroll,
                  itemCount: roster.length,
                  itemExtent: _rowHeight,
                  itemBuilder: (_, i) => _buildStatsRow(roster[i], sessions),
                ),
              ),
              _buildStatsFooter(roster, sessions),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        // ── Scrollable session columns ─────────────────────────────
        Expanded(
          child: Listener(
            key: _sessionPanelKey,
            // Pointer down: determine paint state and immediately apply it to the
            // tapped cell. This ensures the tapped cell always updates whether the
            // user is just clicking or starting a drag.
            onPointerDown: _quickFillMode
                ? (event) {
                    final cell = _cellAt(event.position, roster, sessionDates);
                    if (cell == null) return;
                    final key2 = _dateKey(sessionDates[cell.col]);
                    final currentState = sessionsByDate[key2]?.attendance[roster[cell.row].uid];
                    _dragPaintState = _nextCycleState(currentState);
                    _dragStartRow = cell.row;
                    _dragStartCol = cell.col;
                    _lastDragRow = cell.row;
                    _lastDragCol = cell.col;
                    _dragOccurred = false;
                    unawaited(_applyAttendanceChange(
                      uid: roster[cell.row].uid,
                      sessionDate: sessionDates[cell.col],
                      sessions: sessions,
                      newState: _dragPaintState!,
                    ));
                  }
                : null,
            // Pointer move: paint every new cell the drag enters.
            onPointerMove: _quickFillMode
                ? (event) {
                    if (_dragPaintState == null) return;
                    final cell = _cellAt(event.position, roster, sessionDates);
                    if (cell == null) return;
                    if (cell.row == _lastDragRow && cell.col == _lastDragCol) return;
                    _dragOccurred = true;
                    _lastDragRow = cell.row;
                    _lastDragCol = cell.col;
                    unawaited(_applyAttendanceChange(
                      uid: roster[cell.row].uid,
                      sessionDate: sessionDates[cell.col],
                      sessions: sessions,
                      newState: _dragPaintState!,
                    ));
                  }
                : null,
            // Pointer up: reset drag state.
            onPointerUp: _quickFillMode
                ? (event) {
                    _dragPaintState = null;
                    _lastDragRow = null;
                    _lastDragCol = null;
                    _dragStartRow = null;
                    _dragStartCol = null;
                    _dragOccurred = false;
                  }
                : null,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // Disable horizontal scroll while quick-fill is active so drags
              // paint rather than scroll.
              physics: _quickFillMode ? const NeverScrollableScrollPhysics() : null,
              controller: _hScrollController,
            child: SizedBox(
              width: sessionDates.length * _sessionColWidth,
              child: Column(
                children: [
                  _buildSessionHeader(sessionDates, todayKey, sessions),
                  Expanded(
                    child: ListView.builder(
                      controller: _sessionVScroll,
                      itemCount: roster.length,
                      itemExtent: _rowHeight,
                      itemBuilder: (_, i) => _buildSessionRow(
                        player: roster[i],
                        sessionDates: sessionDates,
                        sessionsByDate: sessionsByDate,
                        sessions: sessions,
                        todayKey: todayKey,
                      ),
                    ),
                  ),
                  _buildPTotalsFooter(sessionDates, sessions),
                ],
              ),
            ),
          ),
        ),
      ),
      ],
    );
  }

  Widget _buildStatsHeader() {
    String ratingHeader = 'Rating';
    if (_ratingsUpdatedAt != null) {
      final d = _ratingsUpdatedAt!.toLocal();
      ratingHeader = 'As of\n${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return Container(
      height: _activeHeaderHeight,
      color: Colors.grey.shade100,
      child: Row(
        children: [
          _sortableHeaderCell('Player', _colName, 'name', align: TextAlign.left),
          if (_isTeam)
            Container(
              width: _colPR,
              height: _activeHeaderHeight,
              alignment: Alignment.center,
              child: Text(
                ratingHeader,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey),
              ),
            ),
          if (!_isTeam) _sortableHeaderCell('Paid', _colPaid, 'paid'),
          _sortableHeaderCell('Played', _colPlayed, 'played'),
          if (!_isTeam) _sortableHeaderCell('%', _colPct, 'pct'),
          if (!_isTeam) _sortableHeaderCell('Left', _colLeft, 'left'),
        ],
      ),
    );
  }

  Widget _sortableHeaderCell(
    String text,
    double width,
    String sortKey, {
    TextAlign align = TextAlign.center,
  }) {
    final isActive = _sortColumn == sortKey;
    final color = isActive ? Colors.blue.shade700 : Colors.blueGrey;
    return GestureDetector(
      onTap: () => _setSort(sortKey),
      child: Container(
        width: width,
        height: _activeHeaderHeight,
        color: Colors.transparent,
        alignment: align == TextAlign.left ? Alignment.centerLeft : Alignment.center,
        padding: align == TextAlign.left
            ? const EdgeInsets.only(left: 8)
            : EdgeInsets.zero,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: align == TextAlign.left
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            if (isActive) ...[
              const SizedBox(width: 2),
              Icon(
                _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 9,
                color: color,
              ),
            ] else ...[
              const SizedBox(width: 2),
              Icon(Icons.unfold_more, size: 9, color: Colors.blueGrey.shade300),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow(ContractPlayer player, List<ContractSession> sessions) {
    final played = _playedCount(player.uid, sessions);
    final pct = player.paidSlots > 0
        ? played / player.paidSlots * 100
        : 0.0;
    final left = (player.paidSlots - played).clamp(0, player.paidSlots);

    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _colName,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                player.displayName,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (_isTeam)
            Builder(builder: (context) {
              final pr = player.powerRating ?? _powerRatings[player.uid];
              return Container(
                width: _colPR,
                alignment: Alignment.center,
                child: Text(
                  pr != null && pr > 0 ? pr.toStringAsFixed(2) : '—',
                  style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade500),
                ),
              );
            }),
          if (!_isTeam) _statCell('${player.paidSlots}', _colPaid),
          _statCell('$played', _colPlayed),
          if (!_isTeam) _statCell('${pct.toStringAsFixed(1)}%', _colPct, color: _pctColor(pct, player.paidSlots > 0)),
          if (!_isTeam) _statCell('$left', _colLeft),
        ],
      ),
    );
  }

  Widget _buildSessionHeader(
    List<DateTime> dates,
    String todayKey,
    List<ContractSession> sessions,
  ) {
    return Container(
      height: _activeHeaderHeight,
      color: Colors.grey.shade100,
      child: Row(
        children: dates.map((d) {
          final key = _dateKey(d);
          final isToday = key == todayKey;
          final isPast = d.isBefore(DateTime.now().subtract(const Duration(days: 1)));
          final session = sessions.firstWhere(
            (s) => s.id == key,
            orElse: () => ContractSession(id: key, date: d, attendance: {}),
          );

          // Availability tally for this session
          final avail = session.availability;
          final nYes = avail.values.where((v) => v == 'available').length;
          final nBackup = avail.values.where((v) => v == 'backup').length;
          final nNo = avail.values.where((v) => v == 'unavailable').length;
          final totalResponded = nYes + nBackup + nNo;
          final totalRoster = widget.contract.roster.length;

          final dateKey2 = key; // capture for closure
          final isActiveSortCol = _sortColumn == 'date:$dateKey2';
          final isTeam = widget.contract.contractType == 'team';
          final opponent = session.opponentName;
          // Abbreviate opponent for display: first 5 chars
          final opponentAbbr = (opponent != null && opponent.isNotEmpty)
              ? (opponent.length > 5 ? opponent.substring(0, 5) : opponent)
              : null;
          final loc = session.locationOverride;
          final locationAbbr = (loc != null && loc.isNotEmpty)
              ? (loc.length > 5 ? loc.substring(0, 5) : loc)
              : null;
          
          String timeStr = _fmtMinsFull(session.startMinutesOverride ?? widget.contract.startMinutes);

          return SizedBox(
            width: _sessionColWidth,
            child: GestureDetector(
              // Tap: team mode → edit match details; contract mode → sort
              onTap: isTeam && !widget.readOnly
                  ? () => _onMatchHeaderTap(date: d, session: session)
                  : () => _setSort('date:$dateKey2'),
              // Long press = availability/assignment dialog (organizer only)
              onLongPress: widget.readOnly
                  ? null
                  : () => _onSessionHeaderTap(
                        date: d,
                        session: session,
                        isPast: isPast,
                      ),
              child: ClipRect(
                child: Container(
                decoration: BoxDecoration(
                  color: isActiveSortCol
                      ? Colors.blue.shade50
                      : isToday
                          ? Colors.blue.shade100
                          : (isPast ? Colors.grey.shade50 : null),
                  border: Border(
                    right: BorderSide(color: Colors.grey.shade200),
                    bottom: isActiveSortCol
                        ? BorderSide(
                            color: Colors.blue.shade400,
                            width: 2,
                          )
                        : BorderSide.none,
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isTeam) ...[
                      if (opponent != null) ...[
                        // Header rows: Date / vs-or-@ Opponent / Time / Location
                        Text(
                          '${_monthAbbr[d.month]} ${d.day}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: (isToday || isActiveSortCol) ? FontWeight.bold : FontWeight.w600,
                            color: (isToday || isActiveSortCol) ? Colors.blue.shade800 : null,
                          ),
                        ),
                        Text(
                          '${session.isHome ? 'vs' : '@'} $opponent',
                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.normal),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.indigo.shade600,
                          ),
                        ),
                        Text(
                          session.locationOverride != null && session.locationOverride!.isNotEmpty
                              ? session.locationOverride!
                              : session.isHome
                                  ? (widget.contract.clubAddress.isNotEmpty
                                      ? widget.contract.clubAddress
                                      : widget.contract.clubName)
                                  : 'Away',
                          style: TextStyle(
                            fontSize: 8,
                            color: session.isHome
                                ? Colors.green.shade700
                                : Colors.orange.shade700,
                            fontStyle: FontStyle.italic,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ] else ...[
                        // Original layout if not a team, or if no opponent
                        Text(
                          _monthAbbr[d.month],
                          style: TextStyle(
                            fontSize: 10,
                            color: (isToday || isActiveSortCol)
                                ? Colors.blue.shade700
                                : Colors.grey.shade600,
                            fontWeight: (isToday || isActiveSortCol)
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        Text(
                          '${d.day}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: (isToday || isActiveSortCol)
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: (isToday || isActiveSortCol)
                                ? Colors.blue.shade800
                                : null,
                          ),
                        ),
                      ],
                      // H/A badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          color: session.isHome
                              ? Colors.green.shade100
                              : Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          session.isHome ? 'H' : 'A',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            color: session.isHome
                                ? Colors.green.shade800
                                : Colors.orange.shade800,
                          ),
                        ),
                      ),
                    ] else ...[
                      if (totalRoster > 0)
                        Text(
                          totalResponded == 0 ? '—' : '$nYes/$totalRoster',
                          style: TextStyle(
                            fontSize: 9,
                            color: totalResponded == 0
                                ? Colors.grey.shade400
                                : Colors.green.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (!isActiveSortCol && session.assignmentState == 'published')
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 2),
                          decoration: BoxDecoration(
                            color: Colors.indigo.shade600,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        }).toList(),
      ),
    );
  }

  Future<void> _onSessionHeaderTap({
    required DateTime date,
    required ContractSession session,
    required bool isPast,
  }) async {
    final avail = session.availability;
    final roster = widget.contract.roster;
    final nYes = avail.values.where((v) => v == 'available').length;
    final nBackup = avail.values.where((v) => v == 'backup').length;
    final nNo = avail.values.where((v) => v == 'unavailable').length;
    final unresponded = roster
        .where((p) => !avail.containsKey(p.uid))
        .toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${_monthAbbr[date.month]} ${date.day} — Availability',
        ),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _availRow(Icons.check_circle, Colors.green.shade700, 'Available', nYes),
              const SizedBox(height: 6),
              _availRow(Icons.people, Colors.amber.shade800, 'Backup', nBackup),
              const SizedBox(height: 6),
              _availRow(Icons.cancel, Colors.grey.shade600, "Can't Make It", nNo),
              const SizedBox(height: 6),
              _availRow(Icons.help_outline, Colors.grey.shade400, 'No Response', unresponded.length),
              if (session.requestSentAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Last request sent: '
                  '${session.requestSentAt!.month}/${session.requestSentAt!.day}/'
                  '${session.requestSentAt!.year}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
              if (!isPast && unresponded.isNotEmpty) ...[
                const Divider(height: 24),
                Text(
                  'Send availability request to ${unresponded.length} unresponded player(s)?',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (!isPast && unresponded.isNotEmpty)
            ElevatedButton.icon(
              icon: const Icon(Icons.send, size: 16),
              label: Text('Send to ${unresponded.length}'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ComposeMessageScreen(
                      config: ComposeMessageConfig(
                        organizerUid: widget.currentUserUid,
                        organizerName: widget.organizerName,
                        availableTypes: const [MessageType.availabilityRequest],
                        initialType: MessageType.availabilityRequest,
                        recipients: unresponded.map((p) => RecipientInfo(
                          uid: p.uid,
                          displayName: p.displayName,
                        )).toList(),
                        contextType: 'contract',
                        contextId: widget.contract.id,
                        contract: widget.contract,
                        sessionDate: date,
                        postSendAction: () => _firebase.upsertSession(
                          widget.contract.id,
                          session.copyWith(requestSentAt: DateTime.now()),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          if (!isPast)
            ElevatedButton.icon(
              icon: const Icon(Icons.assignment_ind_outlined, size: 16),
              label: Text(
                session.assignmentState == 'published'
                    ? 'View Assignment'
                    : 'Assign Slots',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SlotAssignmentScreen(
                      contract: widget.contract,
                      session: session,
                      sessionDate: date,
                      currentUserUid: widget.currentUserUid,
                      organizerName: widget.organizerName,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _onMatchHeaderTap({
    required DateTime date,
    required ContractSession session,
  }) async {
    final opponentCtrl = TextEditingController(text: session.opponentName ?? '');
    final locationCtrl = TextEditingController(text: session.locationOverride ?? '');
    bool isHome = session.isHome;

    // Resolve effective start/end from override or contract default
    int startMins = session.startMinutesOverride ?? widget.contract.startMinutes;
    int endMins = session.endMinutesOverride ?? widget.contract.endMinutes;

    String _fmtMins(int m) {
      final h = m ~/ 60;
      final min = m % 60;
      final suffix = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${min.toString().padLeft(2, '0')} $suffix';
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${_monthAbbr[date.month]} ${date.day} — Match Details'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: opponentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Opponent',
                      hintText: 'e.g. Riverside TC',
                      isDense: true,
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: locationCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Location (venue)',
                      hintText: 'Leave blank to use contract default',
                      isDense: true,
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 16),
                  // Match time overrides
                  Text(
                    'Match Time',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.access_time, size: 16),
                          label: Text(_fmtMins(startMins),
                              style: const TextStyle(fontSize: 13)),
                          onPressed: () async {
                            final t = await showTimePicker(
                              context: ctx,
                              initialTime: TimeOfDay(
                                  hour: startMins ~/ 60,
                                  minute: startMins % 60),
                            );
                            if (t != null) {
                              setDialogState(
                                  () => startMins = t.hour * 60 + t.minute);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('–'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.access_time_filled, size: 16),
                          label: Text(_fmtMins(endMins),
                              style: const TextStyle(fontSize: 13)),
                          onPressed: () async {
                            final t = await showTimePicker(
                              context: ctx,
                              initialTime: TimeOfDay(
                                  hour: endMins ~/ 60, minute: endMins % 60),
                            );
                            if (t != null) {
                              setDialogState(
                                  () => endMins = t.hour * 60 + t.minute);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Home / Away:'),
                      const SizedBox(width: 12),
                      ChoiceChip(
                        label: const Text('Home'),
                        selected: isHome,
                        selectedColor: Colors.green.shade100,
                        onSelected: (_) => setDialogState(() => isHome = true),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Away'),
                        selected: !isHome,
                        selectedColor: Colors.orange.shade100,
                        onSelected: (_) => setDialogState(() => isHome = false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;

    // Only store time as override if it differs from the contract default
    final startOverride =
        startMins != widget.contract.startMinutes ? startMins : null;
    final endOverride =
        endMins != widget.contract.endMinutes ? endMins : null;

    final updated = session.copyWith(
      opponentName:
          opponentCtrl.text.trim().isEmpty ? null : opponentCtrl.text.trim(),
      locationOverride:
          locationCtrl.text.trim().isEmpty ? null : locationCtrl.text.trim(),
      isHome: isHome,
      startMinutesOverride: startOverride,
      endMinutesOverride: endOverride,
    );
    await _firebase.upsertSession(widget.contract.id, updated);
  }

  Widget _availRow(IconData icon, Color color, String label, int count) => Row(
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontSize: 13)),
      const Spacer(),
      Text(
        '$count',
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.bold, color: color),
      ),
    ],
  );

  Widget _buildSessionRow({
    required ContractPlayer player,
    required List<DateTime> sessionDates,
    required Map<String, ContractSession> sessionsByDate,
    required List<ContractSession> sessions,
    required String todayKey,
  }) {
    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: sessionDates.map((d) {
          final key = _dateKey(d);
          final session = sessionsByDate[key];
          final state = session?.attendance[player.uid];
          final availState = session?.availability[player.uid];
          final assignedLine = (widget.contract.lineupMode == 'competitive' &&
                  session?.assignmentState == 'published')
              ? session?.assignmentLine(player.uid)
              : null;
          return _buildAttendanceCell(
            uid: player.uid,
            sessionDate: d,
            state: state,
            availState: availState,
            sessions: sessions,
            isToday: key == todayKey,
            assignedLine: assignedLine,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAttendanceCell({
    required String uid,
    required DateTime sessionDate,
    required String? state,
    required String? availState,
    required List<ContractSession> sessions,
    required bool isToday,
    int? assignedLine,
  }) {
    final bgColor = _stateColor(state);
    // In competitive mode with a published lineup and a line number, show "L1"
    // instead of the generic "P" label for played/confirmed players.
    final label = (assignedLine != null && (state == 'played' || state == 'charged'))
        ? 'L$assignedLine'
        : _stateLabel(state);
    final labelColor = (assignedLine != null && (state == 'played' || state == 'charged'))
        ? Colors.indigo.shade700
        : _stateLabelColor(state);

    return Builder(
      builder: (cellContext) => GestureDetector(
        onTap: widget.readOnly || _quickFillMode
            ? null  // quick-fill taps handled by Listener.onPointerUp
            : () => _onCellTap(
                  cellContext: cellContext,
                  uid: uid,
                  sessionDate: sessionDate,
                  sessions: sessions,
                ),
        child: Container(
          width: _sessionColWidth,
          height: _rowHeight,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              right: BorderSide(color: Colors.grey.shade200),
              left: isToday ? const BorderSide(color: Colors.blue, width: 1.5) : BorderSide.none,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (label != null)
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: labelColor,
                  ),
                ),
              if (availState != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _AvailDot(availState),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper widgets ─────────────────────────────────────────────────

  Widget _buildStatsFooter(List<ContractPlayer> roster, List<ContractSession> sessions) {
    final totalPaid = roster.fold(0, (sum, p) => sum + p.paidSlots);
    final totalPlayed = roster.fold(0, (sum, p) => sum + _playedCount(p.uid, sessions));
    final pct = totalPaid > 0 ? totalPlayed / totalPaid * 100 : 0.0;
    final left = (totalPaid - totalPlayed).clamp(0, totalPaid);

    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border(top: BorderSide(color: Colors.green.shade200, width: 1.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _colName,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                'Totals',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade800,
                ),
              ),
            ),
          ),
          if (!_isTeam)
            _statCell('$totalPaid', _colPaid, color: Colors.green.shade800),
          _statCell('$totalPlayed', _colPlayed, color: Colors.green.shade800),
          if (!_isTeam)
            _statCell('${pct.toStringAsFixed(1)}%', _colPct,
                color: _pctColor(pct, totalPaid > 0)),
          if (!_isTeam)
            _statCell('$left', _colLeft, color: Colors.green.shade800),
        ],
      ),
    );
  }

  Widget _buildPTotalsFooter(
    List<DateTime> sessionDates,
    List<ContractSession> sessions,
  ) {
    final capacity = widget.contract.spotsPerSession;
    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border(top: BorderSide(color: Colors.green.shade200, width: 1.5)),
      ),
      child: Row(
        children: sessionDates.map((d) {
          final key = _dateKey(d);
          final session = sessions.firstWhere(
            (s) => s.id == key,
            orElse: () => ContractSession(id: key, date: d, attendance: {}),
          );
          final pCount = session.attendance.values.where((v) => v == 'available' || v == 'played').length;
          final Color countColor;
          if (pCount == 0) {
            countColor = Colors.grey.shade400;
          } else if (capacity > 0 && pCount >= capacity) {
            countColor = Colors.green.shade700;
          } else {
            countColor = Colors.orange.shade700;
          }
          return Container(
            width: _sessionColWidth,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Text(
              '$pCount',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: countColor,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _statCell(String text, double width, {Color? color}) =>
      SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: color),
        ),
      );

  // ── State helpers ──────────────────────────────────────────────────

  Color? _stateColor(String? state) => switch (state) {
    'available' => Colors.green.shade100,
    'played' => Colors.green.shade100,
    'reserve' => Colors.amber.shade100,
    'out' => Colors.grey.shade200,
    'charged' => Colors.red.shade100,
    _ => null,
  };

  String? _stateLabel(String? state) => switch (state) {
    'available' => 'A',
    'played' => 'P', // Legacy
    'reserve' => 'R',
    'out' => 'O',
    'charged' => '\$',
    _ => null,
  };

  Color _stateLabelColor(String? state) => switch (state) {
    'available' => Colors.green.shade800,
    'played' => Colors.green.shade800,
    'reserve' => Colors.amber.shade800,
    'out' => Colors.grey.shade600,
    'charged' => Colors.red.shade800,
    _ => Colors.black,
  };

  Color? _pctColor(double pct, bool hasPaidSlots) {
    if (!hasPaidSlots) return Colors.grey;
    if (pct >= 75) return Colors.green.shade700;
    if (pct >= 40) return Colors.orange.shade700;
    return Colors.red.shade700;
  }
}

/// Small colored circle used in the popup menu items
class _ColorDot extends StatelessWidget {
  final Color color;
  final bool bordered;
  const _ColorDot(this.color, {this.bordered = false});

  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: bordered ? Border.all(color: Colors.grey.shade400) : null,
    ),
  );
}

/// Small availability indicator dot shown in the top-right corner of a cell.
/// Green = available, amber = backup, grey = unavailable.
class _AvailDot extends StatelessWidget {
  final String state; // 'available' | 'backup' | 'unavailable'
  const _AvailDot(this.state);

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'available' => Colors.green.shade600,
      'backup' => Colors.amber.shade700,
      _ => Colors.grey.shade500,
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1),
      ),
    );
  }
}
