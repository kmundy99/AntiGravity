import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class InvitePlayerScreen extends StatefulWidget {
  const InvitePlayerScreen({super.key});

  @override
  State<InvitePlayerScreen> createState() => _InvitePlayerScreenState();
}

class _InvitePlayerScreenState extends State<InvitePlayerScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  // This function cleans the phone number or lowercases the email
  String _normalizeContact(String input) {
    String trimmed = input.trim();
    if (trimmed.contains('@')) {
      return trimmed.toLowerCase();
    } else {
      return trimmed
          .replaceAll(RegExp(r'[^\d]'), '')
          .replaceFirst(RegExp(r'^1'), '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Invite Player')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Player Name (e.g. Kiran)',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: 'Email or Phone Number',
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final name = _nameController.text.trim();
                final phone = _phoneController.text.trim();

                if (name.isEmpty || phone.isEmpty) return;

                final normalizedContact = _normalizeContact(phone);
                if (normalizedContact.isEmpty) return;

                // This sends your info to the "users" folder in your database
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(normalizedContact)
                    .set({
                      'display_name': name,
                      'primary_contact': normalizedContact,
                      if (normalizedContact.contains('@'))
                        'email': normalizedContact,
                      'accountStatus':
                          'provisional', // Marks this as a Shadow Profile
                      'role': 'player',
                      'createdAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));

                if (mounted) Navigator.pop(context);
              },
              child: const Text('Create Shadow Profile'),
            ),
          ],
        ),
      ),
    );
  }
}
