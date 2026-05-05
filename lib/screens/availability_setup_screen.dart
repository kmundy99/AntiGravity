import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../widgets/weekly_availability_matrix.dart';

class AvailabilitySetupScreen extends StatefulWidget {
  final String playerUid;
  final bool isAdminMode;

  const AvailabilitySetupScreen({
    super.key,
    required this.playerUid,
    this.isAdminMode = false,
  });

  @override
  State<AvailabilitySetupScreen> createState() => _AvailabilitySetupScreenState();
}

class _AvailabilitySetupScreenState extends State<AvailabilitySetupScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  bool _saved = false;

  User? _user;
  Map<String, List<String>> _weeklyAvailability = {};
  
  final _zipCodeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  String _gender = 'Other';
  double _ntrpLevel = 0.0;
  
  @override
  void dispose() {
    _zipCodeCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _fetchUser();
  }

  Future<void> _fetchUser() async {
    if (widget.playerUid.isEmpty) {
      setState(() {
        _error = "Invalid Link: No user ID provided.";
        _isLoading = false;
      });
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(widget.playerUid).get();
      if (!doc.exists) {
        setState(() {
          _error = "User not found. Please check your link.";
          _isLoading = false;
        });
        return;
      }

      final user = User.fromFirestore(doc);
      _user = user;
      _weeklyAvailability = Map<String, List<String>>.from(user.weeklyAvailability);
      _zipCodeCtrl.text = user.address;
      _nameCtrl.text = user.displayName;
      _phoneCtrl.text = user.phoneNumber;
      _gender = user.gender.isNotEmpty ? user.gender : 'Other';
      if (!['Male', 'Female', 'Non-Binary', 'Other'].contains(_gender)) {
        _gender = 'Other';
      }
      _ntrpLevel = user.ntrpLevel;

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = "Error loading your profile: $e";
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(widget.playerUid).update({
        'weekly_availability': _weeklyAvailability,
        'address': _zipCodeCtrl.text.trim(),
        'display_name': _nameCtrl.text.trim(),
        'phone_number': _phoneCtrl.text.trim(),
        'gender': _gender,
        'ntrp_level': _ntrpLevel,
      });

      setState(() {
        _saved = true;
        _isSaving = false;
      });
    } catch (e) {
      setState(() {
        _error = "Failed to save: $e";
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isAdminMode ? "Edit Player Availability" : "My Availability"),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (_saved) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, size: 80, color: Colors.green.shade600),
              const SizedBox(height: 24),
              const Text(
                "Availability Saved!",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                "Thank you for updating your availability. You can safely close this page.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Render a clean grid, scrollable horizontally if too narrow
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      "Hi ${_user?.displayName ?? 'Player'},",
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "Select all the typical times you are available to play tennis. This helps organizers schedule matches more effectively without having to ask you every time.",
                      style: TextStyle(fontSize: 16, color: Colors.black87),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _zipCodeCtrl,
                      decoration: const InputDecoration(
                        labelText: "Zip Code",
                        hintText: "Enter your zip code to get invited to nearby matches",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on_outlined),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    ExpansionTile(
                      title: const Text("Additional Profile Details (Optional)", style: TextStyle(fontWeight: FontWeight.bold)),
                      leading: const Icon(Icons.person),
                      childrenPadding: const EdgeInsets.all(16),
                      children: [
                        TextField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: "Display Name",
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _phoneCtrl,
                          decoration: const InputDecoration(
                            labelText: "Phone Number",
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 16),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Gender',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _gender,
                              isDense: true,
                              isExpanded: true,
                              items: ['Male', 'Female', 'Non-Binary', 'Other']
                                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                                  .toList(),
                              onChanged: (v) => setState(() => _gender = v!),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'NTRP Level',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<double>(
                              value: _ntrpLevel,
                              isDense: true,
                              isExpanded: true,
                              items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                                  .map((v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(v == 0.0 ? 'Not Rated' : 'Level $v'),
                                      ))
                                  .toList(),
                              onChanged: (v) => setState(() => _ntrpLevel = v!),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Display a hint for Select All
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lightbulb_outline, color: Colors.blue.shade800),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              "Tip: Use the checkboxes in the headers to quickly select an entire day or an entire time period.",
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),

                    // The Matrix
                    WeeklyAvailabilityMatrix(
                      initialAvailability: _weeklyAvailability,
                      onAvailabilityChanged: (newAvail) {
                        setState(() {
                          _weeklyAvailability = newAvail;
                        });
                      },
                    ),

                    const SizedBox(height: 48),
                    
                    if (_isSaving)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          backgroundColor: Colors.blue.shade900,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        onPressed: _save,
                        child: const Text("Save Availability"),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
