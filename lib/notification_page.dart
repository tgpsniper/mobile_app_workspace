import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final List<_NotificationItem> _notifications = [
    _NotificationItem(
      icon: Icons.event_available,
      color: const Color(0xFF00BFA5),
      title: 'Leave Approved',
      body: 'Your leave request for Mar 25-26 has been approved by HR.',
      time: DateTime.now().subtract(const Duration(minutes: 5)),
      isRead: false,
    ),
    _NotificationItem(
      icon: Icons.campaign,
      color: const Color(0xFF3B6FE8),
      title: 'Company Announcement',
      body: 'Town hall meeting scheduled for Friday at 3:00 PM in the main conference room.',
      time: DateTime.now().subtract(const Duration(minutes: 30)),
      isRead: false,
    ),
    _NotificationItem(
      icon: Icons.task_alt,
      color: const Color(0xFFFFB300),
      title: 'New Task Assigned',
      body: 'Network audit for Building B has been assigned to you. Due: Mar 28.',
      time: DateTime.now().subtract(const Duration(hours: 1)),
      isRead: false,
    ),
    _NotificationItem(
      icon: Icons.chat_bubble,
      color: const Color(0xFFE91E63),
      title: 'New Message',
      body: 'Sarah from IT sent you a message: "Can you check the server logs?"',
      time: DateTime.now().subtract(const Duration(hours: 2)),
      isRead: true,
    ),
    _NotificationItem(
      icon: Icons.receipt_long,
      color: const Color(0xFFFF7043),
      title: 'Payslip Available',
      body: 'Your payslip for March 2026 is now available for download.',
      time: DateTime.now().subtract(const Duration(hours: 5)),
      isRead: true,
    ),
    _NotificationItem(
      icon: Icons.security,
      color: const Color(0xFF7C4DFF),
      title: 'Security Alert',
      body: 'New device login detected. If this wasn\'t you, please contact IT.',
      time: DateTime.now().subtract(const Duration(hours: 8)),
      isRead: true,
    ),
    _NotificationItem(
      icon: Icons.update,
      color: const Color(0xFF3B6FE8),
      title: 'System Update',
      body: 'Workspace app will undergo maintenance on Sunday 12:00 AM - 2:00 AM.',
      time: DateTime.now().subtract(const Duration(days: 1)),
      isRead: true,
    ),
    _NotificationItem(
      icon: Icons.celebration,
      color: const Color(0xFFFFB300),
      title: 'Birthday Reminder',
      body: 'Don\'t forget! It\'s Mark from Engineering\'s birthday today.',
      time: DateTime.now().subtract(const Duration(days: 1, hours: 3)),
      isRead: true,
    ),
  ];

  int get _unreadCount => _notifications.where((n) => !n.isRead).length;

  void _markAllAsRead() {
    setState(() {
      for (var n in _notifications) {
        n.isRead = true;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All notifications marked as read'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _dismissNotification(int index) {
    final removed = _notifications[index];
    setState(() => _notifications.removeAt(index));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed: ${removed.title}'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            setState(() => _notifications.insert(index, removed));
          },
        ),
      ),
    );
  }

  void _tapNotification(int index) {
    setState(() => _notifications[index].isRead = true);
    showDialog(
      context: context,
      builder: (ctx) {
        final n = _notifications[index];
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: n.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(n.icon, color: n.color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(n.title, style: const TextStyle(fontSize: 16)),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(n.body, style: const TextStyle(fontSize: 14, height: 1.5)),
              const SizedBox(height: 12),
              Text(
                _formatTime(n.time),
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A96B0)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return DateFormat('MMM d, h:mm a').format(time);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_unreadCount > 0)
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text(
                'Mark all read',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
        ],
      ),
      body: _notifications.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_off_outlined,
                      size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No notifications',
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
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _notifications.length,
              itemBuilder: (context, index) {
                final n = _notifications[index];
                return Dismissible(
                  key: ValueKey('${n.title}_${n.time.millisecondsSinceEpoch}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade400,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  onDismissed: (_) => _dismissNotification(index),
                  child: GestureDetector(
                    onTap: () => _tapNotification(index),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: n.isRead ? Colors.white : const Color(0xFFEBF0FF),
                        borderRadius: BorderRadius.circular(12),
                        border: n.isRead
                            ? null
                            : Border.all(
                                color: const Color(0xFF3B6FE8).withValues(alpha: 0.3),
                              ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: n.color.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(n.icon, color: n.color, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        n.title,
                                        style: TextStyle(
                                          fontWeight: n.isRead
                                              ? FontWeight.w500
                                              : FontWeight.bold,
                                          fontSize: 14,
                                          color: const Color(0xFF1A2035),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _formatTime(n.time),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF8A96B0),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  n.body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: n.isRead
                                        ? const Color(0xFF8A96B0)
                                        : const Color(0xFF4A5568),
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!n.isRead)
                            Container(
                              margin: const EdgeInsets.only(left: 8, top: 4),
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF3B6FE8),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _NotificationItem {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final DateTime time;
  bool isRead;

  _NotificationItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.time,
    required this.isRead,
  });
}
