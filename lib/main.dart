import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'screens/admin/admin_dashboard.dart';

const apiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://zbin123xgmailc-001-site1.ktempurl.com',
);
const storage = FlutterSecureStorage();

Future<double?> sampleMotionMagnitude() async {
  try {
    final event = await userAccelerometerEventStream().first.timeout(
      const Duration(milliseconds: 800),
    );
    return math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
  } catch (_) {
    return null;
  }
}

void main() {
  if (kReleaseMode && !_isPublicHttpsApi(apiUrl)) {
    runApp(const _ApiUrlRequiredApp());
    return;
  }
  runApp(const AttendanceApp());
}

bool _isPublicHttpsApi(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || !uri.hasAuthority || uri.host.isEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'api.example.com' ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.internal')) {
    return false;
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return false;
    if (ip.rawAddress.every((byte) => byte == 0)) return false;
    if (ip.type == InternetAddressType.IPv4) {
      final octets = ip.rawAddress;
      if (octets[0] == 10 ||
          (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
          (octets[0] == 192 && octets[1] == 168)) {
        return false;
      }
    } else if ((ip.rawAddress.first & 0xfe) == 0xfc) {
      return false;
    }
  }
  return true;
}

class _ApiUrlRequiredApp extends StatelessWidget {
  const _ApiUrlRequiredApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Cần build lại ứng dụng với URL HTTPS public của API bằng --dart-define=API_BASE_URL=https://ten-mien-api.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}

class Api {
  static Map<String, String> headers({String? token}) => {
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };
  static Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final response = await http
        .post(
          Uri.parse('$apiUrl$path'),
          headers: headers(token: token),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        data['message'] ?? 'Lỗi máy chủ (${response.statusCode})',
      );
    }
    return data;
  }

  static Future<dynamic> get(String path, {String? token}) async {
    final response = await http
        .get(
          Uri.parse('$apiUrl$path'),
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 20));
    final data = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        data is Map
            ? data['message'] ?? 'Lỗi máy chủ'
            : 'Lỗi máy chủ (${response.statusCode})',
      );
    }
    return data;
  }

  static Future<dynamic> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$apiUrl$path');
    final request = http.Request(method, uri)
      ..headers.addAll(headers(token: token));
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send().timeout(const Duration(seconds: 20));
    final response = await http.Response.fromStream(streamed);
    final data = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        data is Map
            ? data['message'] ?? 'Lỗi máy chủ'
            : 'Lỗi máy chủ (${response.statusCode})',
      );
    }
    return data;
  }
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'N7 Chấm công',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff176b5b),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f7f6),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
      ),
    ),
    home: const SessionGate(),
  );
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late Future<bool> session;
  @override
  void initState() {
    super.initState();
    session = validateSession();
  }

  Future<bool> validateSession() async {
    try {
      final token = await storage.read(key: 'access_token');
      if (token == null) return false;
      final profile = await Api.get('/api/auth/me', token: token);
      await storage.write(key: 'role', value: profile['role']);
      await storage.write(key: 'full_name', value: profile['fullName']);
      return true;
    } catch (_) {
      await storage.deleteAll();
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: session,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return snapshot.data == true ? const HomeScreen() : const AuthScreen();
    },
  );
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool busy = false, otpStage = false, obscure = true;
  final username = TextEditingController(),
      password = TextEditingController(),
      otp = TextEditingController();
  String message = '';
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    otp.dispose();
    super.dispose();
  }

  Future<void> resendOtp() async {
    if (username.text.trim().length < 3) {
      setState(() => message = 'Nhập username để gửi lại mã OTP.');
      return;
    }
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final result = await Api.post('/api/auth/resend-otp', {
        'username': username.text.trim(),
      });
      otp.clear();
      if (mounted) {
        setState(() => message = result['message'] ?? 'Đã gửi mã OTP mới.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (otpStage &&
        (otp.text.trim().length != 6 ||
            !RegExp(r'^\d{6}$').hasMatch(otp.text.trim()))) {
      setState(() => message = 'Mã OTP cần gồm đúng 6 chữ số.');
      return;
    }
    if (!otpStage &&
        (username.text.trim().length < 3 || password.text.length < 10)) {
      setState(
        () => message = 'Nhập username hợp lệ và mật khẩu tối thiểu 10 ký tự.',
      );
      return;
    }
    setState(() {
      busy = true;
      message = '';
    });
    try {
      if (otpStage) {
        final result = await Api.post('/api/auth/verify-otp', {
          'username': username.text.trim(),
          'code': otp.text.trim(),
        });
        await storage.write(key: 'access_token', value: result['accessToken']);
        await storage.write(key: 'role', value: result['role']);
        await storage.write(key: 'full_name', value: result['fullName']);
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        }
      } else {
        final result = await Api.post('/api/auth/login', {
          'username': username.text.trim(),
          'password': password.text,
        });
        setState(() => otpStage = true);
        message = result['message'] ?? 'Nhập mã OTP đã gửi đến email của bạn.';
      }
    } catch (e) {
      setState(() => message = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 22),
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xffd9eee7),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.fact_check_rounded,
                    size: 38,
                    color: Color(0xff176b5b),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  otpStage
                      ? 'Xác minh email'
                      : 'Chấm công Nhóm 7',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  otpStage
                      ? 'Nhập mã 6 chữ số đã gửi đến email của bạn.'
                      : 'Trần Xuân Thanh · 2380614806',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 28),
                if (!otpStage)
                  TextField(
                    controller: username,
                    decoration: const InputDecoration(
                      labelText: 'Tên đăng nhập',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  ),
                if (!otpStage) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Mật khẩu',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => obscure = !obscure),
                      ),
                    ),
                  ),
                ] else
                  TextField(
                    controller: otp,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'Mã OTP',
                      prefixIcon: Icon(Icons.verified_user_outlined),
                    ),
                  ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    message,
                    style: TextStyle(
                      color: message.contains('đã được gửi')
                          ? const Color(0xff176b5b)
                          : Colors.red.shade700,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: busy ? null : submit,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                  label: Text(
                    otpStage
                        ? 'Xác minh và đăng nhập'
                        : 'Đăng nhập',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                if (otpStage) ...[
                  TextButton.icon(
                    onPressed: busy ? null : resendOtp,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Gửi lại mã OTP'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            otpStage = false;
                            otp.clear();
                            message = '';
                          }),
                    child: const Text('Quay lại đăng nhập'),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  'Máy chủ: $apiUrl',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int index = 0;
  String name = 'Nhân viên';
  String role = 'Employee';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    name = await storage.read(key: 'full_name') ?? name;
    role = await storage.read(key: 'role') ?? role;
    if (mounted) setState(() {});
  }

  Future<void> logout() async {
    await storage.deleteAll();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(name: name, role: role),
      const HistoryPage(),
      ToolsPage(role: role),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'N7 Chấm công',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            onPressed: logout,
            tooltip: 'Đăng xuất',
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: pages[index],
      bottomNavigationBar: role == 'Admin'
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (v) => setState(() => index = v),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Tổng quan',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history),
                  label: 'Lịch sử',
                ),
                NavigationDestination(
                  icon: Icon(Icons.widgets_outlined),
                  label: 'Tiện ích',
                ),
              ],
            ),
    );
  }
}

class ActiveAttendanceQrPanel extends StatefulWidget {
  const ActiveAttendanceQrPanel({
    super.key,
    required this.isAdmin,
    this.onCheckIn,
  });

  final bool isAdmin;
  final Future<void> Function(String token)? onCheckIn;

  @override
  State<ActiveAttendanceQrPanel> createState() => _ActiveAttendanceQrPanelState();
}

class _ActiveAttendanceQrPanelState extends State<ActiveAttendanceQrPanel> {
  Timer? timer;
  Map<String, dynamic>? session;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final token = await storage.read(key: 'access_token');
      final data = await Api.get('/api/attendance/qr-session/active', token: token);
      if (!mounted) return;
      setState(() {
        session = data as Map<String, dynamic>;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = session?['active'] == true;
    final qr = active ? (session?['token'] as String?) : null;
    final nextStarts = session?['nextStartsAtUtc'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(active ? Icons.qr_code_2 : Icons.schedule),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active ? 'QR chấm công đang mở' : 'QR chấm công',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(onPressed: refresh, tooltip: 'Làm mới QR', icon: const Icon(Icons.refresh)),
              ],
            ),
            if (qr != null) ...[
              const Text('Mã được cập nhật tự động trong thời gian đã đặt.'),
              const SizedBox(height: 12),
              Center(child: QrImageView(data: qr, size: 220, backgroundColor: Colors.white)),
              if (!widget.isAdmin && widget.onCheckIn != null) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: loading ? null : () => widget.onCheckIn!(qr),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Chấm công bằng QR'),
                ),
              ],
            ] else if (nextStarts != null) ...[
              Text('Mã sẽ tự xuất hiện lúc ${DateTime.parse(nextStarts).toLocal().toString().substring(0, 16)}.'),
            ] else if (error != null) ...[
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ] else ...[
              const Text('Chưa có lịch QR đang mở.'),
            ],
          ],
        ),
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.name, required this.role});
  final String name, role;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool busy = false;
  String status = 'Chưa chấm công';
  Future<void> mark(String action, {String? qrToken}) async {
    setState(() => busy = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Cần cấp quyền vị trí để chấm công.');
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Hãy bật GPS trên điện thoại.');
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final token = await storage.read(key: 'access_token');
      final motion = await sampleMotionMagnitude();
      final r = await Api.post('/api/attendance/mark', {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'action': action,
        'qrToken': qrToken,
        'motionMagnitude': motion,
      }, token: token);
      setState(() => status = r['message'] ?? 'Đã ghi nhận');
    } catch (e) {
      setState(() => status = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.role == 'Admin') {
      return AdminDashboard(
        onEmployees: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AdminEmployeesPage()),
        ),
        onAttendances: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AdminAttendancesPage()),
        ),
        onQrSchedule: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const QrSchedulePage()),
        ),
        onProfile: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProfilePage()),
        ),
        onWorkLocations: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WorkLocationsPage()),
        ),
        qrPanel: const ActiveAttendanceQrPanel(isAdmin: true),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xff176b5b), Color(0xff2e9278)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Xin chào, ${widget.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                widget.role == 'Admin' ? 'Quản trị viên' : 'Nhân viên · Nhóm 7',
                style: TextStyle(color: Colors.white.withValues(alpha: .8)),
              ),
              const SizedBox(height: 24),
              Text(
                TimeOfDay.now().format(context),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                DateTime.now().toLocal().toString().substring(0, 10),
                style: TextStyle(color: Colors.white.withValues(alpha: .85)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (widget.role == 'Admin')
          const _AdminOverview()
        else
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chấm công hôm nay',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(status),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: busy ? null : () => mark('check-in'),
                          icon: const Icon(Icons.login),
                          label: const Text('Check-in'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : () => mark('check-out'),
                          icon: const Icon(Icons.logout),
                          label: const Text('Check-out'),
                        ),
                      ),
                    ],
                  ),
                  if (busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        if (widget.role != 'Admin')
          ActiveAttendanceQrPanel(
            isAdmin: false,
            onCheckIn: (token) => mark('check-in', qrToken: token),
          ),
        const SizedBox(height: 8),
        Text(
          'Tính năng',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: [
            _FeatureTile(
              icon: Icons.location_on_outlined,
              title: 'Vị trí GPS',
              subtitle: 'Xác minh tại nơi làm việc',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GpsPage()),
              ),
            ),
            if (widget.role != 'Admin')
              _FeatureTile(
                icon: Icons.qr_code_scanner,
                title: 'Quét QR',
                subtitle: 'Quét mã trong giờ chấm công',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const QrPage()),
                ),
              ),
            _FeatureTile(
              icon: Icons.sensors,
              title: 'Cảm biến',
              subtitle: 'Demo chuyển động',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SensorPage()),
              ),
            ),
            if (widget.role != 'Admin')
              _FeatureTile(
                icon: Icons.calendar_month_outlined,
                title: 'Lịch làm việc',
                subtitle: 'Ca của bạn trong 30 ngày',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SchedulePage()),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.people_alt_outlined,
                title: 'Nhân viên',
                subtitle: 'Tài khoản và trạng thái',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AdminEmployeesPage()),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.work_history_outlined,
                title: 'Ca làm',
                subtitle: 'Tạo và quản lý ca',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AdminShiftsPage()),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.fact_check_outlined,
                title: 'Chấm công',
                subtitle: 'Xem và hủy bản ghi',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminAttendancesPage(),
                  ),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.qr_code_2,
                title: 'Tạo mã QR',
                subtitle: 'Đặt ngày và giờ tự mở mã',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const QrSchedulePage()),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.warning_amber,
                title: 'Cảnh báo',
                subtitle: 'Rà soát bất thường',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AlertPage()),
                ),
              ),
            if (widget.role == 'Admin')
              _FeatureTile(
                icon: Icons.edit_calendar_outlined,
                title: 'Yêu cầu điều chỉnh',
                subtitle: 'Duyệt yêu cầu nhân viên',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminAdjustmentRequestsPage(),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AdminOverview extends StatelessWidget {
  const _AdminOverview();
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: storage
        .read(key: 'access_token')
        .then((token) => Api.get('/api/admin/overview', token: token)),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      if (snapshot.hasError) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(snapshot.error.toString()),
          ),
        );
      }
      final data = snapshot.data as Map<String, dynamic>;
      final stats = [
        ('Nhân viên', data['activeEmployees'], Icons.people_alt_outlined),
        ('Ca đang mở', data['activeShifts'], Icons.work_history_outlined),
        ('Lượt hôm nay', data['attendancesToday'], Icons.fact_check_outlined),
        (
          'Cảnh báo hôm nay',
          data['pendingAlerts'],
          Icons.warning_amber_outlined,
        ),
      ];
      return Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tổng quan hôm nay',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: stats
                    .map(
                      (x) => SizedBox(
                        width: 145,
                        child: ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          leading: Icon(x.$3, color: const Color(0xff176b5b)),
                          title: Text(
                            '${x.$2}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 19,
                            ),
                          ),
                          subtitle: Text(x.$1),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xff176b5b), size: 27),
            const Spacer(),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    ),
  );
}

class GpsPage extends StatefulWidget {
  const GpsPage({super.key});
  @override
  State<GpsPage> createState() => _GpsPageState();
}

class _GpsPageState extends State<GpsPage> {
  String result = 'Chưa đọc vị trí';
  Future<void> read() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('GPS đang tắt.');
      }
      final x = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      setState(
        () => result =
            'Vĩ độ: ${x.latitude}\nKinh độ: ${x.longitude}\nĐộ chính xác: ±${x.accuracy.toStringAsFixed(0)} m\n\nGửi tọa độ khi check-in để backend so với vùng làm việc.',
      );
    } catch (e) {
      setState(() => result = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Chia sẻ vị trí GPS')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.my_location, size: 65, color: Color(0xff176b5b)),
          const SizedBox(height: 20),
          const Text(
            'Chỉ lấy vị trí khi bạn yêu cầu chấm công.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: read, child: const Text('Đọc GPS thật')),
          const SizedBox(height: 20),
          Text(result, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class SensorPage extends StatefulWidget {
  const SensorPage({super.key});
  @override
  State<SensorPage> createState() => _SensorPageState();
}

class _SensorPageState extends State<SensorPage> {
  StreamSubscription? sub;
  double x = 0, y = 0, z = 0;
  @override
  void initState() {
    super.initState();
    sub = userAccelerometerEventStream().listen(
      (e) => setState(() {
        x = e.x;
        y = e.y;
        z = e.z;
      }),
      onError: (_) => setState(() => x = double.nan),
    );
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final magnitude = math.sqrt(x * x + y * y + z * z);
    return Scaffold(
      appBar: AppBar(title: const Text('Cảm biến chuyển động')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sensors, size: 70, color: Color(0xff176b5b)),
              const SizedBox(height: 16),
              Text(
                'Gia tốc (m/s²)',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 14),
              Text(
                'X ${x.toStringAsFixed(2)}  ·  Y ${y.toStringAsFixed(2)}  ·  Z ${z.toStringAsFixed(2)}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text('Độ lớn: ${magnitude.toStringAsFixed(2)}'),
              const SizedBox(height: 18),
              const Text(
                'Đây là dữ liệu chuyển động tham khảo, không xác minh danh tính hay chống gian lận tuyệt đối.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QrPage extends StatefulWidget {
  const QrPage({super.key, this.admin = false});
  final bool admin;
  @override
  State<QrPage> createState() => _QrPageState();
}

class _QrPageState extends State<QrPage> {
  String? qr;
  String message = '';
  bool busy = false, processing = false;

  Future<void> createQr() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final token = await storage.read(key: 'access_token');
      final result = await Api.post('/api/admin/qr-token', {}, token: token);
      setState(() {
        qr = result['token'];
        message = 'Mã hết hạn sau 3 phút. Chỉ dùng được một lần.';
      });
    } catch (e) {
      setState(() => message = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> scan(String raw) async {
    if (processing) return;
    processing = true;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Cần cấp quyền vị trí để chấm công.');
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Hãy bật GPS trên điện thoại.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final token = await storage.read(key: 'access_token');
      final motion = await sampleMotionMagnitude();
      final result = await Api.post('/api/attendance/mark', {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'action': 'check-in',
        'qrToken': raw,
        'motionMagnitude': motion,
      }, token: token);
      setState(() => message = result['message'] ?? 'Đã chấm công.');
    } catch (e) {
      setState(() => message = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      processing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.admin ? 'Tạo mã QR chấm công' : 'Quét QR chấm công'),
    ),
    body: widget.admin
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (qr == null)
                    const Icon(
                      Icons.qr_code_2,
                      size: 80,
                      color: Color(0xff176b5b),
                    )
                  else
                    QrImageView(
                      data: qr!,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  const SizedBox(height: 16),
                  if (message.isNotEmpty)
                    Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy ? null : createQr,
                    child: Text(qr == null ? 'Tạo QR mới' : 'Tạo mã tiếp theo'),
                  ),
                ],
              ),
            ),
          )
        : Column(
            children: [
              Expanded(
                child: MobileScanner(
                  onDetect: (capture) {
                    final raw = capture.barcodes.firstOrNull?.rawValue;
                    if (raw != null) scan(raw);
                  },
                  errorBuilder: (context, error) => Center(
                    child: Text('Không thể mở camera: ${error.errorCode}'),
                  ),
                ),
              ),
              if (message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(message, textAlign: TextAlign.center),
                ),
            ],
          ),
  );
}

class WorkLocationsPage extends StatefulWidget {
  const WorkLocationsPage({super.key});

  @override
  State<WorkLocationsPage> createState() => _WorkLocationsPageState();
}

class _WorkLocationsPageState extends State<WorkLocationsPage> {
  late Future<dynamic> future;

  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<dynamic> load() async => Api.get(
    '/api/admin/work-locations',
    token: await storage.read(key: 'access_token'),
  );

  Future<void> reload() async {
    final next = load();
    setState(() => future = next);
    await next;
  }

  Future<void> editLocation([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['name'] ?? '');
    final latitude = TextEditingController(text: current?['latitude']?.toString() ?? '');
    final longitude = TextEditingController(text: current?['longitude']?.toString() ?? '');
    final radius = TextEditingController(text: '20');
    String? error;
    bool gettingGps = false, saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(current == null ? 'Thêm vị trí công ty' : 'Sửa vị trí công ty'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Tên vị trí')),
                  TextField(controller: latitude, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Vĩ độ')),
                  TextField(controller: longitude, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Kinh độ')),
                  TextField(controller: radius, readOnly: true, decoration: const InputDecoration(labelText: 'Bán kính chấm công cố định (mét)')),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: gettingGps ? null : () async {
                        setDialogState(() { gettingGps = true; error = null; });
                        try {
                          var permission = await Geolocator.checkPermission();
                          if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
                          if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) throw Exception('Cần cấp quyền vị trí cho GPS.');
                          if (!await Geolocator.isLocationServiceEnabled()) throw Exception('Hãy bật GPS trên điện thoại.');
                          final position = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
                          latitude.text = position.latitude.toStringAsFixed(7);
                          longitude.text = position.longitude.toStringAsFixed(7);
                        } catch (e) {
                          error = e.toString().replaceFirst('Exception: ', '');
                        } finally {
                          if (dialogContext.mounted) setDialogState(() => gettingGps = false);
                        }
                      },
                      icon: const Icon(Icons.my_location),
                      label: Text(gettingGps ? 'Đang lấy GPS...' : 'Dùng GPS hiện tại của Admin'),
                    ),
                  ),
                  if (error != null) Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext), child: const Text('Hủy')),
            FilledButton(
              onPressed: saving ? null : () async {
                final lat = double.tryParse(latitude.text.trim().replaceAll(',', '.'));
                final lon = double.tryParse(longitude.text.trim().replaceAll(',', '.'));
                final radiusMeters = double.tryParse(radius.text.trim().replaceAll(',', '.'));
                if (name.text.trim().isEmpty || lat == null || lon == null || radiusMeters == null) {
                  setDialogState(() => error = 'Nhập tên, tọa độ và bán kính hợp lệ.');
                  return;
                }
                setDialogState(() { saving = true; error = null; });
                try {
                  final path = current == null ? '/api/admin/work-locations' : '/api/admin/work-locations/${current['id']}';
                  final token = await storage.read(key: 'access_token');
                  await Api.request(current == null ? 'POST' : 'PUT', path, token: token, body: {
                    'name': name.text.trim(),
                    'latitude': lat,
                    'longitude': lon,
                    'radiusMeters': radiusMeters,
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  await reload();
                } catch (e) {
                  if (dialogContext.mounted) setDialogState(() => error = e.toString().replaceFirst('Exception: ', ''));
                } finally {
                  if (dialogContext.mounted) setDialogState(() => saving = false);
                }
              },
              child: Text(saving ? 'Đang lưu...' : 'Lưu'),
            ),
          ],
        ),
      ),
    );
    name.dispose(); latitude.dispose(); longitude.dispose(); radius.dispose();
  }

  Future<void> deleteLocation(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa vị trí GPS?'),
        content: Text('Ngừng dùng “${item['name']}” để tính khoảng cách chấm công? Bản ghi cũ vẫn được giữ.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Giữ lại')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xóa')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Api.request('DELETE', '/api/admin/work-locations/${item['id']}', token: await storage.read(key: 'access_token'));
      await reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Vị trí GPS công ty')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => editLocation(),
      icon: const Icon(Icons.add_location_alt_outlined),
      label: const Text('Thêm vị trí'),
    ),
    body: FutureBuilder(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: Text(snapshot.error.toString()));
        final items = (snapshot.data as List? ?? const []).cast<Map<String, dynamic>>();
        if (items.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Chưa có vị trí GPS công ty. Hãy thêm vị trí để tính khoảng cách khi nhân viên chấm công.', textAlign: TextAlign.center)));
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
            children: [
              const Padding(padding: EdgeInsets.all(8), child: Text('Có thể đứng tại công ty và bấm “Dùng GPS hiện tại của Admin” để điền tọa độ. Vị trí và bán kính được dùng để tính khoảng cách cho các lượt chấm công mới.')),
              ...items.map((item) {
                final radiusMeters = (item['radiusMeters'] as num?)?.toDouble() ?? 20;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.location_on_outlined),
                    title: Text(item['name'] ?? ''),
                    subtitle: Text('GPS: ${item['latitude']}, ${item['longitude']}\nBán kính chấm công: ${radiusMeters.toStringAsFixed(0)} m${item['isLegacyConfig'] == true ? '\nĐang dùng cấu hình vị trí cũ' : ''}'),
                    isThreeLine: true,
                    trailing: Wrap(
                      spacing: 0,
                      children: [
                        IconButton(tooltip: 'Sửa', onPressed: () => editLocation(item), icon: const Icon(Icons.edit_outlined)),
                        IconButton(tooltip: 'Xóa', onPressed: () => deleteLocation(item), icon: const Icon(Icons.delete_outline)),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    ),
  );
}

class QrSchedulePage extends StatefulWidget {
  const QrSchedulePage({super.key});

  @override
  State<QrSchedulePage> createState() => _QrSchedulePageState();
}

class _QrSchedulePageState extends State<QrSchedulePage> {
  DateTime workDate = DateTime.now();
  TimeOfDay startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay endTime = const TimeOfDay(hour: 17, minute: 0);
  Timer? refreshTimer;
  int? sessionId;
  String? qr;
  String message = '';
  bool busy = false, refreshing = false;

  @override
  void initState() {
    super.initState();
    refreshSession();
    refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshSession());
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  DateTime combine(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  Future<void> refreshSession() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final accessToken = await storage.read(key: 'access_token');
      dynamic data = await Api.get('/api/admin/qr-sessions/active', token: accessToken);
      sessionId = data['active'] == true
          ? data['id'] as int
          : data['nextSessionId'] as int?;
      if (sessionId != null) data = await Api.get('/api/admin/qr-sessions/$sessionId', token: accessToken);
      if (!mounted || data == null) return;
      setState(() {
        if (data['active'] == true) {
          qr = data['token'] as String?;
          message = 'Mã QR đang mở. Nhân viên có thể quét đến ${DateTime.parse(data['endsAtUtc']).toLocal()}.';
        } else {
          qr = null;
          final starts = data['startsAtUtc'] ?? data['nextStartsAtUtc'];
          if (starts != null) {
            final localStart = DateTime.parse(starts).toLocal();
            message = 'Lịch QR đã đặt lúc ${localStart.day.toString().padLeft(2, '0')}/${localStart.month.toString().padLeft(2, '0')} ${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}. Mã sẽ tự hiện khi tới giờ.';
          }
        }
      });
    } catch (e) {
      if (mounted && sessionId == null) {
        setState(() => message = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> createSchedule({bool startNow = false}) async {
    final starts = startNow ? DateTime.now() : combine(workDate, startTime);
    final ends = startNow ? starts.add(const Duration(hours: 1)) : combine(workDate, endTime);
    if (!ends.isAfter(starts)) {
      setState(() => message = 'Giờ kết thúc phải sau giờ bắt đầu trong cùng ngày.');
      return;
    }
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final accessToken = await storage.read(key: 'access_token');
      final result = await Api.post('/api/admin/qr-sessions', {
        'startsAtUtc': starts.toUtc().toIso8601String(),
        'endsAtUtc': ends.toUtc().toIso8601String(),
      }, token: accessToken);
      setState(() {
        sessionId = result['id'] as int;
        qr = null;
        message = startNow
            ? 'QR đã tạo và đang mở ngay trong 1 giờ.'
            : 'Đã đặt lịch QR. Mã sẽ tự xuất hiện trong khung giờ đã chọn.';
      });
      await refreshSession();
    } catch (e) {
      setState(() => message = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: workDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked != null) setState(() => workDate = picked);
  }

  Future<void> chooseTime({required bool start}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: start ? startTime : endTime,
    );
    if (picked != null) setState(() => start ? startTime = picked : endTime = picked);
  }

  String dateLabel(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lịch QR chấm công')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.calendar_month_outlined),
                title: const Text('Ngày chấm công'),
                subtitle: Text(dateLabel(workDate)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: chooseDate,
              ),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('Giờ bắt đầu'),
                subtitle: Text(startTime.format(context)),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => chooseTime(start: true),
              ),
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('Giờ kết thúc'),
                subtitle: Text(endTime.format(context)),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => chooseTime(start: false),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: busy ? null : () => createSchedule(startNow: true),
                      icon: const Icon(Icons.qr_code_2),
                      label: Text(busy ? 'Đang tạo QR...' : 'Tạo QR ngay (mở 1 giờ)'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => createSchedule(),
                      icon: const Icon(Icons.schedule),
                      label: Text(busy ? 'Đang tạo lịch...' : 'Đặt lịch QR'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (qr != null)
          Center(
            child: QrImageView(data: qr!, size: 250, backgroundColor: Colors.white),
          )
        else
          const Center(child: Icon(Icons.qr_code_2, size: 100, color: Color(0xff176b5b))),
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(message, textAlign: TextAlign.center),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'Khi mã xuất hiện, nhân viên mở mục Quét QR để chấm công. Mã chỉ hợp lệ trong giờ Admin đã đặt.',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<dynamic> data;
  @override
  void initState() {
    super.initState();
    data = load();
  }

  Future<dynamic> load() async {
    final token = await storage.read(key: 'access_token');
    return Api.get('/api/attendance/mine', token: token);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text(snapshot.error.toString()));
        }
        final items = (snapshot.data as List? ?? []);
        if (items.isEmpty) {
          return const Center(child: Text('Chưa có bản ghi chấm công.'));
        }
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => data = load());
            await data;
          },
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i] as Map<String, dynamic>;
              final date = DateTime.parse(item['checkInUtc']).toLocal();
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                child: ListTile(
                  leading: const Icon(
                    Icons.access_time,
                    color: Color(0xff176b5b),
                  ),
                  title: Text(
                    '${date.day}/${date.month}/${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                  ),
                  subtitle: Text(
                    '${item['status']} · ${item['checkOutUtc'] == null ? 'Chưa check-out' : 'Đã check-out'}',
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AdjustmentRequestPage()),
      ),
      icon: const Icon(Icons.edit_calendar_outlined),
      label: const Text('Xin điều chỉnh'),
    ),
  );
}

class AdjustmentRequestPage extends StatefulWidget {
  const AdjustmentRequestPage({super.key});
  @override
  State<AdjustmentRequestPage> createState() => _AdjustmentRequestPageState();
}

class _AdjustmentRequestPageState extends State<AdjustmentRequestPage> {
  late Future<dynamic> records;
  int? attendanceId;
  bool busy = false;
  final checkIn = TextEditingController(),
      checkOut = TextEditingController(),
      reason = TextEditingController();
  @override
  void initState() {
    super.initState();
    records = load();
  }

  @override
  void dispose() {
    checkIn.dispose();
    checkOut.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<dynamic> load() async => Api.get(
    '/api/attendance/mine',
    token: await storage.read(key: 'access_token'),
  );
  Future<void> submit() async {
    if (attendanceId == null || reason.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chọn bản ghi và nhập lý do.')),
      );
      return;
    }
    final inTime = checkIn.text.trim().isEmpty
        ? null
        : DateTime.tryParse(checkIn.text);
    final outTime = checkOut.text.trim().isEmpty
        ? null
        : DateTime.tryParse(checkOut.text);
    if ((checkIn.text.trim().isNotEmpty && inTime == null) ||
        (checkOut.text.trim().isNotEmpty && outTime == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Thời gian cần theo định dạng ISO, ví dụ 2026-10-29T09:00.',
          ),
        ),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await Api.post('/api/attendance/adjustment-requests', {
        'attendanceId': attendanceId,
        'proposedCheckInUtc': inTime?.toUtc().toIso8601String(),
        'proposedCheckOutUtc': outTime?.toUtc().toIso8601String(),
        'reason': reason.text.trim(),
      }, token: await storage.read(key: 'access_token'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã gửi yêu cầu để Admin xem xét.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Yêu cầu điều chỉnh')),
    body: FutureBuilder(
      future: records,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) return Center(child: Text(s.error.toString()));
        final rows = (s.data as List? ?? []);
        if (rows.isEmpty) {
          return const Center(
            child: Text('Bạn chưa có bản ghi để yêu cầu điều chỉnh.'),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<int>(
              decoration: const InputDecoration(labelText: 'Bản ghi chấm công'),
              items: rows.map<DropdownMenuItem<int>>((raw) {
                final x = raw as Map<String, dynamic>;
                final t = DateTime.parse(x['checkInUtc']).toLocal();
                return DropdownMenuItem(
                  value: x['id'] as int,
                  child: Text(
                    '${t.toString().substring(0, 16)} · ${x['status']}',
                  ),
                );
              }).toList(),
              onChanged: (v) => setState(() => attendanceId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: checkIn,
              decoration: const InputDecoration(
                labelText: 'Check-in đề nghị (ISO 8601, tùy chọn)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: checkOut,
              decoration: const InputDecoration(
                labelText: 'Check-out đề nghị (ISO 8601, tùy chọn)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Lý do'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(busy ? 'Đang gửi…' : 'Gửi Admin xem xét'),
            ),
          ],
        );
      },
    ),
  );
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late Future<dynamic> future;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<dynamic> load() async => Api.get(
    '/api/attendance/schedule',
    token: await storage.read(key: 'access_token'),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lịch làm việc')),
    body: FutureBuilder(
      future: future,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) return Center(child: Text(s.error.toString()));
        final rows = (s.data as List? ?? []);
        if (rows.isEmpty) {
          return const Center(
            child: Text('Chưa có ca được phân công trong 30 ngày tới.'),
          );
        }
        return ListView(
          children: rows.map((raw) {
            final x = raw as Map<String, dynamic>;
            return Card(
              child: ListTile(
                leading: const Icon(
                  Icons.calendar_month,
                  color: Color(0xff176b5b),
                ),
                title: Text('${x['shift']} · ${x['workDate']}'),
                subtitle: Text('${x['startTime']} – ${x['endTime']}'),
              ),
            );
          }).toList(),
        );
      },
    ),
  );
}

class AdminEmployeesPage extends StatefulWidget {
  const AdminEmployeesPage({super.key});
  @override
  State<AdminEmployeesPage> createState() => _AdminEmployeesPageState();
}

class _AdminEmployeesPageState extends State<AdminEmployeesPage> {
  late Future<dynamic> future;
  final searchController = TextEditingController();
  bool includeDeleted = false;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<dynamic> load([String? search]) async {
    final params = <String, String>{'includeDeleted': '$includeDeleted'};
    if (search != null && search.trim().isNotEmpty) {
      params['search'] = search.trim();
    }
    return Api.get(
      '/api/admin/employees?${Uri(queryParameters: params).query}',
      token: await storage.read(key: 'access_token'),
    );
  }
  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> search() async =>
      setState(() => future = load(searchController.text));

  Future<void> add() async {
    final name = TextEditingController();
    final username = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm nhân viên'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Họ và tên'),
              ),
              TextField(
                controller: username,
                decoration: const InputDecoration(
                  labelText: 'Username (không dấu)',
                ),
              ),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email nhận OTP'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Mật khẩu (tối thiểu 10 ký tự)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Tạo tài khoản'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('/api/admin/employees', {
        'fullName': name.text.trim(),
        'username': username.text.trim(),
        'email': email.text.trim(),
        'password': password.text,
      }, token: await storage.read(key: 'access_token'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Đã tạo tài khoản nhân viên. Nhân viên sẽ nhận OTP tại email này khi đăng nhập.',
            ),
          ),
        );
        setState(() => future = load(searchController.text));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> detail(int id) async {
    try {
      final x = await Api.get(
        '/api/admin/employees/$id',
        token: await storage.read(key: 'access_token'),
      ) as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Hồ sơ nhân viên'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Họ tên: ${x['fullName']}'),
              Text('Username: ${x['username']}'),
              Text('Email: ${x['email']}'),
              Text(
                'Trạng thái: ${x['isActive'] == true ? 'Đang hoạt động' : 'Đã vô hiệu hóa'}',
              ),
              Text('Tạo lúc: ${DateTime.parse(x['createdAtUtc']).toLocal()}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> setActive(Map<String, dynamic> x, bool active) async {
    if (!active) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Vô hiệu hóa nhân viên?'),
          content: Text(
            'Tài khoản ${x['username']} sẽ không thể đăng nhập. Dữ liệu chấm công được giữ nguyên.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Giữ lại'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Vô hiệu hóa'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await Api.request(
        'PATCH',
        '/api/admin/employees/${x['id']}/active?active=$active',
        token: await storage.read(key: 'access_token'),
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> deleteEmployee(Map<String, dynamic> x) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa nhân viên?'),
        content: Text(
          'Tài khoản ${x['username']} sẽ bị khóa và ẩn khỏi danh sách. Lịch sử chấm công và phân ca vẫn được giữ.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xóa nhân viên')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Api.request(
        'DELETE',
        '/api/admin/employees/${x['id']}',
        token: await storage.read(key: 'access_token'),
      );
      if (mounted) setState(() => future = load(searchController.text));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> edit(Map<String, dynamic> x) async {
    final name = TextEditingController(text: x['fullName']);
    final email = TextEditingController(text: x['email']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa nhân viên'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Họ tên'),
            ),
            TextField(
              controller: email,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.request(
        'PUT',
        '/api/admin/employees/${x['id']}',
        token: await storage.read(key: 'access_token'),
        body: {
          'fullName': name.text.trim(),
          'email': email.text.trim(),
          'isActive': x['isActive'],
        },
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Quản lý nhân viên'),
      actions: [
        IconButton(
          onPressed: add,
          tooltip: 'Thêm nhân viên',
          icon: const Icon(Icons.person_add_alt_1),
        ),
        IconButton(
          onPressed: () => setState(() => future = load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              labelText: 'Tìm theo họ tên, username hoặc email',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: search,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilterChip(
            label: const Text('Hiện nhân viên đã xóa'),
            selected: includeDeleted,
            onSelected: (value) => setState(() {
              includeDeleted = value;
              future = load(searchController.text);
            }),
          ),
        ),
        Expanded(
          child: FutureBuilder(
            future: future,
            builder: (context, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (s.hasError) return Center(child: Text(s.error.toString()));
              final rows = (s.data as List? ?? []);
              if (rows.isEmpty) {
                return const Center(
                  child: Text('Chưa có nhân viên. Đăng ký tài khoản để thêm.'),
                );
              }
              return ListView(
                children: rows.map((raw) {
                  final x = raw as Map<String, dynamic>;
                  return Card(
                    child: ListTile(
                      onTap: () => detail(x['id']),
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(x['fullName'] ?? ''),
                      subtitle: Text(
                        '${x['username']} · ${x['email']} · ${x['isDeleted'] == true ? 'Đã xóa' : x['isActive'] == true ? 'Đang hoạt động' : 'Đã vô hiệu hóa'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: x['isDeleted'] == true ? null : () => edit(x),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: x['isDeleted'] == true ? 'Đã xóa' : 'Xóa nhân viên',
                            onPressed: x['isDeleted'] == true ? null : () => deleteEmployee(x),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class AdminShiftsPage extends StatefulWidget {
  const AdminShiftsPage({super.key});
  @override
  State<AdminShiftsPage> createState() => _AdminShiftsPageState();
}

class _AdminShiftsPageState extends State<AdminShiftsPage> {
  late Future<dynamic> future;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<dynamic> load() async => Api.get(
    '/api/admin/shifts',
    token: await storage.read(key: 'access_token'),
  );
  Future<void> add() async {
    final name = TextEditingController();
    final start = TextEditingController(text: '09:00');
    final end = TextEditingController(text: '18:00');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tạo ca làm'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Tên ca'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: start,
                    decoration: const InputDecoration(
                      labelText: 'Bắt đầu HH:mm',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: end,
                    decoration: const InputDecoration(
                      labelText: 'Kết thúc HH:mm',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Tạo'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      String iso(String t) => '${t.trim()}:00';
      await Api.post('/api/admin/shifts', {
        'name': name.text.trim(),
        'startTime': iso(start.text),
        'endTime': iso(end.text),
      }, token: await storage.read(key: 'access_token'));
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> disable(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ngừng sử dụng ca?'),
        content: const Text(
          'Ca đã được xếp sẽ vẫn được giữ trong lịch sử; ca này không thể phân công mới.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Quay lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ngừng sử dụng'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Api.request(
        'DELETE',
        '/api/admin/shifts/$id',
        token: await storage.read(key: 'access_token'),
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> edit(Map<String, dynamic> shift) async {
    final name = TextEditingController(text: shift['name']);
    final start = TextEditingController(
      text: shift['startTime'].toString().substring(0, 5),
    );
    final end = TextEditingController(
      text: shift['endTime'].toString().substring(0, 5),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa ca làm'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Tên ca'),
            ),
            TextField(
              controller: start,
              decoration: const InputDecoration(labelText: 'Bắt đầu HH:mm'),
            ),
            TextField(
              controller: end,
              decoration: const InputDecoration(labelText: 'Kết thúc HH:mm'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.request(
        'PUT',
        '/api/admin/shifts/${shift['id']}',
        token: await storage.read(key: 'access_token'),
        body: {
          'name': name.text.trim(),
          'startTime': '${start.text.trim()}:00',
          'endTime': '${end.text.trim()}:00',
        },
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Quản lý ca làm'),
      actions: [
        IconButton(
          tooltip: 'Phân công ca',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AssignShiftPage()),
          ),
          icon: const Icon(Icons.assignment_add),
        ),
        IconButton(onPressed: add, icon: const Icon(Icons.add)),
      ],
    ),
    body: FutureBuilder(
      future: future,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) return Center(child: Text(s.error.toString()));
        final rows = (s.data as List? ?? []);
        if (rows.isEmpty) {
          return const Center(child: Text('Chưa tạo ca làm nào.'));
        }
        return ListView(
          children: rows.map((raw) {
            final x = raw as Map<String, dynamic>;
            return Card(
              child: ListTile(
                onTap: x['isActive'] == true ? () => edit(x) : null,
                title: Text(x['name'] ?? ''),
                subtitle: Text('${x['startTime']} – ${x['endTime']}'),
                trailing: IconButton(
                  tooltip: 'Ngừng sử dụng',
                  onPressed: x['isActive'] == true
                      ? () => disable(x['id'])
                      : null,
                  icon: const Icon(Icons.archive_outlined),
                ),
              ),
            );
          }).toList(),
        );
      },
    ),
  );
}

class AssignShiftPage extends StatefulWidget {
  const AssignShiftPage({super.key});
  @override
  State<AssignShiftPage> createState() => _AssignShiftPageState();
}

class _AssignShiftPageState extends State<AssignShiftPage> {
  late Future<List<dynamic>> future;
  int? employeeId, shiftId;
  DateTime workDate = DateTime.now();
  bool busy = false;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<List<dynamic>> load() async {
    final token = await storage.read(key: 'access_token');
    return Future.wait([
      Api.get('/api/admin/employees', token: token),
      Api.get('/api/admin/shifts', token: token),
    ]);
  }

  Future<void> save() async {
    if (employeeId == null || shiftId == null) return;
    setState(() => busy = true);
    try {
      await Api.post('/api/admin/employee-shifts', {
        'userId': employeeId,
        'shiftId': shiftId,
        'workDate': workDate.toIso8601String().substring(0, 10),
      }, token: await storage.read(key: 'access_token'));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Đã phân công ca.')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Phân công ca làm')),
    body: FutureBuilder<List<dynamic>>(
      future: future,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) return Center(child: Text(s.error.toString()));
        final employees = (s.data![0] as List)
            .where((x) => x['isActive'] == true)
            .toList();
        final shifts = (s.data![1] as List)
            .where((x) => x['isActive'] == true)
            .toList();
        if (employees.isEmpty || shifts.isEmpty) {
          return const Center(
            child: Text('Cần có nhân viên đang hoạt động và ca làm đang mở.'),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<int>(
              decoration: const InputDecoration(labelText: 'Nhân viên'),
              items: employees
                  .map<DropdownMenuItem<int>>(
                    (x) => DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text(x['fullName']),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => employeeId = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              decoration: const InputDecoration(labelText: 'Ca làm'),
              items: shifts
                  .map<DropdownMenuItem<int>>(
                    (x) => DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text(
                        '${x['name']} · ${x['startTime']}–${x['endTime']}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => shiftId = v),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: workDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 1)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (d != null) setState(() => workDate = d);
              },
              icon: const Icon(Icons.calendar_month),
              label: Text(
                'Ngày làm: ${workDate.year}-${workDate.month.toString().padLeft(2, '0')}-${workDate.day.toString().padLeft(2, '0')}',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Đang lưu…' : 'Phân công'),
            ),
          ],
        );
      },
    ),
  );
}

class AdminAdjustmentRequestsPage extends StatefulWidget {
  const AdminAdjustmentRequestsPage({super.key});
  @override
  State<AdminAdjustmentRequestsPage> createState() =>
      _AdminAdjustmentRequestsPageState();
}

class _AdminAdjustmentRequestsPageState
    extends State<AdminAdjustmentRequestsPage> {
  late Future<dynamic> requests;
  @override
  void initState() {
    super.initState();
    requests = load();
  }

  Future<dynamic> load() async => Api.get(
    '/api/admin/adjustment-requests',
    token: await storage.read(key: 'access_token'),
  );
  Future<void> review(int id, bool approve) async {
    final comment = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Duyệt yêu cầu' : 'Từ chối yêu cầu'),
        content: TextField(
          controller: comment,
          decoration: const InputDecoration(
            labelText: 'Ghi chú Admin (tùy chọn)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(approve ? 'Duyệt' : 'Từ chối'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('/api/admin/adjustment-requests/$id/review', {
        'approve': approve,
        'comment': comment.text.trim(),
      }, token: await storage.read(key: 'access_token'));
      setState(() => requests = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Yêu cầu điều chỉnh')),
    body: FutureBuilder(
      future: requests,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) return Center(child: Text(s.error.toString()));
        final rows = (s.data as List? ?? []);
        if (rows.isEmpty) {
          return const Center(child: Text('Không có yêu cầu chờ duyệt.'));
        }
        return ListView(
          children: rows.map((raw) {
            final x = raw as Map<String, dynamic>;
            return Card(
              child: ListTile(
                title: Text('${x['fullName']} (@${x['username']})'),
                subtitle: Text(
                  'Yêu cầu #${x['id']} · bản ghi ${x['attendanceId'] ?? 'chưa chọn'}\n${x['reason']}\nCheck-in: ${x['proposedCheckInUtc'] ?? 'không đề nghị'}\nCheck-out: ${x['proposedCheckOutUtc'] ?? 'không đề nghị'}',
                ),
                isThreeLine: true,
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Duyệt',
                      onPressed: () => review(x['id'], true),
                      icon: const Icon(
                        Icons.check_circle_outline,
                        color: Colors.green,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Từ chối',
                      onPressed: () => review(x['id'], false),
                      icon: const Icon(
                        Icons.cancel_outlined,
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    ),
  );
}

class AdminAttendancesPage extends StatefulWidget {
  const AdminAttendancesPage({super.key});
  @override
  State<AdminAttendancesPage> createState() => _AdminAttendancesPageState();
}

class _AdminAttendancesPageState extends State<AdminAttendancesPage> {
  late Future<dynamic> future;
  final searchController = TextEditingController();
  String statusFilter = 'Tất cả';
  DateTime? dateFilter;
  bool includeCancelled = false;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<dynamic> load() async {
    final params = <String, String>{};
    final search = searchController.text.trim();
    if (search.isNotEmpty) params['search'] = search;
    if (statusFilter != 'Tất cả') params['status'] = statusFilter;
    if (includeCancelled) params['includeCancelled'] = 'true';
    if (dateFilter != null) {
      final start = DateTime(
        dateFilter!.year,
        dateFilter!.month,
        dateFilter!.day,
      );
      params['fromUtc'] = start.toUtc().toIso8601String();
      params['toUtc'] = start
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String();
    }
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return Api.get(
      '/api/admin/attendances${query.isEmpty ? '' : '?$query'}',
      token: await storage.read(key: 'access_token'),
    );
  }

  Future<void> chooseDate() async {
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDate: dateFilter ?? DateTime.now(),
      helpText: 'Lọc ngày chấm công',
    );
    if (selected != null && mounted) {
      setState(() {
        dateFilter = selected;
        future = load();
      });
    }
  }

  Future<void> detail(int id) async {
    try {
      final result = await Api.get(
        '/api/admin/attendances/$id',
        token: await storage.read(key: 'access_token'),
      ) as Map<String, dynamic>;
      if (!mounted) return;
      final row = result['attendance'] as Map<String, dynamic>;
      final history = (result['history'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      String shown(Object? value) => value?.toString() ?? 'Chưa có';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Chi tiết · ${row['fullName'] ?? row['username']}'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Username: ${row['username']}'),
                  Text(
                    'Check-in: ${DateTime.parse(row['checkInUtc']).toLocal()}',
                  ),
                  Text(
                    'Check-out: ${row['checkOutUtc'] == null ? 'Chưa có' : DateTime.parse(row['checkOutUtc']).toLocal()}',
                  ),
                  Text(
                    'Trạng thái: ${row['status']} · ${row['isCancelled'] == true ? 'Đã hủy' : 'Đang hiệu lực'}',
                  ),
                  Text(
                    'Tọa độ GPS nhân viên: ${shown(row['latitude'])}, ${shown(row['longitude'])}',
                  ),
                  Text(
                    'Vị trí công ty: ${shown(row['workLocationName'])}',
                  ),
                  Text(
                    'Cách công ty: ${row['distanceKilometers'] == null ? 'Chưa xác minh GPS' : '${(row['distanceKilometers'] as num).toStringAsFixed(2)} km'}',
                  ),
                  Text(
                    'GPS khi check-out: ${shown(row['checkOutLatitude'])}, ${shown(row['checkOutLongitude'])}',
                  ),
                  Text(
                    'Vị trí công ty khi check-out: ${shown(row['checkOutWorkLocationName'])}',
                  ),
                  Text(
                    'Khoảng cách khi check-out: ${row['checkOutDistanceMeters'] == null ? 'Chưa xác minh GPS' : '${(row['checkOutDistanceMeters'] as num).toStringAsFixed(0)} m · ${(row['checkOutDistanceMeters'] as num) <= 20 ? 'Trong 20 m' : 'Ngoài 20 m'}'}',
                  ),
                  if (row['latitude'] != null && row['longitude'] != null)
                    SelectableText('Bản đồ: https://maps.google.com/?q=${row['latitude']},${row['longitude']}'),
                  if (row['checkOutLatitude'] != null && row['checkOutLongitude'] != null)
                    SelectableText('Bản đồ check-out: https://maps.google.com/?q=${row['checkOutLatitude']},${row['checkOutLongitude']}'),
                  Text(
                    'Chuyển động: ${shown(row['motionMagnitude'])}',
                  ),
                  const Divider(),
                  const Text(
                    'Lịch sử điều chỉnh',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (history.isEmpty)
                    const Text('Chưa có thao tác điều chỉnh.'),
                  ...history.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${DateTime.parse(entry['changedAtUtc']).toLocal()} · ${entry['changedBy']}\n${entry['changeReason']}\nTrước: ${entry['beforeJson']}\nSau: ${entry['afterJson']}',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> edit(Map<String, dynamic> row) async {
    final checkIn = TextEditingController(
      text: DateTime.parse(row['checkInUtc']).toLocal().toIso8601String(),
    );
    final checkOut = TextEditingController(
      text: row['checkOutUtc'] == null
          ? ''
          : DateTime.parse(row['checkOutUtc']).toLocal().toIso8601String(),
    );
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Điều chỉnh chấm công'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: checkIn,
                decoration: const InputDecoration(
                  labelText: 'Check-in (ISO 8601)',
                ),
              ),
              TextField(
                controller: checkOut,
                decoration: const InputDecoration(
                  labelText: 'Check-out (để trống nếu chưa có)',
                ),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'Lý do điều chỉnh',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final inValue = DateTime.tryParse(checkIn.text);
    final outValue = checkOut.text.trim().isEmpty
        ? null
        : DateTime.tryParse(checkOut.text);
    if (inValue == null ||
        (checkOut.text.trim().isNotEmpty && outValue == null) ||
        reason.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thời gian ISO 8601 hoặc lý do không hợp lệ.'),
          ),
        );
      }
      return;
    }
    try {
      await Api.request(
        'PUT',
        '/api/admin/attendances/${row['id']}',
        token: await storage.read(key: 'access_token'),
        body: {
          'checkInUtc': inValue.toUtc().toIso8601String(),
          'checkOutUtc': outValue?.toUtc().toIso8601String(),
          'reason': reason.text.trim(),
        },
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> cancel(int id) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hủy bản ghi'),
        content: TextField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Lý do'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hủy bản ghi'),
          ),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    try {
      await Api.request(
        'DELETE',
        '/api/admin/attendances/$id?reason=${Uri.encodeQueryComponent(reason.text.trim())}',
        token: await storage.read(key: 'access_token'),
      );
      setState(() => future = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Bản ghi chấm công'),
      actions: [
        IconButton(
          onPressed: () => setState(() => future = load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => setState(() => future = load()),
            decoration: InputDecoration(
              labelText: 'Tìm tên hoặc username',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: () => setState(() => future = load()),
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                value: statusFilter,
                items: const [
                  DropdownMenuItem(
                    value: 'Tất cả',
                    child: Text('Mọi trạng thái'),
                  ),
                  DropdownMenuItem(value: 'OnTime', child: Text('Đúng giờ')),
                  DropdownMenuItem(value: 'Late', child: Text('Đi trễ')),
                ],
                onChanged: (value) => setState(() {
                  statusFilter = value ?? 'Tất cả';
                  future = load();
                }),
              ),
              OutlinedButton.icon(
                onPressed: chooseDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(
                  dateFilter == null
                      ? 'Mọi ngày'
                      : '${dateFilter!.day}/${dateFilter!.month}/${dateFilter!.year}',
                ),
              ),
              if (dateFilter != null)
                IconButton(
                  tooltip: 'Xóa lọc ngày',
                  onPressed: () => setState(() {
                    dateFilter = null;
                    future = load();
                  }),
                  icon: const Icon(Icons.clear),
                ),
              FilterChip(
                label: const Text('Hiện bản ghi đã hủy'),
                selected: includeCancelled,
                onSelected: (value) => setState(() {
                  includeCancelled = value;
                  future = load();
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder(
            future: future,
            builder: (context, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (s.hasError) return Center(child: Text(s.error.toString()));
              final rows = (s.data as List? ?? []);
              if (rows.isEmpty) {
                return const Center(child: Text('Chưa có bản ghi.'));
              }
              return ListView(
                children: rows.map((raw) {
                  final x = raw as Map<String, dynamic>;
                  final time = DateTime.parse(x['checkInUtc']).toLocal();
                  return Card(
                    child: ListTile(
                      onTap: () => detail(x['id']),
                      title: Text(x['fullName'] ?? x['username'] ?? ''),
                      subtitle: Text(
                        '${time.toString().substring(0, 16)} · ${x['status']} · ${x['distanceKilometers'] == null ? 'GPS chưa xác minh' : '${(x['distanceKilometers'] as num).toStringAsFixed(2)} km'}${x['workLocationName'] == null ? '' : ' · ${x['workLocationName']}'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Điều chỉnh',
                            onPressed: x['isCancelled'] == true
                                ? null
                                : () => edit(x),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Hủy bản ghi',
                            onPressed: x['isCancelled'] == true
                                ? null
                                : () => cancel(x['id']),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key, required this.role});
  final String role;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(
          'Tiện ích cá nhân',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Text('Thông tin tài khoản và các tiện ích dành cho bạn.'),
      ),
      Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.badge_outlined)),
          title: Text(role == 'Admin' ? 'Hồ sơ tài khoản' : 'Thông tin nhân viên'),
          subtitle: Text(
            role == 'Admin'
                ? 'Username đăng nhập, Gmail và vai trò Admin.'
                : 'Mã nhân viên, họ tên, username, email và vai trò.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProfilePage()),
          ),
        ),
      ),
      if (role == 'Admin')
        Card(
          child: ListTile(
            leading: const Icon(Icons.admin_panel_settings),
            title: const Text('Quản trị'),
            subtitle: const Text(
              'Quản lý nhân viên, ca làm, chấm công và cảnh báo.',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminEmployeesPage()),
            ),
          ),
        ),
      if (role == 'Admin')
        Card(
          child: ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('Vị trí GPS công ty'),
            subtitle: const Text('Cấu hình nơi làm việc và bán kính chấm công.'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WorkLocationsPage()),
            ),
          ),
        ),
    ],
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late Future<Map<String, dynamic>> profile;

  @override
  void initState() {
    super.initState();
    profile = loadProfile();
  }

  Future<Map<String, dynamic>> loadProfile() async {
    final token = await storage.read(key: 'access_token');
    final data = await Api.get('/api/auth/me', token: token);
    return data as Map<String, dynamic>;
  }

  Future<void> reload() async {
    final next = loadProfile();
    setState(() => profile = next);
    await next;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Hồ sơ tài khoản')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: profile,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 44),
                  const SizedBox(height: 12),
                  const Text('Không tải được hồ sơ nhân viên.'),
                  const SizedBox(height: 8),
                  Text(snapshot.error.toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Thử tải lại'),
                  ),
                ],
              ),
            ),
          );
        }

        final user = snapshot.data!;
        final isEmployee = user['role'] == 'Employee';
        final roleLabel = isEmployee ? 'Nhân viên' : 'Quản trị viên';
        final idLabel = isEmployee ? 'Mã nhân viên' : 'Mã tài khoản';
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        child: Icon(
                          Icons.person,
                          size: 36,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user['fullName'] ?? 'Chưa có họ tên',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '@${user['username'] ?? ''}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 10),
                            Chip(
                              avatar: Icon(
                                isEmployee
                                    ? Icons.badge_outlined
                                    : Icons.admin_panel_settings_outlined,
                                size: 18,
                              ),
                              label: Text(roleLabel),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'THÔNG TIN TÀI KHOẢN',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(letterSpacing: 1.1, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    _ProfileInfoRow(
                      icon: Icons.badge_outlined,
                      label: idLabel,
                      value: '#${user['id'] ?? '—'}',
                    ),
                    const Divider(height: 1, indent: 56),
                    _ProfileInfoRow(
                      icon: Icons.person_outline,
                      label: 'Họ và tên',
                      value: user['fullName'] ?? '—',
                    ),
                    const Divider(height: 1, indent: 56),
                    _ProfileInfoRow(
                      icon: Icons.alternate_email,
                      label: 'Tên đăng nhập',
                      value: user['username'] ?? '—',
                    ),
                    const Divider(height: 1, indent: 56),
                    _ProfileInfoRow(
                      icon: Icons.email_outlined,
                      label: 'Email',
                      value: user['email'] ?? '—',
                    ),
                    const Divider(height: 1, indent: 56),
                    _ProfileInfoRow(
                      icon: Icons.work_outline,
                      label: 'Vai trò',
                      value: roleLabel,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('Vuốt xuống để làm mới thông tin hồ sơ.'),
            ],
          ),
        );
      },
    ),
  );
}

class _ProfileInfoRow extends StatelessWidget {
  const _ProfileInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 3),
              SelectableText(
                value,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class AlertPage extends StatefulWidget {
  const AlertPage({super.key});
  @override
  State<AlertPage> createState() => _AlertPageState();
}

class _AlertPageState extends State<AlertPage> {
  late Future<dynamic> items;
  @override
  void initState() {
    super.initState();
    items = load();
  }

  Future<dynamic> load() async {
    final token = await storage.read(key: 'access_token');
    return Api.get('/api/admin/anomalies', token: token);
  }

  Future<void> review(int id) async {
    try {
      await Api.request(
        'POST',
        '/api/admin/anomalies/$id/review',
        token: await storage.read(key: 'access_token'),
      );
      setState(() => items = load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cảnh báo chấm công')),
    body: FutureBuilder(
      future: items,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text(snapshot.error.toString()));
        }
        final rows = (snapshot.data as List? ?? []);
        if (rows.isEmpty) return const Center(child: Text('Chưa có cảnh báo.'));
        return ListView(
          children: rows.map((row) {
            final item = row as Map<String, dynamic>;
            return Card(
              child: ListTile(
                leading: Icon(
                  item['reviewed'] == true
                      ? Icons.check_circle
                      : Icons.warning_amber,
                  color: Colors.orange,
                ),
                title: Text(item['reason'] ?? ''),
                subtitle: Text(item['createdAtUtc'] ?? ''),
                trailing: item['reviewed'] == true
                    ? const Icon(Icons.done, color: Colors.green)
                    : IconButton(
                        tooltip: 'Đánh dấu đã rà soát',
                        onPressed: () => review(item['id']),
                        icon: const Icon(Icons.check_circle_outline),
                      ),
              ),
            );
          }).toList(),
        );
      },
    ),
  );
}
