import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import 'complete_profile_screen.dart';

/// Player-facing screen for responding to a session availability request.
/// Accessed via deep link: `/#/availability/{contractId}/{sessionDate}?uid={uid}`
class ContractAvailabilityResponseScreen extends StatefulWidget {
  final String contractId;
  final String sessionDate; // 'YYYY-MM-DD'
  final String playerUid;

  const ContractAvailabilityResponseScreen({
    super.key,
    required this.contractId,
    required this.sessionDate,
    required this.playerUid,
  });

  @override
  State<ContractAvailabilityResponseScreen> createState() =>
      _ContractAvailabilityResponseScreenState();
}

class _ContractAvailabilityResponseScreenState
    extends State<ContractAvailabilityResponseScreen> {
  final _firebase = FirebaseService();
  bool _submitting = false;
  String? _submittedResponse; // 'available' | 'backup' | 'unavailable'

  DateTime? _parsedDate;

  @override
  void initState() {
    super.initState();
    final parts = widget.sessionDate.split('-');
    if (parts.length == 3) {
      _parsedDate = DateTime(
        int.tryParse(parts[0]) ?? 2000,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[2]) ?? 1,
      );
    }
  }

  Future<void> _respond(String response, Contract contract) async {
    setState(() => _submitting = true);
    try {
      // Load the existing session doc (or create a stub) and update availability
      final sessions = await _firebase
          .getSessionsStream(widget.contractId)
          .first;

      final existing = sessions.firstWhere(
        (s) => s.id == widget.sessionDate,
        orElse: () => ContractSession(
          id: widget.sessionDate,
          date: _parsedDate ?? DateTime.now(),
          attendance: {},
        ),
      );

      final updatedAvailability =
          Map<String, String>.from(existing.availability)
            ..[widget.playerUid] = response;

      final updatedAttendance = 
          Map<String, String>.from(existing.attendance)
            ..[widget.playerUid] = response;

      await _firebase.upsertSession(
        widget.contractId,
        existing.copyWith(
          availability: updatedAvailability,
          attendance: updatedAttendance,
        ),
      );

      if (mounted) {
        setState(() { _submittedResponse = response; _submitting = false; });
        // Check if profile is incomplete and prompt to complete it
        _maybePromptCompleteProfile();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving response: $e')),
        );
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _maybePromptCompleteProfile() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.playerUid)
        .get();
    if (!mounted || !doc.exists) return;
    if (isProfileIncomplete(doc.data()!)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CompleteProfileScreen(playerUid: widget.playerUid),
        ),
      );
    }
  }

  String _formatTime(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final suffix = h < 12 ? 'AM' : 'PM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $suffix';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Contract?>(
      stream: _firebase.getContractStream(widget.contractId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final contract = snapshot.data;
        if (contract == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Availability')),
            body: const Center(child: Text('Contract not found.')),
          );
        }

        ContractPlayer? player;
        try {
          player = contract.roster.firstWhere((p) => p.uid == widget.playerUid);
        } catch (_) {
          player = null;
        }

        if (player == null) {
          return Scaffold(
            appBar: AppBar(
              title: Text('${contract.clubName} — Availability'),
              backgroundColor: Colors.blue.shade900,
              foregroundColor: Colors.white,
            ),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'You are not enrolled in this contract.',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final deadline = _parsedDate == null ? null : DateTime(
          _parsedDate!.year, _parsedDate!.month, _parsedDate!.day,
          contract.notifLineupTimeMinutes ~/ 60,
          contract.notifLineupTimeMinutes % 60,
        ).subtract(Duration(days: contract.notifLineupDaysBefore));
        final isPastDeadline = deadline != null &&
            DateTime.now().isAfter(deadline);

        return Scaffold(
          appBar: AppBar(
            title: Text('${contract.clubName} — Availability'),
            backgroundColor: Colors.blue.shade900,
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Session info card ──────────────────────────────────
                _card(children: [
                  Text(
                    contract.clubName.isNotEmpty
                        ? contract.clubName
                        : 'Tennis Session',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (contract.clubAddress.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(contract.clubAddress,
                        style: const TextStyle(color: Colors.grey)),
                  ],
                  const SizedBox(height: 12),
                  if (_parsedDate != null) ...[
                    _infoRow(
                      Icons.event,
                      DateFormat('EEEE, MMMM d, y').format(_parsedDate!),
                    ),
                    const SizedBox(height: 4),
                  ],
                  _infoRow(
                    Icons.access_time,
                    '${_formatTime(contract.startMinutes)} – '
                        '${_formatTime(contract.endMinutes)}',
                  ),
                  if (deadline != null) ...[
                    const SizedBox(height: 4),
                    _infoRow(
                      Icons.timer_outlined,
                      'Please respond by ${DateFormat("MMM d 'at' h:mm a").format(deadline)}',
                      color: isPastDeadline ? Colors.red.shade600 : Colors.orange.shade700,
                    ),
                  ],
                ]),

                const SizedBox(height: 16),

                // ── Player greeting ────────────────────────────────────
                _card(children: [
                  Text(
                    'Hi ${player.displayName},',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  const Text('Will you be available for this session?'),
                ]),

                const SizedBox(height: 16),

                // ── Response buttons / confirmation ────────────────────
                if (_submittedResponse != null)
                  _buildConfirmation(_submittedResponse!)
                else
                  _buildResponseButtons(contract, isPastDeadline),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResponseButtons(Contract contract, bool isPastDeadline) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isPastDeadline)
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: Colors.orange.shade700, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'The response deadline has passed, but you can still update your availability.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        _responseButton(
          label: "I'm Available",
          description: 'Ready to play',
          icon: Icons.check_circle_outline,
          color: Colors.green.shade700,
          bgColor: Colors.green.shade50,
          borderColor: Colors.green.shade300,
          onTap: _submitting ? null : () => _respond('available', contract),
        ),
        const SizedBox(height: 12),
        _responseButton(
          label: 'Available as Backup',
          description: 'Available if needed, but prefer to sit out',
          icon: Icons.people_outline,
          color: Colors.amber.shade800,
          bgColor: Colors.amber.shade50,
          borderColor: Colors.amber.shade300,
          onTap: _submitting ? null : () => _respond('backup', contract),
        ),
        const SizedBox(height: 12),
        _responseButton(
          label: "Can't Make It",
          description: 'Unavailable for this session',
          icon: Icons.cancel_outlined,
          color: Colors.grey.shade700,
          bgColor: Colors.grey.shade100,
          borderColor: Colors.grey.shade400,
          onTap: _submitting ? null : () => _respond('unavailable', contract),
        ),
        if (_submitting)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _buildConfirmation(String response) {
    final (icon, color, title, subtitle) = switch (response) {
      'available' => (
          Icons.check_circle,
          Colors.green.shade700,
          "Marked Available",
          'Your availability has been recorded.',
        ),
      'backup' => (
          Icons.people,
          Colors.amber.shade800,
          'Noted as Backup',
          "You've been marked as available if needed. We'll let you know.",
        ),
      _ => (
          Icons.cancel,
          Colors.grey.shade700,
          'Noted — See You Next Time',
          "Your unavailability has been recorded.",
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 56),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => setState(() => _submittedResponse = null),
            child: const Text('Change Response'),
          ),
        ],
      ),
    );
  }

  Widget _responseButton({
    required String label,
    required String description,
    required IconData icon,
    required Color color,
    required Color bgColor,
    required Color borderColor,
    required VoidCallback? onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: color)),
                    Text(description,
                        style: TextStyle(
                            fontSize: 12, color: color.withValues(alpha: 0.8))),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      );

  Widget _card({required List<Widget> children}) => Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );

  Widget _infoRow(IconData icon, String label, {Color? color}) => Row(
        children: [
          Icon(icon, size: 16, color: color ?? Colors.blueGrey),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 14, color: color))),
        ],
      );
}
