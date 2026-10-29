import 'package:flutter/material.dart';

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({
    super.key,
    required this.onEmployees,
    required this.onAttendances,
    required this.onQrSchedule,
    required this.onProfile,
    required this.onWorkLocations,
    required this.qrPanel,
  });

  final VoidCallback onEmployees;
  final VoidCallback onAttendances;
  final VoidCallback onQrSchedule;
  final VoidCallback onProfile;
  final VoidCallback onWorkLocations;
  final Widget qrPanel;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      qrPanel,
      Card(
        child: ListTile(
          leading: const Icon(Icons.people_alt_outlined),
          title: const Text('Quản lý nhân viên'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onEmployees,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('Hồ sơ tài khoản'),
          subtitle: const Text('Xem username đăng nhập và Gmail Admin'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onProfile,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.qr_code_2),
          title: const Text('Tạo QR chấm công'),
          subtitle: const Text('Đặt ngày giờ mở mã cho nhân viên quét'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onQrSchedule,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: const Text('Vị trí GPS công ty'),
          subtitle: const Text('Thêm, sửa, xóa vị trí và bán kính chấm công'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onWorkLocations,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('Chấm công'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onAttendances,
        ),
      ),
    ],
  );
}
