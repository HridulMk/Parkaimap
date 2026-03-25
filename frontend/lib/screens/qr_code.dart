import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/parking_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QRCodeScreen extends StatefulWidget {
  final String slotName;
  final String slotId;
  final int reservationPk;
  final String reservationCode;
  final String? qrData;
  final String initialStatus;
  final double? initialFinalFee;

  const QRCodeScreen({
    super.key,
    required this.slotName,
    required this.slotId,
    required this.reservationPk,
    required this.reservationCode,
    this.qrData,
    this.initialStatus = 'reserved',
    this.initialFinalFee,
  });

  @override
  State<QRCodeScreen> createState() => _QRCodeScreenState();
}

class _QRCodeScreenState extends State<QRCodeScreen> {
  late String _status;
  double? _finalFee;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _finalFee = widget.initialFinalFee;
  }

  Future<void> _runStageAction() async {
    setState(() => _isProcessing = true);

    Map<String, dynamic> result;
    if (_status == 'reserved') {
      result = await ParkingService.checkIn(widget.reservationPk);
    } else if (_status == 'checked_in') {
      result = await ParkingService.checkOut(widget.reservationPk);
    } else if (_status == 'checked_out') {
      result = await ParkingService.payFinal(widget.reservationPk);
    } else {
      result = {'success': false, 'error': 'No action available'};
    }

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (result['success'] == true) {
      final reservation = result['reservation'] as Map<String, dynamic>;
      setState(() {
        _status = (reservation['status'] ?? _status).toString();
        _finalFee = reservation['final_fee'] == null
            ? _finalFee
            : double.tryParse(reservation['final_fee'].toString());
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated: ${_statusLabel(_status)}')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result['error']?.toString() ?? 'Action failed'),
        backgroundColor: Colors.red,
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'pending_booking_payment':
        return 'Pending Booking Payment';
      case 'reserved':
        return 'Reserved';
      case 'checked_in':
        return 'Checked In';
      case 'checked_out':
        return 'Checked Out';
      case 'completed':
        return 'Completed';
      default:
        return status;
    }
  }

  String _actionLabel() {
    switch (_status) {
      case 'reserved':
        return 'Check In';
      case 'checked_in':
        return 'Check Out';
      case 'checked_out':
        return 'Pay Final Fee';
      default:
        return 'No Pending Action';
    }
  }

  bool _canAct() {
    return _status == 'reserved' || _status == 'checked_in' || _status == 'checked_out';
  }

  @override
  Widget build(BuildContext context) {
    final actualQrData = widget.qrData ??
        'BOOKING|${widget.slotId}|${widget.reservationCode}|${DateTime.now().toIso8601String()}';

    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1117),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.tealAccent.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.confirmation_number, color: Colors.tealAccent.shade200, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Reservation Ready',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Status: ${_statusLabel(_status)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1F2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Access QR',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: 250,
                    height: 250,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(255, 254, 253, 253),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    // child: Center(child: QrCodeView(qrData: actualQrData)),
                  child: Center(
  child: FutureBuilder<List<int>>(
    future: ParkingService.getReservationQrImageBytes(widget.reservationPk),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const CircularProgressIndicator();
      }
      if (snapshot.hasError || !snapshot.hasData) {
        return const Text(
          "Failed to load QR",
          style: TextStyle(color: Colors.red),
        );
      }
      return Image.memory(
        Uint8List.fromList(snapshot.data!),
        width: 200,
        height: 200,
        fit: BoxFit.contain,
      );
    },
  ),
),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Use this at gate/checkpoint during check-in.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1F2E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  _InfoRow(label: 'Slot', value: widget.slotName),
                  const Divider(color: Colors.grey, height: 16),
                  _InfoRow(label: 'Reservation Code', value: widget.reservationCode),
                  const Divider(color: Colors.grey, height: 16),
                  _InfoRow(label: 'Slot ID', value: widget.slotId),
                  if (_finalFee != null) ...[
                    const Divider(color: Colors.grey, height: 16),
                    _InfoRow(label: 'Final Fee', value: 'Rs ${_finalFee!.toStringAsFixed(2)}'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: (_isProcessing || !_canAct()) ? null : _runStageAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent.shade700,
                foregroundColor: Colors.black87,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _isProcessing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_actionLabel(), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white54),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.home, color: Colors.white70),
              label: const Text('Back to Home', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
      ],
    );
  }
}

class QrCodeView extends StatelessWidget {
  final String qrData;

  const QrCodeView({super.key, required this.qrData});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: QrCodePainter(qrData),
      size: const Size(200, 200),
    );
  }
}

class QrCodePainter extends CustomPainter {
  final String data;

  QrCodePainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final cellSize = size.width / 21;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black,
    );

    for (int i = 0; i < 19; i++) {
      for (int j = 0; j < 19; j++) {
        final hashCode = (data.hashCode ^ (i * j)).abs();
        if (hashCode % 2 == 0) {
          canvas.drawRect(
            Rect.fromLTWH((i + 1) * cellSize, (j + 1) * cellSize, cellSize, cellSize),
            paint,
          );
        }
      }
    }

    _drawPositionMarker(canvas, 0, 0, cellSize);
    _drawPositionMarker(canvas, size.width - 7 * cellSize, 0, cellSize);
    _drawPositionMarker(canvas, 0, size.height - 7 * cellSize, cellSize);
  }

  void _drawPositionMarker(Canvas canvas, double x, double y, double cellSize) {
    final paint = Paint()..color = Colors.black;

    for (int i = 0; i < 7; i++) {
      for (int j = 0; j < 7; j++) {
        if (i == 0 || i == 6 || j == 0 || j == 6) {
          canvas.drawRect(
            Rect.fromLTWH(x + i * cellSize, y + j * cellSize, cellSize, cellSize),
            paint,
          );
        }
      }
    }

    for (int i = 2; i < 5; i++) {
      for (int j = 2; j < 5; j++) {
        canvas.drawRect(
          Rect.fromLTWH(x + i * cellSize, y + j * cellSize, cellSize, cellSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(QrCodePainter oldDelegate) => oldDelegate.data != data;
}
