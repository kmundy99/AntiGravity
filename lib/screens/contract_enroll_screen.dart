import 'package:flutter/material.dart';
import '../models.dart';
import '../services/firebase_service.dart';

class ContractEnrollScreen extends StatefulWidget {
  final String contractId;
  final String playerUid;

  const ContractEnrollScreen({
    super.key,
    required this.contractId,
    required this.playerUid,
  });

  @override
  State<ContractEnrollScreen> createState() => _ContractEnrollScreenState();
}

class _ContractEnrollScreenState extends State<ContractEnrollScreen> {
  final _firebase = FirebaseService();

  int _slots = 0;
  final _slotsCtrl = TextEditingController();
  bool _initialized = false;
  bool _submitting = false;
  bool _submitted = false;

  static const _weekdayNames = [
    '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  @override
  void dispose() {
    _slotsCtrl.dispose();
    super.dispose();
  }

  String _formatTime(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final suffix = h < 12 ? 'AM' : 'PM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $suffix';
  }

  String _formatDate(DateTime d) => '${d.month}/${d.day}/${d.year}';

  Future<void> _submit(Contract contract, ContractPlayer player) async {
    setState(() => _submitting = true);
    try {
      final updatedPlayer = player.copyWith(paidSlots: _slots, shareLabel: '');
      final updatedRoster = contract.roster
          .map((p) => p.uid == widget.playerUid ? updatedPlayer : p)
          .toList();
      await _firebase.updateContract(widget.contractId, {
        'roster': updatedRoster.map((p) => p.toMap()).toList(),
      });
      if (mounted) setState(() { _submitted = true; _submitting = false; });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error submitting: $e')),
        );
        setState(() => _submitting = false);
      }
    }
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
            appBar: AppBar(title: const Text('Enrollment')),
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
            appBar: AppBar(title: Text('${contract.clubName} — Enrollment')),
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

        // Sync the slots field from Firestore on first load only
        if (!_initialized) {
          _initialized = true;
          _slots = player.paidSlots;
          _slotsCtrl.text = _slots > 0 ? '$_slots' : '';
        }

        final confirmed = player.paymentStatus == 'confirmed';
        final totalSessions = contract.totalSessions;

        // Remaining = total slots minus what everyone else has already committed
        final otherCommitted = contract.committedSlots - player.paidSlots;
        final remaining = (contract.totalCourtSlots - otherCommitted).clamp(0, contract.totalCourtSlots);

        final cost = contract.pricePerSlot > 0 ? _slots * contract.pricePerSlot : 0.0;

        return Scaffold(
          appBar: AppBar(
            title: Text('${contract.clubName} — Enrollment'),
            backgroundColor: Colors.blue.shade900,
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Contract summary ──────────────────────────────────
                _sectionCard(
                  children: [
                    Text(
                      contract.clubName.isNotEmpty ? contract.clubName : 'Unnamed Club',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (contract.clubAddress.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(contract.clubAddress, style: const TextStyle(color: Colors.grey)),
                    ],
                    const SizedBox(height: 12),
                    _infoRow(Icons.date_range, _weekdayNames[contract.weekday]),
                    const SizedBox(height: 4),
                    _infoRow(Icons.access_time,
                        '${_formatTime(contract.startMinutes)} – ${_formatTime(contract.endMinutes)}'),
                    const SizedBox(height: 4),
                    _infoRow(Icons.event,
                        '${_formatDate(contract.seasonStart)} → ${_formatDate(contract.seasonEnd)}'),
                    const SizedBox(height: 4),
                    _infoRow(Icons.sports_tennis,
                        '$totalSessions sessions · ${contract.spotsPerSession} spots/session'),
                    if (contract.pricePerSlot > 0) ...[
                      const SizedBox(height: 4),
                      _infoRow(Icons.attach_money,
                          '\$${contract.pricePerSlot.toStringAsFixed(2)} per slot'),
                    ],
                  ],
                ),

                const SizedBox(height: 12),

                // ── Who's enrolled ────────────────────────────────────
                _sectionCard(
                  children: [
                    const Text('Who\'s Enrolled',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 8),
                    ...contract.roster.map((p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(child: Text('• ${p.displayName}')),
                          if (p.paidSlots > 0)
                            Text(
                              '${p.paidSlots} slot${p.paidSlots == 1 ? '' : 's'}'
                              '${p.paymentStatus == 'confirmed' ? ' ✓' : ''}',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.paymentStatus == 'confirmed'
                                    ? Colors.green.shade700
                                    : Colors.blueGrey.shade600,
                              ),
                            ),
                        ],
                      ),
                    )),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: contract.totalCourtSlots > 0
                                  ? (contract.committedSlots / contract.totalCourtSlots).clamp(0.0, 1.0)
                                  : 0,
                              minHeight: 8,
                              backgroundColor: Colors.grey.shade200,
                              color: Colors.blue.shade700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${contract.committedSlots}/${contract.totalCourtSlots} slots',
                          style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // ── Select slots (hidden if confirmed) ────────────────
                if (!confirmed)
                  _sectionCard(
                    children: [
                      const Text('How Many Sessions Do You Want?',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(
                        '$remaining of ${contract.totalCourtSlots} slot${contract.totalCourtSlots == 1 ? '' : 's'} still available',
                        style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade600),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 80,
                            child: TextField(
                              controller: _slotsCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                hintText: '0',
                              ),
                              onChanged: (v) {
                                final parsed = int.tryParse(v) ?? 0;
                                final clamped = parsed.clamp(0, remaining);
                                setState(() => _slots = clamped);
                                if (parsed > remaining) {
                                  _slotsCtrl.text = '$clamped';
                                  _slotsCtrl.selection = TextSelection.collapsed(
                                      offset: _slotsCtrl.text.length);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '/ $remaining available',
                            style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade600),
                          ),
                        ],
                      ),
                      if (contract.pricePerSlot > 0 && _slots > 0) ...[
                        const SizedBox(height: 10),
                        Text(
                          '$_slots session${_slots == 1 ? '' : 's'} × '
                          '\$${contract.pricePerSlot.toStringAsFixed(2)}/slot'
                          ' = \$${cost.toStringAsFixed(2)} total',
                          style: TextStyle(
                            color: Colors.blue.shade800,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_submitting || _slots == 0)
                              ? null
                              : () => _submit(contract, player!),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade900,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Submit Slot Request'),
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 12),

                // ── How to pay ────────────────────────────────────────
                if (contract.paymentInfo.isNotEmpty)
                  _sectionCard(
                    children: [
                      const Text('How to Pay',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      Text(contract.paymentInfo),
                    ],
                  ),

                const SizedBox(height: 12),

                // ── Confirmation banner ───────────────────────────────
                if (_submitted || confirmed || player.paidSlots > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: confirmed ? Colors.green.shade50 : Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: confirmed ? Colors.green.shade300 : Colors.amber.shade300,
                      ),
                    ),
                    child: confirmed
                        ? Row(
                            children: [
                              Icon(Icons.check_circle, color: Colors.green.shade700),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Payment confirmed. You are enrolled for ${player.paidSlots} session${player.paidSlots == 1 ? '' : 's'}.',
                                  style: TextStyle(color: Colors.green.shade800),
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Icon(Icons.hourglass_top, color: Colors.amber.shade700),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Request for ${player.paidSlots} slot${player.paidSlots == 1 ? '' : 's'} submitted.'
                                  '${contract.pricePerSlot > 0 && player.paidSlots > 0 ? ' Please send \$${(player.paidSlots * contract.pricePerSlot).toStringAsFixed(2)}' : ''}'
                                  '${contract.paymentInfo.isNotEmpty ? ' to ${contract.paymentInfo}' : ''}.',
                                  style: TextStyle(color: Colors.amber.shade900),
                                ),
                              ),
                            ],
                          ),
                  ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionCard({required List<Widget> children}) => Card(
    elevation: 1,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  Widget _infoRow(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 16, color: Colors.blueGrey),
      const SizedBox(width: 8),
      Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
    ],
  );
}
