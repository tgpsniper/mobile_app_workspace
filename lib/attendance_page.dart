import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class AttendancePage extends StatefulWidget {
  final String email;
  final String? displayName;
  const AttendancePage({super.key, required this.email, this.displayName});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage>
    with SingleTickerProviderStateMixin {
  static const String _apiBase = 'https://workspace.jedapps.com/api';
  static const String _userApiUrl =
      'https://workspace.jedapps.com/pbx/app/workspace/user_api.php';
  static const String _authToken = 'ws-fusion-2026-token';

  late TabController _tabController;
  String? _contactUuid;
  bool _loadingUuid = true;

  // Clock status
  Map<String, dynamic>? _clockStatus;
  bool _loadingClock = true;

  // Monthly summary
  Map<String, dynamic>? _monthlySummary;
  bool _loadingMonthly = true;
  DateTime _selectedMonth = DateTime.now();

  // Weekly
  Map<String, dynamic>? _weeklyData;
  bool _loadingWeekly = true;
  DateTime _weeklyMonth = DateTime.now();

  String? _error;
  bool _clockingIn = false;
  bool _clockingOut = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _resolveUuidAndFetch();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _resolveUuidAndFetch() async {
    try {
      final resp = await http.get(
        Uri.parse('$_apiBase/employees'),
        headers: {'Authorization': 'Bearer $_authToken'},
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final List employees =
            data is List ? data : (data['employees'] ?? []);
        final match = employees.cast<Map<String, dynamic>>().where((e) {
          final empEmail = (e['email'] ?? '').toString().toLowerCase();
          return empEmail == widget.email.toLowerCase();
        });
        if (match.isNotEmpty) {
          _contactUuid = match.first['contact_uuid'] ??
              match.first['uuid'] ??
              match.first['id']?.toString();
        }
      }
    } catch (e) {
      debugPrint('[Attendance] UUID resolve error: $e');
    }

    if (!mounted) return;
    if (_contactUuid == null) {
      setState(() {
        _loadingUuid = false;
        _error = 'Could not resolve employee identity.';
      });
      return;
    }

    setState(() => _loadingUuid = false);
    _fetchClockStatus();
    _fetchMonthlySummary();
    _fetchWeeklyData();
  }

  Future<void> _fetchClockStatus() async {
    setState(() => _loadingClock = true);
    try {
      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_clock_status',
          'contact_uuid': _contactUuid,
        }),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          setState(() {
            _clockStatus = data;
            _loadingClock = false;
          });
        } else {
          setState(() {
            _loadingClock = false;
            _error = data['error']?.toString();
          });
        }
      } else {
        setState(() => _loadingClock = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingClock = false);
      debugPrint('[Attendance] Clock status error: $e');
    }
  }

  Future<Position?> _getPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return null;
      }
      if (perm == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleClock(String type) async {
    if (type == 'in') {
      setState(() => _clockingIn = true);
    } else {
      setState(() => _clockingOut = true);
    }

    try {
      final pos = await _getPosition();
      final body = <String, dynamic>{
        'token': _authToken,
        'action': 'hr_attendance_clock',
        'contact_uuid': _contactUuid,
        'type': type,
        'device': 'web',
      };
      if (pos != null) {
        body['latitude'] = pos.latitude;
        body['longitude'] = pos.longitude;
        body['accuracy'] = pos.accuracy;
      }

      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(type == 'in'
                  ? 'Clocked In at ${DateFormat('hh:mm:ss a').format(DateTime.now())}'
                  : 'Clocked Out at ${DateFormat('hh:mm:ss a').format(DateTime.now())}'),
              behavior: SnackBarBehavior.floating,
              backgroundColor:
                  type == 'in' ? const Color(0xFF00BFA5) : const Color(0xFFFF7043),
            ),
          );
          _fetchClockStatus();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['error']?.toString() ?? 'Clock $type failed'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _clockingIn = false;
          _clockingOut = false;
        });
      }
    }
  }

  Future<void> _fetchMonthlySummary() async {
    setState(() => _loadingMonthly = true);
    final monthStr = DateFormat('yyyy-MM').format(_selectedMonth);
    try {
      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_attendance_summary',
          'contact_uuid': _contactUuid,
          'month': monthStr,
        }),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          setState(() {
            _monthlySummary = data;
            _loadingMonthly = false;
          });
        } else {
          setState(() => _loadingMonthly = false);
        }
      } else {
        setState(() => _loadingMonthly = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMonthly = false);
      debugPrint('[Attendance] Monthly summary error: $e');
    }
  }

  Future<void> _fetchWeeklyData() async {
    setState(() => _loadingWeekly = true);
    final monthStr = DateFormat('yyyy-MM').format(_weeklyMonth);
    try {
      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_attendance_weekly',
          'contact_uuid': _contactUuid,
          'month': monthStr,
        }),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          setState(() {
            _weeklyData = data;
            _loadingWeekly = false;
          });
        } else {
          setState(() => _loadingWeekly = false);
        }
      } else {
        setState(() => _loadingWeekly = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingWeekly = false);
      debugPrint('[Attendance] Weekly error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      appBar: AppBar(
        title: const Text(
          'Attendance',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF3B6FE8),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: 'Dashboard'),
            Tab(text: 'Monthly'),
            Tab(text: 'Weekly'),
          ],
        ),
      ),
      body: _loadingUuid
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF3B6FE8)))
          : _error != null && _contactUuid == null
              ? Center(
                  child: Text(_error!,
                      style: TextStyle(color: Colors.grey.shade600)))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDashboardTab(),
                    _buildMonthlyTab(),
                    _buildWeeklyTab(),
                  ],
                ),
    );
  }

  // ─── DASHBOARD TAB ───────────────────────────────────────────────

  Widget _buildDashboardTab() {
    if (_loadingClock) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF3B6FE8)));
    }
    if (_clockStatus == null) {
      return _buildRetryWidget('Could not load clock status', _fetchClockStatus);
    }

    final bool clockedIn = _clockStatus!['clocked_in'] == true;
    final String clockInTime = _clockStatus!['clock_in_time'] ?? '--';
    final elapsedHours = _clockStatus!['elapsed_hours'] ?? 0;

    final today = _clockStatus!['today'] as Map<String, dynamic>? ?? {};
    final week = _clockStatus!['week'] as Map<String, dynamic>? ?? {};
    final month = _clockStatus!['month'] as Map<String, dynamic>? ?? {};

    final todayRecords = today['records'] as List<dynamic>? ?? [];

    return RefreshIndicator(
      onRefresh: _fetchClockStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Clock status card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: clockedIn
                      ? [const Color(0xFF00BFA5), const Color(0xFF00897B)]
                      : [const Color(0xFF3B6FE8), const Color(0xFF1A2035)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Icon(
                    clockedIn ? Icons.timer : Icons.timer_off_outlined,
                    color: Colors.white70,
                    size: 36,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    clockedIn ? 'CLOCKED IN' : 'NOT CLOCKED IN',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  if (clockedIn) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Since $clockInTime',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_formatHours(elapsedHours)} elapsed',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Clock In / Out buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: clockedIn || _clockingIn
                        ? null
                        : () => _handleClock('in'),
                    icon: _clockingIn
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.login, size: 18),
                    label: const Text('Time In'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BFA5),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !clockedIn || _clockingOut
                        ? null
                        : () => _handleClock('out'),
                    icon: _clockingOut
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.logout, size: 18),
                    label: const Text('Time Out'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7043),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Stats row: Today / Week / Month
            Row(
              children: [
                Expanded(
                    child: _buildStatCard(
                        'Today',
                        _formatHours(today['total_hours']),
                        Icons.today,
                        const Color(0xFF3B6FE8))),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildStatCard(
                        'This Week',
                        _formatHours(week['total_hours']),
                        Icons.date_range,
                        const Color(0xFF00BFA5))),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildStatCard(
                        'This Month',
                        _formatHours(month['total_hours']),
                        Icons.calendar_month,
                        const Color(0xFFFF7043))),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _buildStatCard(
                        'Days (Week)',
                        '${week['days_worked'] ?? 0}',
                        Icons.work_history,
                        const Color(0xFF7C4DFF))),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildStatCard(
                        'Days (Month)',
                        '${month['days_worked'] ?? 0}',
                        Icons.event_available,
                        const Color(0xFFE91E63))),
                const SizedBox(width: 10),
                const Expanded(child: SizedBox()),
              ],
            ),
            const SizedBox(height: 24),

            // Today's records
            const Text(
              "Today's Records",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2035),
              ),
            ),
            const SizedBox(height: 10),
            if (todayRecords.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Icon(Icons.event_busy,
                        size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 8),
                    Text(
                      'No records yet today',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 14),
                    ),
                  ],
                ),
              )
            else
              ...todayRecords.map((record) {
                final r = record as Map<String, dynamic>;
                final clockIn = r['clock_in'] ?? '--';
                final clockOut = r['clock_out'] ?? '--';
                final hours = r['hours'] ?? r['total_hours'];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
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
                          color: const Color(0xFF00BFA5).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.access_time,
                            color: Color(0xFF00BFA5), size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$clockIn — $clockOut',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: Color(0xFF1A2035),
                              ),
                            ),
                            if (hours != null)
                              Text(
                                '${_formatHours(hours)} hrs',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF8A96B0)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(
      String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A2035),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A96B0)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ─── MONTHLY TAB ─────────────────────────────────────────────────

  Widget _buildMonthlyTab() {
    return Column(
      children: [
        // Month selector
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Color(0xFF1A2035)),
                onPressed: () {
                  setState(() {
                    _selectedMonth = DateTime(
                        _selectedMonth.year, _selectedMonth.month - 1);
                  });
                  _fetchMonthlySummary();
                },
              ),
              Text(
                DateFormat('MMMM yyyy').format(_selectedMonth),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A2035),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Color(0xFF1A2035)),
                onPressed: () {
                  setState(() {
                    _selectedMonth = DateTime(
                        _selectedMonth.year, _selectedMonth.month + 1);
                  });
                  _fetchMonthlySummary();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingMonthly
              ? const Center(
                  child:
                      CircularProgressIndicator(color: Color(0xFF3B6FE8)))
              : _monthlySummary == null
                  ? _buildRetryWidget(
                      'Could not load monthly data', _fetchMonthlySummary)
                  : _buildMonthlyContent(),
        ),
      ],
    );
  }

  Widget _buildMonthlyContent() {
    final summary =
        _monthlySummary!['summary'] as Map<String, dynamic>? ?? {};
    final calendar =
        _monthlySummary!['calendar'] as List<dynamic>? ?? [];

    return RefreshIndicator(
      onRefresh: _fetchMonthlySummary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary cards
            _buildMonthlySummaryCards(summary),
            const SizedBox(height: 20),

            const Text(
              'Daily Breakdown',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2035),
              ),
            ),
            const SizedBox(height: 10),

            // Calendar entries
            ...calendar.map((day) {
              final d = day as Map<String, dynamic>;
              return _buildDayCard(d);
            }),

            if (calendar.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'No attendance data for this month',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthlySummaryCards(Map<String, dynamic> summary) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
                child: _buildSummaryTile(
                    'Present',
                    '${summary['days_present'] ?? 0}',
                    const Color(0xFF00BFA5))),
            const SizedBox(width: 10),
            Expanded(
                child: _buildSummaryTile(
                    'Absent',
                    '${summary['days_absent'] ?? 0}',
                    const Color(0xFFE91E63))),
            const SizedBox(width: 10),
            Expanded(
                child: _buildSummaryTile(
                    'Total Hrs',
                    _formatHours(summary['total_hours']),
                    const Color(0xFF3B6FE8))),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _buildSummaryTile(
                    'Overtime',
                    _formatHours(summary['overtime'] ?? summary['ot']),
                    const Color(0xFF7C4DFF))),
            const SizedBox(width: 10),
            Expanded(
                child: _buildSummaryTile(
                    'Undertime',
                    _formatHours(summary['undertime']),
                    const Color(0xFFFF7043))),
            const SizedBox(width: 10),
            Expanded(
                child: _buildSummaryTile(
                    'Late',
                    '${summary['late'] ?? summary['late_minutes'] ?? 0}m',
                    const Color(0xFFFFB300))),
          ],
        ),
        if (summary['avg_hours_per_day'] != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: _buildSummaryTile(
                      'Avg/Day',
                      _formatHours(summary['avg_hours_per_day']),
                      const Color(0xFF8A96B0))),
              const SizedBox(width: 10),
              const Expanded(child: SizedBox()),
              const SizedBox(width: 10),
              const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSummaryTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A96B0)),
          ),
        ],
      ),
    );
  }

  Widget _buildDayCard(Map<String, dynamic> day) {
    final date = day['date'] ?? '';
    final status = (day['status'] ?? '').toString().toLowerCase();
    final hours = day['hours'] ?? day['total_hours'];
    final overtime = day['overtime'] ?? day['ot'];
    final undertime = day['undertime'];
    final late = day['late'] ?? day['late_minutes'];

    Color statusColor;
    IconData statusIcon;
    switch (status) {
      case 'present':
        statusColor = const Color(0xFF00BFA5);
        statusIcon = Icons.check_circle;
        break;
      case 'absent':
        statusColor = const Color(0xFFE91E63);
        statusIcon = Icons.cancel;
        break;
      case 'upcoming':
        statusColor = const Color(0xFF8A96B0);
        statusIcon = Icons.schedule;
        break;
      default:
        statusColor = const Color(0xFF8A96B0);
        statusIcon = Icons.remove_circle_outline;
    }

    String dateLabel = date;
    try {
      if (date.isNotEmpty) {
        final parsed = DateTime.parse(date);
        dateLabel = DateFormat('EEE, MMM d').format(parsed);
      }
    } catch (_) {}

    final statusLabel = status.isNotEmpty
        ? status[0].toUpperCase() + status.substring(1)
        : 'Unknown';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Color(0xFF1A2035),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusLabel,
                  style: TextStyle(fontSize: 12, color: statusColor),
                ),
              ],
            ),
          ),
          if (hours != null)
            _buildDayChip('${_formatHours(hours)}h', const Color(0xFF3B6FE8)),
          if (overtime != null && _toDouble(overtime) > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child:
                  _buildDayChip('+${_formatHours(overtime)}', const Color(0xFF7C4DFF)),
            ),
          if (undertime != null && _toDouble(undertime) > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _buildDayChip(
                  '-${_formatHours(undertime)}', const Color(0xFFFF7043)),
            ),
          if (late != null && _toDouble(late) > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _buildDayChip('${late}m late', const Color(0xFFFFB300)),
            ),
        ],
      ),
    );
  }

  Widget _buildDayChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  // ─── WEEKLY TAB ──────────────────────────────────────────────────

  Widget _buildWeeklyTab() {
    return Column(
      children: [
        // Month selector
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Color(0xFF1A2035)),
                onPressed: () {
                  setState(() {
                    _weeklyMonth =
                        DateTime(_weeklyMonth.year, _weeklyMonth.month - 1);
                  });
                  _fetchWeeklyData();
                },
              ),
              Text(
                DateFormat('MMMM yyyy').format(_weeklyMonth),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A2035),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Color(0xFF1A2035)),
                onPressed: () {
                  setState(() {
                    _weeklyMonth =
                        DateTime(_weeklyMonth.year, _weeklyMonth.month + 1);
                  });
                  _fetchWeeklyData();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingWeekly
              ? const Center(
                  child:
                      CircularProgressIndicator(color: Color(0xFF3B6FE8)))
              : _weeklyData == null
                  ? _buildRetryWidget(
                      'Could not load weekly data', _fetchWeeklyData)
                  : _buildWeeklyContent(),
        ),
      ],
    );
  }

  Widget _buildWeeklyContent() {
    final weeks = _weeklyData!['weeks'] as List<dynamic>? ?? [];

    return RefreshIndicator(
      onRefresh: _fetchWeeklyData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (weeks.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'No weekly data available',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                ),
              )
            else
              ...weeks.asMap().entries.map((entry) {
                final weekNum = entry.key + 1;
                final week = entry.value as Map<String, dynamic>;
                return _buildWeekCard(weekNum, week);
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekCard(int weekNum, Map<String, dynamic> week) {
    final totalHours = week['total_hours'] ?? week['week_total_hours'];
    final daysPresent = week['days_present'] ?? week['days_worked'];
    final days = week['days'] as List<dynamic>? ?? [];

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Week header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: Color(0xFF1A2035),
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Week $weekNum',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Row(
                  children: [
                    if (totalHours != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B6FE8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_formatHours(totalHours)} hrs',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (daysPresent != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BFA5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$daysPresent days',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // Daily entries
          ...days.map((day) {
            final d = day as Map<String, dynamic>;
            final date = d['date'] ?? '';
            final status = (d['status'] ?? '').toString().toLowerCase();
            final hours = d['hours'] ?? d['total_hours'];

            String dateLabel = date;
            try {
              if (date.isNotEmpty) {
                final parsed = DateTime.parse(date);
                dateLabel = DateFormat('EEE, MMM d').format(parsed);
              }
            } catch (_) {}

            final isPresent = status == 'present';
            final statusLabel = status.isNotEmpty
                ? status[0].toUpperCase() + status.substring(1)
                : 'Unknown';
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade100),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isPresent ? Icons.check_circle : Icons.cancel,
                    color: isPresent
                        ? const Color(0xFF00BFA5)
                        : const Color(0xFFE91E63),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      dateLabel,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF1A2035)),
                    ),
                  ),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: isPresent
                          ? const Color(0xFF00BFA5)
                          : const Color(0xFFE91E63),
                    ),
                  ),
                  if (hours != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      '${_formatHours(hours)}h',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF3B6FE8),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── HELPERS ─────────────────────────────────────────────────────

  String _formatHours(dynamic value) {
    if (value == null) return '0';
    final d = _toDouble(value);
    if (d == d.roundToDouble()) return d.toInt().toString();
    return d.toStringAsFixed(1);
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  Widget _buildRetryWidget(String message, VoidCallback onRetry) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 12),
          Text(message,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B6FE8),
              foregroundColor: Colors.white,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
