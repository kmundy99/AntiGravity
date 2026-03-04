import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import 'compose_message_screen.dart';

class SlotAssignmentScreen extends StatefulWidget {
  final Contract contract;
  final ContractSession session;
  final DateTime sessionDate;
  final String currentUserUid;
  final String organizerName;

  const SlotAssignmentScreen({
    super.key,
    required this.contract,
    required this.session,
    required this.sessionDate,
    required this.currentUserUid,
    required this.organizerName,
  });

  @override
  State<SlotAssignmentScreen> createState() => _SlotAssignmentScreenState();
}

class _SlotAssignmentScreenState extends State<SlotAssignmentScreen> {
  final _firebase = FirebaseService();
  late Map<String, String> _assignment;

  @override
  void initState() {
    super.initState();
    // If a draft/published assignment already exists, load it; otherwise auto-compute.
    if (widget.session.assignment.isNotEmpty) {
      _assignment = Map<String, String>.from(widget.session.assignment);
    } else {
      _assignment = _autoAssign();
    }
  }

  /// Auto-assignment algorithm:
  /// Sort roster ascending by playedSlots/paidSlots (ties by displayName).
  /// Fill court spots (spotsPerSession) with 'available' players first,
  /// remainder → 'reserve'; unavailable/no-response → 'out'.
  Map<String, String> _autoAssign() {
    final spots = widget.contract.spotsPerSession;
    final roster = List<ContractPlayer>.from(widget.contract.roster);

    roster.sort((a, b) {
      final pctA = a.paidSlots > 0 ? a.playedSlots / a.paidSlots : 0.0;
      final pctB = b.paidSlots > 0 ? b.playedSlots / b.paidSlots : 0.0;
      final cmp = pctA.compareTo(pctB);
      return cmp != 0 ? cmp : a.displayName.compareTo(b.displayName);
    });

    final result = <String, String>{};
    int confirmedCount = 0;

    for (final player in roster) {
      final avail = widget.session.availability[player.uid];
      if (avail == 'available' && confirmedCount < spots) {
        result[player.uid] = 'confirmed';
        confirmedCount++;
      } else if (avail == 'available' || avail == 'backup') {
        result[player.uid] = 'reserve';
      } else {
        result[player.uid] = 'out';
      }
    }

    return result;
  }

  int get _confirmedCount =>
      _assignment.values.where((v) => v == 'confirmed').length;

  Future<void> _saveDraft() async {
    await _firebase.upsertSession(
      widget.contract.id,
      widget.session.copyWith(
        assignment: _assignment,
        assignmentState: 'draft',
      ),
    );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draft saved')),
      );
    }
  }

  Future<void> _publishLineup() async {
    final session = widget.session;
    final contract = widget.contract;
    final assignmentSnapshot = Map<String, String>.from(_assignment);

    final config = ComposeMessageConfig(
      organizerUid: widget.currentUserUid,
      organizerName: widget.organizerName,
      availableTypes: const [MessageType.sessionLineup],
      initialType: MessageType.sessionLineup,
      recipients: contract.roster
          .map((p) => RecipientInfo(uid: p.uid, displayName: p.displayName))
          .toList(),
      contextType: 'contract',
      contextId: contract.id,
      contract: contract,
      sessionDate: widget.sessionDate,
      sessionAssignment: assignmentSnapshot,
      postSendAction: () async {
        final updatedAttendance = Map<String, String>.from(session.attendance);
        for (final e in assignmentSnapshot.entries) {
          if (e.value == 'confirmed') updatedAttendance[e.key] = 'played';
        }
        await _firebase.upsertSession(
          contract.id,
          session.copyWith(
            assignment: assignmentSnapshot,
            assignmentState: 'published',
            attendance: updatedAttendance,
          ),
        );
      },
    );

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ComposeMessageScreen(config: config)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contract = widget.contract;
    final spots = contract.spotsPerSession;
    final confirmed = _confirmedCount;
    final isOver = confirmed > spots;

    final dayStr = DateFormat('EEE, MMM d').format(widget.sessionDate);
    final title = '${contract.clubName.isNotEmpty ? contract.clubName : "Session"} — $dayStr';

    final roster = List<ContractPlayer>.from(contract.roster);
    // Show in same sort order as auto-assign (by played%)
    roster.sort((a, b) {
      final pctA = a.paidSlots > 0 ? a.playedSlots / a.paidSlots : 0.0;
      final pctB = b.paidSlots > 0 ? b.playedSlots / b.paidSlots : 0.0;
      final cmp = pctA.compareTo(pctB);
      return cmp != 0 ? cmp : a.displayName.compareTo(b.displayName);
    });

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          _buildCapacityBar(confirmed, spots, isOver),
          _buildColumnHeader(),
          Expanded(
            child: ListView.builder(
              itemCount: roster.length,
              itemBuilder: (_, i) => _buildPlayerRow(roster[i]),
            ),
          ),
          const Divider(height: 1),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildCapacityBar(int confirmed, int spots, bool isOver) {
    final progress = spots > 0 ? (confirmed / spots).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Capacity: $confirmed / $spots',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isOver ? Colors.red.shade700 : null,
                ),
              ),
              if (isOver)
                Text(
                  'Over capacity!',
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              color: isOver ? Colors.red : Colors.indigo.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Text('Player', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey))),
          SizedBox(width: 48, child: Text('Played%', style: TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
          SizedBox(width: 36, child: Text('Avail', style: TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
          SizedBox(width: 110, child: Text('Assignment', style: TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
        ],
      ),
    );
  }

  Widget _buildPlayerRow(ContractPlayer player) {
    final avail = widget.session.availability[player.uid];
    final current = _assignment[player.uid] ?? 'out';
    final pct = player.paidSlots > 0
        ? '${(player.playedSlots / player.paidSlots * 100).round()}%'
        : '—';

    return Container(
      height: 52,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              player.displayName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(pct, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 36,
            child: Center(child: _AvailIcon(avail)),
          ),
          SizedBox(
            width: 110,
            child: _AssignmentChip(
              value: current,
              onChanged: (newVal) {
                if (newVal != null) setState(() => _assignment[player.uid] = newVal);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: _saveDraft,
            child: const Text('Save Draft'),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Publish...'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: _publishLineup,
          ),
        ],
      ),
    );
  }
}

/// Availability icon: ✓ available · ≈ backup · ✗ unavailable · — no response
class _AvailIcon extends StatelessWidget {
  final String? state;
  const _AvailIcon(this.state);

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case 'available':
        return Icon(Icons.check, size: 16, color: Colors.green.shade700);
      case 'backup':
        return Icon(Icons.remove, size: 16, color: Colors.amber.shade800);
      case 'unavailable':
        return Icon(Icons.close, size: 16, color: Colors.grey.shade600);
      default:
        return Text('—', style: TextStyle(fontSize: 13, color: Colors.grey.shade400));
    }
  }
}

/// Tappable chip that opens a popup menu for Confirmed / Reserve / Out.
class _AssignmentChip extends StatelessWidget {
  final String value;
  final ValueChanged<String?> onChanged;

  const _AssignmentChip({required this.value, required this.onChanged});

  Color _bgColor() => switch (value) {
    'confirmed' => Colors.green.shade100,
    'reserve'   => Colors.amber.shade100,
    _           => Colors.grey.shade200,
  };

  Color _fgColor() => switch (value) {
    'confirmed' => Colors.green.shade800,
    'reserve'   => Colors.amber.shade900,
    _           => Colors.grey.shade700,
  };

  String _label() => switch (value) {
    'confirmed' => 'Confirmed',
    'reserve'   => 'Reserve',
    _           => 'Out',
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final offset = box.localToGlobal(Offset.zero);
        final result = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(
            offset.dx,
            offset.dy + box.size.height,
            offset.dx + box.size.width,
            offset.dy + box.size.height + 150,
          ),
          items: const [
            PopupMenuItem(value: 'confirmed', child: Text('Confirmed')),
            PopupMenuItem(value: 'reserve',   child: Text('Reserve')),
            PopupMenuItem(value: 'out',        child: Text('Out')),
          ],
        );
        onChanged(result);
      },
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _bgColor(),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _fgColor()),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 14, color: _fgColor()),
          ],
        ),
      ),
    );
  }
}
