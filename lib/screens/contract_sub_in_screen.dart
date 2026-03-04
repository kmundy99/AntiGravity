import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import 'contract_session_player_screen.dart';

class ContractSubInScreen extends StatelessWidget {
  final String contractId;
  final String sessionDate; // 'YYYY-MM-DD'
  final String playerUid;

  const ContractSubInScreen({
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

  Future<void> _fillIn(
    BuildContext context,
    FirebaseService firebase,
    ContractSession session,
  ) async {
    final updated = session.copyWith(
      assignment: {...session.assignment, playerUid: 'confirmed'},
    );
    await firebase.upsertSession(contractId, updated);

    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ContractSessionPlayerScreen(
            contractId: contractId,
            sessionDate: sessionDate,
            playerUid: playerUid,
          ),
        ),
      );
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

            final parts = sessionDate.split('-');
            final sessionDt = parts.length == 3
                ? DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]))
                : DateTime.now();
            final dayStr = DateFormat('EEE, MMM d').format(sessionDt);

            final appBarTitle = 'Fill In — $dayStr';

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
                      : _buildBody(context, firebase, contract, session, sessionDt),
            );
          },
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    FirebaseService firebase,
    Contract contract,
    ContractSession? session,
    DateTime sessionDt,
  ) {
    final startStr = _formatTime(contract.startMinutes);
    final endStr = _formatTime(contract.endMinutes);
    final dayStr = DateFormat('EEEE, MMMM d').format(sessionDt);

    final assignment = session?.assignment ?? {};
    final myStatus = assignment[playerUid];
    final spotsPerSession = contract.spotsPerSession;

    final confirmed = contract.roster
        .where((p) => assignment[p.uid] == 'confirmed')
        .toList();
    final confirmedCount = confirmed.length;
    final isFull = confirmedCount >= spotsPerSession;
    final alreadyIn = myStatus == 'confirmed';

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
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Lineup card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current lineup ($confirmedCount/$spotsPerSession spots filled)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                if (confirmed.isEmpty)
                  Text(
                    'No one confirmed yet.',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  )
                else
                  ...confirmed.map((p) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 16, color: Colors.green.shade600),
                        const SizedBox(width: 8),
                        Text(p.displayName),
                      ],
                    ),
                  )),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),

        if (alreadyIn) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: const Text(
              "You're already in the lineup.",
              style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => ContractSessionPlayerScreen(
                    contractId: contractId,
                    sessionDate: sessionDate,
                    playerUid: playerUid,
                  ),
                ),
              ),
              child: const Text('Manage My Spot'),
            ),
          ),
        ] else if (isFull) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey.shade400,
                foregroundColor: Colors.white,
              ),
              onPressed: null,
              child: const Text('This spot has been filled'),
            ),
          ),
        ] else ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: session != null
                  ? () => _fillIn(context, firebase, session)
                  : null,
              child: const Text("I'll Fill In",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ],
    );
  }
}
