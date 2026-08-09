import 'package:flutter/material.dart';
import 'user.dart';

class UserProfilePage extends StatelessWidget {
  final User user;

  const UserProfilePage({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      appBar: AppBar(title: Text('${user.username} Profile')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.grey[300],
              child: Icon(Icons.person, size: 40, color: Colors.grey[700]),
            ),
            const SizedBox(height: 16),
            Text('Username: ${user.username}', style: TextStyle(color: textColor, fontSize: 18)),
            const SizedBox(height: 8),
            Text('Online: ${user.isOnline ? "Yes" : "No"}', style: TextStyle(color: textColor)),
            const SizedBox(height: 8),
            Text('Last Message: ${user.lastMessage}', style: TextStyle(color: textColor)),
            const SizedBox(height: 8),
            Text('Last Seen: ${user.lastTimestamp}', style: TextStyle(color: textColor)),
          ],
          ),
        ),
      ),
    );
  }
}
