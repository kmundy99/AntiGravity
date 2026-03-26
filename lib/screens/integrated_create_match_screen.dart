import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../secrets.dart';
import '../services/match_service.dart';
import '../services/location_service.dart';
import '../widgets/player_selection_panel.dart';

class IntegratedCreateMatchScreen extends StatefulWidget {
  final DateTime prefillDate;

  const IntegratedCreateMatchScreen({
    super.key,
    required this.prefillDate,
  });

  @override
  State<IntegratedCreateMatchScreen> createState() => _IntegratedCreateMatchScreenState();
}

class _IntegratedCreateMatchScreenState extends State<IntegratedCreateMatchScreen> {
  // Form State
  String _selectedAddress = '';
  late DateTime _selectedDate;
  late TimeOfDay _selectedStartTime;
  late TimeOfDay _selectedEndTime;
  int _playerLimit = 4;
  double _minNtrp = 3.5;
  TextEditingController? _addressController;
  bool _isSaving = false;

  // Player Selection State
  final Set<String> _selectedRecruitUids = {};
  final List<User> _selectedRecruits = [];
  String? _currentUserUid;
  String _organizerName = 'Organizer (You)';
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.prefillDate;
    _selectedStartTime = TimeOfDay.fromDateTime(widget.prefillDate);
    _selectedEndTime = TimeOfDay.fromDateTime(
      widget.prefillDate.add(const Duration(hours: 1, minutes: 30)),
    );
    _loadUser();
  }

  void _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('user_uid');
    if (uid != null) {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists) {
        final user = User.fromFirestore(doc);
        setState(() {
          _currentUser = user;
          _organizerName = user.displayName;
          _minNtrp = 0.0;
          _currentUserUid = uid;
        });
      } else {
        setState(() => _currentUserUid = uid);
      }
    }
  }

  Future<List<Map<String, String>>> _fetchPlaceSuggestions(String input) async {
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
            .map((s) => {
                  'text': s['placePrediction']['text']['text'] as String,
                  'placeId': s['placePrediction']['placeId'] as String,
                })
            .toList();
      }
    } catch (e) {
      debugPrint('Places autocomplete error: $e');
    }
    return [];
  }

  // Generate a combined target DateTime for availability evaluation
  DateTime get _currentSlot {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedStartTime.hour,
      _selectedStartTime.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUser == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isWide = MediaQuery.of(context).size.width > 800;

    Widget formContent = _buildFormColumn();
    Widget lovContent = PlayerSelectionPanel(
      currentUser: _currentUser!,
      currentUserUid: _currentUserUid!,
      targetLocation: _selectedAddress,
      targetSlot: _currentSlot,
      onSelectionChanged: (uids, users) {
        setState(() {
          _selectedRecruitUids.clear();
          _selectedRecruitUids.addAll(uids);
          _selectedRecruits.clear();
          _selectedRecruits.addAll(users);
        });
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Match'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: formContent),
                const VerticalDivider(width: 1, color: Colors.grey),
                Expanded(flex: 5, child: lovContent),
              ],
            )
          : ListView(
              children: [
                formContent,
                const Divider(height: 1, color: Colors.grey),
                SizedBox(height: 600, child: lovContent),
              ],
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, -2))
          ],
        ),
        child: SafeArea(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: _isSaving
                ? null
                : () async {
                    if (_selectedAddress.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select a court location')),
                      );
                      return;
                    }

                    setState(() => _isSaving = true);
                    final matchDate = DateTime(
                      _selectedDate.year,
                      _selectedDate.month,
                      _selectedDate.day,
                      _selectedStartTime.hour,
                      _selectedStartTime.minute,
                    );

                    final newMatch = Match(
                      organizerId: _currentUserUid!,
                      location: _selectedAddress,
                      matchDate: matchDate,
                      requiredCount: _playerLimit,
                      minNtrp: _minNtrp,
                      maxNtrp: 5.0,
                      status: MatchStatus.Filling,
                      roster: [
                        Roster(
                          uid: _currentUserUid!,
                          displayName: _organizerName,
                          status: RosterStatus.accepted,
                        ),
                        ..._selectedRecruits.map(
                          (user) => Roster(
                            uid: user.uid,
                            displayName: user.displayName,
                            status: RosterStatus.invited,
                          ),
                        ),
                      ],
                    );

                    try {
                      final docRef = await FirebaseFirestore.instance.collection('matches').add(newMatch.toFirestore());
                      
                      if (_selectedRecruits.isNotEmpty && mounted) {
                        await MatchService.addPlayersToMatch(
                          context: context,
                          match: newMatch,
                          matchId: docRef.id,
                          newRecruits: _selectedRecruits,
                          organizerName: _organizerName,
                        );
                      }
                      if (mounted) Navigator.pop(context);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e')),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _isSaving = false);
                    }
                  },
            child: _isSaving
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : Text('Confirm & Post Match (${_selectedRecruitUids.length} invited)'),
          ),
        ),
      ),
    );
  }

  Widget _buildFormColumn() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          "COURT LOCATION",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
        ),
        TypeAheadField<Map<String, String>>(
          suggestionsCallback: _fetchPlaceSuggestions,
          itemBuilder: (context, suggestion) {
            return ListTile(
              leading: const Icon(Icons.place),
              title: Text(suggestion['text']!),
            );
          },
          onSelected: (suggestion) async {
            final display = suggestion['text']!;
            final placeId = suggestion['placeId']!;
            _addressController?.text = display;
            setState(() => _selectedAddress = display);
            final formatted = await LocationService.fetchFormattedAddress(placeId, placesApiKey);
            if (formatted != null && mounted) {
              setState(() => _selectedAddress = formatted);
            }
          },
          builder: (context, controller, focusNode) {
            _addressController = controller;
            if (_selectedAddress.isNotEmpty && controller.text.isEmpty) {
              controller.text = _selectedAddress;
            }

            return TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: (val) {
                 // Update state on each keystroke so LOV distance calculation updates reactively
                 setState(() => _selectedAddress = val);
              },
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
          contentPadding: EdgeInsets.zero,
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
                contentPadding: EdgeInsets.zero,
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
                contentPadding: EdgeInsets.zero,
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

        const SizedBox(height: 20),
        const Text(
          "MATCH SETTINGS",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Total Players (including you)"),
          trailing: DropdownButton<int>(
            value: _playerLimit,
            items: [2, 3, 4, 6]
                .map((v) => DropdownMenuItem(value: v, child: Text(v.toString())))
                .toList(),
            onChanged: (val) => setState(() => _playerLimit = val!),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Minimum NTRP Level"),
          trailing: DropdownButton<double>(
            value: _minNtrp,
            items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text(v == 0.0 ? 'Any' : v.toString())))
                .toList(),
            onChanged: (val) => setState(() => _minNtrp = val!),
          ),
        ),
      ],
    );
  }
}
