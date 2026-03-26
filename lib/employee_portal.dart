import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'chat_page.dart';
import 'notification_page.dart';
import 'active_users_page.dart';
import 'leave_page.dart';
import 'payroll_page.dart';
import 'profile_page.dart';
import 'attendance_page.dart';
import 'websocket_service.dart';

class EmployeePortal extends StatefulWidget {
  final String username;
  final String? displayName;
  const EmployeePortal({super.key, required this.username, this.displayName});

  @override
  State<EmployeePortal> createState() => _EmployeePortalState();
}

class _EmployeePortalState extends State<EmployeePortal> {
  final LocalAuthentication _localAuth = LocalAuthentication();
  final WebSocketService _wsService = WebSocketService();
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  ConnectionStatus _wsStatus = ConnectionStatus.disconnected;
  List<ActiveUser> _activeUsers = [];
  int _notifUnreadCount = 0;
  int _chatUnreadCount = 0;
  String? _contactUuid;
  StreamSubscription? _wsStatusSub;
  StreamSubscription? _wsMessageSub;
  StreamSubscription? _wsUsersSub;
  StreamSubscription? _wsUnreadSub;
  StreamSubscription? _wsChatSub;
  StreamSubscription? _wsNotifSub;

  static const String _apiBase = 'https://workspace.jedapps.com/api';
  static const String _authToken = 'ws-fusion-2026-token';

  @override
  void initState() {
    super.initState();
    _authenticateWithBiometrics();
    _initWebSocket();
    _resolveContactUuid();
  }

  void _initWebSocket() {
    _wsStatusSub = _wsService.statusStream.listen((status) {
      if (mounted) setState(() => _wsStatus = status);
    });
    _wsMessageSub = _wsService.messageStream.listen((message) {
      debugPrint('[Portal] WS message: $message');
      if (message['type'] == 'notification' && mounted) {
        _showSnackBar(message['body'] ?? 'New notification received');
      }
    });
    _wsUsersSub = _wsService.activeUsersStream.listen((users) {
      if (mounted) setState(() => _activeUsers = users);
    });
    _wsUnreadSub = _wsService.unreadStream.listen((data) {
      if (mounted) {
        final count = data['unread_count'] ?? 0;
        setState(() {
          _chatUnreadCount = count;
        });
      }
    });
    _wsNotifSub = _wsService.notificationsStream.listen((data) {
      if (!mounted) return;
      final event = data['event'] ?? data['type'];
      if (event == 'new_notification') {
        setState(() => _notifUnreadCount++);
        final title = data['title'] ?? 'New notification';
        _showSnackBar(title);
      }
    });
    _wsChatSub = _wsService.chatMessageStream.listen((msg) {
      if (!mounted) return;
      final myEmail = _wsService.currentEmail ?? widget.username;
      // Only notify for messages from others
      if (msg.senderEmail != myEmail && !msg.isHistory) {
        setState(() => _chatUnreadCount++);
        _showNewMessageNotification(msg);
      }
    });
    _wsService.connect(
      username: widget.displayName ?? widget.username,
      email: widget.username,
    );
  }

  @override
  void dispose() {
    _wsStatusSub?.cancel();
    _wsMessageSub?.cancel();
    _wsUsersSub?.cancel();
    _wsUnreadSub?.cancel();
    _wsChatSub?.cancel();
    _wsNotifSub?.cancel();
    super.dispose();
  }

  static const String _userApiUrl =
      'https://workspace.jedapps.com/pbx/app/workspace/user_api.php';

  Future<void> _resolveContactUuid() async {
    try {
      final resp = await http.get(
        Uri.parse('$_apiBase/employees'),
        headers: {'Authorization': 'Bearer $_authToken'},
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final List employees = data is List ? data : (data['employees'] ?? []);
        final match = employees.cast<Map<String, dynamic>>().where((e) {
          final empEmail = (e['email'] ?? '').toString().toLowerCase();
          return empEmail == widget.username.toLowerCase();
        });
        if (match.isNotEmpty) {
          _contactUuid =
              match.first['contact_uuid'] ??
              match.first['uuid'] ??
              match.first['id']?.toString();
          if (_contactUuid != null) {
            _fetchNotificationCount();
          }
        }
      }
    } catch (e) {
      debugPrint('[Portal] UUID resolve error: $e');
    }
  }

  Future<void> _fetchNotificationCount() async {
    if (_contactUuid == null) return;
    try {
      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_notifications_count',
          'contact_uuid': _contactUuid,
        }),
      );
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          setState(() {
            _notifUnreadCount = data['unread_count'] ?? 0;
          });
        }
      }
    } catch (e) {
      debugPrint('[Portal] Notification count error: $e');
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    setState(() => _isAuthenticating = true);

    try {
      final bool canAuth = await _localAuth.canCheckBiometrics;
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();

      if (!canAuth || !isDeviceSupported) {
        if (mounted) {
          setState(() {
            _isAuthenticated = true;
            _isAuthenticating = false;
          });
          _showSnackBar('Biometrics not available — access granted.');
        }
        return;
      }

      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Scan your fingerprint to access the Employee Portal',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (mounted) {
        setState(() {
          _isAuthenticated = authenticated;
          _isAuthenticating = false;
        });
        if (!authenticated) {
          _showSnackBar('Authentication failed. Tap the lock to retry.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAuthenticated = true;
          _isAuthenticating = false;
        });
        _showSnackBar('Biometric error — access granted.');
      }
    }
  }

  void _showNewMessageNotification(ChatMessage msg) {
    final senderName = msg.senderName ?? msg.senderEmail;
    if (senderName.isEmpty) return;
    final preview = msg.text.length > 50
        ? '${msg.text.substring(0, 50)}...'
        : msg.text;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: const Color(0xFF3B6FE8),
              child: Text(
                senderName[0].toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    senderName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    preview,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1A2035),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Open',
          textColor: const Color(0xFF3B6FE8),
          onPressed: _openChat,
        ),
      ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticated) {
      return _buildLockScreen();
    }
    return _buildPortal();
  }

  Widget _buildLockScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A2035),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.1),
                border: Border.all(
                  color: const Color(0xFF3B6FE8).withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
              child: Icon(
                _isAuthenticating ? Icons.fingerprint : Icons.lock_outline,
                size: 50,
                color: _isAuthenticating
                    ? const Color(0xFF3B6FE8)
                    : Colors.white70,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _isAuthenticating
                  ? 'Verifying identity...'
                  : 'Authentication Required',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Use your fingerprint to access\nthe Employee Portal',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 32),
            if (!_isAuthenticating)
              ElevatedButton.icon(
                onPressed: _authenticateWithBiometrics,
                icon: const Icon(Icons.fingerprint, size: 22),
                label: const Text('Authenticate'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B6FE8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            if (_isAuthenticating)
              const CircularProgressIndicator(color: Color(0xFF3B6FE8)),
          ],
        ),
      ),
    );
  }

  Widget _buildPortal() {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      appBar: AppBar(
        title: const Text(
          'Employee Portal',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () {
                  if (_contactUuid != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            NotificationPage(contactUuid: _contactUuid!),
                      ),
                    ).then((_) {
                      // Refresh count when returning from notification page
                      _fetchNotificationCount();
                    });
                  } else {
                    _showSnackBar('Loading notifications...');
                  }
                },
                tooltip: 'Notifications',
              ),
              if (_notifUnreadCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        _notifUnreadCount > 99 ? '99+' : '$_notifUnreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Welcome header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF3B6FE8), Color(0xFF1A2035)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white.withValues(alpha: 0.2),
                    child: Text(
                      (widget.displayName ?? widget.username)[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome, ${widget.displayName ?? widget.username}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.verified_user,
                              color: Colors.greenAccent.shade200,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Biometric Verified',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 8,
                              color: _wsStatus == ConnectionStatus.connected
                                  ? Colors.greenAccent.shade200
                                  : _wsStatus == ConnectionStatus.connecting
                                  ? Colors.orangeAccent
                                  : Colors.redAccent.shade100,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _wsStatus == ConnectionStatus.connected
                                  ? 'Live Connected'
                                  : _wsStatus == ConnectionStatus.connecting
                                  ? 'Connecting...'
                                  : 'Offline',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            if (_wsStatus == ConnectionStatus.disconnected ||
                                _wsStatus == ConnectionStatus.error)
                              GestureDetector(
                                onTap: () => _wsService.connect(),
                                child: const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.refresh,
                                    color: Colors.white54,
                                    size: 14,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Quick Actions
            const Text(
              'Quick Actions',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2035),
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.3,
              children: [
                _buildActionCardWithCallback(
                  Icons.access_time_rounded,
                  'Attendance',
                  'View DTR & Status',
                  const Color(0xFF3B6FE8),
                  _openAttendance,
                ),
                _buildActionCardWithCallback(
                  Icons.calendar_today_rounded,
                  'Leave Request',
                  'Apply for leave',
                  const Color(0xFF00BFA5),
                  _openLeave,
                ),
                _buildActionCardWithCallback(
                  Icons.receipt_long_rounded,
                  'Payslip',
                  'View payslips',
                  const Color(0xFFFF7043),
                  _openPayslip,
                ),
                _buildActionCardWithCallback(
                  Icons.person_outline_rounded,
                  'My Profile',
                  'View details',
                  const Color(0xFF7C4DFF),
                  _openProfile,
                ),
                _buildActionCardWithCallback(
                  Icons.people_alt_rounded,
                  'Active Users',
                  '${_activeUsers.length + (_wsStatus == ConnectionStatus.connected ? 1 : 0)} online',
                  const Color(0xFFFFB300),
                  _openActiveUsers,
                ),
                _buildActionCardWithBadge(
                  Icons.chat_rounded,
                  'Chat',
                  'Team messaging',
                  const Color(0xFFE91E63),
                  _openChat,
                  _chatUnreadCount,
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Recent Activity
            const Text(
              'Recent Activity',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2035),
              ),
            ),
            const SizedBox(height: 12),
            _buildActivityItem(
              Icons.login,
              'Clocked In',
              'Today at 9:00 AM',
              const Color(0xFF00BFA5),
            ),
            _buildActivityItem(
              Icons.task_alt,
              'Task Completed',
              'Network audit - Building A',
              const Color(0xFF3B6FE8),
            ),
            _buildActivityItem(
              Icons.event_available,
              'Leave Approved',
              'Mar 25 - Mar 26, 2026',
              const Color(0xFF7C4DFF),
            ),
          ],
        ),
      ),
    );
  }

  void _openAttendance() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AttendancePage(
          email: widget.username,
          displayName: widget.displayName,
        ),
      ),
    );
  }

  void _openLeave() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            LeavePage(email: widget.username, displayName: widget.displayName),
      ),
    );
  }

  void _openPayslip() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PayrollPage(
          email: widget.username,
          displayName: widget.displayName,
        ),
      ),
    );
  }

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfilePage(
          email: widget.username,
          displayName: widget.displayName,
        ),
      ),
    );
  }

  void _openActiveUsers() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ActiveUsersPage(currentUsername: widget.username),
      ),
    );
  }

  void _openChat() {
    setState(() => _chatUnreadCount = 0);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatPage(username: widget.username),
      ),
    );
  }

  Widget _buildActionCardWithCallback(
    IconData icon,
    String title,
    String subtitle,
    Color color,
    VoidCallback onTap,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Color(0xFF1A2035),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8A96B0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionCardWithBadge(
    IconData icon,
    String title,
    String subtitle,
    Color color,
    VoidCallback onTap,
    int badgeCount,
  ) {
    return Stack(
      children: [
        _buildActionCardWithCallback(icon, title, subtitle, color, onTap),
        if (badgeCount > 0)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                badgeCount > 99 ? '99+' : '$badgeCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildActivityItem(
    IconData icon,
    String title,
    String subtitle,
    Color color,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Color(0xFF1A2035),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8A96B0),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceModal extends StatefulWidget {
  const _AttendanceModal();

  @override
  State<_AttendanceModal> createState() => _AttendanceModalState();
}

class _AttendanceModalState extends State<_AttendanceModal> {
  Timer? _timer;
  DateTime _now = DateTime.now();
  bool _loadingLocation = true;
  String _latitude = '--';
  String _longitude = '--';
  String _accuracy = '--';
  String? _timeInStamp;
  String? _timeOutStamp;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _fetchLocation();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchLocation() async {
    setState(() => _loadingLocation = true);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setLocationError('Location disabled');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _setLocationError('Permission denied');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        _setLocationError('Permission permanently denied');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (mounted) {
        setState(() {
          _latitude = position.latitude.toStringAsFixed(6);
          _longitude = position.longitude.toStringAsFixed(6);
          _accuracy = '${position.accuracy.toStringAsFixed(1)} m';
          _loadingLocation = false;
        });
      }
    } catch (e) {
      _setLocationError('Error fetching GPS');
    }
  }

  void _setLocationError(String msg) {
    if (mounted) {
      setState(() {
        _latitude = msg;
        _longitude = msg;
        _accuracy = '--';
        _loadingLocation = false;
      });
    }
  }

  void _handleTimeIn() {
    setState(() {
      _timeInStamp = DateFormat('hh:mm:ss a').format(DateTime.now());
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Clocked In at $_timeInStamp'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF00BFA5),
      ),
    );
  }

  void _handleTimeOut() {
    setState(() {
      _timeOutStamp = DateFormat('hh:mm:ss a').format(DateTime.now());
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Clocked Out at $_timeOutStamp'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFFFF7043),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('EEEE, MMMM d, yyyy').format(_now);
    final timeStr = DateFormat('hh:mm:ss a').format(_now);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Title
          const Row(
            children: [
              Icon(
                Icons.access_time_rounded,
                color: Color(0xFF3B6FE8),
                size: 24,
              ),
              SizedBox(width: 10),
              Text(
                'Attendance',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A2035),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Date & Time card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3B6FE8), Color(0xFF1A2035)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.calendar_today,
                  color: Colors.white70,
                  size: 18,
                ),
                const SizedBox(height: 6),
                Text(
                  dateStr,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  timeStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // GPS Data card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F5FA),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.location_on,
                      color: Color(0xFF3B6FE8),
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'GPS Location',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Color(0xFF1A2035),
                      ),
                    ),
                    const Spacer(),
                    if (_loadingLocation)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF3B6FE8),
                        ),
                      )
                    else
                      GestureDetector(
                        onTap: _fetchLocation,
                        child: const Icon(
                          Icons.refresh,
                          color: Color(0xFF8A96B0),
                          size: 18,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildGpsRow('Latitude', _latitude),
                const SizedBox(height: 6),
                _buildGpsRow('Longitude', _longitude),
                const SizedBox(height: 6),
                _buildGpsRow('Accuracy', _accuracy),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Time In / Time Out stamps
          if (_timeInStamp != null || _timeOutStamp != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F5FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  if (_timeInStamp != null)
                    Column(
                      children: [
                        const Text(
                          'Time In',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8A96B0),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _timeInStamp!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00BFA5),
                          ),
                        ),
                      ],
                    ),
                  if (_timeOutStamp != null)
                    Column(
                      children: [
                        const Text(
                          'Time Out',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8A96B0),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _timeOutStamp!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF7043),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

          // Time In / Time Out buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _timeInStamp == null ? _handleTimeIn : null,
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('Time In'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFA5),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _timeInStamp != null && _timeOutStamp == null
                      ? _handleTimeOut
                      : null,
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Time Out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF7043),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGpsRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF8A96B0)),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A2035),
          ),
        ),
      ],
    );
  }
}
