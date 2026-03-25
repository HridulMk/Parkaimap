import 'package:flutter/material.dart';

import '../services/parking_service.dart';

class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  late Future<List<dynamic>> _reservationsFuture;

  @override
  void initState() {
    super.initState();
    _reservationsFuture = ParkingService.getReservations();
  }

  void _reload() {
    setState(() {
      _reservationsFuture = ParkingService.getReservations();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _reservationsFuture,
      builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Failed to load bookings: ${snapshot.error}'),
              ),
            );
          }

          final rows = snapshot.data ?? <dynamic>[];
          if (rows.isEmpty) {
            return const Center(child: Text('No bookings found yet.'));
          }

      return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = rows[i] as Map<String, dynamic>;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.confirmation_number_outlined),
                    title: Text('Reservation: ${r['reservation_id'] ?? '-'}'),
                    subtitle: Text(
                      'Slot: ${r['slot_label'] ?? '-'}\nStatus: ${r['status'] ?? '-'}\nFinal Fee: ${r['final_fee'] ?? r['booking_fee'] ?? '-'}',
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
          );
        },
      );
  }
}



