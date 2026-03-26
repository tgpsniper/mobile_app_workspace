import 'dart:async';
import 'package:flutter/material.dart';
import 'websocket_service.dart';

class ActiveUsersPage extends StatefulWidget {
  final String currentUsername;
  const ActiveUsersPage({super.key, required this.currentUsername});

  @override
  State<ActiveUsersPage> createState() => _ActiveUsersPageState();
}

class _ActiveUsersPageState extends State<ActiveUsersPage> {
  final WebSocketService _wsService = WebSocketService();
  List<Contact> _contacts = [];
  StreamSubscription? _contactsSub;
  StreamSubscription? _statusSub;
  ConnectionStatus _wsStatus = ConnectionStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _wsStatus = _wsService.currentStatus;
    _contacts = List.from(_wsService.contacts);

    _contactsSub = _wsService.contactsStream.listen((contacts) {
      if (mounted) setState(() => _contacts = contacts);
    });

    _statusSub = _wsService.statusStream.listen((status) {
      if (mounted) setState(() => _wsStatus = status);
    });

    // Request fresh contacts list
    _wsService.getContacts();
  }

  @override
  void dispose() {
    _contactsSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Color _getAvatarColor(String name) {
    final colors = [
      const Color(0xFF3B6FE8),
      const Color(0xFF00BFA5),
      const Color(0xFFFF7043),
      const Color(0xFF7C4DFF),
      const Color(0xFFE91E63),
      const Color(0xFFFFB300),
      const Color(0xFF26A69A),
      const Color(0xFFAB47BC),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    // Count online users
    final onlineCount = _contacts.where((c) => c.online).length;
    final totalCount = _contacts.length;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      appBar: AppBar(
        title: Text(
          'Users ($onlineCount online / $totalCount)',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _wsService.getContacts(),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection status banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: _wsStatus == ConnectionStatus.connected
                ? const Color(0xFF00BFA5)
                : _wsStatus == ConnectionStatus.connecting
                ? Colors.orange
                : Colors.redAccent,
            child: Row(
              children: [
                Icon(
                  _wsStatus == ConnectionStatus.connected
                      ? Icons.cloud_done
                      : _wsStatus == ConnectionStatus.connecting
                      ? Icons.cloud_sync
                      : Icons.cloud_off,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  _wsStatus == ConnectionStatus.connected
                      ? 'Connected to workspace.jedapps.com'
                      : _wsStatus == ConnectionStatus.connecting
                      ? 'Connecting to server...'
                      : 'Disconnected from server',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const Spacer(),
                if (_wsStatus != ConnectionStatus.connected)
                  GestureDetector(
                    onTap: () =>
                        _wsService.connect(username: widget.currentUsername),
                    child: const Text(
                      'Retry',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Users list
          Expanded(
            child: _contacts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _wsStatus == ConnectionStatus.connected
                              ? 'No users found'
                              : 'Connect to see active users',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade500,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _contacts.length,
                    itemBuilder: (context, index) {
                      // Sort: online first
                      final sorted = List<Contact>.from(_contacts)
                        ..sort((a, b) {
                          if (a.online && !b.online) return -1;
                          if (!a.online && b.online) return 1;
                          return a.name.compareTo(b.name);
                        });
                      final contact = sorted[index];
                      final isCurrentUser =
                          contact.email == _wsService.currentEmail ||
                          contact.name == widget.currentUsername;
                      final avatarColor = _getAvatarColor(contact.name);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isCurrentUser
                              ? const Color(0xFFEBF0FF)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: isCurrentUser
                              ? Border.all(
                                  color: const Color(
                                    0xFF3B6FE8,
                                  ).withValues(alpha: 0.3),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            // Avatar with online indicator
                            Stack(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: avatarColor.withValues(
                                    alpha: 0.15,
                                  ),
                                  child: Text(
                                    contact.name[0].toUpperCase(),
                                    style: TextStyle(
                                      color: avatarColor,
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: contact.online
                                          ? const Color(0xFF00BFA5)
                                          : Colors.grey,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 14),

                            // User info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          contact.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                            color: Color(0xFF1A2035),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (isCurrentUser) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF3B6FE8),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: const Text(
                                            'You',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    contact.email,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF8A96B0),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Status badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: contact.online
                                    ? const Color(
                                        0xFF00BFA5,
                                      ).withValues(alpha: 0.1)
                                    : Colors.grey.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                contact.online ? 'ONLINE' : 'OFFLINE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: contact.online
                                      ? const Color(0xFF00BFA5)
                                      : Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
