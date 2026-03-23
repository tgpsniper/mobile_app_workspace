import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'websocket_service.dart';

class ProfilePage extends StatefulWidget {
  final String email;
  final String? displayName;

  const ProfilePage({super.key, required this.email, this.displayName});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const String _apiBase = 'https://workspace.jedapps.com/api';
  static const String _authToken = 'ws-fusion-2026-token';

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditing = false;
  Map<String, dynamic> _employee = {};
  String? _contactUuid;
  File? _profileImage;
  final _picker = ImagePicker();
  StreamSubscription? _employeeChangeSub;

  // Edit controllers
  final _nameGivenCtrl = TextEditingController();
  final _nameFamilyCtrl = TextEditingController();
  final _organizationCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _employeeIdCtrl = TextEditingController();
  final _dateHiredCtrl = TextEditingController();
  final _employmentTypeCtrl = TextEditingController();
  final _employmentStatusCtrl = TextEditingController();
  final _tinCtrl = TextEditingController();
  final _sssCtrl = TextEditingController();
  final _philhealthCtrl = TextEditingController();
  final _pagibigCtrl = TextEditingController();
  final _emergNameCtrl = TextEditingController();
  final _emergRelCtrl = TextEditingController();
  final _emergPhoneCtrl = TextEditingController();
  final _emergAddressCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfileImage();
    _fetchProfile();
    // Listen for real-time employee changes and auto-refresh
    _employeeChangeSub = WebSocketService().employeeChangeStream.listen((msg) {
      final changedUuid = msg['uuid']?.toString();
      if (changedUuid != null && changedUuid == _contactUuid && !_isEditing) {
        debugPrint('[Profile] Employee changed via WebSocket — refreshing');
        _fetchProfile();
      }
    });
  }

  @override
  void dispose() {
    _nameGivenCtrl.dispose();
    _nameFamilyCtrl.dispose();
    _organizationCtrl.dispose();
    _titleCtrl.dispose();
    _categoryCtrl.dispose();
    _phoneCtrl.dispose();
    _nicknameCtrl.dispose();
    _employeeIdCtrl.dispose();
    _dateHiredCtrl.dispose();
    _employmentTypeCtrl.dispose();
    _employmentStatusCtrl.dispose();
    _tinCtrl.dispose();
    _sssCtrl.dispose();
    _philhealthCtrl.dispose();
    _pagibigCtrl.dispose();
    _emergNameCtrl.dispose();
    _emergRelCtrl.dispose();
    _emergPhoneCtrl.dispose();
    _emergAddressCtrl.dispose();
    _employeeChangeSub?.cancel();
    super.dispose();
  }

  Future<void> _loadProfileImage() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/profile_${widget.email}.jpg');
    if (await file.exists()) {
      setState(() => _profileImage = file);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final savedPath = '${dir.path}/profile_${widget.email}.jpg';
    final savedFile = await File(picked.path).copy(savedPath);

    setState(() => _profileImage = savedFile);
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF232A3E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Profile Photo',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFF3B6FE8)),
                title: const Text('Take Photo', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Color(0xFF3B6FE8)),
                title: const Text('Choose from Gallery', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
              if (_profileImage != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Remove Photo', style: TextStyle(color: Colors.redAccent)),
                  onTap: () async {
                    Navigator.pop(context);
                    if (_profileImage != null && await _profileImage!.exists()) {
                      await _profileImage!.delete();
                    }
                    setState(() => _profileImage = null);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Helper accessors for nested employee data ---
  Map<String, dynamic> get _employment => _employee['employment'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _govIds => _employee['gov_ids'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _emergencyContact => _employee['emergency_contact'] as Map<String, dynamic>? ?? {};

  String get _fullName {
    final given = _valRaw(_employee['contact_name_given']);
    final family = _valRaw(_employee['contact_name_family']);
    if (given.isEmpty && family.isEmpty) return '';
    return '$given $family'.trim();
  }

  // --- REST API: Fetch profile ---
  Future<void> _fetchProfile() async {
    setState(() => _isLoading = true);
    try {
      // Step 1: Find the employee UUID by listing all employees and matching email
      if (_contactUuid == null) {
        final listResp = await http.get(
          Uri.parse('$_apiBase/employees'),
          headers: {'Authorization': 'Bearer $_authToken'},
        );
        if (listResp.statusCode == 200) {
          final data = jsonDecode(listResp.body) as Map<String, dynamic>;
          if (data['ok'] == true) {
            final employees = data['employees'] as List<dynamic>? ?? [];
            for (final emp in employees) {
              if (emp['email'] == widget.email) {
                _contactUuid = emp['contact_uuid'];
                break;
              }
            }
          }
        }
        debugPrint('[Profile] Found UUID: $_contactUuid for ${widget.email}');
      }

      // Step 2: Fetch full employee details
      if (_contactUuid != null) {
        final detailResp = await http.get(
          Uri.parse('$_apiBase/employees/$_contactUuid'),
          headers: {'Authorization': 'Bearer $_authToken'},
        );
        if (detailResp.statusCode == 200) {
          final data = jsonDecode(detailResp.body) as Map<String, dynamic>;
          debugPrint('[Profile] API response: ${detailResp.body.substring(0, detailResp.body.length > 500 ? 500 : detailResp.body.length)}');
          if (data['ok'] == true && data['employee'] != null) {
            _employee = Map<String, dynamic>.from(data['employee']);
          }
        }
      }
    } catch (e) {
      debugPrint('[Profile] Error fetching profile: $e');
    }

    if (mounted) setState(() => _isLoading = false);
  }

  // --- REST API: Save profile ---
  void _startEditing() {
    _nameGivenCtrl.text = _valRaw(_employee['contact_name_given']);
    _nameFamilyCtrl.text = _valRaw(_employee['contact_name_family']);
    _organizationCtrl.text = _valRaw(_employee['contact_organization']).isEmpty ? 'J2 Network' : _valRaw(_employee['contact_organization']);
    _titleCtrl.text = _valRaw(_employee['contact_title']);
    _categoryCtrl.text = _valRaw(_employee['contact_category']);
    _phoneCtrl.text = _valRaw(_employee['phone']);
    _nicknameCtrl.text = _valRaw(_employee['contact_nickname']);
    _employeeIdCtrl.text = _valRaw(_employment['employee_id']);
    _dateHiredCtrl.text = _valRaw(_employment['date_hired']);
    _employmentTypeCtrl.text = _valRaw(_employment['employment_type']);
    _employmentStatusCtrl.text = _valRaw(_employment['employment_status']);
    _tinCtrl.text = _valRaw(_govIds['tin']);
    _sssCtrl.text = _valRaw(_govIds['sss']);
    _philhealthCtrl.text = _valRaw(_govIds['philhealth']);
    _pagibigCtrl.text = _valRaw(_govIds['pagibig']);
    _emergNameCtrl.text = _valRaw(_emergencyContact['name']);
    _emergRelCtrl.text = _valRaw(_emergencyContact['relationship']);
    _emergPhoneCtrl.text = _valRaw(_emergencyContact['phone']);
    _emergAddressCtrl.text = _valRaw(_emergencyContact['address']);
    setState(() => _isEditing = true);
  }

  Future<void> _saveProfile() async {
    setState(() => _isSaving = true);

    try {
      final body = {
        'contact_name_given': _nameGivenCtrl.text.trim(),
        'contact_name_family': _nameFamilyCtrl.text.trim(),
        'contact_organization': _organizationCtrl.text.trim(),
        'contact_title': _titleCtrl.text.trim(),
        'contact_category': _categoryCtrl.text.trim(),
        'contact_nickname': _nicknameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'employment': {
          'employee_id': _employeeIdCtrl.text.trim(),
          'date_hired': _dateHiredCtrl.text.trim(),
          'employment_type': _employmentTypeCtrl.text.trim(),
          'employment_status': _employmentStatusCtrl.text.trim(),
        },
        'gov_ids': {
          'tin': _tinCtrl.text.trim(),
          'sss': _sssCtrl.text.trim(),
          'philhealth': _philhealthCtrl.text.trim(),
          'pagibig': _pagibigCtrl.text.trim(),
        },
        'emergency_contact': {
          'name': _emergNameCtrl.text.trim(),
          'relationship': _emergRelCtrl.text.trim(),
          'phone': _emergPhoneCtrl.text.trim(),
          'address': _emergAddressCtrl.text.trim(),
        },
      };

      debugPrint('[Profile] PUT /api/employees/$_contactUuid body: ${jsonEncode(body)}');

      final response = await http.put(
        Uri.parse('$_apiBase/employees/$_contactUuid'),
        headers: {
          'Authorization': 'Bearer $_authToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      debugPrint('[Profile] PUT response (${response.statusCode}): ${response.body}');

      if (mounted) {
        if (response.statusCode == 200) {
          setState(() {
            _isEditing = false;
            _isSaving = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Profile updated successfully'),
              backgroundColor: Color(0xFF00BFA5),
              behavior: SnackBarBehavior.floating,
            ),
          );
          _fetchProfile();
        } else {
          setState(() => _isSaving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: ${response.statusCode} — ${response.body}'),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _val(dynamic value) {
    if (value == null) return '--';
    final s = value.toString().trim();
    return s.isEmpty ? '--' : s;
  }

  String _valRaw(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final name = _fullName.isEmpty
        ? (widget.displayName ?? widget.email)
        : _fullName;
    final initials = name.split(' ').where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).take(2).join();

    return Scaffold(
      backgroundColor: const Color(0xFF1A2035),
      appBar: AppBar(
        title: const Text('My Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isEditing) ...[
            TextButton(
              onPressed: () => setState(() => _isEditing = false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: _isSaving ? null : _saveProfile,
              child: _isSaving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save', style: TextStyle(color: Color(0xFF3B6FE8), fontWeight: FontWeight.bold)),
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: _isLoading ? null : _startEditing,
              tooltip: 'Edit Profile',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _fetchProfile,
              tooltip: 'Refresh',
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF3B6FE8)))
          : RefreshIndicator(
              onRefresh: _fetchProfile,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildProfileHeader(name, initials),
                    const SizedBox(height: 16),
                    _buildPersonalInfo(),
                    const SizedBox(height: 12),
                    _buildEmploymentDetails(),
                    const SizedBox(height: 12),
                    _buildGovernmentIds(),
                    const SizedBox(height: 12),
                    _buildEmergencyContact(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildProfileHeader(String name, String initials) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF232A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _showImagePickerOptions,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: const Color(0xFF00BFA5),
                  backgroundImage: _profileImage != null ? FileImage(_profileImage!) : null,
                  child: _profileImage == null
                      ? Text(initials, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold))
                      : null,
                ),
                Positioned(
                  right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B6FE8),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF232A3E), width: 2),
                    ),
                    child: const Icon(Icons.camera_alt, color: Colors.white, size: 14),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isEditing)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameGivenCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          decoration: _editDecoration('First Name'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _nameFamilyCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          decoration: _editDecoration('Last Name'),
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    name,
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                const SizedBox(height: 4),
                Text(
                  _val(_employee['contact_title']) == '--' ? 'No title set' : _val(_employee['contact_title']),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _val(_employee['contact_role']).toUpperCase(),
                    style: const TextStyle(color: Color(0xFF00BFA5), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalInfo() {
    return _buildSection(
      icon: Icons.person,
      title: 'Personal Information',
      children: _isEditing
          ? [
              _buildEditField('ORGANIZATION', _organizationCtrl),
              _buildEditField('TITLE', _titleCtrl),
              _buildEditField('DEPARTMENT', _categoryCtrl),
              _buildReadOnlyField('EMAIL', _val(_employee['email'])),
              _buildEditField('PHONE', _phoneCtrl, TextInputType.phone),
              _buildEditField('NICKNAME', _nicknameCtrl),
            ]
          : [
              _buildFieldRow('ORGANIZATION', _val(_employee['contact_organization'])),
              _buildFieldRow('TITLE', _val(_employee['contact_title'])),
              _buildFieldRow('DEPARTMENT', _val(_employee['contact_category'])),
              _buildFieldRow('EMAIL', _val(_employee['email'])),
              _buildFieldRow('PHONE', _val(_employee['phone'])),
              _buildFieldRow('NICKNAME', _val(_employee['contact_nickname'])),
            ],
    );
  }

  Widget _buildEmploymentDetails() {
    return _buildSection(
      icon: Icons.work_outline,
      title: 'Employment Details',
      children: _isEditing
          ? [
              Row(children: [
                Expanded(child: _buildEditField('EMPLOYEE ID', _employeeIdCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('DATE HIRED', _dateHiredCtrl)),
              ]),
              Row(children: [
                Expanded(child: _buildEditField('EMPLOYMENT TYPE', _employmentTypeCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('STATUS', _employmentStatusCtrl)),
              ]),
            ]
          : [
              _buildTwoColumn('EMPLOYEE ID', _val(_employment['employee_id']), 'DATE HIRED', _val(_employment['date_hired'])),
              _buildTwoColumn('EMPLOYMENT TYPE', _val(_employment['employment_type']), 'STATUS', _val(_employment['employment_status'])),
            ],
    );
  }

  Widget _buildGovernmentIds() {
    return _buildSection(
      icon: Icons.account_balance,
      title: 'Government IDs',
      children: _isEditing
          ? [
              Row(children: [
                Expanded(child: _buildEditField('TIN', _tinCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('SSS NUMBER', _sssCtrl)),
              ]),
              Row(children: [
                Expanded(child: _buildEditField('PHILHEALTH', _philhealthCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('PAG-IBIG / HDMF', _pagibigCtrl)),
              ]),
            ]
          : [
              _buildTwoColumn('TIN', _val(_govIds['tin']), 'SSS NUMBER', _val(_govIds['sss'])),
              _buildTwoColumn('PHILHEALTH', _val(_govIds['philhealth']), 'PAG-IBIG / HDMF', _val(_govIds['pagibig'])),
            ],
    );
  }

  Widget _buildEmergencyContact() {
    return _buildSection(
      icon: Icons.phone_in_talk,
      title: 'Emergency Contact',
      children: _isEditing
          ? [
              Row(children: [
                Expanded(child: _buildEditField('NAME', _emergNameCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('RELATIONSHIP', _emergRelCtrl)),
              ]),
              Row(children: [
                Expanded(child: _buildEditField('PHONE', _emergPhoneCtrl, TextInputType.phone)),
                const SizedBox(width: 12),
                Expanded(child: _buildEditField('ADDRESS', _emergAddressCtrl)),
              ]),
            ]
          : [
              _buildTwoColumn('NAME', _val(_emergencyContact['name']), 'RELATIONSHIP', _val(_emergencyContact['relationship'])),
              _buildTwoColumn('PHONE', _val(_emergencyContact['phone']), 'ADDRESS', _val(_emergencyContact['address'])),
            ],
    );
  }

  // --- UI Building Blocks ---

  InputDecoration _editDecoration(String hint) {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF3B6FE8))),
      hintText: hint,
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
    );
  }

  Widget _buildSection({required IconData icon, required String title, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF232A3E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF3B6FE8), size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildFieldRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.4), letterSpacing: 0.8)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
        ],
      ),
    );
  }

  Widget _buildReadOnlyField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.4), letterSpacing: 0.8)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
        ],
      ),
    );
  }

  Widget _buildEditField(String label, TextEditingController controller, [TextInputType? keyboardType]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.4), letterSpacing: 0.8)),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF3B6FE8)),
              ),
              hintText: 'Enter $label',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 13, fontWeight: FontWeight.normal),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoColumn(String label1, String value1, String label2, String value2) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label1, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.4), letterSpacing: 0.8)),
                const SizedBox(height: 4),
                Text(value1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label2, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.4), letterSpacing: 0.8)),
                const SizedBox(height: 4),
                Text(value2, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}