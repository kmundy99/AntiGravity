import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'models.dart';
import 'secrets.dart';
import 'screens/select_players_screen.dart';

import 'services/match_service.dart';

class CreateMatchScreen extends StatefulWidget {
  final DateTime? prefillDate;
  final String? prefillLocation;
  final List<String>? prefillPlayerUids;

  const CreateMatchScreen({
    super.key,
    this.prefillDate,
    this.prefillLocation,
    this.prefillPlayerUids,
  });

  @override
  State<CreateMatchScreen> createState() => _CreateMatchScreenState();
}

class _CreateMatchScreenState extends State<CreateMatchScreen> {
  String _selectedAddress = '';
  DateTime _selectedDate = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _selectedStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _selectedEndTime = const TimeOfDay(hour: 10, minute: 30);
  int _playerLimit = 4;
  double _minNtrp = 3.5;
  TextEditingController? _addressController;
  bool _isSaving = false;

  final List<User> _selectedRecruits = [];
  String? _currentUserUid; // UUID
  String _organizerName = 'Organizer (You)';
  double _organizerNtrp = 0.0;

  @override
  void initState() {
    super.initState();
    if (widget.prefillDate != null) {
      _selectedDate = widget.prefillDate!;
      _selectedStartTime = TimeOfDay.fromDateTime(widget.prefillDate!);
      _selectedEndTime = TimeOfDay.fromDateTime(
        widget.prefillDate!.add(const Duration(hours: 1, minutes: 30)),
      );
    }
    if (widget.prefillLocation != null) {
      _selectedAddress = widget.prefillLocation!;
    }
    _loadUser();
  }

  void _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('user_uid');
    if (uid != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists) {
        final userData = doc.data() as Map<String, dynamic>;
        setState(() {
          _organizerName = userData['display_name'] ?? 'Organizer';
          _organizerNtrp = (userData['ntrp_level'] ?? 0.0).toDouble();
          _currentUserUid = uid;
        });
      } else {
        setState(() {
          _currentUserUid = uid;
        });
      }
    }

    // Load previous players for Rematch flow
    if (widget.prefillPlayerUids != null &&
        widget.prefillPlayerUids!.isNotEmpty) {
      await _loadRematchPlayers(widget.prefillPlayerUids!);
    }
  }

  /// Loads User objects from Firestore for the Rematch pre-fill.
  /// UIDs are now Firestore doc IDs (UUIDs).
  Future<void> _loadRematchPlayers(List<String> uids) async {
    final users = <User>[];
    for (final uid in uids) {
      if (uid.isEmpty) continue;
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        if (doc.exists) {
          users.add(User.fromFirestore(doc));
        }
      } catch (_) {
        // Skip users that can't be loaded
      }
    }
    if (mounted && users.isNotEmpty) {
      setState(() {
        _selectedRecruits.addAll(users);
      });
    }
  }

  Future<List<String>> _fetchPlaceSuggestions(String input) async {
    if (input.isEmpty) return [];

    try {
      final response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': placesApiKey,
        },
        body: jsonEncode({'input': input}),
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final suggestions = json['suggestions'] as List? ?? [];
        return suggestions
            .where((s) => s['placePrediction'] != null)
            .map((s) => s['placePrediction']['text']['text'] as String)
            .toList();
      }
    } catch (e) {
      debugPrint('Places autocomplete error: $e');
    }

    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host a Match')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "COURT LOCATION",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          TypeAheadField<String>(
            suggestionsCallback: _fetchPlaceSuggestions,
            itemBuilder: (context, suggestion) {
              return ListTile(
                leading: const Icon(Icons.place),
                title: Text(suggestion),
              );
            },
            onSelected: (suggestion) {
              setState(() => _selectedAddress = suggestion);
              _addressController?.text = suggestion;
            },
            builder: (context, controller, focusNode) {
              _addressController = controller;
              if (_selectedAddress.isNotEmpty && controller.text.isEmpty) {
                controller.text = _selectedAddress;
              }

              return TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: (val) => _selectedAddress = val,
                decoration: const InputDecoration(
                  hintText: 'Search Court...',
                  prefixIcon: Icon(Icons.map),
                ),
              );
            },
          ),

          const SizedBox(height: 30),
          const Text(
            "MATCH DETAILS",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),

          ListTile(
            leading: const Icon(Icons.calendar_today),
            title: const Text("Date"),
            subtitle: Text("${_selectedDate.toLocal()}".split(' ')[0]),
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date != null) {
                setState(() => _selectedDate = date);
              }
            },
          ),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  leading: const Icon(Icons.access_time),
                  title: const Text("Start Time"),
                  subtitle: Text(_selectedStartTime.format(context)),
                  onTap: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: _selectedStartTime,
                    );
                    if (time != null) {
                      setState(() {
                        _selectedStartTime = time;
                        int endHour = time.hour + 1;
                        int endMinute = time.minute + 30;
                        if (endMinute >= 60) {
                          endHour += 1;
                          endMinute -= 60;
                        }
                        _selectedEndTime = TimeOfDay(
                          hour: endHour % 24,
                          minute: endMinute,
                        );
                      });
                    }
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  leading: const Icon(Icons.access_time_filled),
                  title: const Text("End Time"),
                  subtitle: Text(_selectedEndTime.format(context)),
                  onTap: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: _selectedEndTime,
                    );
                    if (time != null) {
                      setState(() => _selectedEndTime = time);
                    }
                  },
                ),
              ),
            ],
          ),

          Row(
            children: [
              Expanded(
                child: ListTile(
                  title: const Text("Min NTRP"),
                  subtitle: DropdownButton<double>(
                    value: _minNtrp,
                    items: [3.0, 3.5, 4.0, 4.5, 5.0]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(v.toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _minNtrp = v!),
                  ),
                ),
              ),
              Expanded(
                child: ListTile(
                  title: const Text("Max Players"),
                  subtitle: DropdownButton<int>(
                    value: _playerLimit,
                    items: [2, 3, 4, 6]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(v.toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _playerLimit = v!),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          const Text(
            "PLAYERS",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
          ),

          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text(_organizerName)),
              ..._selectedRecruits
                  .map(
                    (player) => Chip(
                      label: Text(player.displayName),
                      onDeleted: () =>
                          setState(() => _selectedRecruits.remove(player)),
                    ),
                  )
                  .toList(),
            ],
          ),

          ElevatedButton.icon(
            icon: const Icon(Icons.person_add),
            label: const Text('Add Players...'),
            onPressed: () async {
              if (_currentUserUid == null) return;
              final List<User>? selectedUsers = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SelectPlayersScreen(
                    currentUserUid: _currentUserUid!,
                    // UUID MIGRATION: Use user.uid (UUID) for deduplication
                    alreadyInRosterUids: _selectedRecruits
                        .map((u) => u.uid)
                        .toList(),
                  ),
                ),
              );

              if (selectedUsers != null && selectedUsers.isNotEmpty) {
                setState(() {
                  _selectedRecruits.addAll(selectedUsers);
                });
              }
            },
          ),

          const SizedBox(height: 40),

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.blue.shade900,
              foregroundColor: Colors.white,
            ),
            onPressed: _isSaving
                ? null
                : () async {
                    if (_selectedAddress.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter a location'),
                        ),
                      );
                      return;
                    }

                    setState(() => _isSaving = true);

                    final finalDateTime = DateTime(
                      _selectedDate.year,
                      _selectedDate.month,
                      _selectedDate.day,
                      _selectedStartTime.hour,
                      _selectedStartTime.minute,
                    );

                    final newMatch = Match(
                      organizerId: _currentUserUid ?? 'host', // UUID
                      location: _selectedAddress,
                      matchDate: finalDateTime,
                      status: MatchStatus.Filling,
                      roster: [
                        Roster(
                          uid: _currentUserUid ?? 'host', // UUID
                          displayName: _organizerName,
                          status: RosterStatus.accepted,
                          ntrpLevel: _organizerNtrp > 0 ? _organizerNtrp : null,
                        ),
                      ],
                      requiredCount: _playerLimit,
                      minNtrp: _minNtrp,
                      maxNtrp: 7.0,
                      currentTier: 1,
                    );

                    try {
                      final docRef = await FirebaseFirestore.instance
                          .collection('matches')
                          .add(newMatch.toFirestore());

                      final matchId = docRef.id;

                      await MatchService.addPlayersToMatch(
                        context: context,
                        match: newMatch,
                        matchId: matchId,
                        newRecruits: _selectedRecruits,
                        organizerName: _organizerName,
                      );

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Match saved successfully!'),
                          ),
                        );
                        Navigator.pop(context);
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() => _isSaving = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error saving: $e')),
                        );
                      }
                    }
                  },
            child: _isSaving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('Confirm & Post Match'),
          ),
        ],
      ),
    );
  }
}
