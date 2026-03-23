import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'websocket_service.dart';

class NotificationPage extends StatefulWidget {
  final String contactUuid;
  const NotificationPage({super.key, required this.contactUuid});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  static const String _apiUrl =
      'https://workspace.jedapps.com/pbx/app/workspace/user_api.php';
  static const String _authToken = 'ws-fusion-2026-token';

  final WebSocketService _wsService = WebSocketService();
  final List<_NotificationItem> _notifications = [];
  bool _loading = true;
  String? _error;
  StreamSubscription? _notifSub;

  @override
  void initState() {
    super.initState();
    // Listen for real-time pushes while page is open
    _notifSub = _wsService.notificationsStream.listen(_handleRealtimePush);
    _fetchNotifications();
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchNotifications() async {
    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_notifications_list',
          'contact_uuid': widget.contactUuid,
          'limit': 50,
          'offset': 0,
        }),
      );

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          final list = data['notifications'] as List<dynamic>? ?? [];
          final items = list.map((n) {
            return _NotificationItem.fromJson(n as Map<String, dynamic>);
          }).toList();
          setState(() {
            _notifications.clear();
            _notifications.addAll(items);
            _loading = false;
            _error = null;
          });
        } else {
          setState(() {
            _loading = false;
            _error = data['error']?.toString() ?? 'Failed to load notifications.';
          });
        }
      } else {
        setState(() {
          _loading = false;
          _error = 'Server error (${resp.statusCode}).';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Network error: $e';
        });
      }
    }
  }

  Future<void> _markRead({int? notificationId}) async {
    try {
      final body = <String, dynamic>{
        'token': _authToken,
        'action': 'ep_notifications_read',
        'contact_uuid': widget.contactUuid,
      };
      if (notificationId != null) {
        body['notification_id'] = notificationId;
      }
      await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (e) {
      debugPrint('[Notifications] Mark read error: $e');
    }
  }

  void _handleRealtimePush(Map<String, dynamic> data) {
    final event = data['event'] ?? data['type'];
    if (event == 'new_notification' && mounted) {
      final item = _NotificationItem.fromJson(data);
      setState(() => _notifications.insert(0, item));
    }
  }

  int get _unreadCount => _notifications.where((n) => !n.isRead).length;

  void _markAllAsRead() {
    _markRead();
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

  void _tapNotification(int index) {
    final n = _notifications[index];
    if (!n.isRead) {
      _markRead(notificationId: n.id);
      setState(() => n.isRead = true);
    }
    showDialog(
      context: context,
      builder: (ctx) {
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
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF3B6FE8)),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline,
                          size: 48, color: Colors.red.shade300),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _fetchNotifications();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _notifications.isEmpty
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
                  : RefreshIndicator(
                      onRefresh: () async {
                        await _fetchNotifications();
                      },
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _notifications.length,
                        itemBuilder: (context, index) {
                          final n = _notifications[index];
                          return GestureDetector(
                            onTap: () => _tapNotification(index),
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: n.isRead
                                    ? Colors.white
                                    : const Color(0xFFEBF0FF),
                                borderRadius: BorderRadius.circular(12),
                                border: n.isRead
                                    ? null
                                    : Border.all(
                                        color: const Color(0xFF3B6FE8)
                                            .withValues(alpha: 0.3),
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
                                    child:
                                        Icon(n.icon, color: n.color, size: 22),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                                  color:
                                                      const Color(0xFF1A2035),
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
                                      margin: const EdgeInsets.only(
                                          left: 8, top: 4),
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
                          );
                        },
                      ),
                    ),
    );
  }
}

class _NotificationItem {
  final int id;
  final String type;
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final DateTime time;
  bool isRead;

  _NotificationItem({
    required this.id,
    required this.type,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.time,
    required this.isRead,
  });

  factory _NotificationItem.fromJson(Map<String, dynamic> json) {
    final type = json['type'] ?? 'general';
    return _NotificationItem(
      id: json['id'] ?? 0,
      type: type,
      icon: _iconForType(type),
      color: _colorForType(type),
      title: json['title'] ?? 'Notification',
      body: json['body'] ?? '',
      time: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())?.toLocal() ??
              DateTime.now()
          : DateTime.now(),
      isRead: json['is_read'] == true || json['is_read'] == 1,
    );
  }

  static IconData _iconForType(String type) {
    switch (type) {
      case 'leave_approved':
        return Icons.event_available;
      case 'leave_rejected':
        return Icons.event_busy;
      case 'payslip_ready':
        return Icons.receipt_long;
      default:
        return Icons.notifications;
    }
  }

  static Color _colorForType(String type) {
    switch (type) {
      case 'leave_approved':
        return const Color(0xFF00BFA5);
      case 'leave_rejected':
        return const Color(0xFFE91E63);
      case 'payslip_ready':
        return const Color(0xFFFF7043);
      default:
        return const Color(0xFF3B6FE8);
    }
  }
}
