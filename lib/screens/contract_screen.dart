import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';
import '../utils/message_templates.dart';
import 'compose_message_screen.dart';
import 'contract_setup_screen.dart';
import 'contract_session_grid_screen.dart';
import 'scheduled_messages_list_screen.dart';
import 'select_players_screen.dart';
import 'sent_messages_screen.dart';

class ContractScreen extends StatefulWidget {
  final String currentUserUid;
  final String organizerName;
  final String organizerEmail;
  /// Contracts the current user is enrolled in as a player (not as organizer).
  final List<Contract> playerContracts;
  const ContractScreen({
    super.key,
    required this.currentUserUid,
    this.organizerName = '',
    this.organizerEmail = '',
    this.playerContracts = const [],
  });

  @override
  State<ContractScreen> createState() => _ContractScreenState();
}

class _ContractScreenState extends State<ContractScreen> {
  final _firebaseService = FirebaseService();
  final Set<String> _selectedPlayerUids = {};

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

  Future<void> _sendScheduledMessageNow(Contract contract, ScheduledMessage msg) async {
    // Apply recipients filter at send time
    List<RecipientInfo> recipients;
    if (msg.recipientsFilter == 'unpaid') {
      final unpaidUids = contract.roster
          .where((p) => p.paymentStatus == 'pending')
          .map((p) => p.uid)
          .toSet();
      recipients = msg.recipients.where((r) => unpaidUids.contains(r.uid)).toList();
    } else {
      recipients = msg.recipients;
    }

    // Build a per-recipient link for message types that include one
    String? Function(String uid)? linkBuilder;
    if (msg.type == 'availability_request' && msg.sessionDate != null) {
      final dateKey = '${msg.sessionDate!.year}-'
          '${msg.sessionDate!.month.toString().padLeft(2, '0')}-'
          '${msg.sessionDate!.day.toString().padLeft(2, '0')}';
      linkBuilder = (uid) =>
          'https://www.finapps.com/#/availability/${msg.contractId}/$dateKey'
          '?uid=${Uri.encodeComponent(uid)}';
    } else if (msg.type == 'last_ditch' && msg.sessionDate != null) {
      final dateKey = '${msg.sessionDate!.year}-'
          '${msg.sessionDate!.month.toString().padLeft(2, '0')}-'
          '${msg.sessionDate!.day.toString().padLeft(2, '0')}';
      linkBuilder = (uid) =>
          'https://www.finapps.com/#/session/${msg.contractId}/$dateKey'
          '/subin?uid=${Uri.encodeComponent(uid)}';
    } else if (msg.type == 'lineup_publish' && msg.sessionDate != null) {
      final dateKey = '${msg.sessionDate!.year}-'
          '${msg.sessionDate!.month.toString().padLeft(2, '0')}-'
          '${msg.sessionDate!.day.toString().padLeft(2, '0')}';
      linkBuilder = (uid) =>
          'https://www.finapps.com/#/session/${msg.contractId}/$dateKey'
          '/manage?uid=${Uri.encodeComponent(uid)}';
    }

    for (final r in recipients) {
      unawaited(NotificationService.sendComposed(
        recipientUid: r.uid,
        recipientDisplayName: r.displayName,
        subject: msg.subject,
        body: msg.body,
        linkBuilder: linkBuilder,
        replyToEmail: widget.organizerEmail,
      ));
    }

    if (recipients.isNotEmpty) {
      unawaited(_firebaseService.logMessage(MessageLogEntry(
        sentBy: widget.currentUserUid,
        sentAt: DateTime.now(),
        type: switch (msg.type) {
          'availability_request' => MessageType.availabilityRequest,
          'last_ditch'           => MessageType.subRequest,
          'sub_request'          => MessageType.subRequest,
          'lineup_publish'       => MessageType.sessionLineup,
          _                      => MessageType.paymentReminder,
        },
        subject: msg.subject,
        body: msg.body,
        recipients: recipients,
        contextType: 'contract',
        contextId: contract.id,
        deliveryCount: recipients.length,
        expireAt: DateTime.now().add(const Duration(days: 90)),
      )));
    }

    await _firebaseService.updateScheduledMessage(msg.id, {'status': 'sent'});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent to ${recipients.length} player(s)')),
      );
    }
  }

  Future<void> _editScheduledMessage(ScheduledMessage msg) async {
    final subjectCtrl = TextEditingController(text: msg.subject);
    final bodyCtrl = TextEditingController(text: msg.body);
    DateTime? scheduledFor = msg.scheduledFor;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Notification'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Scheduled date/time ────────────────────────────
                  const Text('Send date/time',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.blueGrey)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            scheduledFor != null
                                ? DateFormat('MMM d, yyyy').format(scheduledFor!)
                                : 'No date — on hold',
                            style: const TextStyle(fontSize: 13),
                          ),
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: ctx,
                              initialDate: scheduledFor ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2040),
                            );
                            if (d != null) {
                              setDialogState(() {
                                final t = scheduledFor;
                                scheduledFor = DateTime(
                                  d.year, d.month, d.day,
                                  t?.hour ?? 9, t?.minute ?? 0,
                                );
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.access_time, size: 16),
                        label: Text(
                          scheduledFor != null
                              ? TimeOfDay.fromDateTime(scheduledFor!).format(ctx)
                              : '--:--',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: ctx,
                            initialTime: scheduledFor != null
                                ? TimeOfDay.fromDateTime(scheduledFor!)
                                : const TimeOfDay(hour: 9, minute: 0),
                          );
                          if (t != null && scheduledFor != null) {
                            setDialogState(() {
                              scheduledFor = DateTime(
                                scheduledFor!.year, scheduledFor!.month, scheduledFor!.day,
                                t.hour, t.minute,
                              );
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  if (scheduledFor != null)
                    TextButton.icon(
                      icon: const Icon(Icons.pause_circle_outline, size: 16),
                      label: const Text('Put on hold (clear date)', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: Colors.orange),
                      onPressed: () => setDialogState(() => scheduledFor = null),
                    ),
                  const SizedBox(height: 12),
                  // ── Subject / body ─────────────────────────────────
                  TextField(
                    controller: subjectCtrl,
                    decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: bodyCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Body', border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    final savedSubject = subjectCtrl.text;
    final savedBody = bodyCtrl.text;
    subjectCtrl.dispose();
    bodyCtrl.dispose();

    if (saved == true) {
      final updates = <String, dynamic>{
        'subject': savedSubject,
        'body': savedBody,
      };
      if (scheduledFor != null) {
        updates['scheduled_for'] = Timestamp.fromDate(scheduledFor!);
      } else {
        updates['scheduled_for'] = FieldValue.delete();
      }
      await _firebaseService.updateScheduledMessage(msg.id, updates);
    }
  }

  String _formatCurrency(double amount) => '\$${amount.toStringAsFixed(2)}';

  // ── Build ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Contract?>(
      stream: _firebaseService.getContractByOrganizer(widget.currentUserUid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final contract = snapshot.data;

        if (contract == null) {
          return _buildEmptyState();
        }

        return _buildContractView(contract);
      },
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

  Widget _buildPinGate(Contract contract) {
    // Request focus exactly once — avoids the Android keyboard flicker caused by
    // autofocus inside a StreamBuilder that rebuilds on Firestore updates.
    if (!_pinFocusRequested) {
      _pinFocusRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
            Text(
              contract.clubName.isNotEmpty ? contract.clubName : 'Contract',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter your organizer PIN to manage this contract.',
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 220,
              child: TextField(
                controller: _pinEntryCtrl,
                focusNode: _pinFocusNode,
                keyboardType: TextInputType.number,
                obscureText: !_pinVisible,
                maxLength: 8,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, letterSpacing: 6),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  counterText: '',
                  errorText: _pinError,
                  suffixIcon: IconButton(
                    icon: Icon(_pinVisible ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _pinVisible = !_pinVisible),
                  ),
                ),
                onSubmitted: (_) => _checkPin(contract),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 220,
              child: ElevatedButton(
                onPressed: () => _checkPin(contract),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Unlock'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.email_outlined, size: 18),
              label: const Text('Email me my PIN'),
              onPressed: () async {
                await NotificationService.sendContractPin(
                  organizerUid: widget.currentUserUid,
                  pin: contract.organizerPin,
                  clubName: contract.clubName,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN sent to your registered contact')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _checkPin(Contract contract) {
    if (_pinEntryCtrl.text == contract.organizerPin) {
      setState(() {
        _pinVerified = true;
        _pinError = null;
      });
    } else {
      setState(() => _pinError = 'Incorrect PIN — try again');
    }
  }

  Widget _buildContractView(Contract contract) {
    if (contract.organizerPin.isNotEmpty && !_pinVerified) {
      return _buildPinGate(contract);
    }

    final sessions = contract.totalSessions;
    final spots = contract.spotsPerSession;
    final total = contract.totalCourtSlots;
    final committed = contract.committedSlots;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // ── Capacity indicator ────────────────────────────────────
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

        const SizedBox(height: 16),

        // ── Upcoming Auto-Messages ────────────────────────────────
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
      stream: _firebaseService.getScheduledMessagesStream(widget.currentUserUid),
      builder: (context, snapshot) {
        final all = snapshot.data ?? [];
        final pending = all
            .where((m) => m.status == 'pending' && m.contractId == contract.id)
            .toList()
          ..sort((a, b) {
            if (a.scheduledFor == null && b.scheduledFor == null) return 0;
            if (a.scheduledFor == null) return 1;
            if (b.scheduledFor == null) return -1;
            return a.scheduledFor!.compareTo(b.scheduledFor!);
          });

        if (pending.isEmpty) return const SizedBox.shrink();

        final visible = pending.take(3).toList();

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.schedule, size: 16, color: Colors.blueGrey),
                    const SizedBox(width: 6),
                    Text(
                      'Upcoming Auto-Messages (${pending.length})',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ScheduledMessagesListScreen(
                            organizerUid: widget.currentUserUid,
                            contract: contract,
                            onSendNow: (msg) => _sendScheduledMessageNow(contract, msg),
                            onEdit: _editScheduledMessage,
                          ),
                        ),
                      ),
                      child: const Text('View All'),
                    ),
                  ],
                ),
                const Divider(height: 8),
                ...visible.map((msg) => _buildScheduledMessageRow(contract, msg)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildScheduledMessageRow(Contract contract, ScheduledMessage msg) {
    final typeLabel = switch (msg.type) {
      'availability_request'  => 'Availability Request',
      'availability_reminder' => 'Availability Reminder',
      'last_ditch'            => 'Last-Ditch Fill Request',
      'sub_request'           => 'Sub Request',
      'lineup_publish'        => 'Auto Lineup Publish',
      _                       => 'Payment Reminder',
    };
    final dateStr = msg.scheduledFor != null
        ? DateFormat('EEE, MMM d').format(msg.scheduledFor!)
        : 'On Hold';
    final sessionStr = msg.sessionDate != null
        ? ' — ${DateFormat('MMM d').format(msg.sessionDate!)}'
        : '';
    final filterLabel = msg.recipientsFilter == 'unpaid' ? 'unpaid players' : '${msg.recipients.length} players';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$typeLabel$sessionStr',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  '$dateStr · $filterLabel',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _editScheduledMessage(msg),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
            child: const Text('Edit', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => _firebaseService.deleteScheduledMessage(msg.id),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              foregroundColor: Colors.red.shade400,
            ),
            child: const Text('Delete', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => _sendScheduledMessageNow(contract, msg),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              foregroundColor: Colors.blue.shade700,
            ),
            child: const Text('Send Now', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerTile(Contract contract, ContractPlayer player) {
    final confirmed = player.paymentStatus == 'confirmed';
    final amountOwed = contract.pricePerSlot > 0
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
        title: Text(player.displayName),
        subtitle: Text(
          amountOwed != null
              ? '${player.paidSlots} sessions · ${_formatCurrency(amountOwed)}'
              : '${player.paidSlots} sessions',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
