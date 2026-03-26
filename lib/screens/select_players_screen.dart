import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../utils/feedback_utils.dart';
import '../widgets/player_selection_panel.dart';

class SelectPlayersScreen extends StatefulWidget {
  final String currentUserUid;
  final List<Roster> existingRoster;
  final String? targetLocation; // e.g., the court's address

  const SelectPlayersScreen({
    super.key,
    required this.currentUserUid,
    this.existingRoster = const [],
    this.targetLocation,
  });

  @override
  State<SelectPlayersScreen> createState() => _SelectPlayersScreenState();
}

class _SelectPlayersScreenState extends State<SelectPlayersScreen> {
  final Set<String> _selectedUids = {};
  final List<User> _selectedUsers = [];

  User? _currentUser;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  void _loadUser() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.currentUserUid)
        .get();
    if (doc.exists && mounted) {
      setState(() {
        _currentUser = User.fromFirestore(doc);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Players'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () {
              Navigator.pop(context, _selectedUsers);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'feedbackBtnSelectPlayers',
        onPressed: () {
          showFeedbackModal(
            context,
            widget.currentUserUid,
            'User',
            "Select Players Screen",
          );
        },
        backgroundColor: Colors.amber.shade300,
        foregroundColor: Colors.black87,
        child: const Icon(Icons.lightbulb_outline),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: PlayerSelectionPanel(
                    currentUser: _currentUser!,
                    currentUserUid: widget.currentUserUid,
                    targetLocation: widget.targetLocation,
                    existingRoster: widget.existingRoster,
                    onSelectionChanged: (uids, users) {
                      setState(() {
                        _selectedUids.clear();
                        _selectedUids.addAll(uids);
                        _selectedUsers.clear();
                        _selectedUsers.addAll(users);
                      });
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: Colors.blue.shade900,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(context, _selectedUsers);
                    },
                    child: Text('Confirm Invites (${_selectedUids.length})'),
                  ),
                ),
              ],
            ),
    );
  }
}
