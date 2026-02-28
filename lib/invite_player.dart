import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class InvitePlayerScreen extends StatefulWidget {
  const InvitePlayerScreen({super.key});

  @override
  State<InvitePlayerScreen> createState() => _InvitePlayerScreenState();
}

class _InvitePlayerScreenState extends State<InvitePlayerScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

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
              controller: _emailController,
              decoration: const InputDecoration(labelText: 'Email Address'),
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
                final email = _emailController.text.trim().toLowerCase();

                if (name.isEmpty || email.isEmpty) return;
                if (!email.contains('@')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter a valid email address'),
                    ),
                  );
                  return;
                }

                // Check if a user with this email already exists
                var existingQuery = await FirebaseFirestore.instance
                    .collection('users')
                    .where('primary_contact', isEqualTo: email)
                    .limit(1)
                    .get();

                if (existingQuery.docs.isEmpty) {
                  existingQuery = await FirebaseFirestore.instance
                      .collection('users')
                      .where('email', isEqualTo: email)
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
                  // Create with auto-generated doc ID
                  await FirebaseFirestore.instance.collection('users').add({
                    'display_name': name,
                    'primary_contact': email,
                    'email': email,
                    'accountStatus': 'provisional',
                    'role': 'player',
                    'createdAt': FieldValue.serverTimestamp(),
                  });
                }

                if (mounted) Navigator.pop(context);
              },
              child: const Text('Add Custom Player'),
            ),
          ],
        ),
      ),
    );
  }
}
