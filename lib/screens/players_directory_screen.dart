import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models.dart';
import '../widgets/add_custom_player_button.dart';
import '../utils/player_sort.dart';
import 'compose_message_screen.dart';
import 'general_email_queue_screen.dart';
import '../services/location_service.dart';
import 'complete_profile_screen.dart';
import 'availability_setup_screen.dart';
import '../utils/link_utils.dart';

class PlayersDirectoryScreen extends StatefulWidget {
  final String currentUserUid;
  final VoidCallback onEditProfile;
  /// UIDs from the contract this user organizes; null if they have no contract.
  final List<String>? organizerContractRosterUids;

  const PlayersDirectoryScreen({
    super.key,
    required this.currentUserUid,
    required this.onEditProfile,
    this.organizerContractRosterUids,
  });

  @override
  State<PlayersDirectoryScreen> createState() => _PlayersDirectoryScreenState();
}

class _PlayersDirectoryScreenState extends State<PlayersDirectoryScreen> {
  final Set<String> _selectedPlayers = {};
  final Map<String, String> _selectedPlayerNames = {};

  // Filter State
  double _filterMinNtrp = 0.0;
  int? _filterCircle;
  String _filterLocation = "";
  String _filterName = "";
  String _filterGender = "Any";
  bool _filterMyContract = false;
  
  double? _filterMaxDistance;
  bool _initializedDistance = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;

        final currentUserDocIndex = docs.indexWhere(
          (d) => d.id == widget.currentUserUid,
        );
        if (currentUserDocIndex == -1) return const SizedBox.shrink();
        final currentUser = User.fromFirestore(docs[currentUserDocIndex]);

        // Initialize distance filter to Any — Players page shows everyone by default
        if (!_initializedDistance) {
          _filterMaxDistance = 1000.0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _initializedDistance = true);
          });
        }

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
            if (!nameStr.contains(_filterName.trim().toLowerCase())) {
              return false;
            }
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

          if (_filterGender != 'Any' && user.gender != _filterGender) {
            return false;
          }

          if (_filterMyContract) {
            final rosterUids = widget.organizerContractRosterUids;
            if (rosterUids == null || !rosterUids.contains(doc.id)) return false;
          }

          if (_filterMaxDistance != null && _filterMaxDistance! < 1000) { // 1000 acts as "Any"
            final distance = LocationService().getDistanceBetweenAddresses(currentUser.address, user.address);
            if (distance != null && distance > _filterMaxDistance!) {
              return false;
            }
          }

          return true;
        }).toList();

        filteredDocs.sort((a, b) => sortPlayerDocs(a, b,
          currentUserUid: widget.currentUserUid,
          circleRatings: currentUser.circleRatings,
        ));

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
                  // Only show the distance filter if the user's zip code is known
                  if (currentUser.address.isNotEmpty && LocationService().extractZipCode(currentUser.address) != null)
                    ListTile(
                      title: const Text("Maximum Distance"),
                      subtitle: const Text("Based on your zip code"),
                      trailing: DropdownButton<double>(
                        value: _filterMaxDistance ?? 10.0,
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
                            setState(() => _filterMaxDistance = val);
                            // Save preference to Firestore
                            await FirebaseFirestore.instance
                                .collection('users')
                                .doc(widget.currentUserUid)
                                .update({'defaultDistanceFilter': val});
                          }
                        },
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
                ListTile(
                  title: const Text("Filter by Gender"),
                  trailing: DropdownButton<String>(
                    value: _filterGender,
                    items: ['Any', 'Male', 'Female', 'Non-Binary', 'Other']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (val) => setState(() => _filterGender = val!),
                  ),
                ),
                if (widget.organizerContractRosterUids != null)
                  SwitchListTile(
                    title: const Text('My Contract players only'),
                    subtitle: const Text('Show only players on your contract roster'),
                    value: _filterMyContract,
                    onChanged: (val) => setState(() => _filterMyContract = val),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: AddCustomPlayerButton(
                label: 'Add Custom Player',
                fullWidth: true,
                creatorUid: widget.currentUserUid,
              ),
            ),
            if (filteredDocs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                child: Row(
                  children: [
                    Checkbox(
                      value: filteredDocs.every((doc) => _selectedPlayers.contains(doc.id)),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            for (final doc in filteredDocs) {
                              final user = User.fromFirestore(doc);
                              _selectedPlayers.add(doc.id);
                              _selectedPlayerNames[doc.id] = user.displayName.isNotEmpty ? user.displayName : doc.id;
                            }
                          } else {
                            for (final doc in filteredDocs) {
                              _selectedPlayers.remove(doc.id);
                              _selectedPlayerNames.remove(doc.id);
                            }
                          }
                        });
                      },
                    ),
                    const Text("Select All Filtered", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
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

                        return _buildPlayerCard(
                          context: context,
                          user: user,
                          docId: docId,
                          isMe: isMe,
                          isSelected: isSelected,
                          assignedCircle: assignedCircle,
                          currentUser: currentUser,
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
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.send, size: 16),
                      label: const Text("Compose Message"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ComposeMessageScreen(
                            config: ComposeMessageConfig(
                              organizerUid: widget.currentUserUid,
                              availableTypes: const [MessageType.custom],
                              initialType: MessageType.custom,
                              recipients: _selectedPlayerNames.entries
                                  .map((e) => RecipientInfo(uid: e.key, displayName: e.value))
                                  .toList(),
                              contextType: 'general',
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (currentUser.isAdmin) ...[
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.mark_email_unread_outlined, size: 16),
                        label: const Text("Request Availability"),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(40),
                          backgroundColor: Colors.orange.shade700,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => _generateAvailabilityRequests(currentUser),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // GENERATE AVAILABILITY REQUESTS
  // ---------------------------------------------------------------------------
  Future<void> _generateAvailabilityRequests(User currentUser) async {
    if (_selectedPlayers.isEmpty) return;

    final renderedEmails = <RenderedEmail>[];
    for (final uid in _selectedPlayers) {
      final name = _selectedPlayerNames[uid] ?? 'Player';
      renderedEmails.add(RenderedEmail(
        uid: uid,
        displayName: name,
        subject: "Please Update Your Tennis Preferences",
        body: "Hi $name,\n\nCould you please take a moment to put in your zip code and the available times during the week when you would like to play? Entering your availability and zip code allows us to invite you to matches scheduled close to your location during those time slots.\n\nClick the link below to set your preferences (no login required):\n${LinkUtils.getBaseUrl()}/#/availability-setup?uid=$uid\n\nThanks!",
      ));
    }

    final msg = ScheduledMessage(
      contractId: 'general',
      organizerId: currentUser.uid,
      type: 'general_availability_request',
      status: 'pending_approval',
      subject: "Please Update Your Tennis Preferences",
      body: "Hi {name},\n...",
      recipients: _selectedPlayers.map((uid) => RecipientInfo(uid: uid, displayName: _selectedPlayerNames[uid] ?? '')).toList(),
      renderedEmails: renderedEmails,
      generatedAt: DateTime.now(),
      baseUrl: LinkUtils.getBaseUrl(),
    );

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    await FirebaseFirestore.instance.collection('scheduled_messages').add(msg.toFirestore());

    if (mounted) {
      Navigator.pop(context); // close dialog
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GeneralEmailQueueScreen(
            adminUid: currentUser.uid,
            adminEmail: currentUser.email,
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // COMPACT PLAYER CARD — replaces the old ExpansionTile
  // ---------------------------------------------------------------------------
  Widget _buildPlayerCard({
    required BuildContext context,
    required User user,
    required String docId,
    required bool isMe,
    required bool isSelected,
    required int? assignedCircle,
    required User currentUser,
  }) {
    // Truncate address to city-level for space
    String shortAddress = '';
    if (user.address.isNotEmpty) {
      final parts = user.address.split(',');
      shortAddress = parts.length > 1
          ? parts[parts.length - 2].trim()
          : parts[0].trim();
    }

    final double? distFromMe = (!isMe && currentUser.address.isNotEmpty)
        ? LocationService().getDistanceBetweenAddresses(currentUser.address, user.address)
        : null;
    // True when we have addresses but zip codes are missing/unrecognised
    final bool zipMissing = !isMe &&
        distFromMe == null &&
        (currentUser.address.isNotEmpty || user.address.isNotEmpty) &&
        (LocationService().extractZipCode(currentUser.address) == null ||
            LocationService().extractZipCode(user.address) == null);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () {
          if (!isMe) {
            setState(() {
              if (isSelected) {
                _selectedPlayers.remove(docId);
                _selectedPlayerNames.remove(docId);
              } else {
                _selectedPlayers.add(docId);
                _selectedPlayerNames[docId] = user.displayName;
              }
            });
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── ROW 1: Avatar + Name + NTRP + Notif icon + Checkbox ──
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: isMe
                        ? Colors.green.shade100
                        : Colors.blue.shade100,
                    child: Text(
                      user.displayName[0].toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: isMe
                            ? Colors.green.shade900
                            : Colors.blue.shade900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.displayName + (isMe ? " (You)" : ""),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          "NTRP ${user.ntrpLevel == 0.0 ? '—' : user.ntrpLevel.toString()}"
                          " · ${user.gender.isNotEmpty ? user.gender : '—'}",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        if (distFromMe != null)
                          Text(
                            "${distFromMe.toStringAsFixed(1)} miles away",
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey.shade600,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        else if (zipMissing)
                          Text(
                            "Add zip code to address for distance",
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.orange.shade700,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Notification indicator
                  Tooltip(
                    message: user.notifActive
                        ? 'Notifications ON'
                        : 'Notifications OFF',
                    child: Icon(
                      user.notifActive
                          ? Icons.notifications_active
                          : Icons.notifications_off,
                      size: 22,
                      color: user.notifActive
                          ? Colors.green.shade400
                          : Colors.grey.shade400,
                    ),
                  ),
                  if (!isMe)
                    Checkbox(
                      value: isSelected,
                      visualDensity: VisualDensity.compact,
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedPlayers.add(docId);
                            _selectedPlayerNames[docId] = user.displayName;
                          } else {
                            _selectedPlayers.remove(docId);
                            _selectedPlayerNames.remove(docId);
                          }
                        });
                      },
                    ),
                  if (isMe)
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      color: Colors.blue,
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onEditProfile,
                      tooltip: 'Edit Profile',
                    ),
                  if (!isMe && currentUser.isAdmin)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.admin_panel_settings, size: 20, color: Colors.indigo),
                      tooltip: 'Admin Tools',
                      padding: EdgeInsets.zero,
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit_profile',
                          child: Text('Edit Profile'),
                        ),
                        const PopupMenuItem(
                          value: 'edit_availability',
                          child: Text('Edit Availability'),
                        ),
                      ],
                      onSelected: (value) {
                        if (value == 'edit_profile') {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CompleteProfileScreen(playerUid: docId, isAdminMode: true),
                            ),
                          );
                        } else if (value == 'edit_availability') {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AvailabilitySetupScreen(playerUid: docId, isAdminMode: true),
                            ),
                          );
                        }
                      },
                    ),
                ],
              ),

              const SizedBox(height: 6),

              // ── ROW 2: Contact info (compact icons) ──
              Row(
                children: [
                  const SizedBox(width: 54), // indent to align with name
                  if (user.phoneNumber.isNotEmpty) ...[
                    Icon(Icons.phone, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        user.phoneNumber,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (user.email.isNotEmpty) ...[
                    Icon(Icons.email, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        user.email,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (shortAddress.isNotEmpty) ...[
                    Icon(Icons.place, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        shortAddress,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),

              // ── ROW 3: Circle selector (other players) or Delete (me) ──
              if (!isMe) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(width: 54),
                    Text(
                      "Circle:",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _circleChip(1, assignedCircle, docId, currentUser),
                    const SizedBox(width: 4),
                    _circleChip(2, assignedCircle, docId, currentUser),
                    const SizedBox(width: 4),
                    _circleChip(3, assignedCircle, docId, currentUser),
                    if (user.accountStatus == AccountStatus.provisional &&
                        user.createdByUid == widget.currentUserUid) ...[
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.person_remove, size: 16, color: Colors.red),
                        label: const Text('Remove', style: TextStyle(color: Colors.red, fontSize: 13)),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => _confirmDeleteProvisionalPlayer(context, docId, user.displayName),
                      ),
                    ],
                  ],
                ),
              ],
              if (isMe) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 54),
                    TextButton.icon(
                      icon: const Icon(
                        Icons.delete,
                        size: 16,
                        color: Colors.red,
                      ),
                      label: const Text(
                        "Delete Account",
                        style: TextStyle(color: Colors.red, fontSize: 14),
                      ),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _confirmDeleteAccount(context),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Small circle-number chip — tappable to assign/unassign
  // ---------------------------------------------------------------------------
  Widget _circleChip(
    int circle,
    int? assignedCircle,
    String targetUid,
    User currentUser,
  ) {
    final bool isActive = assignedCircle == circle;
    return InkWell(
      onTap: () async {
        final newRatings = Map<String, int>.from(currentUser.circleRatings);
        if (isActive) {
          newRatings.remove(targetUid);
        } else {
          newRatings[targetUid] = circle;
        }
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.currentUserUid)
            .update({'circleRatings': newRatings});
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? Colors.blue.shade700 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          '$circle',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: isActive ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DELETE PROVISIONAL PLAYER (created by current user, never logged in)
  // ---------------------------------------------------------------------------
  void _confirmDeleteProvisionalPlayer(BuildContext context, String docId, String displayName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Provisional Player?'),
        content: Text(
          '$displayName has not logged in yet and will be removed from the directory. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await FirebaseFirestore.instance.collection('users').doc(docId).delete();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$displayName removed.')),
                );
              }
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DELETE ACCOUNT — extracted from old expansion tile
  // ---------------------------------------------------------------------------
  void _confirmDeleteAccount(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Account?"),
        content: const Text(
          "Are you sure you want to permanently delete your account?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final myUid = widget.currentUserUid;

              final matchesSnapshot = await FirebaseFirestore.instance
                  .collection('matches')
                  .get();
              for (var doc in matchesSnapshot.docs) {
                final matchData = doc.data();

                if (matchData['organizerId'] == myUid) {
                  await doc.reference.delete();
                  continue;
                }

                final roster = List.from(matchData['roster'] ?? []);
                final initialLength = roster.length;
                roster.removeWhere((r) => r['uid'] == myUid);
                if (roster.length < initialLength) {
                  await doc.reference.update({'roster': roster});
                }
              }

              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(myUid)
                  .delete();
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('user_uid');
              await prefs.remove('user_login_contact');
              await prefs.remove('user_display_name');
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Account deleted.")),
                );
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (context) => const TennisApp()),
                  (route) => false,
                );
              }
            },
            child: const Text("Delete"),
          ),
        ],
      ),
    );
  }
}
