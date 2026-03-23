import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

class ActiveUser {
  final String username;
  final String email;
  final String status;
  final String? device;
  final String? extension_;
  final String? role;
  final DateTime connectedAt;

  ActiveUser({
    required this.username,
    required this.email,
    required this.status,
    this.device,
    this.extension_,
    this.role,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();

  factory ActiveUser.fromJson(Map<String, dynamic> json) {
    final name =
        json['name'] ?? json['username'] ?? json['display_name'] ?? 'Unknown';
    final email = json['email'] ?? '';
    final ext = json['extension'] ?? json['ext'];
    final userStatus = json['online'] == true
        ? 'online'
        : (json['status'] ?? 'offline');
    final dev = json['device'] ?? json['platform'];
    final userRole = json['role'] ?? json['type'];

    return ActiveUser(
      username: name.toString(),
      email: email.toString(),
      status: userStatus.toString().toLowerCase(),
      device: dev?.toString(),
      extension_: ext?.toString(),
      role: userRole?.toString(),
      connectedAt: json['connected_at'] != null
          ? DateTime.tryParse(json['connected_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class ChatMessage {
  final int? id;
  final String senderEmail;
  final String? receiverEmail;
  final String? groupId;
  final String text;
  final String messageType;
  final DateTime createdAt;
  final String? senderName;
  final bool isHistory;

  ChatMessage({
    this.id,
    required this.senderEmail,
    this.receiverEmail,
    this.groupId,
    required this.text,
    this.messageType = 'text',
    DateTime? createdAt,
    this.senderName,
    this.isHistory = false,
  }) : createdAt = createdAt ?? DateTime.now();

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] ?? json['message_id'],
      senderEmail: json['sender_email'] ?? json['from'] ?? '',
      receiverEmail: json['receiver_email'] ?? json['to'],
      groupId: json['group_id'],
      text: json['message_text'] ?? json['text'] ?? json['message'] ?? '',
      messageType: json['message_type'] ?? 'text',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      senderName: json['sender_name'] ?? json['name'],
    );
  }
}

class Contact {
  final String? id;
  final String name;
  final String email;
  final bool online;

  Contact({
    this.id,
    required this.name,
    required this.email,
    required this.online,
  });

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: json['id']?.toString(),
      name: json['name'] ?? json['display_name'] ?? 'Unknown',
      email: json['email'] ?? '',
      online: json['online'] == true || json['online'] == 1,
    );
  }
}

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  static const String _wsUrl = 'wss://workspace.jedapps.com/ws';
  static const String _authToken = 'ws-fusion-2026-token';
  static const Duration _reconnectDelay = Duration(seconds: 5);
  static const Duration _presenceInterval = Duration(seconds: 25);
  static const int _maxReconnectAttempts = 10;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _presenceTimer;
  int _reconnectAttempts = 0;
  bool _intentionalClose = false;
  String? _username;
  String? _email;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _activeUsersController = StreamController<List<ActiveUser>>.broadcast();
  final _contactsController = StreamController<List<Contact>>.broadcast();
  final _chatMessageController = StreamController<ChatMessage>.broadcast();
  final _typingController = StreamController<Map<String, dynamic>>.broadcast();
  final _unreadController = StreamController<Map<String, dynamic>>.broadcast();
  final _reactionsController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _employeeChangeController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _notificationsController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<List<ActiveUser>> get activeUsersStream =>
      _activeUsersController.stream;
  Stream<List<Contact>> get contactsStream => _contactsController.stream;
  Stream<ChatMessage> get chatMessageStream => _chatMessageController.stream;
  Stream<Map<String, dynamic>> get typingStream => _typingController.stream;
  Stream<Map<String, dynamic>> get unreadStream => _unreadController.stream;
  Stream<Map<String, dynamic>> get reactionsStream =>
      _reactionsController.stream;
  Stream<Map<String, dynamic>> get employeeChangeStream =>
      _employeeChangeController.stream;
  Stream<Map<String, dynamic>> get notificationsStream =>
      _notificationsController.stream;

  ConnectionStatus _currentStatus = ConnectionStatus.disconnected;
  ConnectionStatus get currentStatus => _currentStatus;

  List<ActiveUser> _activeUsers = [];
  List<ActiveUser> get activeUsers => _activeUsers;

  List<Contact> _contacts = [];
  List<Contact> get contacts => _contacts;

  String? get currentEmail => _email;
  String? get currentUsername => _username;

  void connect({String? username, String? email}) {
    // If already connected but with a different user, disconnect first
    if ((_currentStatus == ConnectionStatus.connecting ||
            _currentStatus == ConnectionStatus.connected) &&
        email != null &&
        _email != null &&
        email != _email) {
      debugPrint(
        '[WebSocket] User changed from $_email to $email — reconnecting',
      );
      disconnect();
    }

    if (_currentStatus == ConnectionStatus.connecting ||
        _currentStatus == ConnectionStatus.connected) {
      return;
    }

    _username = username ?? _username;
    _email = email ?? _email;
    _intentionalClose = false;
    _setStatus(ConnectionStatus.connecting);

    try {
      final uri = Uri.parse(_wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _channel!.ready
          .then((_) {
            _setStatus(ConnectionStatus.connected);
            _reconnectAttempts = 0;
            _authenticate();
            debugPrint('[WebSocket] Connected to $_wsUrl');
          })
          .catchError((error) {
            debugPrint('[WebSocket] Connection failed: $error');
            _setStatus(ConnectionStatus.error);
            _scheduleReconnect();
          });

      _channel!.stream.listen(
        (data) {
          final text = data as String;
          debugPrint('[WebSocket] Received (${text.length} chars)');

          // Try to parse the message directly
          try {
            final decoded = jsonDecode(text) as Map<String, dynamic>;
            _handleMessage(decoded);
            _messageController.add(decoded);
          } catch (e) {
            debugPrint('[WebSocket] Parse error: $e');
            debugPrint(
              '[WebSocket] Raw data: ${text.substring(0, text.length > 500 ? 500 : text.length)}',
            );
          }
        },
        onError: (error) {
          debugPrint('[WebSocket] Stream error: $error');
          _setStatus(ConnectionStatus.error);
          _cleanup();
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[WebSocket] Connection closed');
          _setStatus(ConnectionStatus.disconnected);
          _cleanup();
          if (!_intentionalClose) {
            _scheduleReconnect();
          }
        },
      );
    } catch (e) {
      debugPrint('[WebSocket] Error: $e');
      _setStatus(ConnectionStatus.error);
      _scheduleReconnect();
    }
  }

  void _authenticate() {
    send({
      'action': 'auth',
      'token': _authToken,
      'email': _email ?? '${_username ?? 'user'}@jedapps.com',
      'name': _username ?? 'Mobile User',
    });
  }

  void _startPresenceHeartbeat() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(_presenceInterval, (_) {
      if (_currentStatus == ConnectionStatus.connected) {
        send({'action': 'presence'});
      }
    });
  }

  // --- Chat Actions ---

  void sendChatMessage({
    required String senderEmail,
    String? receiverEmail,
    String? groupId,
    required String messageText,
    String messageType = 'text',
  }) {
    send({
      'action': 'send_message',
      'sender_email': senderEmail,
      'receiver_email': receiverEmail,
      'group_id': groupId,
      'message_text': messageText,
      'message_type': messageType,
    });
  }

  void getMessages({
    required String userEmail,
    String? otherEmail,
    String? groupId,
    String? since,
    int limit = 100,
  }) {
    send({
      'action': 'get_messages',
      'user_email': userEmail,
      'other_email': otherEmail,
      'group_id': groupId,
      'since': ?since,
      'limit': limit,
    });
  }

  void getContacts() {
    send({'action': 'get_contacts'});
  }

  void getConversations({required String userEmail}) {
    send({'action': 'get_conversations', 'user_email': userEmail});
  }

  void getGroups({required String userEmail}) {
    send({'action': 'get_groups', 'user_email': userEmail});
  }

  void getUnreadCount({required String userEmail}) {
    send({'action': 'get_unread_count', 'user_email': userEmail});
  }

  void markRead({
    required String userEmail,
    String? otherEmail,
    String? groupId,
  }) {
    send({
      'action': 'mark_read',
      'user_email': userEmail,
      'other_email': otherEmail,
      'group_id': groupId,
    });
  }

  void sendTyping({
    required String userEmail,
    String? otherEmail,
    String? groupId,
  }) {
    send({
      'action': 'typing',
      'user_email': userEmail,
      'other_email': otherEmail,
      'group_id': groupId,
    });
  }

  void getReactions({required List<int> messageIds}) {
    send({'action': 'get_reactions', 'message_ids': messageIds});
  }

  void toggleReaction({
    required int messageId,
    required String userEmail,
    required String reaction,
  }) {
    send({
      'action': 'toggle_reaction',
      'message_id': messageId,
      'user_email': userEmail,
      'reaction': reaction,
    });
  }

  // --- Notifications ---

  void getNotifications({required String contactUuid, int limit = 50, int offset = 0}) {
    send({
      'action': 'ep_notifications_list',
      'contact_uuid': contactUuid,
      'limit': limit,
      'offset': offset,
    });
  }

  void getNotificationCount({required String contactUuid}) {
    send({
      'action': 'ep_notifications_count',
      'contact_uuid': contactUuid,
    });
  }

  void markNotificationRead({required String contactUuid, int? notificationId}) {
    final msg = <String, dynamic>{
      'action': 'ep_notifications_read',
      'contact_uuid': contactUuid,
    };
    if (notificationId != null) {
      msg['notification_id'] = notificationId;
    }
    send(msg);
  }

  // --- Active Users ---

  void refreshActiveUsers() {
    getContacts();
  }

  // --- Message Handling ---

  void _handleMessage(Map<String, dynamic> message) {
    final event = message['event'] ?? message['type'] ?? message['action'];

    switch (event) {
      case 'authenticated':
        debugPrint('[WebSocket] Authenticated successfully');
        _startPresenceHeartbeat();
        // Fetch contacts (active users) after auth
        getContacts();
        if (_email != null) {
          getUnreadCount(userEmail: _email!);
        }
        break;

      case 'contacts':
        final contactsList = message['contacts'] as List<dynamic>? ?? [];
        _contacts = contactsList
            .map((c) => Contact.fromJson(c as Map<String, dynamic>))
            .toList();
        _contactsController.add(_contacts);
        // Also update active users from contacts
        _activeUsers = _contacts
            .map(
              (c) => ActiveUser(
                username: c.name,
                email: c.email,
                status: c.online ? 'online' : 'offline',
              ),
            )
            .toList();
        _activeUsersController.add(_activeUsers);
        debugPrint('[WebSocket] Contacts loaded: ${_contacts.length}');
        break;

      case 'new_message':
        final chatMsg = ChatMessage.fromJson(message);
        _chatMessageController.add(chatMsg);
        debugPrint('[WebSocket] New message from: ${chatMsg.senderEmail}');
        break;

      case 'message_sent':
        debugPrint('[WebSocket] Message sent OK, id: ${message['message_id']}');
        break;

      case 'messages':
        // History messages response
        final msgList = message['messages'] as List<dynamic>? ?? [];
        for (final m in msgList) {
          final json = m as Map<String, dynamic>;
          final chatMsg = ChatMessage(
            id: json['id'] ?? json['message_id'],
            senderEmail: json['sender_email'] ?? json['from'] ?? '',
            receiverEmail: json['receiver_email'] ?? json['to'],
            groupId: json['group_id'],
            text: json['message_text'] ?? json['text'] ?? json['message'] ?? '',
            messageType: json['message_type'] ?? 'text',
            createdAt: json['created_at'] != null
                ? DateTime.tryParse(json['created_at'].toString()) ??
                      DateTime.now()
                : DateTime.now(),
            senderName: json['sender_name'] ?? json['name'],
            isHistory: true,
          );
          _chatMessageController.add(chatMsg);
        }
        debugPrint('[WebSocket] Message history: ${msgList.length} messages');
        break;

      case 'conversations':
        debugPrint('[WebSocket] Conversations: ${message['conversations']}');
        break;

      case 'groups':
        debugPrint('[WebSocket] Groups: ${message['groups']}');
        break;

      case 'unread_count':
        _unreadController.add(message);
        debugPrint('[WebSocket] Unread: ${message['unread_count']}');
        break;

      case 'presence_update':
        final email = message['email'] as String?;
        final online = message['online'] == true;
        if (email != null) {
          // Update contact online status
          final idx = _contacts.indexWhere((c) => c.email == email);
          if (idx >= 0) {
            _contacts[idx] = Contact(
              id: _contacts[idx].id,
              name: _contacts[idx].name,
              email: _contacts[idx].email,
              online: online,
            );
            _contactsController.add(_contacts);
            // Update active users too
            _activeUsers = _contacts
                .map(
                  (c) => ActiveUser(
                    username: c.name,
                    email: c.email,
                    status: c.online ? 'online' : 'offline',
                  ),
                )
                .toList();
            _activeUsersController.add(_activeUsers);
          }
        }
        debugPrint('[WebSocket] Presence: $email online=$online');
        break;

      case 'typing':
        _typingController.add(message);
        debugPrint('[WebSocket] Typing: ${message['user_email']}');
        break;

      case 'mark_read':
        debugPrint('[WebSocket] Marked read');
        break;

      case 'reactions':
        _reactionsController.add(message);
        debugPrint('[WebSocket] Reactions received');
        break;

      case 'reaction_updated':
        _reactionsController.add(message);
        debugPrint(
          '[WebSocket] Reaction updated for message ${message['message_id']}',
        );
        break;

      case 'employee_change':
        _employeeChangeController.add(message);
        debugPrint(
          '[WebSocket] Employee change: ${message['action_type']} ${message['uuid']}',
        );
        break;

      case 'notifications':
      case 'notification_count':
      case 'notifications_read':
        _notificationsController.add(message);
        debugPrint('[WebSocket] Notification event: $event');
        break;

      case 'new_notification':
        _notificationsController.add(message);
        debugPrint('[WebSocket] New notification pushed: ${message['title']}');
        break;

      case 'error':
        debugPrint('[WebSocket] Server error: ${message['message']}');
        break;

      default:
        debugPrint('[WebSocket] Unknown event: $event');
    }
  }

  void send(Map<String, dynamic> message) {
    if (_currentStatus != ConnectionStatus.connected || _channel == null) {
      debugPrint('[WebSocket] Cannot send — not connected');
      return;
    }
    final encoded = jsonEncode(message);
    _channel!.sink.add(encoded);
    debugPrint('[WebSocket] Sent: $encoded');
  }

  void disconnect() {
    _intentionalClose = true;
    _cleanup();
    _channel?.sink.close();
    _channel = null;
    _activeUsers = [];
    _contacts = [];
    _activeUsersController.add(_activeUsers);
    _contactsController.add(_contacts);
    _setStatus(ConnectionStatus.disconnected);
    debugPrint('[WebSocket] Disconnected');
  }

  void _scheduleReconnect() {
    if (_intentionalClose || _reconnectAttempts >= _maxReconnectAttempts) {
      if (_reconnectAttempts >= _maxReconnectAttempts) {
        debugPrint('[WebSocket] Max reconnect attempts reached');
      }
      return;
    }

    _reconnectAttempts++;
    final delay = _reconnectDelay * _reconnectAttempts;
    debugPrint(
      '[WebSocket] Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => connect());
  }

  void _cleanup() {
    _presenceTimer?.cancel();
    _reconnectTimer?.cancel();
  }

  void _setStatus(ConnectionStatus status) {
    _currentStatus = status;
    _statusController.add(status);
  }

  void dispose() {
    disconnect();
    _statusController.close();
    _messageController.close();
    _activeUsersController.close();
    _contactsController.close();
    _chatMessageController.close();
    _typingController.close();
    _unreadController.close();
    _reactionsController.close();
    _employeeChangeController.close();
    _notificationsController.close();
  }
}
