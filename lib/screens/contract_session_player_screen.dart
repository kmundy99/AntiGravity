import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import 'contract_session_grid_screen.dart';

class ContractSessionPlayerScreen extends StatelessWidget {
  final String contractId;
  final String sessionDate; // 'YYYY-MM-DD'
  final String playerUid;

  const ContractSessionPlayerScreen({
    super.key,
    required this.contractId,
    required this.sessionDate,
    required this.playerUid,
  });

  String _formatTime(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final suffix = h < 12 ? 'AM' : 'PM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:${m.toString().padLeft(2, '0')} $suffix';
  }

  DateTime _sessionStart(Contract contract, ContractSession session) {
    return DateTime(
      session.date.year, session.date.month, session.date.day,
      contract.startMinutes ~/ 60, contract.startMinutes % 60,
    );
  }

  DateTime _sessionEnd(Contract contract, ContractSession session) {
    return DateTime(
      session.date.year, session.date.month, session.date.day,
      contract.endMinutes ~/ 60, contract.endMinutes % 60,
    );
  }

  bool _isWithin24h(DateTime sessionStart) {
    return sessionStart.difference(DateTime.now()).inHours < 24;
  }

  Future<void> _downloadIcs(
    BuildContext context,
    Contract contract,
    ContractSession session,
  ) async {
    final start = _sessionStart(contract, session);
    final end = _sessionEnd(contract, session);

    String fmtIcs(DateTime dt) {
      final u = dt.toUtc();
      return '${u.year}'
          '${u.month.toString().padLeft(2, '0')}'
          '${u.day.toString().padLeft(2, '0')}'
          'T${u.hour.toString().padLeft(2, '0')}'
          '${u.minute.toString().padLeft(2, '0')}'
          '00Z';
    }

    final escLoc = (contract.clubAddress.isNotEmpty ? contract.clubAddress : contract.clubName)
        .replaceAll(',', '\\,')
        .replaceAll(';', '\\;');

    final ics = 'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//AntiGravity Tennis//EN\r\n'
        'BEGIN:VEVENT\r\n'
        'DTSTART:${fmtIcs(start)}\r\n'
        'DTEND:${fmtIcs(end)}\r\n'
        'SUMMARY:${contract.clubName} Tennis\r\n'
        'LOCATION:$escLoc\r\n'
        'DESCRIPTION:Court contract session via AntiGravity Tennis\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    final encoded = Uri.encodeComponent(ics);
    final dataUri = Uri.parse('data:text/calendar;charset=utf-8,$encoded');

    if (!await launchUrl(dataUri)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open calendar file')),
        );
      }
    }
  }

  Future<void> _dropOut(
    BuildContext context,
    FirebaseService firebase,
    Contract contract,
    ContractSession session,
  ) async {
    final start = _sessionStart(contract, session);
    final isLate = _isWithin24h(start);

    if (isLate) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Drop Out?'),
          content: const Text(
            'Dropping out less than 24 hours before the session '
            'may result in a charge. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Drop Out'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final updated = session.copyWith(
      assignment: {...session.assignment, playerUid: <String, dynamic>{'status': 'out'}},
    );
    await firebase.upsertSession(contractId, updated);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dropped out. The organizer has been notified.'),
        ),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _removeFromReserve(
    BuildContext context,
    FirebaseService firebase,
    ContractSession session,
  ) async {
    final updated = session.copyWith(
      assignment: {...session.assignment, playerUid: <String, dynamic>{'status': 'out'}},
    );
    await firebase.upsertSession(contractId, updated);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Removed from reserve list.')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firebase = FirebaseService();

    return StreamBuilder<Contract?>(
      stream: firebase.getContractStream(contractId),
      builder: (context, contractSnap) {
        final contract = contractSnap.data;

        return StreamBuilder<List<ContractSession>>(
          stream: firebase.getSessionsStream(contractId),
          builder: (context, sessionsSnap) {
            ContractSession? session;
            if (sessionsSnap.hasData) {
              try {
                session = sessionsSnap.data!.firstWhere((s) => s.id == sessionDate);
              } catch (_) {
                session = null;
              }
            }

            final loading = contractSnap.connectionState == ConnectionState.waiting ||
                sessionsSnap.connectionState == ConnectionState.waiting;

            final appBarTitle = contract != null
                ? _buildTitle(contract)
                : 'Session';

            return Scaffold(
              appBar: AppBar(
                title: Text(appBarTitle),
                backgroundColor: Colors.indigo.shade700,
                foregroundColor: Colors.white,
              ),
              body: loading && contract == null
                  ? const Center(child: CircularProgressIndicator())
                  : contract == null
                      ? const Center(child: Text('Session not found.'))
                      : _buildBody(context, firebase, contract, session),
            );
          },
        );
      },
    );
  }

  String _buildTitle(Contract contract) {
    final parts = sessionDate.split('-');
    if (parts.length == 3) {
      final dt = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      final dayStr = DateFormat('EEE, MMM d').format(dt);
      return '${contract.clubName} — $dayStr';
    }
    return contract.clubName;
  }

  Widget _buildBody(
    BuildContext context,
    FirebaseService firebase,
    Contract contract,
    ContractSession? session,
  ) {
    final parts = sessionDate.split('-');
    final sessionDt = parts.length == 3
        ? DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]))
        : DateTime.now();

    final startStr = _formatTime(contract.startMinutes);
    final endStr = _formatTime(contract.endMinutes);
    final dayStr = DateFormat('EEEE, MMMM d').format(sessionDt);

    final myStatus = session?.assignmentStatus(playerUid);
    final isConfirmed = myStatus == 'confirmed';
    final isReserve = myStatus == 'reserve';

    final roster = contract.roster;
    final assignmentPublished = (session?.assignmentState ?? 'none') == 'published';

    final confirmed = roster.where((p) => session?.assignmentStatus(p.uid) == 'confirmed').toList();
    final reserves = roster.where((p) => session?.assignmentStatus(p.uid) == 'reserve').toList();
    final out = roster.where((p) => session?.assignmentStatus(p.uid) == 'out').toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Session info card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contract.clubName,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '$dayStr · $startStr – $endStr',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                if (contract.clubAddress.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    contract.clubAddress,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 12),
                // My status chip
                if (myStatus != null) ...[
                  Row(
                    children: [
                      const Text('Your status: ', style: TextStyle(fontSize: 13)),
                      _statusChip(myStatus),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Lineup card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: assignmentPublished
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Playing (${confirmed.length}/${contract.spotsPerSession})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      ...confirmed.map((p) => _playerTile(p, playerUid, 'confirmed')),
                      if (reserves.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Reserve',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        ...reserves.map((p) => _playerTile(p, playerUid, 'reserve')),
                      ],
                      if (out.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Not assigned',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        ...out.map((p) => _playerTile(p, playerUid, 'out')),
                      ],
                    ],
                  )
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Lineup not yet published.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
          ),
        ),

        const SizedBox(height: 16),

        // View full season grid (read-only)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.grid_on, size: 16),
            label: const Text('View Season Grid'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ContractSessionGridScreen(
                  contract: contract,
                  currentUserUid: playerUid,
                  readOnly: true,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: const Text('Download to Calendar'),
                onPressed: session != null
                    ? () => _downloadIcs(context, contract, session)
                    : null,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        if (isConfirmed)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
              ),
              onPressed: session != null
                  ? () => _dropOut(context, firebase, contract, session)
                  : null,
              child: const Text('Drop Out'),
            ),
          ),

        if (isReserve)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade700,
              ),
              onPressed: session != null
                  ? () => _removeFromReserve(context, firebase, session)
                  : null,
              child: const Text('Remove from Reserve'),
            ),
          ),
      ],
    );
  }

  Widget _playerTile(ContractPlayer player, String myUid, String statusKey) {
    final isMe = player.uid == myUid;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            statusKey == 'confirmed'
                ? Icons.check_circle
                : statusKey == 'reserve'
                    ? Icons.schedule
                    : Icons.cancel,
            size: 16,
            color: statusKey == 'confirmed'
                ? Colors.green.shade600
                : statusKey == 'reserve'
                    ? Colors.amber.shade700
                    : Colors.grey.shade400,
          ),
          const SizedBox(width: 8),
          Text(
            player.displayName,
            style: TextStyle(
              fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
              color: isMe ? Colors.indigo.shade700 : null,
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 6),
            Text(
              '(You)',
              style: TextStyle(fontSize: 12, color: Colors.indigo.shade400),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChip(String status) {
    Color color;
    String label;
    switch (status) {
      case 'confirmed':
        color = Colors.green;
        label = 'Playing';
      case 'reserve':
        color = Colors.amber.shade700;
        label = 'Reserve';
      case 'out':
        color = Colors.grey;
        label = 'Not assigned';
      default:
        color = Colors.grey;
        label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}
