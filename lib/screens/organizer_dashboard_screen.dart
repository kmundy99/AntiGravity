import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import 'select_players_screen.dart';
import 'match_chat_screen.dart';
import '../utils/feedback_utils.dart';
import '../services/notification_service.dart';
import '../services/match_service.dart';

class OrganizerDashboardScreen extends StatefulWidget {
  final String matchId;
  const OrganizerDashboardScreen({super.key, required this.matchId});

  @override
  State<OrganizerDashboardScreen> createState() =>
      _OrganizerDashboardScreenState();
}

class _OrganizerDashboardScreenState extends State<OrganizerDashboardScreen> {
  Match? _match;
  StreamSubscription<DocumentSnapshot>? _matchSub;

  @override
  void initState() {
    super.initState();
    _loadMatch();
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    super.dispose();
  }

  void _loadMatch() {
    _matchSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.matchId)
        .snapshots()
        .listen((doc) {
          if (!mounted) return;
          if (doc.exists) {
            setState(() {
              _match = Match.fromFirestore(doc);
            });
          }
        });
  }

  void _removePlayer(Roster player) {
    showDialog(
      context: context,
      builder: (context) {
        final reasonCtrl = TextEditingController();
        return AlertDialog(
          title: const Text("Remove Player"),
          content: TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(labelText: "Reason for removal"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                if (_match != null) {
                  final newRoster = _match!.roster
                      .where((r) => r.uid != player.uid)
                      .toList();
                  await FirebaseFirestore.instance
                      .collection('matches')
                      .doc(widget.matchId)
                      .update({
                        'roster': newRoster.map((e) => e.toMap()).toList(),
                      });
                  if (player.status == RosterStatus.accepted &&
                      player.uid.isNotEmpty) {
                    final orgName = _match!.roster
                        .firstWhere(
                          (r) => r.uid == _match!.organizerId,
                          orElse: () => Roster(
                            uid: '',
                            displayName: 'Organizer',
                            status: RosterStatus.accepted,
                          ),
                        )
                        .displayName;

                    await NotificationService.sendRemoval(
                      contact: player.uid, // UUID
                      match: _match!,
                      organizerName: orgName,
                      isSms: false, // _send() handles routing
                      reason: reasonCtrl.text,
                    );
                  }
                }
                if (context.mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("Remove"),
            ),
          ],
        );
      },
    );
  }

  void _cancelMatch() {
    showDialog(
      context: context,
      builder: (context) {
        final reasonCtrl = TextEditingController();
        return AlertDialog(
          title: const Text("Cancel Match"),
          content: TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(
              labelText: "Reason for cancellation",
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Abort"),
            ),
            ElevatedButton(
              onPressed: () async {
                if (_match != null && reasonCtrl.text.isNotEmpty) {
                  final orgName = _match!.roster
                      .firstWhere(
                        (r) => r.uid == _match!.organizerId,
                        orElse: () => Roster(
                          uid: '',
                          displayName: 'Organizer',
                          status: RosterStatus.accepted,
                        ),
                      )
                      .displayName;

                  await NotificationService.sendMatchCancellation(
                    roster: _match!.roster,
                    match: _match!,
                    organizerName: orgName,
                    reason: reasonCtrl.text,
                  );

                  await FirebaseFirestore.instance
                      .collection('matches')
                      .doc(widget.matchId)
                      .delete();

                  if (context.mounted) {
                    Navigator.pop(context);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Match permanently canceled."),
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("Confirm Cancel"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_match == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Match"),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'feedbackBtnOrgDash',
        onPressed: () {
          final orgName = _match!.roster
              .firstWhere(
                (r) => r.uid == _match!.organizerId,
                orElse: () => Roster(
                  uid: '',
                  displayName: 'Organizer',
                  status: RosterStatus.accepted,
                ),
              )
              .displayName;
          showFeedbackModal(
            context,
            _match!.organizerId,
            orgName,
            "Organizer Dashboard - Manage Match",
          );
        },
        backgroundColor: Colors.amber.shade300,
        foregroundColor: Colors.black87,
        child: const Icon(Icons.lightbulb_outline),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: const Text(
                "Match Info",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                "Location: ${_match!.location}\n"
                "Time: ${NotificationService.formatDateTime(Match(organizerId: '', location: '', matchDate: _match!.matchDate, status: MatchStatus.Filling, roster: []))}\n"
                "Tier: ${_match!.currentTier}",
              ),
              trailing: IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () {
                  // TODO: Edit flow
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "Roster & Waitlist",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          ..._match!.roster.map(
            (player) => ListTile(
              title: Text(player.displayName),
              subtitle: Text("Status: ${player.status.name}"),
              trailing: player.uid == _match!.organizerId
                  ? const Text("Organizer")
                  : IconButton(
                      icon: const Icon(Icons.remove_circle, color: Colors.red),
                      onPressed: () => _removePlayer(player),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8.0,
            runSpacing: 8.0,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.chat),
                label: const Text("Match Chat"),
                onPressed: () {
                  final orgName = _match!.roster
                      .firstWhere(
                        (r) => r.uid == _match!.organizerId,
                        orElse: () => Roster(
                          uid: '',
                          displayName: 'Organizer',
                          status: RosterStatus.accepted,
                        ),
                      )
                      .displayName;

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MatchChatScreen(
                        matchId: widget.matchId,
                        currentUserId: _match!.organizerId, // UUID
                        currentUserName: orgName,
                      ),
                    ),
                  );
                },
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text("Recruit Players"),
                onPressed: () async {
                  if (_match == null) return;
                  final List<User>? selectedUsers = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SelectPlayersScreen(
                        currentUserUid: _match!.organizerId, // UUID
                        alreadyInRosterUids: _match!.roster
                            .map((r) => r.uid)
                            .toList(),
                      ),
                    ),
                  );

                  if (selectedUsers != null && selectedUsers.isNotEmpty) {
                    final orgName = _match!.roster
                        .firstWhere(
                          (r) => r.uid == _match!.organizerId,
                          orElse: () => Roster(
                            uid: '',
                            displayName: 'Organizer',
                            status: RosterStatus.accepted,
                          ),
                        )
                        .displayName;

                    await MatchService.addPlayersToMatch(
                      context: context,
                      match: _match!,
                      matchId: widget.matchId,
                      newRecruits: selectedUsers,
                      organizerName: orgName,
                    );
                  }
                },
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.cancel),
                label: const Text("Cancel Match"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade100,
                  foregroundColor: Colors.red.shade900,
                ),
                onPressed: () => _cancelMatch(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
