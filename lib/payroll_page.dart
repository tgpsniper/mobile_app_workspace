import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

// ---------- Philippine Payroll Computation (matching phPayroll.js) ----------

class PhPayroll {
  /// SSS 2025 employee contribution (RA 11199)
  /// Total rate 15%, EE share 5% of MSC, max MSC ₱35,000
  static double sssEmployee(double monthlyGross) {
    if (monthlyGross <= 0) return 0;
    // Determine Monthly Salary Credit (MSC) — ₱500 brackets
    double msc;
    if (monthlyGross < 4250) {
      msc = 4000;
    } else if (monthlyGross >= 34750) {
      msc = 35000;
    } else {
      msc = ((monthlyGross + 250) / 500).floor() * 500;
    }
    return msc * 0.05; // 5% EE share
  }

  /// PhilHealth 2025 — 5% premium rate, EE pays half (2.5%)
  /// Floor ₱10,000, Ceiling ₱100,000
  static double philhealthEmployee(double monthlyGross) {
    if (monthlyGross <= 0) return 0;
    final base = monthlyGross.clamp(10000, 100000);
    return base * 0.05 / 2; // 2.5% EE share
  }

  /// Pag-IBIG employee contribution — 2% of monthly comp, max ₱200
  static double pagibigEmployee(double monthlyGross) {
    if (monthlyGross <= 0) return 0;
    if (monthlyGross <= 1500) return monthlyGross * 0.01;
    final contribution = monthlyGross * 0.02;
    return math.min(contribution, 200);
  }

  /// BIR Withholding Tax — TRAIN Law monthly brackets
  /// Taxable = gross - SSS - PhilHealth - Pag-IBIG
  static double withholdingTax(double monthlyGross) {
    if (monthlyGross <= 0) return 0;
    final sss = sssEmployee(monthlyGross);
    final phil = philhealthEmployee(monthlyGross);
    final pagibig = pagibigEmployee(monthlyGross);
    final taxable = monthlyGross - sss - phil - pagibig;
    if (taxable <= 20833) return 0;

    // TRAIN Law annual brackets converted to monthly
    const brackets = [
      [20833, 0.0, 0.15],
      [33333, 1875.0, 0.20],
      [66667, 8541.80, 0.25],
      [166667, 33541.80, 0.30],
      [666667, 183541.80, 0.35],
    ];

    for (int i = brackets.length - 1; i >= 0; i--) {
      final floor = brackets[i][0];
      final base = brackets[i][1];
      final rate = brackets[i][2];
      if (taxable > floor) {
        return base + (taxable - floor) * rate;
      }
    }
    return 0;
  }

  /// Apply deductions to a payslip map when API returns zeros
  static Map<String, dynamic> applyDeductions(Map<String, dynamic> payslip) {
    final gross = (payslip['gross'] ?? 0).toDouble();
    if (gross <= 0) return payslip;

    final currentTotal = (payslip['total_deductions'] ?? 0).toDouble();

    // Only compute if API returned zeros
    if (currentTotal > 0) {
      return payslip;
    }

    final sss = sssEmployee(gross);
    final phil = philhealthEmployee(gross);
    final pagibig = pagibigEmployee(gross);
    final tax = withholdingTax(gross);
    final totalDed = sss + phil + pagibig + tax;
    final net = gross - totalDed;

    return {
      ...payslip,
      'sss': sss,
      'philhealth': phil,
      'pagibig': pagibig,
      'withholding_tax': tax,
      'total_deductions': totalDed,
      'net': net,
    };
  }
}

// ---------- Payroll Page ----------

class PayrollPage extends StatefulWidget {
  final String email;
  final String? displayName;
  const PayrollPage({super.key, required this.email, this.displayName});

  @override
  State<PayrollPage> createState() => _PayrollPageState();
}

class _PayrollPageState extends State<PayrollPage> {
  static const String _apiBase = 'https://workspace.jedapps.com/api';
  static const String _authToken = 'ws-fusion-2026-token';
  static const String _userApiUrl = 'https://workspace.jedapps.com/pbx/app/workspace/user_api.php';

  bool _isLoading = true;
  String? _error;
  String? _contactUuid;

  int _selectedYear = DateTime.now().year;
  List<Map<String, dynamic>> _payslips = [];
  String _payType = '';
  double _rate = 0;
  double _salary = 0;

  // Track expanded month cards
  final Set<int> _expandedIndices = {};

  final _currencyFormat = NumberFormat('#,##0.00', 'en_PH');

  @override
  void initState() {
    super.initState();
    _fetchPayroll();
  }

  Future<void> _resolveUuid() async {
    if (_contactUuid != null) return;
    final resp = await http.get(
      Uri.parse('$_apiBase/employees'),
      headers: {'Authorization': 'Bearer $_authToken'},
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['ok'] == true) {
        for (final emp in (data['employees'] as List<dynamic>? ?? [])) {
          if (emp['email'] == widget.email) {
            _contactUuid = emp['contact_uuid'];
            break;
          }
        }
      }
    }
  }

  Future<void> _fetchPayroll() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _resolveUuid();
      if (_contactUuid == null) {
        setState(() {
          _isLoading = false;
          _error = 'Could not resolve employee UUID.';
        });
        return;
      }

      final resp = await http.post(
        Uri.parse(_userApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': _authToken,
          'action': 'ep_payslips',
          'contact_uuid': _contactUuid,
          'year': '$_selectedYear',
        }),
      );

      debugPrint('[Payroll] Response (${resp.statusCode}): ${resp.body.substring(0, resp.body.length > 500 ? 500 : resp.body.length)}');

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (data['ok'] == true) {
          setState(() {
            _payslips = (data['payslips'] as List<dynamic>? ?? [])
                .map((p) => PhPayroll.applyDeductions(Map<String, dynamic>.from(p)))
                .toList();
            _payType = (data['pay_type'] ?? '').toString();
            _rate = (data['rate'] ?? 0).toDouble();
            _salary = (data['salary'] ?? 0).toDouble();
            _isLoading = false;
            _expandedIndices.clear();
          });
        } else {
          setState(() {
            _isLoading = false;
            _error = data['message'] ?? 'Failed to load payslips.';
          });
        }
      } else {
        setState(() {
          _isLoading = false;
          _error = 'Server returned ${resp.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Connection error: $e';
      });
    }
  }

  // --- Annual summary computed from payslips ---
  double get _totalGross => _payslips.fold(0.0, (s, p) => s + (p['gross'] ?? 0).toDouble());
  double get _totalDeductions => _payslips.fold(0.0, (s, p) => s + (p['total_deductions'] ?? 0).toDouble());
  double get _totalNet => _payslips.fold(0.0, (s, p) => s + (p['net'] ?? 0).toDouble());
  double get _totalDays => _payslips.fold(0.0, (s, p) => s + (p['days_worked'] ?? 0).toDouble());
  double get _totalHours => _payslips.fold(0.0, (s, p) => s + (p['hours'] ?? 0).toDouble());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A2035),
      appBar: AppBar(
        title: const Text('Payroll', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // Pay type badge
          if (_payType.isNotEmpty && !_isLoading)
            Center(
              child: Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _payType == 'hourly' ? const Color(0xFF3B6FE8) : const Color(0xFF00BFA5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _payType == 'hourly' ? '₱${_currencyFormat.format(_rate)}/hr' : '₱${_currencyFormat.format(_salary)}/mo',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF3B6FE8)))
          : _error != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _fetchPayroll,
                  color: const Color(0xFF3B6FE8),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _buildYearSelector(),
                      const SizedBox(height: 16),
                      _buildAnnualSummary(),
                      const SizedBox(height: 20),
                      ..._buildMonthCards(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white38, size: 48),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _fetchPayroll,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B6FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearSelector() {
    final currentYear = DateTime.now().year;
    final years = List.generate(5, (i) => currentYear - i);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white70),
          onPressed: () {
            setState(() => _selectedYear--);
            _fetchPayroll();
          },
        ),
        GestureDetector(
          onTap: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('Select Year'),
                children: years.map((y) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, y),
                  child: Text('$y', style: TextStyle(
                    fontWeight: y == _selectedYear ? FontWeight.bold : FontWeight.normal,
                    color: y == _selectedYear ? const Color(0xFF3B6FE8) : null,
                    fontSize: 16,
                  )),
                )).toList(),
              ),
            );
            if (picked != null && picked != _selectedYear) {
              setState(() => _selectedYear = picked);
              _fetchPayroll();
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_today, color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                Text('$_selectedYear', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 20),
              ],
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Colors.white70),
          onPressed: () {
            setState(() => _selectedYear++);
            _fetchPayroll();
          },
        ),
      ],
    );
  }

  Widget _buildAnnualSummary() {
    return Container(
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart_rounded, color: Colors.white70, size: 20),
              const SizedBox(width: 8),
              Text('$_selectedYear Annual Summary', style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 16),
          _summaryRow('Gross Pay', _totalGross, Colors.white),
          const SizedBox(height: 8),
          _summaryRow('Total Deductions', _totalDeductions, const Color(0xFFFF7043)),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white24, height: 1),
          ),
          _summaryRow('Net Pay', _totalNet, const Color(0xFF69F0AE)),
          const SizedBox(height: 14),
          Row(
            children: [
              _summaryChip(Icons.calendar_today, '${_totalDays.toStringAsFixed(0)} days'),
              const SizedBox(width: 12),
              _summaryChip(Icons.access_time, '${_totalHours.toStringAsFixed(1)} hrs'),
              const SizedBox(width: 12),
              _summaryChip(Icons.receipt_long, '${_payslips.length} months'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, double amount, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Text('₱${_currencyFormat.format(amount)}', style: TextStyle(color: valueColor, fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _summaryChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white54, size: 12),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }

  List<Widget> _buildMonthCards() {
    if (_payslips.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(
            child: Column(
              children: [
                const Icon(Icons.receipt_long_outlined, color: Colors.white24, size: 48),
                const SizedBox(height: 12),
                Text('No payslips for $_selectedYear', style: const TextStyle(color: Colors.white38, fontSize: 14)),
              ],
            ),
          ),
        ),
      ];
    }

    return List.generate(_payslips.length, (i) {
      final p = _payslips[i];
      final isExpanded = _expandedIndices.contains(i);
      final monthName = p['month_name'] ?? '';
      final gross = (p['gross'] ?? 0).toDouble();
      final net = (p['net'] ?? 0).toDouble();
      final totalDed = (p['total_deductions'] ?? 0).toDouble();
      final days = (p['days_worked'] ?? 0);
      final hours = (p['hours'] ?? 0).toDouble();
      final sss = (p['sss'] ?? 0).toDouble();
      final philhealth = (p['philhealth'] ?? 0).toDouble();
      final pagibig = (p['pagibig'] ?? 0).toDouble();
      final withholdingTax = (p['withholding_tax'] ?? (totalDed - sss - philhealth - pagibig)).toDouble();

      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GestureDetector(
          onTap: () => setState(() {
            if (isExpanded) {
              _expandedIndices.remove(i);
            } else {
              _expandedIndices.add(i);
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              color: const Color(0xFF232A3E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isExpanded ? const Color(0xFF3B6FE8).withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                // Header row — always visible
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // Month icon
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B6FE8).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            monthName.split(' ').first.substring(0, 3).toUpperCase(),
                            style: const TextStyle(color: Color(0xFF3B6FE8), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(monthName, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('$days days  ·  ${hours.toStringAsFixed(1)} hrs', style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('₱${_currencyFormat.format(net)}', style: const TextStyle(color: Color(0xFF69F0AE), fontSize: 15, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text('net pay', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10)),
                        ],
                      ),
                      const SizedBox(width: 8),
                      AnimatedRotation(
                        turns: isExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Icon(Icons.keyboard_arrow_down, color: Colors.white.withValues(alpha: 0.3), size: 22),
                      ),
                    ],
                  ),
                ),

                // Expanded details
                AnimatedCrossFade(
                  firstChild: const SizedBox.shrink(),
                  secondChild: _buildExpandedDetails(gross, sss, philhealth, pagibig, withholdingTax, totalDed, net, days, hours),
                  crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 250),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildExpandedDetails(double gross, double sss, double philhealth, double pagibig, double tax, double totalDed, double net, dynamic days, double hours) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
          const SizedBox(height: 14),

          // Earnings section
          _sectionHeader('Earnings', Icons.trending_up, const Color(0xFF3B6FE8)),
          const SizedBox(height: 8),
          _detailRow('Gross Pay', gross, Colors.white),
          if (_payType == 'hourly')
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(
                '${hours.toStringAsFixed(1)} hrs × ₱${_currencyFormat.format(_rate)}',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11),
              ),
            ),
          const SizedBox(height: 14),

          // Deductions section
          _sectionHeader('Deductions', Icons.remove_circle_outline, const Color(0xFFFF7043)),
          const SizedBox(height: 8),
          _deductionRow('SSS', sss, const Color(0xFF42A5F5)),
          _deductionRow('PhilHealth', philhealth, const Color(0xFF66BB6A)),
          _deductionRow('Pag-IBIG', pagibig, const Color(0xFFFFCA28)),
          if (tax > 0.01)
            _deductionRow('Withholding Tax', tax, const Color(0xFFEF5350)),
          const SizedBox(height: 4),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
          const SizedBox(height: 4),
          _detailRow('Total Deductions', totalDed, const Color(0xFFFF7043)),
          const SizedBox(height: 14),

          // Net pay highlight
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF69F0AE).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF69F0AE).withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Net Pay', style: TextStyle(color: Color(0xFF69F0AE), fontSize: 14, fontWeight: FontWeight.w600)),
                Text('₱${_currencyFormat.format(net)}', style: const TextStyle(color: Color(0xFF69F0AE), fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 6),
        Text(title, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      ],
    );
  }

  Widget _detailRow(String label, double amount, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
          Text('₱${_currencyFormat.format(amount)}', style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _deductionRow(String label, double amount, Color dotColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13))),
          Text('- ₱${_currencyFormat.format(amount)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
        ],
      ),
    );
  }
}
