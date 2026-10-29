# tranxuanthanh_2380614806_n7

Flutter attendance app for Trần Xuân Thanh (2380614806), Group 7. Run from Android Studio or the project root with Flutter 3.47+ and Android SDK installed.

Configure the API URL at run/build time; production must use the deployed HTTPS API URL:

```powershell
flutter run --dart-define=API_BASE_URL=https://<your-api-domain>
flutter build apk --release --dart-define=API_BASE_URL=https://<your-api-domain>
```

The source default is a non-local placeholder (`https://api.example.com`) so no APK silently targets the developer laptop. Replace it with the actual HTTPS deployment URL before distribution. Android requests camera and location permissions only for QR scan and attendance actions. The app uses secure storage for JWT, live GPS, accelerometer data, and a QR camera scanner.

The Admin dashboard shows employee and attendance management plus scheduled attendance QR sessions. Admin selects a date and time window; the QR appears automatically during that window. Employees scan it and submit current GPS. Legacy short-lived one-time QR tokens are also supported. The sensor view is an educational movement demo; movement samples only trigger a transparent high-acceleration warning and do not verify identity.
