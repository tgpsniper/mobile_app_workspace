import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class LeavePage extends StatefulWidget {
  final String email;
  final String? displayName;
  const LeavePage({super.key, required this.email, this.displayName});

  @override
  State<LeavePage> createState() => _LeavePageState();
}

class _LeavePageState extends State<LeavePage> {
  static const String _apiUrl =
      'https://workspace.jedapps.com/pbx/app/workspace/user_api.php';
  static const String _apiBase = 'https://workspace.jedapps.com/api';
  static const String _authToken = 'ws-fusion-2026-token';

  bool _loading = true;
  String? _error;
  String? _contactUuid;

  List<Map<String, dynamic>> _leaves = [];
  Map<String, dynamic> _balances = {};

  // Filing form
  String _leaveType = 'Vacation';
  DateTime? _dateFrom;
  DateTime? _dateTo;
  final _reasonCtrl = TextEditingController();
  bool _filing = false;

  static const _leaveTypes = [
    'Vacation',
    'Sick',
    'SIL',
    'Maternity',
    'Paternity',
    'Solo Parent',
    'Emergency',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _resolveUuidAndFetch();
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
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
        final List employees = data is List ? data : (data['employees'] ?? []);
        final match = employees.cast<Map<String, dynamic>>().where((e) {
          final empEmail = (e['email'] ?? '').toString().toLowerCase();
          return empEmail == widget.email.toLowerCase();
        });
        if (match.isNotEmpty) {
          _contactUuid =
              match.first['contact_uuid'] ??
              match.first['uuid'] ??
              match.first['id']?.toString();
        }
      }
    } catch (e) {
      debugPrint('[Leave] UUID resolve error: $e');
    }

    if (_contactUuid != null) {
      await _fetchLeaves();
    } else {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not resolve employee record.';
        });
      }
    }
  }

  Future<void> _fetchLeaves() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_leave_list',
          'contact_uuid': _contactUuid,
        }),
      );

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        // Handle both Map and List responses
        Map<String, dynamic> data;
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        } else if (decoded is List) {
          // API returned a raw list — treat as leaves with no balances
          data = {'ok': true, 'leaves': decoded, 'balances': {}};
        } else {
          data = {'ok': false, 'error': 'Unexpected response format.'};
        }

        if (data['ok'] == true) {
          final rawLeaves = data['leaves'];
          _leaves = (rawLeaves is List)
              ? rawLeaves
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList()
              : <Map<String, dynamic>>[];
          _balances = data['balances'] is Map
              ? Map<String, dynamic>.from(data['balances'] as Map)
              : {};
          // Sort by filed_date desc
          _leaves.sort((a, b) {
            final da = a['filed_date'] ?? a['date_from'] ?? '';
            final db = b['filed_date'] ?? b['date_from'] ?? '';
            return db.toString().compareTo(da.toString());
          });
        } else {
          _error = data['error']?.toString() ?? 'Failed to load leaves.';
        }
      } else {
        _error = 'Server error (${resp.statusCode}).';
      }
    } catch (e) {
      _error = 'Connection error: $e';
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fileLeave() async {
    if (_dateFrom == null || _dateTo == null) {
      _snack('Please select date range.');
      return;
    }
    if (_dateTo!.isBefore(_dateFrom!)) {
      _snack('End date cannot be before start date.');
      return;
    }
    final reason = _reasonCtrl.text.trim();
    if (reason.isEmpty) {
      _snack('Please enter a reason.');
      return;
    }

    setState(() => _filing = true);

    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_leave_save',
          'contact_uuid': _contactUuid,
          'leave_type': _leaveType,
          'date_from': DateFormat('yyyy-MM-dd').format(_dateFrom!),
          'date_to': DateFormat('yyyy-MM-dd').format(_dateTo!),
          'reason': reason,
        }),
      );

      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (data['ok'] == true) {
        _snack('Leave request filed successfully!');
        _reasonCtrl.clear();
        setState(() {
          _dateFrom = null;
          _dateTo = null;
        });
        await _fetchLeaves();
      } else {
        _snack(data['error'] ?? 'Failed to file leave.');
      }
    } catch (e) {
      _snack('Error: $e');
    }

    if (mounted) setState(() => _filing = false);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickDate(bool isFrom) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _dateFrom : _dateTo) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF3B6FE8),
            surface: Color(0xFF1A2035),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        if (isFrom) {
          _dateFrom = picked;
          if (_dateTo != null && _dateTo!.isBefore(picked)) _dateTo = picked;
        } else {
          _dateTo = picked;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A2035),
      appBar: AppBar(
        title: const Text(
          'Leave Request',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF3B6FE8)),
            )
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _resolveUuidAndFetch,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchLeaves,
              color: const Color(0xFF3B6FE8),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildBalanceCards(),
                  const SizedBox(height: 20),
                  _buildFileLeaveForm(),
                  const SizedBox(height: 20),
                  _buildLeaveHistory(),
                ],
              ),
            ),
    );
  }

  // ─── Balance Cards ─────────────────────────────────────────────
  Widget _buildBalanceCards() {
    final items = <_BalanceItem>[
      _BalanceItem('Vacation', _bal('vacation'), const Color(0xFF3B6FE8)),
      _BalanceItem('Sick', _bal('sick'), const Color(0xFFFF7043)),
      _BalanceItem('SIL', _bal('sil'), const Color(0xFF00BFA5)),
    ];

    // Add extra balances if present
    for (final key in _balances.keys) {
      final k = key.toString().toLowerCase();
      if (!['vacation', 'sick', 'sil'].contains(k)) {
        items.add(
          _BalanceItem(
            _capitalize(key.toString()),
            _bal(key.toString()),
            const Color(0xFF7C4DFF),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Leave Balances',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: items.map((b) => _balanceCard(b)).toList(),
        ),
      ],
    );
  }

  Widget _balanceCard(_BalanceItem b) {
    return Container(
      width: (MediaQuery.of(context).size.width - 52) / 3,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: b.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: b.color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(
            b.value,
            style: TextStyle(
              color: b.color,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            b.label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  String _bal(String key) {
    final v = _balances[key] ?? _balances[key.toLowerCase()];
    if (v == null) return '0';
    if (v is num)
      return v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
    return v.toString();
  }

  // ─── File Leave Form ───────────────────────────────────────────
  Widget _buildFileLeaveForm() {
    final fmt = DateFormat('MMM d, yyyy');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF232A3E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'File Leave Request',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),

          // Leave Type
          _label('LEAVE TYPE'),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _leaveType,
            decoration: _inputDecor(),
            dropdownColor: const Color(0xFF232A3E),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            items: _leaveTypes
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) => setState(() => _leaveType = v ?? 'Vacation'),
          ),
          const SizedBox(height: 12),

          // Date Range
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('FROM'),
                    const SizedBox(height: 4),
                    _dateButton(
                      _dateFrom != null ? fmt.format(_dateFrom!) : 'Select',
                      () => _pickDate(true),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('TO'),
                    const SizedBox(height: 4),
                    _dateButton(
                      _dateTo != null ? fmt.format(_dateTo!) : 'Select',
                      () => _pickDate(false),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Reason
          _label('REASON'),
          const SizedBox(height: 4),
          TextField(
            controller: _reasonCtrl,
            maxLines: 3,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: _inputDecor(hint: 'Enter reason for leave'),
          ),
          const SizedBox(height: 16),

          // Submit
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton(
              onPressed: _filing ? null : _fileLeave,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFA5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: _filing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Submit Leave Request',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2035),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: text == 'Select' ? Colors.white38 : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            const Icon(Icons.calendar_today, color: Colors.white38, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.4),
        letterSpacing: 0.8,
      ),
    );
  }

  InputDecoration _inputDecor({String? hint}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
      filled: true,
      fillColor: const Color(0xFF1A2035),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }

  // ─── Leave History ─────────────────────────────────────────────
  Widget _buildLeaveHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Leave History',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        if (_leaves.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF232A3E),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(
              child: Text(
                'No leave records found.',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ),
          )
        else
          ..._leaves.map(_leaveCard),
      ],
    );
  }

  Widget _leaveCard(Map<String, dynamic> leave) {
    final type = leave['leave_type'] ?? 'Leave';
    final status = (leave['status'] ?? 'pending').toString().toLowerCase();
    final dateFrom = leave['date_from'] ?? '';
    final dateTo = leave['date_to'] ?? '';
    final reason = leave['reason'] ?? '';
    final filedDate = leave['filed_date'] ?? '';

    Color statusColor;
    IconData statusIcon;
    switch (status) {
      case 'approved':
        statusColor = const Color(0xFF00BFA5);
        statusIcon = Icons.check_circle;
        break;
      case 'denied':
      case 'rejected':
        statusColor = Colors.redAccent;
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = const Color(0xFFFFB300);
        statusIcon = Icons.schedule;
    }

    // Format date range
    String dateRange = dateFrom;
    if (dateTo.isNotEmpty && dateTo != dateFrom) {
      dateRange = '$dateFrom  to  $dateTo';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF232A3E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: type + status
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B6FE8).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  type,
                  style: const TextStyle(
                    color: Color(0xFF3B6FE8),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Icon(statusIcon, color: statusColor, size: 16),
              const SizedBox(width: 4),
              Text(
                _capitalize(status),
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Date range
          Row(
            children: [
              const Icon(Icons.date_range, color: Colors.white38, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  dateRange,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ],
          ),

          // Reason
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],

          // Filed date
          if (filedDate.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Filed: $filedDate',
              style: const TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _BalanceItem {
  final String label;
  final String value;
  final Color color;
  const _BalanceItem(this.label, this.value, this.color);
}
