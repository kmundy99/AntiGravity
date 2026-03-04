import 'package:flutter/material.dart';
import '../invite_player.dart';

class AddCustomPlayerButton extends StatelessWidget {
  final String label;
  final bool fullWidth;
  final String? creatorUid;

  const AddCustomPlayerButton({
    super.key,
    this.label = 'Add Custom Player',
    this.fullWidth = false,
    this.creatorUid,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: const Icon(Icons.person_add),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        minimumSize: fullWidth ? const Size.fromHeight(40) : null,
        backgroundColor: Colors.orange.shade700,
        foregroundColor: Colors.white,
      ),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => InvitePlayerScreen(creatorUid: creatorUid)),
        );
      },
    );
  }
}
