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
import 'utils/email_error_checker.dart';
import 'utils/calendar_export.dart';
import 'utils/availability_utils.dart';
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
  String _cachedDisplayName = 'Player'; // Offline fallback
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
  String _notifMode = 'Email';
  Map<String, List<String>> _weeklyAvailability = {};
  List<BlackoutPeriod> _blackouts = [];

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
  List<User> _allUsersData = [];
  DateTime? _selectedSlot;

  // Draggable feedback FAB position
  Offset? _feedbackBtnOffset;

  // Sidebar filters & player selection
  double? _sidebarNtrpFilter;
  int? _sidebarCircleFilter;
  Set<String> _selectedPlayerUids = {};

  /// Cached read-timestamps so _refreshCalendarData can check unread chats synchronously.
  Map<String, Timestamp?> _chatReadTimestamps = {};
  StreamSubscription<QuerySnapshot>? _matchesSub;
  StreamSubscription<QuerySnapshot>? _usersSub;
  late _MeetingDataSource _calendarDataSource;

  static const _avDays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _avDayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _avPeriods = ['morning', 'afternoon', 'evening'];
  static const _avPeriodLabels = ['Morn', 'Aft', 'Eve'];
  static const _avPeriodTimeLabels = ['5am–Noon', 'Noon–5pm', '5pm–11pm'];

  @override
  void initState() {
    super.initState();
    _calendarDataSource = _MeetingDataSource(<Appointment>[]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _feedbackBtnOffset == null) {
        final size = MediaQuery.of(context).size;
        setState(() {
          _feedbackBtnOffset = Offset(size.width - 72, size.height - 200);
        });
      }
    });
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
          _loadChatReads(snap.docs);
          _refreshCalendarData();
        });

    _usersSub = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          setState(() {
            final users = snap.docs
                .map((d) => User.fromFirestore(d))
                .where((u) => u.displayName.trim().isNotEmpty)
                .toList()
              ..sort((a, b) => a.displayName.compareTo(b.displayName));
            _allUsersData = users;
            _allUsers = users.map((u) => u.displayName).toSet().toList()..sort();
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
    try {
      // 1. Try primary_contact field
      var query = await FirebaseFirestore.instance
          .collection('users')
          .where('primary_contact', isEqualTo: normalizedContact)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        return query.docs.first.id;
      }

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

      if (query.docs.isNotEmpty) {
        return query.docs.first.id;
      }

      // 3. Legacy support: check if a doc exists with the contact as its ID
      final legacyDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(normalizedContact)
          .get();

      if (legacyDoc.exists) {
        return legacyDoc.id;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  void _loadUser() async {
    final prefs = await SharedPreferences.getInstance();

    // Load cached display name for immediate UI display
    _cachedDisplayName = prefs.getString('user_display_name') ?? 'Player';

    // Auto-login via Deep Link — uid param is now a UUID
    if (widget.initialUid != null && widget.initialUid!.isNotEmpty) {
      await prefs.setString('user_uid', widget.initialUid!);
    }

    final storedUid = prefs.getString('user_uid');
    if (storedUid != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(storedUid)
            .get();
        if (doc.exists) {
          final user = User.fromFirestore(doc);

          // Cache display name locally for offline fallback
          await prefs.setString('user_display_name', user.displayName);
          _cachedDisplayName = user.displayName;

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
            _weeklyAvailability = Map<String, List<String>>.from(
              user.weeklyAvailability.map(
                (k, v) => MapEntry(k, List<String>.from(v)),
              ),
            );
            // Default to all slots checked if the user has never set availability
            if (_weeklyAvailability.isEmpty) {
              _weeklyAvailability = {
                for (final day in _avDays) day: List<String>.from(_avPeriods),
              };
            }
            _blackouts = List<BlackoutPeriod>.from(user.blackouts);
            _isEditingProfile =
                user.accountStatus == AccountStatus.provisional &&
                widget.initialMatchId == null;
          });

          // Now that _myUid is set, load chat reads and re-color the calendar
          _loadChatReads(_allMatches);
          _refreshCalendarData();

          if (widget.initialMatchId != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showMatchDetailsDialog(widget.initialMatchId!);
            });
          }

          // Background check for email delivery failures (e.g. Resend quota)
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              EmailErrorChecker.showBannerIfNeeded(context);
            }
          });
        } else {
          // Stored UID points to a deleted doc — clear it and show login
          await prefs.remove('user_uid');
          await prefs.remove('user_login_contact');
          await prefs.remove('user_display_name');
          setState(() {
            _myUid = null;
          });
        }
      } catch (e) {
        // Firestore failed (offline, etc.) — use cached UID so the user
        // can at least see their calendar from Firestore's offline cache.
        final cachedName = prefs.getString('user_display_name') ?? 'Player';
        _cachedDisplayName = cachedName;
        setState(() {
          _myUid = storedUid;
          // _user stays null but _myUid is set, so calendar colors work
        });
        _refreshCalendarData();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Offline mode — showing cached data for $cachedName',
              ),
            ),
          );
        }
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
      notifMode: 'Email',
      accountStatus: _isQuickSetup
          ? AccountStatus.provisional
          : AccountStatus.fully_registered,
      createdAt: _user?.createdAt ?? Timestamp.now(),
      activatedAt: Timestamp.now(),
      weeklyAvailability: _weeklyAvailability,
      blackouts: _blackouts,
    );

    await FirebaseFirestore.instance
        .collection('users')
        .doc(_myUid)
        .set(newUser.toFirestore(), SetOptions(merge: true));

    setState(() => _isEditingProfile = false);
    _loadUser();
  }

  Future<void> _pickBlackout() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (range == null || !mounted) return;

    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Blackout Reason (optional)"),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(hintText: "e.g. Vacation, Travel"),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Add"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        _blackouts.add(
          BlackoutPeriod(
            start: range.start,
            end: range.end,
            reason: reasonCtrl.text.trim().isEmpty ? null : reasonCtrl.text.trim(),
          ),
        );
      });
    }
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
        title: Text("Hi, ${_user?.displayName ?? _cachedDisplayName}"),
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
              // Cancel Firestore listeners FIRST to stop stale data
              _matchesSub?.cancel();
              _matchesSub = null;
              _usersSub?.cancel();
              _usersSub = null;

              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('user_uid');
              await prefs.remove('user_display_name');
              await prefs.remove('user_login_contact');

              // Full app restart so the next user starts fresh.
              // We don't need to clear Firestore's offline cache because
              // the login flow checks cached contact vs entered contact
              // and won't reuse a UID meant for a different person.
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const TennisApp()),
                  (_) => false,
                );
              }
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_feedbackBtnOffset != null)
            _buildDraggableFab(
              offset: _feedbackBtnOffset!,
              onPressed: () {
                final tabs = ["Upcoming", "Players", "History"];
                showFeedbackModal(
                  context,
                  _myUid,
                  _user?.displayName,
                  tabs[_selectedIndex],
                );
              },
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() {
          _selectedIndex = index;
          if (index != 0) {
            _selectedSlot = null;
            _selectedPlayerUids = {};
          }
        }),
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

  /// Draggable feedback/lightbulb button that can be repositioned by the user.
  Widget _buildDraggableFab({
    required Offset offset,
    required VoidCallback onPressed,
  }) {
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _feedbackBtnOffset = Offset(
              (offset.dx + details.delta.dx).clamp(0.0, size.width - 56),
              (offset.dy + details.delta.dy).clamp(0.0, size.height - 120),
            );
          });
        },
        child: Material(
          elevation: 6,
          shape: const CircleBorder(),
          color: Colors.amber.shade300,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const SizedBox(
              width: 56,
              height: 56,
              child: Icon(Icons.lightbulb_outline, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }

  /// Loads the current user's chat-read timestamps for all visible matches.
  /// Runs asynchronously; when done, re-renders the calendar with badges.
  void _loadChatReads(List<QueryDocumentSnapshot> matchDocs) async {
    if (_myUid == null) return;

    final newTimestamps = <String, Timestamp?>{};
    final futures = <Future>[];

    for (final doc in matchDocs) {
      final matchData = doc.data() as Map<String, dynamic>;
      // Only bother loading for matches that have chat activity
      if (matchData['lastMessageAt'] == null) continue;

      futures.add(
        FirebaseFirestore.instance
            .collection('matches')
            .doc(doc.id)
            .collection('chatReads')
            .doc(_myUid)
            .get()
            .then((readDoc) {
              if (readDoc.exists) {
                newTimestamps[doc.id] = readDoc.data()?['readAt'] as Timestamp?;
              } else {
                newTimestamps[doc.id] = null; // never read
              }
            })
            .catchError((_) {}),
      );
    }

    await Future.wait(futures, eagerError: false);

    if (!mounted) return;
    setState(() {
      _chatReadTimestamps = newTimestamps;
    });
    _refreshCalendarData();
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
      if (!isOrg && !isJnd && !isInv) return false;

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

      final bool isJoined = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'accepted',
      );
      final bool isInvited = roster.any(
        (r) => r['uid'] == _myUid && r['status'] == 'invited',
      );
      final bool isOrganizer = match['organizerId'] == _myUid;

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

      // Check for unread chat messages
      final lastMessageAt = match['lastMessageAt'] as Timestamp?;
      bool hasUnreadChat = false;
      if (lastMessageAt != null && (isJoined || isOrganizer)) {
        final readAt = _chatReadTimestamps[doc.id];
        if (readAt == null ||
            lastMessageAt.millisecondsSinceEpoch >
                readAt.millisecondsSinceEpoch) {
          hasUnreadChat = true;
        }
      }

      final String spotLabel = isFull ? 'Full' : '$spotsOpen Spots';
      final String chatBadge = hasUnreadChat ? '💬 ' : '';

      fetchedAppointments.add(
        Appointment(
          startTime: date,
          endTime: match['end_time'] != null
              ? (match['end_time'] as Timestamp).toDate()
              : date.add(const Duration(hours: 1, minutes: 30)),
          subject: "$chatBadge${match['location'] ?? 'Court'} ($spotLabel)",
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    appointmentDisplayMode:
                        MonthAppointmentDisplayMode.appointment,
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
                        setState(() {
                          final isSameSlot = _selectedSlot != null &&
                              _selectedSlot!.year == chosenSlot.year &&
                              _selectedSlot!.month == chosenSlot.month &&
                              _selectedSlot!.day == chosenSlot.day &&
                              _selectedSlot!.hour == chosenSlot.hour;
                          if (isSameSlot) {
                            _selectedSlot = null;
                            _selectedPlayerUids = {};
                          } else {
                            _selectedSlot = chosenSlot;
                            _selectedPlayerUids = {};
                          }
                        });
                      }
                    }
                  },
                ),
              ),
              if (_selectedSlot != null)
                SizedBox(width: 180, child: _buildAvailabilitySidebar()),
            ],
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

    // ── Check for unread chat messages ──
    bool hasUnreadChat = false;
    try {
      final matchData = docSnapshot.data() as Map<String, dynamic>;
      final lastMessageAt = matchData['lastMessageAt'] as Timestamp?;
      if (lastMessageAt != null && _myUid != null) {
        final readDoc = await FirebaseFirestore.instance
            .collection('matches')
            .doc(matchId)
            .collection('chatReads')
            .doc(_myUid)
            .get();
        if (!readDoc.exists) {
          hasUnreadChat = true; // never opened chat
        } else {
          final readAt = readDoc.data()?['readAt'] as Timestamp?;
          if (readAt == null ||
              lastMessageAt.millisecondsSinceEpoch >
                  readAt.millisecondsSinceEpoch) {
            hasUnreadChat = true;
          }
        }
      }
    } catch (_) {
      // Ignore — just don't show badge
    }

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
          if (isJoined || isOrganizer) ...[
            IconButton(
              icon: Icon(Icons.event, color: Colors.blue.shade700),
              tooltip: 'Add to Google Calendar',
              onPressed: () {
                CalendarExport.addToGoogleCalendar(context, match);
              },
            ),
            IconButton(
              icon: Icon(Icons.download, color: Colors.grey.shade700),
              tooltip: 'Download .ics (Outlook, Apple, etc.)',
              onPressed: () {
                CalendarExport.downloadIcsFile(context, match);
              },
            ),
          ],
          if (isOrganizer)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple.shade500,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.pop(context);
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        OrganizerDashboardScreen(matchId: matchId),
                  ),
                );
                // Re-fetch chat reads — they may or may not have opened chat
                // from the dashboard, so we can't assume they've read it.
                _loadChatReads(_allMatches);
              },
              child: const Text("Manage (Organizer)"),
            ),
          if (isJoined || isOrganizer)
            ElevatedButton.icon(
              icon: Badge(
                isLabelVisible: hasUnreadChat,
                backgroundColor: Colors.red,
                smallSize: 10,
                child: const Icon(Icons.chat),
              ),
              label: Text(hasUnreadChat ? "Match Chat (new!)" : "Match Chat"),
              style: ElevatedButton.styleFrom(
                backgroundColor: hasUnreadChat
                    ? Colors.orange.shade100
                    : Colors.blue.shade100,
                foregroundColor: hasUnreadChat
                    ? Colors.orange.shade900
                    : Colors.blue.shade900,
              ),
              onPressed: () async {
                Navigator.pop(context);
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MatchChatScreen(
                      matchId: matchId,
                      currentUserId: _myUid!,
                      currentUserName: _user?.displayName ?? 'Player',
                    ),
                  ),
                );
                // Set a future-padded local timestamp to guarantee 💬 clears
                // despite any client/server clock skew. The next _loadChatReads
                // from the matches stream will normalize it to the real value.
                _chatReadTimestamps[matchId] =
                    Timestamp.fromMillisecondsSinceEpoch(
                      DateTime.now().millisecondsSinceEpoch + 60000,
                    );
                _refreshCalendarData();
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
                  labelText: "Email",
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

                  final prefs = await SharedPreferences.getInstance();

                  // OFFLINE-SAFE: If we previously logged in with this same
                  // contact and have a cached UID, reuse it without querying
                  // Firestore. This prevents stale-cache cross-user bugs.
                  final cachedContact = prefs.getString('user_login_contact');
                  final cachedUid = prefs.getString('user_uid');
                  if (cachedContact == loginId &&
                      cachedUid != null &&
                      cachedUid.isNotEmpty) {
                    _loadUser();
                    return;
                  }

                  // Resolve contact → UUID (requires Firestore / network)
                  String? uid;
                  try {
                    uid = await _resolveContactToUid(loginId);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Unable to log in — please check your internet connection and try again.',
                          ),
                        ),
                      );
                    }
                    return;
                  }

                  if (uid == null) {
                    // New user — create a doc with auto-generated UUID
                    // This also requires network; show error if it fails.
                    try {
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
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Unable to create account — please check your internet connection.',
                            ),
                          ),
                        );
                      }
                      return;
                    }
                  }

                  // Cache BOTH the UID and the contact used to resolve it.
                  // On future logins with the same contact, we skip Firestore.
                  await prefs.setString('user_uid', uid!);
                  await prefs.setString('user_login_contact', loginId);
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

  // ===========================================================================
  // AVAILABILITY SIDEBAR
  // ===========================================================================
  Widget _buildAvailabilitySidebar() {
    final slot = _selectedSlot!;

    // Apply NTRP and Circle filters to the player list
    final filteredUsers = _allUsersData.where((u) {
      if (_sidebarNtrpFilter != null && u.ntrpLevel < _sidebarNtrpFilter!) {
        return false;
      }
      if (_sidebarCircleFilter != null && _user != null) {
        if (_user!.circleRatings[u.uid] != _sidebarCircleFilter) return false;
      }
      return true;
    }).toList();

    final available = <User>[];
    final away = <User>[];
    final unknown = <User>[];

    for (final u in filteredUsers) {
      switch (AvailabilityUtils.playerAvailability(u, slot)) {
        case AvailabilityStatus.available:
          available.add(u);
        case AvailabilityStatus.away:
          away.add(u);
        case AvailabilityStatus.unknown:
          unknown.add(u);
      }
    }

    final periodLabel = AvailabilityUtils.periodForTime(slot) ?? 'Time';
    final isPast = slot.isBefore(DateTime.now().subtract(const Duration(hours: 1)));

    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            color: const Color(0xFF1A237E),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "${_monthAbbr(slot.month)} ${slot.day}",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _capitalize(periodLabel),
                            style: const TextStyle(
                              color: Color(0xFF90CAF9),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _selectedSlot = null;
                        _selectedPlayerUids = {};
                      }),
                      child: const Icon(Icons.close, color: Colors.white70, size: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  "Players most likely available",
                  style: TextStyle(
                    color: Color(0xFF90CAF9),
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          // Filters
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<double?>(
                      value: _sidebarNtrpFilter,
                      isDense: true,
                      isExpanded: true,
                      hint: const Text('NTRP', style: TextStyle(fontSize: 9)),
                      style: const TextStyle(fontSize: 9, color: Colors.black87),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Any', style: TextStyle(fontSize: 9)),
                        ),
                        ...[3.0, 3.5, 4.0, 4.5, 5.0].map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text('≥$v', style: const TextStyle(fontSize: 9)),
                          ),
                        ),
                      ],
                      onChanged: (val) => setState(() => _sidebarNtrpFilter = val),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int?>(
                      value: _sidebarCircleFilter,
                      isDense: true,
                      isExpanded: true,
                      hint: const Text('Circle', style: TextStyle(fontSize: 9)),
                      style: const TextStyle(fontSize: 9, color: Colors.black87),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Any', style: TextStyle(fontSize: 9)),
                        ),
                        ...[1, 2, 3].map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text('C$v', style: const TextStyle(fontSize: 9)),
                          ),
                        ),
                      ],
                      onChanged: (val) => setState(() => _sidebarCircleFilter = val),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Player lists
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 4),
              children: [
                _sidebarSection("Available", available, Colors.green.shade700,
                    showCheckbox: true),
                _sidebarSection("Not set", unknown, Colors.grey.shade600,
                    showCheckbox: true),
                _sidebarSection("Away", away, Colors.red.shade700),
              ],
            ),
          ),
          // Create Match button
          Padding(
            padding: const EdgeInsets.all(6),
            child: ElevatedButton(
              onPressed: isPast
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => CreateMatchScreen(
                            prefillDate: slot,
                            prefillPlayerUids: _selectedPlayerUids.toList(),
                          ),
                        ),
                      );
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: isPast ? Colors.grey : Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 6),
                textStyle: const TextStyle(fontSize: 11),
              ),
              child: Text(
                _selectedPlayerUids.isEmpty
                    ? "Create Match\nHere"
                    : "Create Match\n(${_selectedPlayerUids.length} selected)",
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebarSection(
    String label,
    List<User> users,
    Color color, {
    bool showCheckbox = false,
  }) {
    if (users.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
        for (final u in users)
          showCheckbox
              ? Row(
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: Checkbox(
                        value: _selectedPlayerUids.contains(u.uid),
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedPlayerUids.add(u.uid);
                            } else {
                              _selectedPlayerUids.remove(u.uid);
                            }
                          });
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        u.displayName,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                  child: Text(
                    u.displayName,
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
      ],
    );
  }

  static String _monthAbbr(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return months[month - 1];
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _buildProfileEditor() {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Player Profile"),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _isEditingProfile = false),
        ),
      ),
      body: Stack(
        children: [
          ListView(
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
              title: const Text("New Match Notifications Active"),
              subtitle: const Text(
                "Get notified when you're invited to new matches. "
                "Match updates always send for matches you're on.",
              ),
              value: _notifOn,
              onChanged: (v) => setState(() => _notifOn = v),
            ),
            const SizedBox(height: 20),
            const Text(
              "Weekly Availability",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Text(
              "All times default to available. Uncheck slots when you're NOT free to play.",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.2),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1),
                3: FlexColumnWidth(1),
              },
              children: [
                TableRow(
                  children: [
                    const SizedBox.shrink(),
                    ...List.generate(_avPeriodLabels.length, (i) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _avPeriodLabels[i],
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _avPeriodTimeLabels[i],
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.black54,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )),
                  ],
                ),
                for (int di = 0; di < _avDays.length; di++)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          _avDayLabels[di],
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final period in _avPeriods)
                        Center(
                          child: Transform.scale(
                            scale: 0.75,
                            child: FilterChip(
                              label: const SizedBox.shrink(),
                              padding: EdgeInsets.zero,
                              selected:
                                  _weeklyAvailability[_avDays[di]]?.contains(
                                    period,
                                  ) ??
                                  false,
                              onSelected: (selected) {
                                setState(() {
                                  final day = _avDays[di];
                                  final periods =
                                      _weeklyAvailability[day] ?? [];
                                  if (selected) {
                                    _weeklyAvailability[day] = [
                                      ...periods,
                                      period,
                                    ];
                                  } else {
                                    _weeklyAvailability[day] =
                                        periods
                                            .where((p) => p != period)
                                            .toList();
                                    if (_weeklyAvailability[day]!.isEmpty) {
                                      _weeklyAvailability.remove(day);
                                    }
                                  }
                                });
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              "Blackout Dates",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range),
              label: const Text("Add Blackout"),
              onPressed: _pickBlackout,
            ),
            for (int i = 0; i < _blackouts.length; i++)
              ListTile(
                dense: true,
                leading: const Icon(Icons.block, color: Colors.red),
                title: Text(
                  "${_blackouts[i].start.month}/${_blackouts[i].start.day}"
                  " – "
                  "${_blackouts[i].end.month}/${_blackouts[i].end.day}",
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: _blackouts[i].reason != null &&
                        _blackouts[i].reason!.isNotEmpty
                    ? Text(
                        _blackouts[i].reason!,
                        style: const TextStyle(fontSize: 12),
                      )
                    : null,
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _blackouts.removeAt(i)),
                ),
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
      if (_feedbackBtnOffset != null)
        _buildDraggableFab(
          offset: _feedbackBtnOffset!,
          onPressed: () =>
              showFeedbackModal(context, _myUid, _user?.displayName, 'Profile'),
        ),
        ],
      ),
    );
  }
}
