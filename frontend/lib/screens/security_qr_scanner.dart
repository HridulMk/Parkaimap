import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/parking_service.dart';

class SecurityQrScannerScreen extends StatelessWidget {
  const SecurityQrScannerScreen({super.key});

  static bool get _isMobile =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    return _isMobile ? const _MobileScannerScreen() : const _DesktopScannerScreen();
  }
}

// ─────────────────────────────────────────────
// MOBILE — live camera scanner
// ─────────────────────────────────────────────
class _MobileScannerScreen extends StatefulWidget {
  const _MobileScannerScreen();

  @override
  State<_MobileScannerScreen> createState() => _MobileScannerScreenState();
}

class _MobileScannerScreenState extends State<_MobileScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _processing = false;
  _ScanResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null || code.isEmpty) return;
    await _controller.stop();
    await _submitCode(code);
  }

  Future<void> _submitCode(String code) async {
    setState(() {
      _processing = true;
      _result = null;
    });
    final result = await ParkingService.scanQrCode(code);
    if (!mounted) return;
    setState(() {
      _processing = false;
      _result = _ScanResult.fromServiceResult(result);
    });
  }

  void _rescan() {
    setState(() => _result = null);
    _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: _appBar(
        context,
        trailing: IconButton(
          icon: const Icon(Icons.flash_on, color: Colors.white),
          onPressed: _controller.toggleTorch,
          tooltip: 'Toggle Flash',
        ),
      ),
      body: _result != null
          ? _ResultView(result: _result!, onRescan: _rescan)
          : Stack(
              children: [
                MobileScanner(controller: _controller, onDetect: _onDetect),
                CustomPaint(painter: _OverlayPainter(), child: const SizedBox.expand()),
                Positioned(
                  bottom: 48,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _processing
                        ? const CircularProgressIndicator(color: Colors.tealAccent)
                        : const Text(
                            'Point camera at the booking QR code',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// DESKTOP / WEB — type or pick image
// ─────────────────────────────────────────────
class _DesktopScannerScreen extends StatefulWidget {
  const _DesktopScannerScreen();

  @override
  State<_DesktopScannerScreen> createState() => _DesktopScannerScreenState();
}

class _DesktopScannerScreenState extends State<_DesktopScannerScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _processing = false;
  _ScanResult? _result;
  Uint8List? _pickedImageBytes;

  @override
  void initState() {
    super.initState();
    // Auto-focus so USB QR scanners (which act as keyboards) work immediately
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submitText() async {
    final code = _textCtrl.text.trim();
    if (code.isEmpty) return;
    _textCtrl.clear();
    await _submit(code);
  }

  Future<void> _pickAndScanImage() async {
    final picker = ImagePicker();
    final picked = kIsWeb
        ? await picker.pickImage(source: ImageSource.gallery)
        : await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    setState(() => _pickedImageBytes = bytes);

    // Use MobileScanner to decode QR from image bytes
    final result = await MobileScannerController().analyzeImage(picked.path);
    if (!mounted) return;

    if (result == null || result.barcodes.isEmpty) {
      setState(() {
        _pickedImageBytes = null;
        _result = _ScanResult(
          success: false,
          action: '',
          message: 'No QR code found in the selected image.',
          slotLabel: '',
          reservationId: '',
          userName: '',
        );
      });
      return;
    }

    final code = result.barcodes.first.rawValue ?? '';
    await _submit(code);
  }

  Future<void> _submit(String code) async {
    setState(() {
      _processing = true;
      _result = null;
    });
    final result = await ParkingService.scanQrCode(code);
    if (!mounted) return;
    setState(() {
      _processing = false;
      _pickedImageBytes = null;
      _result = _ScanResult.fromServiceResult(result);
    });
  }

  void _rescan() {
    setState(() {
      _result = null;
      _pickedImageBytes = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: _appBar(context),
      body: _result != null
          ? _ResultView(result: _result!, onRescan: _rescan)
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Info banner
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.tealAccent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.tealAccent, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Use a USB QR scanner (auto-types below) or upload a QR image.',
                            style: TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Option 1: USB / manual input ──
                  const Text('USB Scanner / Manual Entry',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 10),
                  KeyboardListener(
                    focusNode: FocusNode(),
                    onKeyEvent: (event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter) {
                        _submitText();
                      }
                    },
                    child: TextField(
                      controller: _textCtrl,
                      focusNode: _focusNode,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Scan or type QR code here…',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF1A1F2E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.tealAccent),
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.send, color: Colors.tealAccent),
                          onPressed: _submitText,
                          tooltip: 'Submit',
                        ),
                      ),
                      onSubmitted: (_) => _submitText(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: _processing ? null : _submitText,
                    icon: _processing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.qr_code),
                    label: const Text('Submit Code', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent.shade700,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),

                  const SizedBox(height: 32),
                  Row(children: [
                    const Expanded(child: Divider(color: Colors.white12)),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('OR', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ),
                    const Expanded(child: Divider(color: Colors.white12)),
                  ]),
                  const SizedBox(height: 32),

                  // ── Option 2: Upload QR image ──
                  const Text('Upload QR Image',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 10),
                  if (_pickedImageBytes != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_pickedImageBytes!, height: 200, fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 10),
                  ],
                  OutlinedButton.icon(
                    onPressed: _processing ? null : _pickAndScanImage,
                    icon: const Icon(Icons.upload_file, color: Colors.tealAccent),
                    label: const Text('Choose QR Image',
                        style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.tealAccent),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────
PreferredSizeWidget _appBar(BuildContext context, {Widget? trailing}) {
  return AppBar(
    backgroundColor: const Color(0xFF1A1F2E),
    elevation: 0,
    title: const Text('QR Scanner', style: TextStyle(color: Colors.white)),
    iconTheme: const IconThemeData(color: Colors.white),
    actions: [if (trailing != null) trailing],
  );
}

class _OverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cutoutSize = 260.0;
    final cx = size.width / 2;
    final cy = size.height / 2 - 40;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: cutoutSize, height: cutoutSize);

    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)))
        ..fillType = PathFillType.evenOdd,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(16)),
      Paint()
        ..color = Colors.tealAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    const len = 24.0;
    final cp = Paint()
      ..color = Colors.tealAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final c in [
      [rect.topLeft, Offset(rect.left + len, rect.top), Offset(rect.left, rect.top + len)],
      [rect.topRight, Offset(rect.right - len, rect.top), Offset(rect.right, rect.top + len)],
      [rect.bottomLeft, Offset(rect.left + len, rect.bottom), Offset(rect.left, rect.bottom - len)],
      [rect.bottomRight, Offset(rect.right - len, rect.bottom), Offset(rect.right, rect.bottom - len)],
    ]) {
      canvas.drawLine(c[1], c[0], cp);
      canvas.drawLine(c[0], c[2], cp);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

class _ResultView extends StatelessWidget {
  final _ScanResult result;
  final VoidCallback onRescan;

  const _ResultView({required this.result, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    final color = result.success ? Colors.tealAccent : Colors.redAccent;
    final icon = result.success
        ? (result.action == 'checkout' ? Icons.logout : Icons.login)
        : Icons.error_outline;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 2),
              ),
              child: Icon(icon, color: color, size: 44),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            result.message,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 28),
          if (result.success) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1F2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Column(
                children: [
                  _Row('Action', result.action == 'checkout' ? 'Check-Out' : 'Check-In'),
                  const Divider(color: Colors.white12, height: 16),
                  _Row('Slot', result.slotLabel),
                  const Divider(color: Colors.white12, height: 16),
                  _Row('Reservation', result.reservationId),
                  const Divider(color: Colors.white12, height: 16),
                  _Row('User', result.userName),
                  if (result.action == 'checkout' && result.finalFee != null) ...[
                    const Divider(color: Colors.white12, height: 16),
                    _Row('Final Fee', 'Rs ${result.finalFee}'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),
          ],
          ElevatedButton.icon(
            onPressed: onRescan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan Next', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.tealAccent.shade700,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }
}

class _ScanResult {
  final bool success;
  final String action;
  final String message;
  final String slotLabel;
  final String reservationId;
  final String userName;
  final String? finalFee;

  _ScanResult({
    required this.success,
    required this.action,
    required this.message,
    required this.slotLabel,
    required this.reservationId,
    required this.userName,
    this.finalFee,
  });

  factory _ScanResult.fromServiceResult(Map<String, dynamic> r) {
    if (r['success'] == true) {
      final res = r['reservation'] as Map<String, dynamic>;
      return _ScanResult(
        success: true,
        action: r['action']?.toString() ?? '',
        message: r['message']?.toString() ?? '',
        slotLabel: res['slot_label']?.toString() ?? '',
        reservationId: res['reservation_id']?.toString() ?? '',
        userName: res['user_name']?.toString() ?? '',
        finalFee: res['final_fee']?.toString(),
      );
    }
    return _ScanResult(
      success: false,
      action: '',
      message: r['error']?.toString() ?? 'Scan failed.',
      slotLabel: '',
      reservationId: '',
      userName: '',
    );
  }
}
