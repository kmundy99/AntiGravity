import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/location_service.dart';
import '../widgets/weekly_availability_matrix.dart';

/// Standalone profile completion screen shown after a player responds to an
/// availability request or match invite. Prompts for essential missing fields.
/// Has a Close/Skip option so the player is never forced.
class CompleteProfileScreen extends StatefulWidget {
  final String playerUid;
  final bool isAdminMode;

  const CompleteProfileScreen({
    super.key,
    required this.playerUid,
    this.isAdminMode = false,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  double _ntrp = 0.0;
  String _gender = 'Male';
  Map<String, List<String>> _availability = {};
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.playerUid)
        .get();
    if (!doc.exists || !mounted) return;
    final data = doc.data()!;
    _emailCtrl.text = data['email'] ?? '';
    _phoneCtrl.text = data['phone_number'] ?? '';
    _addressCtrl.text = data['address'] ?? '';
    final ntrp = (data['ntrp_level'] ?? 0.0).toDouble();
    _ntrp = [0.0, 3.0, 3.5, 4.0, 4.5, 5.0].contains(ntrp) ? ntrp : 0.0;
    final gender = data['gender'] ?? '';
    _gender = ['Male', 'Female', 'Non-Binary', 'Other'].contains(gender)
        ? gender
        : 'Male';
    
    if (data['weekly_availability'] != null) {
      _availability = Map<String, List<String>>.from(
        (data['weekly_availability'] as Map).map(
          (k, v) => MapEntry(k as String, List<String>.from(v)),
        ),
      );
    }
    
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final addressText = _addressCtrl.text.trim();
    if (addressText.isNotEmpty) {
      final extractedZip = LocationService().extractZipCode(addressText);
      if (extractedZip == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter a valid 5-digit zip code.')),
          );
        }
        return;
      }
    }

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.playerUid)
          .update({
        if (_emailCtrl.text.trim().isNotEmpty) 'email': _emailCtrl.text.trim(),
        if (_phoneCtrl.text.trim().isNotEmpty)
          'phone_number': _phoneCtrl.text.trim(),
        if (_addressCtrl.text.trim().isNotEmpty)
          'address': _addressCtrl.text.trim(),
        'ntrp_level': _ntrp,
        'gender': _gender,
        'weekly_availability': _availability,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving profile: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isAdminMode ? 'Edit Player Profile' : 'Complete Your Profile'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Skip for now',
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isAdminMode
                        ? 'Update this player\'s record.'
                        : 'Help organizers and other players get to know you better.',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _emailCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phoneCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _addressCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Zip Code',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 20),
                  const Text('Gender',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
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
                  const SizedBox(height: 20),
                  const Text('NTRP Level',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'NTRP Level',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<double>(
                        value: _ntrp,
                        isDense: true,
                        isExpanded: true,
                        items: [0.0, 3.0, 3.5, 4.0, 4.5, 5.0]
                            .map((v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(v == 0.0 ? 'Not Rated' : 'Level $v'),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _ntrp = v!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('Weekly Availability', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Select the times you generally prefer to play. This helps matchmakers find you!', style: TextStyle(color: Colors.black54, fontSize: 13)),
                  const SizedBox(height: 12),
                  WeeklyAvailabilityMatrix(
                    initialAvailability: _availability,
                    onAvailabilityChanged: (val) => setState(() => _availability = val),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Save Profile'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Returns true if the user's profile is considered incomplete (worth prompting).
bool isProfileIncomplete(Map<String, dynamic> data) {
  final ntrp = (data['ntrp_level'] ?? 0.0).toDouble();
  final email = (data['email'] ?? '') as String;
  final phone = (data['phone_number'] ?? '') as String;
  final address = (data['address'] ?? '') as String;
  return ntrp == 0.0 || email.isEmpty || phone.isEmpty || address.isEmpty;
}
