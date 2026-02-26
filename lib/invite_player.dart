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

  /// Cleans the phone number or lowercases the email
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

                // Check if a user with this contact already exists
                var existingQuery = await FirebaseFirestore.instance
                    .collection('users')
                    .where('primary_contact', isEqualTo: normalizedContact)
                    .limit(1)
                    .get();

                if (existingQuery.docs.isEmpty &&
                    normalizedContact.contains('@')) {
                  existingQuery = await FirebaseFirestore.instance
                      .collection('users')
                      .where('email', isEqualTo: normalizedContact)
                      .limit(1)
                      .get();
                }

                if (existingQuery.docs.isNotEmpty) {
                  // User already exists — update name if it was empty
                  final existingDoc = existingQuery.docs.first;
                  final existingData = existingDoc.data();
                  if ((existingData['display_name'] ?? '').toString().isEmpty) {
                    await existingDoc.reference.update({'display_name': name});
                  }
                } else {
                  // UUID MIGRATION: Create with auto-generated doc ID
                  await FirebaseFirestore.instance.collection('users').add({
                    'display_name': name,
                    'primary_contact': normalizedContact,
                    if (normalizedContact.contains('@'))
                      'email': normalizedContact
                    else
                      'phone_number': normalizedContact,
                    'accountStatus': 'provisional',
                    'role': 'player',
                    'createdAt': FieldValue.serverTimestamp(),
                  });
                }

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
