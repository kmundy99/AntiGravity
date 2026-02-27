import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models.dart';
import '../widgets/add_custom_player_button.dart';

class PlayersDirectoryScreen extends StatefulWidget {
  final String currentUserUid;
  final VoidCallback onEditProfile;

  const PlayersDirectoryScreen({
    super.key,
    required this.currentUserUid,
    required this.onEditProfile,
  });

  @override
  State<PlayersDirectoryScreen> createState() => _PlayersDirectoryScreenState();
}

class _PlayersDirectoryScreenState extends State<PlayersDirectoryScreen> {
  final Set<String> _selectedPlayers = {};

  // Filter State
  double _filterMinNtrp = 0.0;
  int? _filterCircle;
  String _filterLocation = "";
  String _filterName = "";

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());

        final docs = snapshot.data!.docs;

        final currentUserDocIndex = docs.indexWhere(
          (d) => d.id == widget.currentUserUid,
        );
        if (currentUserDocIndex == -1) return const SizedBox.shrink();
        final currentUser = User.fromFirestore(docs[currentUserDocIndex]);

        // Filter players based on state
        final filteredDocs = docs.where((doc) {
          final user = User.fromFirestore(doc);
          if (user.displayName.isEmpty) return false;

          // Always show self so they can edit their profile
          if (doc.id == widget.currentUserUid) return true;

          if (_filterMinNtrp > 0.0 && user.ntrpLevel < _filterMinNtrp) {
            return false;
          }

          if (_filterName.trim().isNotEmpty) {
            final nameStr = user.displayName.toLowerCase();
            if (!nameStr.contains(_filterName.trim().toLowerCase()))
              return false;
          }

          if (_filterLocation.isNotEmpty) {
            final addr = user.address.toLowerCase();
            if (!addr.contains(_filterLocation.toLowerCase())) return false;
          }

          // Circle filter uses doc.id (UUID) as key into circleRatings
          if (_filterCircle != null) {
            final assignedCircle = currentUser.circleRatings[doc.id];
            if (assignedCircle != _filterCircle) return false;
          }

          return true;
        }).toList();

        return Column(
          children: [
            ExpansionTile(
              title: const Text(
                "Advanced Filters",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              leading: const Icon(Icons.filter_list),
              children: [
                ListTile(
                  title: const Text("Minimum NTRP Level"),
                  trailing: DropdownButton<double?>(
                    value: _filterMinNtrp == 0.0 ? null : _filterMinNtrp,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Any')),
                      ...[3.0, 3.5, 4.0, 4.5, 5.0].map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.toString()),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setState(() => _filterMinNtrp = val ?? 0.0),
                  ),
                ),
                ListTile(
                  title: const Text("Filter by Circle"),
                  trailing: DropdownButton<int?>(
                    value: _filterCircle,
                    items: const [
                      DropdownMenuItem(value: null, child: Text('Any')),
                      DropdownMenuItem(value: 1, child: Text('Circle 1')),
                      DropdownMenuItem(value: 2, child: Text('Circle 2')),
                      DropdownMenuItem(value: 3, child: Text('Circle 3')),
                    ],
                    onChanged: (val) => setState(() => _filterCircle = val),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: "Search by Name (e.g. 'Jane')",
                      prefixIcon: Icon(Icons.person_search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      setState(() {
                        _filterName = val;
                      });
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: "Location Contains (e.g. 'Boston')",
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      setState(() {
                        _filterLocation = val;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: AddCustomPlayerButton(
                label: 'Add Custom Player',
                fullWidth: true,
              ),
            ),
            Expanded(
              child: filteredDocs.isEmpty
                  ? const Center(
                      child: Text("No players found matching your filters."),
                    )
                  : ListView.builder(
                      itemCount: filteredDocs.length,
                      itemBuilder: (context, index) {
                        final user = User.fromFirestore(filteredDocs[index]);
                        final docId = filteredDocs[index].id; // UUID
                        final isSelected = _selectedPlayers.contains(docId);

                        final isMe = docId == widget.currentUserUid;
                        final assignedCircle = currentUser.circleRatings[docId];

                        return ExpansionTile(
                          leading: CircleAvatar(
                            child: Text(user.displayName[0].toUpperCase()),
                          ),
                          title: Text(
                            user.displayName + (isMe ? " (You)" : ""),
                          ),
                          subtitle: Text(
                            "NTRP: ${user.ntrpLevel} | ${user.gender}",
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isMe && assignedCircle != null)
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
                                      _selectedPlayers.add(docId);
                                    } else {
                                      _selectedPlayers.remove(docId);
                                    }
                                  });
                                },
                              ),
                              const Icon(Icons.expand_more, color: Colors.grey),
                            ],
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Phone: ${user.phoneNumber.isNotEmpty ? user.phoneNumber : 'Not provided'}",
                                  ),
                                  Text(
                                    "Email: ${user.email.isNotEmpty ? user.email : 'Not provided'}",
                                  ),
                                  Text(
                                    "Address: ${user.address.isNotEmpty ? user.address : 'Not provided'}",
                                  ),
                                  Text(
                                    "Gender: ${user.gender.isNotEmpty ? user.gender : 'Not provided'}",
                                  ),
                                  Text(
                                    "Account Status: ${user.accountStatus.name}",
                                  ),
                                  Text(
                                    "Notifications: ${user.notifActive ? 'ON (${user.notifMode})' : 'OFF'}",
                                  ),
                                  if (user.createdAt != null)
                                    Text(
                                      "Created: ${user.createdAt!.toDate().toString().split('.')[0]}",
                                    ),
                                  if (user.activatedAt != null)
                                    Text(
                                      "Activated: ${user.activatedAt!.toDate().toString().split('.')[0]}",
                                    ),
                                  if (!isMe) ...[
                                    const Divider(),
                                    const Text(
                                      "Assign to Circle:",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SegmentedButton<int>(
                                      segments: const [
                                        ButtonSegment(
                                          value: 1,
                                          label: Text('Circle 1'),
                                        ),
                                        ButtonSegment(
                                          value: 2,
                                          label: Text('Circle 2'),
                                        ),
                                        ButtonSegment(
                                          value: 3,
                                          label: Text('Circle 3'),
                                        ),
                                      ],
                                      selected: assignedCircle != null
                                          ? {assignedCircle}
                                          : <int>{},
                                      emptySelectionAllowed: true,
                                      onSelectionChanged: (set) async {
                                        final newCircle = set.isEmpty
                                            ? null
                                            : set.first;
                                        final targetUid = docId;

                                        final newRatings =
                                            Map<String, int>.from(
                                              currentUser.circleRatings,
                                            );
                                        if (newCircle == null) {
                                          newRatings.remove(targetUid);
                                        } else {
                                          newRatings[targetUid] = newCircle;
                                        }

                                        // Write to current user's doc by UUID
                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(widget.currentUserUid)
                                            .update({
                                              'circleRatings': newRatings,
                                            });
                                      },
                                    ),
                                  ],
                                  if (isMe) ...[
                                    const Divider(),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        TextButton.icon(
                                          icon: const Icon(
                                            Icons.edit,
                                            color: Colors.blue,
                                          ),
                                          label: const Text("Edit Profile"),
                                          onPressed: widget.onEditProfile,
                                        ),
                                        TextButton.icon(
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                          ),
                                          label: const Text(
                                            "Delete Account",
                                            style: TextStyle(color: Colors.red),
                                          ),
                                          onPressed: () {
                                            showDialog(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: const Text(
                                                  "Delete Account?",
                                                ),
                                                content: const Text(
                                                  "Are you sure you want to permanently delete your account?",
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(context),
                                                    child: const Text("Cancel"),
                                                  ),
                                                  ElevatedButton(
                                                    style:
                                                        ElevatedButton.styleFrom(
                                                          backgroundColor:
                                                              Colors.red,
                                                          foregroundColor:
                                                              Colors.white,
                                                        ),
                                                    onPressed: () async {
                                                      final myUid =
                                                          widget.currentUserUid;

                                                      final matchesSnapshot =
                                                          await FirebaseFirestore
                                                              .instance
                                                              .collection(
                                                                'matches',
                                                              )
                                                              .get();
                                                      for (var doc
                                                          in matchesSnapshot
                                                              .docs) {
                                                        final matchData = doc
                                                            .data();

                                                        if (matchData['organizerId'] ==
                                                            myUid) {
                                                          await doc.reference
                                                              .delete();
                                                          continue;
                                                        }

                                                        final roster = List.from(
                                                          matchData['roster'] ??
                                                              [],
                                                        );
                                                        final initialLength =
                                                            roster.length;
                                                        roster.removeWhere(
                                                          (r) =>
                                                              r['uid'] == myUid,
                                                        );
                                                        if (roster.length <
                                                            initialLength) {
                                                          await doc.reference
                                                              .update({
                                                                'roster':
                                                                    roster,
                                                              });
                                                        }
                                                      }

                                                      await FirebaseFirestore
                                                          .instance
                                                          .collection('users')
                                                          .doc(myUid)
                                                          .delete();
                                                      if (context.mounted) {
                                                        final prefs =
                                                            await SharedPreferences.getInstance();
                                                        await prefs.remove(
                                                          'user_uid',
                                                        );
                                                        Navigator.pop(context);
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              "Account deleted.",
                                                            ),
                                                          ),
                                                        );
                                                        Navigator.pushAndRemoveUntil(
                                                          context,
                                                          MaterialPageRoute(
                                                            builder: (context) =>
                                                                const TennisApp(),
                                                          ),
                                                          (route) => false,
                                                        );
                                                      }
                                                    },
                                                    child: const Text("Delete"),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            if (_selectedPlayers.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                color: Colors.blue.shade50,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("Selected: ${_selectedPlayers.length} players"),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                      ),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text("Availability Heatmap"),
                            content: const Text(
                              "Placeholder for the UI02 heatmap showing overlapping busy slots.",
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text("Close"),
                              ),
                            ],
                          ),
                        );
                      },
                      child: const Text("View Availability Heatmap"),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
