import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../services/location_service.dart';
import '../utils/availability_utils.dart';

class PlayerSelectionPanel extends StatefulWidget {
  final User currentUser;
  final String currentUserUid;
  final String? targetLocation;
  final DateTime? targetSlot;
  final List<Roster> existingRoster;
  final Function(Set<String>, List<User>) onSelectionChanged;

  const PlayerSelectionPanel({
    super.key,
    required this.currentUser,
    required this.currentUserUid,
    this.targetLocation,
    this.targetSlot,
    this.existingRoster = const [],
    required this.onSelectionChanged,
  });

  @override
  State<PlayerSelectionPanel> createState() => _PlayerSelectionPanelState();
}

class _PlayerSelectionPanelState extends State<PlayerSelectionPanel> {
  final Set<String> _selectedRecruitUids = {};
  final List<User> _selectedRecruits = [];

  // Filters
  int? _circleFilter;
  double? _maxDistanceFilter;
  double _minNtrp = 0.0;
  String _genderFilter = 'Any';
  String _nameQuery = '';

  @override
  void initState() {
    super.initState();
    // Default 20 miles as requested by user feedback
    _maxDistanceFilter = 20.0;
  }

  void _notifySelectionChanged() {
    widget.onSelectionChanged(_selectedRecruitUids, _selectedRecruits);
  }

  void _toggleSelection(User user, bool isSelected) {
    setState(() {
      if (isSelected) {
        _selectedRecruitUids.add(user.uid);
        _selectedRecruits.add(user);
      } else {
        _selectedRecruitUids.remove(user.uid);
        _selectedRecruits.removeWhere((r) => r.uid == user.uid);
      }
    });
    _notifySelectionChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // LOV Filters Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.blue.shade50,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Invite Players",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue),
              ),
              const SizedBox(height: 8),
              
              // Search by Name
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Search by name...',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: EdgeInsets.all(8),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                ),
                onChanged: (val) {
                  setState(() {
                    _nameQuery = val.toLowerCase();
                  });
                },
              ),
              const SizedBox(height: 8),
              
              // Top Row Filters: Circle & Distance
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Circle", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        DropdownButton<int?>(
                          isExpanded: true,
                          isDense: true,
                          value: _circleFilter,
                          items: const [
                            DropdownMenuItem(value: null, child: Text('All', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 1, child: Text('Circle 1', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 2, child: Text('Circle 2', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 3, child: Text('Circle 3', style: TextStyle(fontSize: 13))),
                          ],
                          onChanged: (val) => setState(() => _circleFilter = val),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Max Distance", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        DropdownButton<double>(
                          isExpanded: true,
                          isDense: true,
                          value: _maxDistanceFilter,
                          items: const [
                            DropdownMenuItem(value: 3.0, child: Text('3m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 5.0, child: Text('5m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 10.0, child: Text('10m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 15.0, child: Text('15m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 20.0, child: Text('20m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 30.0, child: Text('30m', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 1000.0, child: Text('Any', style: TextStyle(fontSize: 13))),
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
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // Bottom Row Filters: NTRP & Gender
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Min NTRP", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        DropdownButton<double>(
                          isExpanded: true,
                          isDense: true,
                          value: _minNtrp,
                          items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                              .map((v) => DropdownMenuItem(value: v, child: Text(v == 0.0 ? 'Any' : v.toString(), style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (val) => setState(() => _minNtrp = val!),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Gender", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        DropdownButton<String>(
                          isExpanded: true,
                          isDense: true,
                          value: _genderFilter,
                          items: ['Any', 'Male', 'Female', 'Non-Binary', 'Other']
                              .map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: (val) => setState(() => _genderFilter = val!),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.targetLocation == null || widget.targetLocation!.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: Text(
                    "⚠️ Distance filtering is from your home address since no court is selected.",
                    style: TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
        
        // Player List Stream
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('users').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              
              final allDocs = snapshot.data!.docs;
              
              // Apply filters
              final filteredUsers = allDocs.where((doc) {
                if (doc.id == widget.currentUserUid) return false;

                final u = User.fromFirestore(doc);
                if (u.displayName.isEmpty) return false;
                
                // Name filter
                if (_nameQuery.isNotEmpty && !u.displayName.toLowerCase().contains(_nameQuery)) return false;
                
                // NTRP filter
                if (_minNtrp > 0.0 && u.ntrpLevel < _minNtrp) return false;
                
                // Gender filter
                if (_genderFilter != 'Any' && u.gender != _genderFilter) return false;
                
                // Circle filter
                if (_circleFilter != null && widget.currentUser.circleRatings[doc.id] != _circleFilter) return false;
                
                // Distance filter
                if (_maxDistanceFilter != null && _maxDistanceFilter! < 1000) {
                  final targetAddress = (widget.targetLocation != null && widget.targetLocation!.isNotEmpty) 
                      ? widget.targetLocation! 
                      : widget.currentUser.address;
                  if (targetAddress.isNotEmpty) {
                    final dist = LocationService().getDistanceBetweenAddresses(targetAddress, u.address);
                    if (dist != null && dist > _maxDistanceFilter!) return false;
                  }
                }
                return true;
              }).map((d) => User.fromFirestore(d)).toList();

              // Sort the list inline
              filteredUsers.sort((a, b) {
                final circleA = widget.currentUser.circleRatings[a.uid];
                final circleB = widget.currentUser.circleRatings[b.uid];
                if (circleA != null && circleB == null) return -1;
                if (circleA == null && circleB != null) return 1;
                if (circleA != null && circleB != null) {
                  if (circleA != circleB) return circleA.compareTo(circleB);
                }
                return a.displayName.compareTo(b.displayName);
              });

              // Group by availability
              final available = <User>[];
              final away = <User>[];
              final unknown = <User>[];

              for (final u in filteredUsers) {
                if (widget.targetSlot != null) {
                  switch (AvailabilityUtils.playerAvailability(u, widget.targetSlot!)) {
                    case AvailabilityStatus.available:
                      available.add(u);
                    case AvailabilityStatus.away:
                      away.add(u);
                    case AvailabilityStatus.unknown:
                      unknown.add(u);
                  }
                } else {
                  // If no specific slot, put everyone in Unknown
                  unknown.add(u);
                }
              }

              final filterableUsersList = filteredUsers.where((u) => !widget.existingRoster.any((r) => r.uid == u.uid)).toList();
              final bool allSelected = filterableUsersList.isNotEmpty &&
                  filterableUsersList.every((u) => _selectedRecruitUids.contains(u.uid));

              return ListView(
                padding: const EdgeInsets.only(bottom: 100, top: 4),
                children: [
                  CheckboxListTile(
                    title: const Text("Select All Matches", style: TextStyle(fontWeight: FontWeight.bold)),
                    value: allSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          for (var u in filterableUsersList) {
                            if (!_selectedRecruitUids.contains(u.uid)) {
                              _selectedRecruitUids.add(u.uid);
                              _selectedRecruits.add(u);
                            }
                          }
                        } else {
                          for (var u in filterableUsersList) {
                            _selectedRecruitUids.remove(u.uid);
                            _selectedRecruits.removeWhere((r) => r.uid == u.uid);
                          }
                        }
                      });
                      _notifySelectionChanged();
                    },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                  const Divider(),
                  _buildLovSection("Available", available, Colors.green.shade700),
                  _buildLovSection("Not set", unknown, Colors.grey.shade700),
                  _buildLovSection("Away", away, Colors.red.shade700),
                  if (available.isEmpty && unknown.isEmpty && away.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20.0),
                      child: Text("No players match your filters.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLovSection(String title, List<User> players, Color color) {
    if (players.isEmpty) return const SizedBox.shrink();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            title,
            style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13),
          ),
        ),
        ...players.map((u) {
          final isSelected = _selectedRecruitUids.contains(u.uid);
          final circle = widget.currentUser.circleRatings[u.uid];
          
          final rosterEntry = widget.existingRoster.firstWhere(
            (r) => r.uid == u.uid,
            orElse: () => Roster(uid: '', displayName: '', status: RosterStatus.invited),
          );
          final bool isInRoster = rosterEntry.uid.isNotEmpty;
          
          final double? distFromCourt = (widget.targetLocation != null && widget.targetLocation!.isNotEmpty)
              ? LocationService().getDistanceBetweenAddresses(widget.targetLocation!, u.address)
              : null;
          final double? distFromHome = (widget.currentUser.address.isNotEmpty)
              ? LocationService().getDistanceBetweenAddresses(widget.currentUser.address, u.address)
              : null;
          final double? distToShow = distFromCourt ?? distFromHome;
          final String distLabel = distFromCourt != null ? 'mi from court' : 'mi from home';
          final String distText = distToShow != null ? ' • ${distToShow.toStringAsFixed(1)} $distLabel' : '';

          Widget trailingWidget;
          if (isInRoster) {
            trailingWidget = Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: rosterEntry.status == RosterStatus.accepted
                    ? Colors.green.shade100
                    : rosterEntry.status == RosterStatus.declined
                        ? Colors.red.shade100
                        : Colors.orange.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                rosterEntry.status.name.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: rosterEntry.status == RosterStatus.accepted
                      ? Colors.green.shade900
                      : rosterEntry.status == RosterStatus.declined
                          ? Colors.red.shade900
                          : Colors.orange.shade900,
                ),
              ),
            );
          } else {
            trailingWidget = Checkbox(
              value: isSelected,
              visualDensity: VisualDensity.compact,
              onChanged: (val) {
                _toggleSelection(u, val == true);
              },
            );
          }

          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: CircleAvatar(
              radius: 16,
              child: Text(u.displayName.isNotEmpty ? u.displayName[0].toUpperCase() : '?'),
            ),
            title: Text(u.displayName, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Text("NTRP: ${u.ntrpLevel == 0.0 ? '—' : u.ntrpLevel}$distText"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (circle != null)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(4)),
                    child: Text("C$circle", style: TextStyle(color: Colors.blue.shade900, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                trailingWidget,
              ],
            ),
            onTap: isInRoster ? null : () {
              _toggleSelection(u, !isSelected);
            },
          );
        }),
      ],
    );
  }
}
