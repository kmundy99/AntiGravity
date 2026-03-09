import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models.dart';
import '../widgets/weekly_availability_matrix.dart';

class AvailabilitySetupScreen extends StatefulWidget {
  final String playerUid;

  const AvailabilitySetupScreen({super.key, required this.playerUid});

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
        title: const Text("My Availability"),
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
