import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../widgets/add_custom_player_button.dart';
import '../utils/feedback_utils.dart';
import '../utils/player_sort.dart';
import '../services/location_service.dart';

class SelectPlayersScreen extends StatefulWidget {
  final String currentUserUid;
  final List<String> alreadyInRosterUids;
  final String? targetLocation; // e.g., the court's address

  const SelectPlayersScreen({
    super.key,
    required this.currentUserUid,
    this.alreadyInRosterUids = const [],
    this.targetLocation,
  });

  @override
  State<SelectPlayersScreen> createState() => _SelectPlayersScreenState();
}

class _SelectPlayersScreenState extends State<SelectPlayersScreen> {
  final Set<String> _selectedUids = {};
  final List<User> _selectedUsers = [];

  double? _minNtrpFilter;
  int? _circleFilter;
  String _genderFilter = 'Any';
  double? _maxDistanceFilter;
  bool _initializedDefaults = false;

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
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;

          final currentUserDocIndex = docs.indexWhere(
            (d) => d.id == widget.currentUserUid,
          );
          if (currentUserDocIndex == -1) {
            return const Center(child: Text("Error: User record not found."));
          }
          final currentUser = User.fromFirestore(docs[currentUserDocIndex]);

          var players = docs.where((doc) {
            final user = User.fromFirestore(doc);
            if (user.displayName.isEmpty) return false;
            if (doc.id == widget.currentUserUid) return false;
            if (widget.alreadyInRosterUids.contains(doc.id)) return false;

            if (_minNtrpFilter != null && user.ntrpLevel < _minNtrpFilter!) {
              return false;
            }

            if (_circleFilter != null) {
              final assignedCircle = currentUser.circleRatings[doc.id];
              if (assignedCircle != _circleFilter) return false;
            }

            if (_genderFilter != 'Any' && user.gender != _genderFilter) {
              return false;
            }

            if (widget.targetLocation != null && _maxDistanceFilter != null && _maxDistanceFilter! < 1000) {
              final distance = LocationService().getDistanceBetweenAddresses(widget.targetLocation!, user.address);
              if (distance != null && distance > _maxDistanceFilter!) {
                return false;
              }
            }

            return true;
          }).toList()
            ..sort((a, b) => sortPlayerDocs(a, b,
              currentUserUid: widget.currentUserUid,
              circleRatings: currentUser.circleRatings,
            ));

          // Set defaults once after reading the current user
          if (!_initializedDefaults) {
            _minNtrpFilter = null; // default to Any — caller sets match min NTRP separately
            _maxDistanceFilter = 1000.0; // default to Any distance
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _initializedDefaults = true);
            });
          }

          return Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                color: Colors.grey.shade100,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Filter by Circle",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          DropdownButton<int?>(
                            isExpanded: true,
                            value: _circleFilter,
                            items: const [
                              DropdownMenuItem(
                                value: null,
                                child: Text('All Circles'),
                              ),
                              DropdownMenuItem(
                                value: 1,
                                child: Text('Circle 1'),
                              ),
                              DropdownMenuItem(
                                value: 2,
                                child: Text('Circle 2'),
                              ),
                              DropdownMenuItem(
                                value: 3,
                                child: Text('Circle 3'),
                              ),
                            ],
                            onChanged: (val) =>
                                setState(() => _circleFilter = val),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Min NTRP",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          DropdownButton<double>(
                            isExpanded: true,
                            value: _minNtrpFilter ?? 0.0,
                            items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v,
                                    child: Text(
                                      v == 0.0 ? 'Any' : v.toString(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _minNtrpFilter = val),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Gender",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          DropdownButton<String>(
                            isExpanded: true,
                            value: _genderFilter,
                            items:
                                ['Any', 'Male', 'Female', 'Non-Binary', 'Other']
                                    .map(
                                      (v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(
                                          v,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (val) =>
                                setState(() => _genderFilter = val!),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.targetLocation != null && widget.targetLocation!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  color: Colors.grey.shade100,
                  child: Row(
                    children: [
                      const Text(
                        "Max Distance from Court:",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<double>(
                          isExpanded: true,
                          value: _maxDistanceFilter ?? 10.0,
                          items: const [
                            DropdownMenuItem(value: 3.0, child: Text('3 miles')),
                            DropdownMenuItem(value: 5.0, child: Text('5 miles')),
                            DropdownMenuItem(value: 10.0, child: Text('10 miles')),
                            DropdownMenuItem(value: 15.0, child: Text('15 miles')),
                            DropdownMenuItem(value: 20.0, child: Text('20 miles')),
                            DropdownMenuItem(value: 30.0, child: Text('30 miles')),
                            DropdownMenuItem(value: 1000.0, child: Text('Any')),
                          ],
                          onChanged: (val) async {
                            if (val != null) {
                              setState(() => _maxDistanceFilter = val);
                              await FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(widget.currentUserUid)
                                  .update({'defaultDistanceFilter': val});
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Row(
                  children: [
                    Expanded(child: const AddCustomPlayerButton()),
                    const SizedBox(width: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value:
                              players.isNotEmpty &&
                              players.every(
                                (doc) => _selectedUids.contains(doc.id),
                              ),
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                for (var doc in players) {
                                  final docId = doc.id;
                                  if (!_selectedUids.contains(docId)) {
                                    _selectedUids.add(docId);
                                    _selectedUsers.add(User.fromFirestore(doc));
                                  }
                                }
                              } else {
                                for (var doc in players) {
                                  final docId = doc.id;
                                  _selectedUids.remove(docId);
                                  _selectedUsers.removeWhere(
                                    (u) => u.uid == docId,
                                  );
                                }
                              }
                            });
                          },
                        ),
                        const Text(
                          'Select All',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: players.length,
                  itemBuilder: (context, index) {
                    final docId = players[index].id; // UUID
                    final user = User.fromFirestore(players[index]);
                    final isSelected = _selectedUids.contains(docId);
                    final assignedCircle = currentUser.circleRatings[docId];

                    final double? distFromCourt = (widget.targetLocation != null && widget.targetLocation!.isNotEmpty)
                        ? LocationService().getDistanceBetweenAddresses(widget.targetLocation!, user.address)
                        : null;
                    final double? distFromOrganizer = currentUser.address.isNotEmpty
                        ? LocationService().getDistanceBetweenAddresses(currentUser.address, user.address)
                        : null;
                    final double? distToShow = distFromCourt ?? distFromOrganizer;
                    final String distLabel = distFromCourt != null ? 'miles from court' : 'miles from organizer';

                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(user.displayName[0].toUpperCase()),
                      ),
                      title: Text(user.displayName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("NTRP: ${user.ntrpLevel} | ${user.gender}"),
                          if (distToShow != null)
                            Text(
                              "${distToShow.toStringAsFixed(1)} $distLabel",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blueGrey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (assignedCircle != null)
                            Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                "Circle $assignedCircle",
                                style: TextStyle(
                                  color: Colors.blue.shade900,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          Checkbox(
                            value: isSelected,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) {
                                  _selectedUids.add(docId);
                                  _selectedUsers.add(user);
                                } else {
                                  _selectedUids.remove(docId);
                                  // Match by uid (UUID) for reliable removal
                                  _selectedUsers.removeWhere(
                                    (u) => u.uid == user.uid,
                                  );
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedUids.remove(docId);
                            _selectedUsers.removeWhere(
                              (u) => u.uid == user.uid,
                            );
                          } else {
                            _selectedUids.add(docId);
                            _selectedUsers.add(user);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: Colors.blue.shade900,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Navigator.pop(context, _selectedUsers);
                      },
                      child: Text('Invite Selected (${_selectedUids.length})'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
