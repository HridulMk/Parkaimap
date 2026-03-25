import 'dart:convert';
import 'dart:ui';

import '../models/parking_slot.dart';
import 'api_service.dart';
import 'package:http/http.dart' as http;

class ParkingService {
  static List<dynamic> _normalizeListResponse(dynamic response) {
    if (response is List) return response;
    if (response is Map<String, dynamic> && response['results'] is List) {
      return response['results'] as List<dynamic>;
    }
    return <dynamic>[];
  }

  static Future<List<dynamic>> getParkingSpaces() async {
    try {
      final response = await ApiService.get('spaces/', auth: true);
      return _normalizeListResponse(response);
    } catch (e) {
      throw Exception('Failed to load parking spaces: $e');
    }
  }

  static Future<List<dynamic>> getSlots(int spaceId) async {
    try {
      final response = await ApiService.get('slots/?space=$spaceId', auth: true);
      return _normalizeListResponse(response);
    } catch (e) {
      throw Exception('Failed to load parking slots: $e');
    }
  }

  static Future<List<ParkingSlot>> getParkingSlots() async {
    try {
      final response = await ApiService.get('slots/', auth: true);
      final rows = _normalizeListResponse(response);
      return rows.map((slotData) => ParkingSlot.fromJson(slotData as Map<String, dynamic>)).toList();
    } catch (e) {
      throw Exception('Failed to load all parking slots: $e');
    }
  }

  static Future<Map<String, dynamic>> reserveSlot({required int spaceId, required int slotId}) async {
    try {
      final response = await ApiService.post('spaces/$spaceId/slots/$slotId/book/', auth: true);
      return {'success': true, 'reservation': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<List<dynamic>> getReservations() async {
    try {
      final response = await ApiService.get('reservations/', auth: true);
      return _normalizeListResponse(response);
    } catch (e) {
      throw Exception('Failed to fetch reservations: $e');
    }
  }

  static Future<Map<String, dynamic>> payReservation(int reservationId) async {
    try {
      final response = await ApiService.post('reservations/$reservationId/pay_booking/', auth: true);
      return {'success': true, 'reservation': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<String> getReservationQrUrl(int reservationId) async {
    try {
      final response = await ApiService.get('reservations/$reservationId/qr/', auth: true);
      final url = response['qr_image_url']?.toString() ?? '';
      if (url.isEmpty) throw Exception('QR image not available');
      return url;
    } catch (e) {
      throw Exception('Failed to get QR URL: $e');
    }
  }

  static Future<List<int>> getReservationQrImageBytes(int reservationId) async {
    final url = await getReservationQrUrl(reservationId);
    final token = await ApiService.getAccessToken();
    final response = await http.get(
      Uri.parse(url),
      headers: token != null ? {'Authorization': 'Bearer $token'} : {},
    );
    if (response.statusCode != 200) throw Exception('Failed to download QR image');
    return response.bodyBytes;
  }

  static Future<Map<String, dynamic>> scanQrCode(String qrCode) async {
    try {
      final response = await ApiService.post(
        'reservations/scan/',
        auth: true,
        body: {'qr_code': qrCode},
      );
      return {
        'success': true,
        'action': response['action'],
        'message': response['message'],
        'reservation': response['reservation'],
      };
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> checkIn(int reservationId) async {
    try {
      final response = await ApiService.post('reservations/$reservationId/checkin/', auth: true);
      return {'success': true, 'reservation': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> checkOut(int reservationId) async {
    try {
      final response = await ApiService.post('reservations/$reservationId/checkout/', auth: true);
      return {'success': true, 'reservation': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> payFinal(int reservationId) async {
    try {
      final response = await ApiService.post('reservations/$reservationId/pay_final/', auth: true);
      return {'success': true, 'reservation': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<bool> cancelReservation(int reservationId) async {
    try {
      await ApiService.delete('reservations/$reservationId/');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> createParkingSpace({
    required String name,
    required int numberOfSlots,
    required String location,
    required String openTime,
    required String closeTime,
    String? googleMapLink,
    String? imagePath,
    List<int>? imageBytes,
    String? imageFileName,
    String? cctvVideoPath,
    List<int>? cctvVideoBytes,
    String? cctvVideoFileName,
    int? vendorId,
  }) async {
    try {
      final files = <String, MultipartUploadFile>{};

      if ((imageBytes != null && imageBytes.isNotEmpty) || (imagePath != null && imagePath.isNotEmpty)) {
        files['parking_image'] = MultipartUploadFile(
          filename: imageFileName ?? 'parking_image.jpg',
          path: imagePath,
          bytes: imageBytes,
        );
      }

      if ((cctvVideoBytes != null && cctvVideoBytes.isNotEmpty) || (cctvVideoPath != null && cctvVideoPath.isNotEmpty)) {
        files['cctv_video'] = MultipartUploadFile(
          filename: cctvVideoFileName ?? 'cctv_video.mp4',
          path: cctvVideoPath,
          bytes: cctvVideoBytes,
        );
      }

      final fields = <String, String>{
        'name': name,
        'number_of_slots': numberOfSlots.toString(),
        'location': location,
        'open_time': openTime,
        'close_time': closeTime,
        'google_map_link': googleMapLink ?? '',
      };

      if (vendorId != null) {
        fields['vendor'] = vendorId.toString();
      }

      final response = await ApiService.postMultipart(
        'spaces/create-space/',
        auth: true,
        fields: fields,
        files: files,
      );
      return {'success': true, 'space': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> processParkingDemoVideo({
    String? videoPath,
    List<int>? videoBytes,
    String? videoFileName,
    List<List<Offset>>? polygons,
  }) async {
    try {
      final files = <String, MultipartUploadFile>{};
      final fields = <String, String>{};

      if ((videoBytes != null && videoBytes.isNotEmpty) || (videoPath != null && videoPath.isNotEmpty)) {
        files['video'] = MultipartUploadFile(
          filename: videoFileName ?? 'demo_video.mp4',
          path: videoPath,
          bytes: videoBytes,
        );
      }

      if (polygons != null && polygons.isNotEmpty) {
        // Serialize polygons to JSON
        final polygonsJson = polygons.map((polygon) =>
          polygon.map((offset) => {'x': offset.dx, 'y': offset.dy}).toList()
        ).toList();
        fields['polygons'] = jsonEncode(polygonsJson);
      }

      final response = await ApiService.postMultipart(
        'parking-lot/process-video/',
        auth: true,
        files: files,
        fields: fields,
      );

      if (response is Map<String, dynamic>) {
        return {
          'success': true,
          'jobId': response['job_id'],
          'status': response['status'],
          'inputVideoUrl': response['input_video_url'],
        };
      }

      return {'success': false, 'error': 'Unexpected response from server'};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> getParkingVideoJobStatus(String jobId) async {
    try {
      final response = await ApiService.get(
        'parking-lot/jobs/$jobId/',
        auth: true,
      );

      if (response is Map<String, dynamic>) {
        return {
          'success': true,
          'status': response['status'],
          'inputVideoUrl': response['input_video_url'],
          'outputVideoUrl': response['output_video_url'],
          'error': response['error'],
          'occupied': response['occupied'],
          'free': response['free'],
          'total': response['total'],
          'slots': response['slots'], // ✅ ADD THIS LINE
        };
      }

      return {'success': false, 'error': 'Unexpected response from server'};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> savePolygons(List<List<Offset>> polygons, {
    String? jobId,
    String? videoPath,
    List<int>? videoBytes,
    String? videoFileName,
  }) async {
    try {
      final fields = <String, String>{};
      final files = <String, MultipartUploadFile>{};

      // Use double values for coordinates, do not round
      final payloadPolygons = polygons
          .map((List<Offset> poly) => poly
              .map((Offset p) => [p.dx, p.dy])
              .toList())
          .toList();
      fields['polygons'] = jsonEncode(payloadPolygons);
      if (jobId != null) {
        fields['job_id'] = jobId;
      }

      if ((videoBytes != null && videoBytes.isNotEmpty) || (videoPath != null && videoPath.isNotEmpty)) {
        files['video'] = MultipartUploadFile(
          filename: videoFileName ?? 'video.mp4',
          path: videoPath,
          bytes: videoBytes,
        );
      }

      final response = await ApiService.postMultipart(
        'parking-lot/polygons/',
        auth: true,
        fields: fields,
        files: files,
      );

      if (response is Map<String, dynamic>) {
        return {'success': true, 'polygons': response['polygons']};
      }

      return {'success': false, 'error': 'Unexpected response from server'};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> loadPolygons({String? jobId}) async {
    try {
      String endpoint = 'parking-lot/polygons/';
      if (jobId != null) {
        endpoint += '?job_id=$jobId';
      }
      final response = await ApiService.get(
        endpoint,
        auth: true,
      );

      if (response is Map<String, dynamic> && response['polygons'] is List) {
        final polygonsData = response['polygons'] as List;
        final polygons = polygonsData
            .map((poly) => (poly as List)
                .map((point) => Offset((point[0] as num).toDouble(), (point[1] as num).toDouble()))
                .toList())
            .toList();
        return {'success': true, 'polygons': polygons};
      }

      return {'success': false, 'error': 'Unexpected response from server'};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<List<dynamic>> getUsers() async {
    final response = await ApiService.get('users/', auth: true);
    return _normalizeListResponse(response);
  }

  static Future<Map<String, dynamic>> updateUserStatus(int userId, bool isActive) async {
    try {
      final response = await ApiService.patch('users/$userId/', auth: true, body: {'is_active': isActive});
      return {'success': true, 'user': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> setSpaceActive(int spaceId, bool isActive) async {
    try {
      final endpoint = isActive ? 'spaces/$spaceId/activate/' : 'spaces/$spaceId/deactivate/';
      final response = await ApiService.post(endpoint, auth: true);
      return {'success': true, 'data': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  static Future<Map<String, dynamic>> setSlotActive(int slotId, bool isActive) async {
    try {
      final endpoint = isActive ? 'slots/$slotId/activate/' : 'slots/$slotId/deactivate/';
      final response = await ApiService.post(endpoint, auth: true);
      return {'success': true, 'data': response};
    } catch (e) {
      return {'success': false, 'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }
}
