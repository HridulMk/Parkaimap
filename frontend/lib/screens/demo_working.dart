// ignore_for_file: deprecated_member_use, unnecessary_import

import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:ui';

import '../services/auth_service.dart';
import '../services/parking_service.dart';

class DemoWorkingScreen extends StatefulWidget {
  const DemoWorkingScreen({super.key});

  @override
  State<DemoWorkingScreen> createState() => _DemoWorkingScreenState();
}

class _DemoWorkingScreenState extends State<DemoWorkingScreen> with SingleTickerProviderStateMixin {
  final _nameController = TextEditingController(text: 'Demo Parking Space');
  final _locationController = TextEditingController(text: 'Demo City Center');
  final _slotsController = TextEditingController(text: '5');
  final _openTimeController = TextEditingController(text: '08:00:00');
  final _closeTimeController = TextEditingController(text: '22:00:00');
  final _mapController = TextEditingController();

  PlatformFile? _selectedVideo;
  VideoPlayerController? _videoController;
  VideoPlayerController? _processedVideoController;
  String? _processedVideoUrl;
  String? _lastErrorMessage;
  String? _processingJobId;
  bool _isSubmitting = false;
  bool _isProcessing = false;
  int _occupiedSlots = 0;
  int _freeSlots = 0;
  int _processingProgress = 0;
  Timer? _processingTimer;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  final List<List<Offset>> _polygons = [];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_animationController);
    _loadPolygons();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _slotsController.dispose();
    _openTimeController.dispose();
    _closeTimeController.dispose();
    _mapController.dispose();
    _videoController?.dispose();
    _processedVideoController?.dispose();
    _processingTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadPolygons() async {
    final result = await ParkingService.loadPolygons();
    if (result['success'] == true && result['polygons'] != null) {
      setState(() {
        _polygons.clear();
        _polygons.addAll(result['polygons'] as List<List<Offset>>);
      });
    }
  }

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video, withData: true);
    if (result != null) {
      setState(() {
        _selectedVideo = result.files.single;
        _processedVideoUrl = null;
        _processedVideoController?.dispose();
        _processedVideoController = null;
        _lastErrorMessage = null;
      });
      if (kIsWeb && _selectedVideo?.bytes != null) {
        final dataUrl = Uri.dataFromBytes(
          _selectedVideo!.bytes!,
          mimeType: 'video/mp4',
        ).toString();
        _videoController = VideoPlayerController.networkUrl(Uri.parse(dataUrl));
        await _videoController!.initialize();
        setState(() {});
        _animationController.forward(from: 0.0);
      } else if (!kIsWeb && _selectedVideo?.path != null) {
        _videoController = VideoPlayerController.file(File(_selectedVideo!.path!));
        await _videoController!.initialize();
        setState(() {});
        _animationController.forward(from: 0.0);
      }
    }
  }

  Future<void> _savePolygons() async {
    final result = await ParkingService.savePolygons(_polygons);
    if (!mounted) return;
    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Polygons saved successfully')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save polygons: ${result['error']}')),
      );
    }
  }

  Future<void> _submitDemo() async {
    final isLoggedIn = await AuthService.isLoggedIn();
    if (!isLoggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please login as vendor/admin to upload CCTV demo.')),
      );
      Navigator.pushNamed(context, '/login');
      return;
    }

    final slots = int.tryParse(_slotsController.text.trim());
    if (_nameController.text.trim().isEmpty ||
        _locationController.text.trim().isEmpty ||
        slots == null ||
        slots <= 0 ||
        _selectedVideo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all required fields and select a CCTV video.')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _isProcessing = true;
      _processingProgress = 0;
      _lastErrorMessage = null;
      _processingJobId = null;
    });

    final result = await ParkingService.createParkingSpace(
      name: _nameController.text.trim(),
      numberOfSlots: slots,
      location: _locationController.text.trim(),
      openTime: _openTimeController.text.trim(),
      closeTime: _closeTimeController.text.trim(),
      googleMapLink: _mapController.text.trim(),
      cctvVideoPath: _selectedVideo?.path,
      cctvVideoBytes: _selectedVideo?.bytes,
      cctvVideoFileName: _selectedVideo?.name,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      // After creating the space, send the video to the parking_lot-main backend for processing (background job).
      final processingInitResult = await ParkingService.processParkingDemoVideo(
        videoPath: _selectedVideo?.path,
        videoBytes: _selectedVideo?.bytes,
        videoFileName: _selectedVideo?.name,
      );

      if (processingInitResult['success'] == true && processingInitResult['jobId'] != null) {
        _processingJobId = processingInitResult['jobId'] as String;

        // Save polygons with job_id
        final savePolygonsResult = await ParkingService.savePolygons(_polygons, jobId: _processingJobId);
        if (savePolygonsResult['success'] != true) {
          setState(() {
            _isSubmitting = false;
            _isProcessing = false;
            _processingProgress = 0;
            _lastErrorMessage = savePolygonsResult['error']?.toString() ?? 'Failed to save polygons';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_lastErrorMessage!)),
          );
          return;
        }

        _processingTimer?.cancel();
        _processingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
          if (!_isProcessing || _processingJobId == null) {
            timer.cancel();
            return;
          }

          final statusResult = await ParkingService.getParkingVideoJobStatus(_processingJobId!);
          if (!mounted) return;

          if (statusResult['success'] != true) {
            setState(() {
              _isProcessing = false;
              _isSubmitting = false;
              _lastErrorMessage = statusResult['error']?.toString() ?? 'Failed to check processing status';
              _processingProgress = 0;
            });
            timer.cancel();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_lastErrorMessage!)),
            );
            return;
          }

          final status = (statusResult['status'] as String?) ?? 'queued';

          setState(() {
            if (status == 'queued') {
              _processingProgress = 10;
            } else if (status == 'running') {
              _processingProgress = 60;
            } else if (status == 'completed') {
              _processingProgress = 100;
            } else if (status == 'failed') {
              _processingProgress = 0;
            }
          });

          if (status == 'completed') {
            final outputUrl = statusResult['outputVideoUrl'] as String?;
            if (outputUrl != null && outputUrl.isNotEmpty) {
              _processedVideoUrl = outputUrl;
              _processedVideoController = VideoPlayerController.networkUrl(Uri.parse(outputUrl));
              await _processedVideoController!.initialize();
            }

            // Simulate AI results - in real app, parse from backend response if available
            // final totalSlots = slots;
            // _occupiedSlots = (totalSlots * 0.6).round();
            // _freeSlots = totalSlots - _occupiedSlots;
            final occupied = statusResult['occupied'] ?? 0;
final free = statusResult['free'] ?? 0;

_occupiedSlots = occupied;
_freeSlots = free;
final slotData = statusResult['slots'] ?? [];
List<bool> slotStatus = [];

for (var s in slotData) {
  slotStatus.add(s['occupied'] == true);
}

            setState(() {
              _isProcessing = false;
              _isSubmitting = false;
            });
            timer.cancel();

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Demo processed successfully!')),
            );
          } else if (status == 'failed') {
            setState(() {
              _isProcessing = false;
              _isSubmitting = false;
              _lastErrorMessage = statusResult['error']?.toString() ?? 'Video processing failed';
            });
            timer.cancel();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_lastErrorMessage!)),
            );
          }
        });
      } else {
        setState(() {
          _isSubmitting = false;
          _isProcessing = false;
          _processingProgress = 0;
          _lastErrorMessage = processingInitResult['error']?.toString() ?? 'Failed to start video processing';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_lastErrorMessage!)),
        );
      }
    } else {
      setState(() {
        _isSubmitting = false;
        _isProcessing = false;
        _processingProgress = 0;
        _processingTimer?.cancel();
        _lastErrorMessage = result['error']?.toString() ?? 'Demo upload failed';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_lastErrorMessage!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF334155)],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: true,
                flexibleSpace: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Colors.blue.withOpacity(0.1), Colors.cyan.withOpacity(0.1)],
                    ),
                  ),
                  child: const FlexibleSpaceBar(
                    title: Text(
                      'AI Parking Demo',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                    centerTitle: true,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIntroCard(),
                      const SizedBox(height: 24),
                      _buildFormCard(),
                      const SizedBox(height: 24),
                      _buildVideoUploadSection(),
                      if (_selectedVideo != null) _buildVideoPreview(),
                      if (_selectedVideo != null) ...[
                        const SizedBox(height: 24),
                        const Text(
                          'Mark Parking Slots',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildPolygonEditor(),
                        const SizedBox(height: 16),
                        _buildSavePolygonsButton(),
                      ],
                      if (_processedVideoController != null && _processedVideoController!.value.isInitialized)
                        const SizedBox(height: 24),
                      if (_processedVideoController != null && _processedVideoController!.value.isInitialized)
                        _buildProcessedVideoPlayer(),
                      const SizedBox(height: 24),
                      _buildSubmitButton(),
                      if (_occupiedSlots > 0 || _freeSlots > 0) _buildResultsCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIntroCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.1),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy, color: Colors.cyan[400], size: 28),
              const SizedBox(width: 12),
              const Text(
                'Experience AI-Powered Parking',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Upload a CCTV video and watch our AI model analyze parking slots in real-time. It detects vehicles, counts occupied and free spaces, and provides instant insights.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Parking Space Details',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _buildTextField(_nameController, 'Parking Space Name', Icons.local_parking),
          const SizedBox(height: 12),
          _buildTextField(_locationController, 'Location', Icons.location_on),
          const SizedBox(height: 12),
          _buildTextField(_slotsController, 'Number of Slots', Icons.grid_view, keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildTextField(_openTimeController, 'Open Time', Icons.access_time)),
              const SizedBox(width: 12),
              Expanded(child: _buildTextField(_closeTimeController, 'Close Time', Icons.access_time)),
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(_mapController, 'Google Map Link (optional)', Icons.map),
        ],
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, IconData icon, {TextInputType? keyboardType}) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
        prefixIcon: Icon(icon, color: Colors.cyan[400]),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.cyan, width: 2),
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
      ),
    );
  }

  Widget _buildVideoUploadSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        children: [
          Icon(Icons.videocam, color: Colors.cyan[400], size: 48),
          const SizedBox(height: 12),
          const Text(
            'Upload CCTV Video',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Select a video file to analyze parking occupancy',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (_selectedVideo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                'Selected file: ${_selectedVideo!.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ElevatedButton.icon(
            onPressed: _pickVideo,
            icon: const Icon(Icons.upload_file),
            label: const Text('Choose Video'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan[600],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withOpacity(0.05),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          children: [
            Text(
              'Selected: ${_selectedVideo!.name}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            if (_videoController != null && _videoController!.value.isInitialized)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: _videoController!.value.aspectRatio,
                  child: VideoPlayer(_videoController!),
                ),
              ),
            if (_videoController != null && _videoController!.value.isInitialized)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _videoController!.value.isPlaying
                              ? _videoController!.pause()
                              : _videoController!.play();
                        });
                      },
                      icon: Icon(
                        _videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        _videoController!,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.cyan,
                          bufferedColor: Colors.cyanAccent,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessedVideoPlayer() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.movie_filter, color: Colors.cyan[400]),
              const SizedBox(width: 8),
              const Text(
                'Processed Simulation',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_processedVideoUrl != null)
            Text(
              _processedVideoUrl!,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 12,
              ),
            ),
          const SizedBox(height: 12),
          if (_processedVideoController != null && _processedVideoController!.value.isInitialized)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: _processedVideoController!.value.aspectRatio,
                child: VideoPlayer(_processedVideoController!),
              ),
            ),
          if (_processedVideoController != null && _processedVideoController!.value.isInitialized)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _processedVideoController!.value.isPlaying
                            ? _processedVideoController!.pause()
                            : _processedVideoController!.play();
                      });
                    },
                    icon: Icon(
                      _processedVideoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      _processedVideoController!,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: Colors.cyan,
                        bufferedColor: Colors.cyanAccent,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSavePolygonsButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _polygons.isEmpty ? null : _savePolygons,
        icon: const Icon(Icons.save),
        label: const Text('Save Polygons'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange[600],
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: (_isSubmitting || _isProcessing) ? null : _submitDemo,
            icon: _isProcessing ? const SizedBox.shrink() : const Icon(Icons.play_arrow),
            label: _isProcessing
                ? const Text('Processing with AI...')
                : Text(_isSubmitting ? 'Uploading...' : 'Run AI Analysis'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[600],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (_isProcessing) ...[
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Processing video... $_processingProgress%',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _processingProgress.clamp(0, 100) / 100.0,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyan),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ],
          if (_lastErrorMessage != null && !_isProcessing) ...[
            const SizedBox(height: 12),
            Text(
              _lastErrorMessage!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withOpacity(0.1),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: Colors.green[400], size: 28),
              const SizedBox(width: 12),
              const Text(
                'AI Analysis Results',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildResultItem('Occupied Slots', _occupiedSlots, Colors.red[400]!),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildResultItem('Free Slots', _freeSlots, Colors.green[400]!),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPolygonEditor() {
    final width = MediaQuery.of(context).size.width - 40;
    const height = 220.0;

    if (_videoController == null || !_videoController!.value.isInitialized) {
      return Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.black.withOpacity(0.2),
          border: Border.all(color: Colors.white.withOpacity(0.3)),
        ),
        child: const Text(
          'Load a video to mark parking zones',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: width,
          height: height,
          child: PolygonEditor(
            polygons: _polygons,
            onChanged: (polys) => setState(() {}),
            background: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController!.value.size.width,
                height: _videoController!.value.size.height,
                child: VideoPlayer(_videoController!),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _polygons.isEmpty ? 'Tap to add points' : '${_polygons.length} zone(s) defined',
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildResultItem(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: TextStyle(
              color: color,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class PolygonEditor extends StatefulWidget {
  final List<List<Offset>> polygons;
  final ValueChanged<List<List<Offset>>> onChanged;
  final Widget background;

  const PolygonEditor({
    super.key,
    required this.polygons,
    required this.onChanged,
    required this.background,
    
  });

  @override
  State<PolygonEditor> createState() => _PolygonEditorState();
}

class _PolygonEditorState extends State<PolygonEditor> {
  List<List<Offset>> get _polygons => widget.polygons;
  List<Offset> _currentPolygon = [];

  void _handleTap(TapUpDetails details) {
    final localPos = details.localPosition;
    setState(() {
      _currentPolygon.add(localPos);
    });
  }

  void _finishPolygon() {
    if (_currentPolygon.length < 3) return;
    setState(() {
      _polygons.add(List<Offset>.from(_currentPolygon));
      _currentPolygon = [];
    });
    widget.onChanged(_polygons);
  }

  void _undoLastPoint() {
    if (_currentPolygon.isNotEmpty) {
      setState(() {
        _currentPolygon.removeLast();
      });
    }
  }

  void _clearAll() {
    setState(() {
      _polygons.clear();
      _currentPolygon.clear();
    });
    widget.onChanged(_polygons);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            minScale: 0.7,
            maxScale: 4.0,
            child: GestureDetector(
              onTapUp: _handleTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.background,
                    CustomPaint(
                      painter: _PolygonPainter(
  polygons: _polygons,
  currentPolygon: _currentPolygon,
  slotStatus: [], // empty while editing
),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ElevatedButton(
              onPressed: _finishPolygon,
              child: const Text('Finish Polygon'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _undoLastPoint,
              child: const Text('Undo Point'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _clearAll,
              child: const Text('Clear All'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PolygonPainter extends CustomPainter {
  final List<List<Offset>> polygons;
  final List<Offset> currentPolygon;
  final List<bool> slotStatus; // true = occupied, false = free

  _PolygonPainter({
    required this.polygons,
    required this.currentPolygon,
    required this.slotStatus,
  });

 @override
void paint(Canvas canvas, Size size) {
  for (int i = 0; i < polygons.length; i++) {
    final poly = polygons[i];

    if (poly.length < 2) continue;

    // ✅ Get slot status safely
    final isOccupied =
        (i < slotStatus.length) ? slotStatus[i] : false;

    // ✅ Dynamic color based on AI result
    final fillPaint = Paint()
      ..color = isOccupied
          ? Colors.red.withOpacity(0.4)
          : Colors.green.withOpacity(0.4)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = isOccupied ? Colors.red : Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final path = Path()..addPolygon(poly, true);

canvas.drawPath(path, fillPaint);
canvas.drawPath(path, borderPaint);

// ✅ Calculate center of polygon
double centerX = 0;
double centerY = 0;

for (final p in poly) {
  centerX += p.dx;
  centerY += p.dy;
}

centerX /= poly.length;
centerY /= poly.length;

// ✅ Draw slot number text
final textPainter = TextPainter(
  text: TextSpan(
    text: 'S${i + 1}', // Slot number
    style: TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
    ),
  ),
  textDirection: TextDirection.ltr,
);

textPainter.layout();

// Center text
final offset = Offset(
  centerX - textPainter.width / 2,
  centerY - textPainter.height / 2,
);

textPainter.paint(canvas, offset);
  }

  // ✏️ Drawing current polygon (while user is marking)
  if (currentPolygon.isNotEmpty) {
    final path = Path()..addPolygon(currentPolygon, false);

    final currentPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawPath(path, currentPaint);

    for (final p in currentPolygon) {
      canvas.drawCircle(p, 4, Paint()..color = const Color(0xFF38BDF8));
    }
  }
}

  @override
  bool shouldRepaint(covariant _PolygonPainter oldDelegate) {
    return oldDelegate.polygons != polygons || oldDelegate.currentPolygon != currentPolygon;
  }
}
