import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'firebase_options.dart';
import 'secrets.dart';
import 'create_match.dart';
import 'utils/feedback_utils.dart';
import 'models.dart';
import 'screens/history_screen.dart';
import 'screens/organizer_dashboard_screen.dart';
import 'screens/players_directory_screen.dart';

import 'screens/match_chat_screen.dart';
import 'services/notification_service.dart';
import 'services/match_service.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const TennisApp());
}

class TennisApp extends StatelessWidget {
  const TennisApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      onGenerateRoute: (settings) {
        if (settings.name != null && settings.name!.startsWith('/match/')) {
          final uri = Uri.parse(settings.name!);
          final pathSegments = uri.pathSegments;

          if (pathSegments.length == 2 && pathSegments[0] == 'match') {
            final matchId = pathSegments[1];
            final uid = uri.queryParameters['uid'];

            return MaterialPageRoute(
              builder: (context) =>
                  HomeScreen(initialMatchId: matchId, initialUid: uid),
            );
          }
        }
        return MaterialPageRoute(builder: (context) => const HomeScreen());
      },
      home: const HomeScreen(),
    );
  }
}

class _MeetingDataSource extends CalendarDataSource {
  _MeetingDataSource(List<Appointment> source) {
    appointments = source;
  }

  void updateAppointments(List<Appointment> source) {
    appointments = source;
    notifyListeners(CalendarDataSourceAction.reset, source);
  }
}

class HomeScreen extends StatefulWidget {
  final String? initialMatchId;
  final String? initialUid;
  const HomeScreen({super.key, this.initialMatchId, this.initialUid});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The current user's Firestore document ID (UUID). Replaces old `_myPhone`.
  String? _myUid;
  User? _user;
  bool _isEditingProfile = false;
  bool _isQuickSetup = false;
  final _phoneCtrl = TextEditingController();
  int _selectedIndex = 0;

  // Controllers for the 9 Spec Fields
  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneFormCtrl = TextEditingController();
  String _gender = 'Other';
  double _ntrp = 3.5;
  bool _notifOn = true;
  String _notifMode = 'SMS';

  // Calendar State
  final CalendarController _calendarController = CalendarController();

  // Filter State
  final TextEditingController _filterPlayerCtrl = TextEditingController(
    text: 'Anyone',
  );
  int? _filterSpotsLeft;
  double? _filterMinNtrpMatch;
  int? _filterIncludesCircle;
  int? _filterCirclePlayerCount;
  CalendarView _currentCalendarView = CalendarView.month;

  List<QueryDocumentSnapshot> _allMatches = [];
  List<String> _allUsers = [];
  StreamSubscription<QuerySnapshot>? _matchesSub;
  StreamSubscription<QuerySnapshot>? _usersSub;
  late _MeetingDataSource _calendarDataSource;

  @override
  void initState() {
    super.initState();
    _calendarDataSource = _MeetingDataSource(<Appointment>[]);
    _loadUser();

    _matchesSub = FirebaseFirestore.instance
        .collection('matches')
        .where(
          'match_date',
          isGreaterThanOrEqualTo: Timestamp.fromDate(
            DateTime.now().subtract(const Duration(days: 1)),
          ),
        )
        .orderBy('match_date')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          setState(() {
            _allMatches = snap.docs;
          });
          _refreshCalendarData();
        });

    _usersSub = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          setState(() {
            _allUsers = snap.docs
                .map((d) => d['display_name'].toString())
                .where((name) => name.trim().isNotEmpty)
                .toSet()
                .toList();
            _allUsers.sort();
          });
        });
  }

  @override
  void dispose() {
    _matchesSub?.cancel();
    _usersSub?.cancel();
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _emailCtrl.dispose();
    _phoneFormCtrl.dispose();
    _filterPlayerCtrl.dispose();
    _calendarController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // LOGIN & USER LOADING — now resolves contact → UUID
  // ===========================================================================

  /// Looks up a user by their phone or email and returns the Firestore doc ID (UUID).
  /// Returns null if no matching user is found.
  Future<String?> _resolveContactToUid(String normalizedContact) async {
    // 1. Try primary_contact field
    var query = await FirebaseFirestore.instance
        .collection('users')
        .where('primary_contact', isEqualTo: normalizedContact)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) return query.docs.first.id;

    // 2. Try email or phone field explicitly
    if (normalizedContact.contains('@')) {
      query = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: normalizedContact)
          .limit(1)
          .get();
    } else {
      query = await FirebaseFirestore.instance
          .collection('users')
          .where('phone_number', isEqualTo: normalizedContact)
          .limit(1)
          .get();
    }

    if (query.docs.isNotEmpty) return query.docs.first.id;

    // 3. Legacy support: check if a doc exists with the contact as its ID
    //    (for pre-migration users whose doc ID IS their phone/email)
    final legacyDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(normalizedContact)
        .get();

    if (legacyDoc.exists) return legacyDoc.id;

    return null;
  }

  void _loadUser() async {
    final prefs = await SharedPreferences.getInstance();

    // Auto-login via Deep Link — uid param is now a UUID
    if (widget.initialUid != null && widget.initialUid!.isNotEmpty) {
      await prefs.setString('user_uid', widget.initialUid!);
    }

    final storedUid = prefs.getString('user_uid');
    if (storedUid != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(storedUid)
          .get();
      if (doc.exists) {
        final user = User.fromFirestore(doc);
        setState(() {
          _myUid = storedUid;
          _user = user;
          _nameCtrl.text = _user?.displayName ?? "";
          _addressCtrl.text = _user?.address ?? "";
          _emailCtrl.text = _user?.email ?? "";
          _phoneFormCtrl.text = _user?.phoneNumber ?? "";
          _gender =
              ['Male', 'Female', 'Non-Binary', 'Other'].contains(user.gender)
              ? user.gender
              : 'Other';
          _ntrp = [0.0, 3.0, 3.5, 4.0, 4.5, 5.0].contains(user.ntrpLevel)
              ? user.ntrpLevel
              : 3.5;
          _notifOn = _user?.notifActive ?? true;
          _notifMode = ['SMS', 'Email', 'Both'].contains(user.notifMode)
              ? user.notifMode
              : 'SMS';
          _isEditingProfile =
              user.accountStatus == AccountStatus.provisional &&
              widget.initialMatchId == null;
        });

        // Now that _myUid is set, re-color the calendar
        _refreshCalendarData();

        if (widget.initialMatchId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showMatchDetailsDialog(widget.initialMatchId!);
          });
        }
      } else {
        // Stored UID points to a deleted doc — clear it and show login
        await prefs.remove('user_uid');
        setState(() {
          _myUid = null;
        });
      }
    }
  }

  void _saveProfile() async {
    if (_myUid == null) return;

    final contactValue = _user?.primaryContact ?? _phoneCtrl.text.trim();

    final newUser = User(
      uid: _myUid!,
      displayName: _nameCtrl.text,
      primaryContact: contactValue,
      ntrpLevel: _isQuickSetup ? 0.0 : _ntrp,
      gender: _isQuickSetup ? 'Other' : _gender,
      address: _isQuickSetup ? '' : _addressCtrl.text,
      email: _isQuickSetup ? '' : _emailCtrl.text,
      phoneNumber: _isQuickSetup ? '' : _phoneFormCtrl.text,
      notifActive: _isQuickSetup ? false : _notifOn,
      notifMode: _isQuickSetup ? 'SMS' : _notifMode,
      accountStatus: _isQuickSetup
          ? AccountStatus.provisional
          : AccountStatus.fully_registered,
      createdAt: _user?.createdAt ?? Timestamp.now(),
      activatedAt: Timestamp.now(),
    );

    await FirebaseFirestore.instance
        .collection('users')
        .doc(_myUid)
        .set(newUser.toFirestore(), SetOptions(merge: true));

    setState(() => _isEditingProfile = false);
    _loadUser();
  }

  Future<void> _launchMap() async {
    final address = Uri.encodeComponent(_addressCtrl.text);
    final url = Uri.parse(
      "https://www.google.com/maps/search/?api=1&query=$address",
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Could not open maps")));
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
    if (_myUid == null) return _buildLogin();
    if (_isEditingProfile) return _buildProfileEditor();

    return Scaffold(
      appBar: AppBar(
        title: Text("Hi, ${_user?.displayName ?? 'Player'}"),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        actions: [
          if (_user?.accountStatus == AccountStatus.provisional)
            ElevatedButton(
              onPressed: () => setState(() {
                _isQuickSetup = false;
                _isEditingProfile = true;
              }),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              child: const Text("Complete Profile"),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => setState(() => _isEditingProfile = true),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('user_uid');
              setState(() {
                _myUid = null;
                _user = null;
                _isEditingProfile = false;
                _isQuickSetup = false;
              });
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        heroTag: 'feedbackBtn',
        onPressed: () {
          final tabs = ["Upcoming", "Players", "History"];
          final currentTab = tabs[_selectedIndex];
          showFeedbackModal(context, _myUid, _user?.displayName, currentTab);
        },
        backgroundColor: Colors.amber.shade300,
        foregroundColor: Colors.black87,
        child: const Icon(Icons.lightbulb_outline),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_tennis),
            label: "Upcoming",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: "Players"),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: "History"),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return _buildUpcomingMatches();
      case 1:
        return PlayersDirectoryScreen(
          currentUserUid: _myUid ?? '',
          onEditProfile: () {
            setState(() {
              _selectedIndex = 0;
              _isEditingProfile = true;
            });
          },
        );
      case 2:
        return const HistoryScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  void _refreshCalendarData() {
    // Don't process until the user has loaded — otherwise everything is grey
    if (_myUid == null) return;

    var filteredDocs = _allMatches.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final roster = List.from(data['roster'] ?? []);

      // 0. Only show matches where the user is the Organizer, Joined, or Invited
      final bool isOrg = data['organizerId'] == _myUid;
      final bool isJnd = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'accepted',
      );
      final bool isInv = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'invited',
      );
      // TEMPORARILY DISABLED: if (!isOrg && !isJnd && !isInv) return false;

      // 1. Show <Player LOV> scheduled matches only
      if (_filterPlayerCtrl.text.trim().isNotEmpty &&
          _filterPlayerCtrl.text.trim().toLowerCase() != 'anyone') {
        final target = _filterPlayerCtrl.text.trim().toLowerCase();
        if (target == 'me') {
          bool inRoster = roster.any((r) => r['uid'] == _myUid);
          if (!inRoster && data['organizerId'] != _myUid) return false;
        } else {
          bool inRoster = roster.any(
            (r) =>
                (r['displayName']?.toString().toLowerCase() ?? '') == target &&
                r['status'] == 'accepted',
          );
          if (!inRoster) return false;
        }
      }

      // 2. <1,2,3> or more slots open
      if (_filterSpotsLeft != null) {
        int acceptedCount = roster
            .where((r) => r['status'] == 'accepted')
            .length;
        int spotsOpen = (data['requiredCount'] ?? 4) - acceptedCount;
        if (spotsOpen < _filterSpotsLeft!) return false;
      }

      // 3. All players are above level <NTRP Levels LOV>
      if (_filterMinNtrpMatch != null) {
        double matchMin = (data['minNtrp'] ?? 0.0).toDouble();
        if (matchMin < _filterMinNtrpMatch!) return false;
      }

      // 4. Show matches with at least <Number LOV> Players from my <Circle LOV>
      if (_filterIncludesCircle != null &&
          _user != null &&
          _filterCirclePlayerCount != null) {
        int circleCount = 0;
        for (var r in roster) {
          final uid = r['uid'];
          if (uid != null &&
              uid != _myUid &&
              r['status'] == 'accepted' &&
              _user!.circleRatings[uid] == _filterIncludesCircle) {
            circleCount++;
          }
        }
        if (circleCount < _filterCirclePlayerCount!) return false;
      }

      return true;
    }).toList();

    final List<Appointment> fetchedAppointments = [];
    for (var doc in filteredDocs) {
      final match = doc.data() as Map<String, dynamic>;
      if (match['match_date'] == null) continue;
      final date = (match['match_date'] as Timestamp).toDate();

      final List roster = List.from(match['roster'] ?? []);

      // DEBUG: Log uid comparison to help diagnose color mismatches.
      // Check the browser console (F12 → Console) to see these.
      for (var r in roster) {
        debugPrint(
          '[CalendarColor] roster uid="${r['uid']}" status="${r['status']}" | _myUid="$_myUid" | match=${match['location']}',
        );
      }

      final bool isJoined = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'accepted',
      );
      final bool isInvited = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'invited',
      );
      final bool isOrganizer = match['organizerId'] == _myUid;

      debugPrint(
        '[CalendarColor] ${match['location']}: isOrganizer=$isOrganizer isJoined=$isJoined isInvited=$isInvited → will be ${isOrganizer
            ? "blue"
            : isJoined
            ? "green"
            : isInvited
            ? "yellow/red"
            : "GREY (no match!)"}',
      );

      final int reqCount = match['requiredCount'] ?? 4;
      final int acceptedCount = roster
          .where((r) => r['status'] == 'accepted')
          .length;
      final int spotsOpen = reqCount - acceptedCount;
      final bool isFull = spotsOpen <= 0;

      Color matchColor;
      if (isOrganizer) {
        // Organizer: dark blue (full, show up!) or light blue (needs players, recruit!)
        matchColor = isFull ? Colors.blue.shade900 : Colors.blue.shade400;
      } else if (isJoined) {
        // Accepted invite: green — you're confirmed, show up!
        matchColor = Colors.green.shade600;
      } else if (isInvited) {
        // Invited but haven't accepted yet: yellow (open, join now!) or red (full)
        matchColor = isFull ? Colors.red.shade400 : Colors.amber.shade600;
      } else {
        // Not involved in this match
        matchColor = Colors.grey.shade400;
      }

      fetchedAppointments.add(
        Appointment(
          startTime: date,
          endTime: match['end_time'] != null
              ? (match['end_time'] as Timestamp).toDate()
              : date.add(const Duration(hours: 1, minutes: 30)),
          subject:
              "${match['location'] ?? 'Court'} (${isFull ? 'Full' : '$spotsOpen Spots'})",
          color: matchColor,
          id: doc.id,
          notes: doc.id,
        ),
      );
    }

    _calendarDataSource.updateAppointments(fetchedAppointments);
  }

  Widget _buildUpcomingMatches() {
    String currentVal = _filterPlayerCtrl.text;
    if (currentVal != 'Anyone' &&
        currentVal != 'Me' &&
        !_allUsers.contains(currentVal)) {
      currentVal = 'Anyone';
    }

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
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  const Text("Show"),
                  DropdownButton<String>(
                    value: currentVal.isEmpty ? 'Anyone' : currentVal,
                    items: [
                      const DropdownMenuItem(
                        value: 'Anyone',
                        child: Text('Anyone'),
                      ),
                      const DropdownMenuItem(value: 'Me', child: Text('Me')),
                      ..._allUsers
                          .where((u) => u != 'Anyone' && u != 'Me')
                          .map(
                            (u) => DropdownMenuItem(value: u, child: Text(u)),
                          ),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _filterPlayerCtrl.text = val ?? 'Anyone';
                      });
                      _refreshCalendarData();
                    },
                  ),
                  const Text("scheduled matches only"),
                ],
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Row(
                children: [
                  DropdownButton<int?>(
                    value: _filterSpotsLeft,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Any')),
                      ...[1, 2, 3, 4].map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.toString()),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() => _filterSpotsLeft = val);
                      _refreshCalendarData();
                    },
                  ),
                  const SizedBox(width: 10),
                  const Text("or more slots are open"),
                ],
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Row(
                children: [
                  const Text("All players are above level: "),
                  const SizedBox(width: 10),
                  DropdownButton<double?>(
                    value: _filterMinNtrpMatch,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Any')),
                      ...[3.0, 3.5, 4.0, 4.5, 5.0].map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.toString()),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() => _filterMinNtrpMatch = val);
                      _refreshCalendarData();
                    },
                  ),
                ],
              ),
            ),
            if (_user != null)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    const Text("Matches with at least"),
                    DropdownButton<int?>(
                      value: _filterCirclePlayerCount,
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Any')),
                        ...[1, 2, 3, 4].map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(v.toString()),
                          ),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _filterCirclePlayerCount = val);
                        _refreshCalendarData();
                      },
                    ),
                    const Text("players from my"),
                    DropdownButton<int?>(
                      value: _filterIncludesCircle,
                      items: const [
                        DropdownMenuItem(
                          value: null,
                          child: Text('Any Circle'),
                        ),
                        DropdownMenuItem(value: 1, child: Text('Circle 1')),
                        DropdownMenuItem(value: 2, child: Text('Circle 2')),
                        DropdownMenuItem(value: 3, child: Text('Circle 3')),
                      ],
                      onChanged: (val) {
                        setState(() => _filterIncludesCircle = val);
                        _refreshCalendarData();
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: 12,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.blue.shade900, size: 12),
                  const SizedBox(width: 4),
                  const Text(
                    "Your Match — Show Up!",
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.blue.shade400, size: 12),
                  const SizedBox(width: 4),
                  const Text(
                    "Your Match — Recruit Players",
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.green.shade600, size: 12),
                  const SizedBox(width: 4),
                  const Text(
                    "Joined — Show Up!",
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.amber.shade600, size: 12),
                  const SizedBox(width: 4),
                  const Text(
                    "Invited — Join Now",
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.red.shade400, size: 12),
                  const SizedBox(width: 4),
                  const Text(
                    "Invited — Match Full",
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: SegmentedButton<CalendarView>(
            segments: const [
              ButtonSegment(
                value: CalendarView.schedule,
                label: Text('Agenda'),
              ),
              ButtonSegment(value: CalendarView.day, label: Text('Day')),
              ButtonSegment(value: CalendarView.week, label: Text('Week')),
              ButtonSegment(value: CalendarView.month, label: Text('Month')),
            ],
            selected: {_currentCalendarView},
            onSelectionChanged: (Set<CalendarView> newSelection) {
              setState(() {
                _currentCalendarView = newSelection.first;
                _calendarController.view = _currentCalendarView;
              });
            },
          ),
        ),

        Container(
          width: double.infinity,
          color: Colors.grey.shade200,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          child: Text(
            "Showing ${_calendarDataSource.appointments?.length ?? 0} match(es)",
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.black54,
            ),
          ),
        ),

        Expanded(
          child: SfCalendar(
            view: _currentCalendarView,
            controller: _calendarController,
            showNavigationArrow: true,
            showDatePickerButton: true,
            dataSource: _calendarDataSource,
            timeSlotViewSettings: const TimeSlotViewSettings(
              startHour: 0,
              endHour: 24,
            ),
            monthViewSettings: const MonthViewSettings(
              showAgenda: false,
              appointmentDisplayMode: MonthAppointmentDisplayMode.appointment,
            ),
            onTap: (CalendarTapDetails details) {
              if (details.appointments != null &&
                  details.appointments!.isNotEmpty) {
                final Appointment appt = details.appointments!.first;
                final docId = appt.notes;
                if (docId != null) {
                  _showMatchDetailsDialog(docId);
                }
              } else if (details.targetElement ==
                  CalendarElement.calendarCell) {
                final DateTime chosenSlot = details.date!;
                if (chosenSlot.isAfter(
                  DateTime.now().subtract(const Duration(hours: 1)),
                )) {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text("Create Match Here?"),
                      content: Text(
                        "Would you like to host a match on ${chosenSlot.month}/${chosenSlot.day} at ${TimeOfDay.fromDateTime(chosenSlot).format(context)}?",
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("Cancel"),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    CreateMatchScreen(prefillDate: chosenSlot),
                              ),
                            );
                          },
                          child: const Text("Create Match"),
                        ),
                      ],
                    ),
                  );
                }
              }
            },
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // MATCH DETAILS DIALOG
  // ===========================================================================
  void _showMatchDetailsDialog(String matchId) async {
    final docSnapshot = await FirebaseFirestore.instance
        .collection('matches')
        .doc(matchId)
        .get();

    if (!docSnapshot.exists) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Match Not Found"),
            content: const Text(
              "This match may have been cancelled or the link is invalid.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
      return;
    }

    final match = Match.fromFirestore(docSnapshot);
    final date = match.matchDate;

    Roster? myRosterEntry;
    for (var r in match.roster) {
      if (r.uid == _myUid) {
        myRosterEntry = r;
        break;
      }
    }

    final bool isJoined =
        myRosterEntry != null && myRosterEntry.status == RosterStatus.accepted;
    final bool isInvited =
        myRosterEntry != null && myRosterEntry.status == RosterStatus.invited;

    final int reqCount = match.requiredCount ?? 4;
    final int acceptedCount = match.roster
        .where((r) => r.status == RosterStatus.accepted)
        .length;
    final bool isFull = acceptedCount >= reqCount;
    final bool canAccept = isInvited && !isFull;

    final bool isOrganizer = match.organizerId == _myUid;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(match.location),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "🗓 ${date.month}/${date.day} at ${TimeOfDay.fromDateTime(date).format(context)}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text("Level: ${match.minNtrp} - ${match.maxNtrp}"),
            Text("Players: $acceptedCount/${match.requiredCount}"),
            if (acceptedCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Accepted Players:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    ...match.roster
                        .where((r) => r.status == RosterStatus.accepted)
                        .map((r) {
                          final bool isMe = r.uid == _myUid;
                          final bool isOrgPlayer = r.uid == match.organizerId;
                          final String cleanName = r.displayName.replaceAll(
                            ' (You)',
                            '',
                          );

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: Colors.green,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isMe ? "$cleanName (You)" : cleanName,
                                  ),
                                ),
                                if (isMe && !isOrgPlayer)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 0,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      final noteCtrl = TextEditingController();
                                      showDialog(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: const Text("Leave Match"),
                                          content: TextField(
                                            controller: noteCtrl,
                                            decoration: const InputDecoration(
                                              labelText:
                                                  "Note for organizer (optional)",
                                              hintText:
                                                  "e.g. Sorry, schedule conflict",
                                            ),
                                            autofocus: true,
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dialogContext),
                                              child: const Text("Cancel"),
                                            ),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.red,
                                                foregroundColor: Colors.white,
                                              ),
                                              onPressed: () async {
                                                final note = noteCtrl.text
                                                    .trim();

                                                await MatchService.removeMe(
                                                  matchId: matchId,
                                                  playerUid: _myUid!,
                                                  playerDisplayName:
                                                      _user?.displayName ??
                                                      'Player',
                                                  note: note.isNotEmpty
                                                      ? note
                                                      : null,
                                                );

                                                if (dialogContext.mounted) {
                                                  Navigator.pop(dialogContext);
                                                }
                                                if (context.mounted) {
                                                  Navigator.pop(context);
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        "You have been removed from the match.",
                                                      ),
                                                    ),
                                                  );
                                                }
                                              },
                                              child: const Text("Leave Match"),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      "Remove Me",
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        })
                        .toList(),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            if (isInvited)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "🎾 You are invited to play",
                  style: TextStyle(
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else if (isFull)
              const Text(
                "⚠️ Match is Full",
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
          if (isOrganizer)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple.shade500,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        OrganizerDashboardScreen(matchId: matchId),
                  ),
                );
              },
              child: const Text("Manage (Organizer)"),
            ),
          if (isJoined || isOrganizer)
            ElevatedButton.icon(
              icon: const Icon(Icons.chat),
              label: const Text("Match Chat"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade100,
                foregroundColor: Colors.blue.shade900,
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MatchChatScreen(
                      matchId: matchId,
                      currentUserId: _myUid!,
                      currentUserName: _user?.displayName ?? 'Player',
                    ),
                  ),
                );
              },
            ),
          if (isInvited)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    await MatchService.declineInvite(
                      matchId: matchId,
                      playerUid: _myUid!,
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text("Decline"),
                ),
                const SizedBox(width: 8),
                if (canAccept)
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      final success = await MatchService.acceptInvite(
                        matchId: matchId,
                        playerUid: _myUid!,
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? "Invite Accepted!"
                                  : "Match is full — couldn't accept.",
                            ),
                          ),
                        );
                      }
                    },
                    child: const Text("Accept Invite"),
                  )
                else
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: null,
                    child: const Text("Match Full"),
                  ),
              ],
            ),
          if (!isJoined && !isInvited && !isFull)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final result = await MatchService.joinMatch(
                  matchId: matchId,
                  playerUid: _myUid!,
                  playerDisplayName: _user?.displayName ?? 'Player',
                  playerNtrpLevel: _user?.ntrpLevel,
                );
                if (context.mounted) {
                  Navigator.pop(context);
                  final message = switch (result) {
                    JoinResult.accepted => "Joined Match!",
                    JoinResult.waitlisted =>
                      "Match is full — you've been added to the waitlist.",
                    JoinResult.full => "Match is completely full.",
                    JoinResult.alreadyInRoster =>
                      "You're already in this match.",
                    JoinResult.error => "Something went wrong.",
                  };
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(message)));
                }
              },
              child: const Text("Join Match"),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // LOGIN — resolves phone/email → UUID, creates new UUID doc if needed
  // ===========================================================================
  Widget _buildLogin() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sports_tennis, size: 80, color: Colors.green),
              const SizedBox(height: 20),
              TextField(
                controller: _phoneCtrl,
                decoration: const InputDecoration(
                  labelText: "Email or Phone Number",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.account_circle),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  if (_phoneCtrl.text.trim().isEmpty) return;

                  String loginId = _phoneCtrl.text.trim();

                  if (loginId.contains('@')) {
                    loginId = loginId.toLowerCase();
                  } else {
                    loginId = loginId
                        .replaceAll(RegExp(r'[^\d]'), '')
                        .replaceFirst(RegExp(r'^1'), '');
                    if (loginId.isEmpty) return;
                  }

                  // Resolve contact → UUID
                  String? uid = await _resolveContactToUid(loginId);

                  if (uid == null) {
                    // New user — create a doc with auto-generated UUID
                    final newDocRef = FirebaseFirestore.instance
                        .collection('users')
                        .doc(); // auto-ID

                    await newDocRef.set({
                      'display_name': '',
                      'primary_contact': loginId,
                      if (loginId.contains('@'))
                        'email': loginId
                      else
                        'phone_number': loginId,
                      'accountStatus': 'provisional',
                      'role': 'player',
                      'createdAt': FieldValue.serverTimestamp(),
                    });

                    uid = newDocRef.id;
                  }

                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('user_uid', uid);
                  _loadUser();
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                ),
                child: const Text("Login / Register"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileEditor() {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Player Profile"),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _isEditingProfile = false),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'feedbackBtnProfile',
        onPressed: () {
          showFeedbackModal(context, _myUid, _user?.displayName, 'Profile');
        },
        backgroundColor: Colors.amber.shade300,
        foregroundColor: Colors.black87,
        child: const Icon(Icons.lightbulb_outline),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_user == null ||
              _user?.accountStatus == AccountStatus.provisional)
            SwitchListTile(
              title: const Text("Quick Setup (Limited Features)"),
              subtitle: const Text(
                "Only provide name to accept invites. You won't be able to organize matches.",
              ),
              value: _isQuickSetup,
              onChanged: (v) => setState(() => _isQuickSetup = v),
              activeColor: Colors.blue,
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: "Display Name (Required)",
            ),
          ),
          if (!_isQuickSetup) ...[
            Row(
              children: [
                Expanded(
                  child: TypeAheadField<String>(
                    controller: _addressCtrl,
                    suggestionsCallback: _fetchPlaceSuggestions,
                    itemBuilder: (context, suggestion) {
                      return ListTile(
                        leading: const Icon(Icons.place),
                        title: Text(suggestion),
                      );
                    },
                    onSelected: (suggestion) {
                      setState(() {
                        _addressCtrl.text = suggestion;
                      });
                    },
                    builder: (context, controller, focusNode) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          labelText: "Physical Address",
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.map, color: Colors.blue),
                  onPressed: _launchMap,
                ),
              ],
            ),
            TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(labelText: "Email"),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneFormCtrl,
              decoration: const InputDecoration(labelText: "Phone Number"),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 20),
            const Text("Gender", style: TextStyle(fontWeight: FontWeight.bold)),
            DropdownButton<String>(
              value: _gender,
              isExpanded: true,
              items: [
                'Male',
                'Female',
                'Non-Binary',
                'Other',
              ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => setState(() => _gender = v!),
            ),
            const SizedBox(height: 20),
            const Text(
              "NTRP Level",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            DropdownButton<double>(
              value: _ntrp,
              isExpanded: true,
              items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(v == 0.0 ? "Not Rated" : "Level $v"),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _ntrp = v!),
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              title: const Text("Notifications Active"),
              value: _notifOn,
              onChanged: (v) => setState(() => _notifOn = v),
            ),
            const Text(
              "Notification Preference",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'SMS', label: Text('SMS')),
                ButtonSegment(value: 'Email', label: Text('Email')),
                ButtonSegment(value: 'Both', label: Text('Both')),
              ],
              selected: {_notifMode},
              onSelectionChanged: (set) =>
                  setState(() => _notifMode = set.first),
            ),
          ],
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: () {
              if (_nameCtrl.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Display Name is required')),
                );
                return;
              }
              _saveProfile();
            },
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
            ),
            child: Text(_isQuickSetup ? "Quick Join" : "Save & View Matches"),
          ),
        ],
      ),
    );
  }
}
