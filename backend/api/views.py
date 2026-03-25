from decimal import Decimal, ROUND_HALF_UP
from datetime import timedelta
import io
import json
import os
import subprocess
import uuid

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import FileSystemStorage
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import status, viewsets
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.views import TokenObtainPairView
import qrcode

from .models import CCTVFeed, Gate, ParkingSlot, ParkingSpace, Reservation, User
from .permissions import IsAdminUserType, IsVendorOrAdmin
from .realtime import notify_slot_update
from .serializers import (
    CCTVFeedSerializer,
    CustomTokenObtainPairSerializer,
    GateSerializer,
    ParkingSlotSerializer,
    ParkingSpaceCreateSerializer,
    ParkingSpaceSerializer,
    ReservationSerializer,
    UserRegistrationSerializer,
    UserSerializer,
)

BOOKING_FEE = Decimal('1.00')
HOURLY_RATE = Decimal('2.40')


def _generate_qr_image(reservation):
    img = qrcode.make(reservation.qr_code)
    buffer = io.BytesIO()
    img.save(buffer, format='PNG')
    buffer.seek(0)
    filename = f"{reservation.reservation_id}.png"
    reservation.qr_image.save(
        filename,
        ContentFile(buffer.read()),
        save=False,
    )


def _can_manage_space(user, space):
    if user.is_staff or user.user_type == 'admin':
        return True
    return user.user_type == 'vendor' and space.vendor_id == user.id


def _active_booking_exists(slot):
    return Reservation.objects.filter(
        slot=slot,
        status__in=[
            Reservation.STATUS_PENDING_BOOKING_PAYMENT,
            Reservation.STATUS_RESERVED,
            Reservation.STATUS_CHECKED_IN,
        ],
    ).exists()


def _create_pending_reservation(user, slot):
    if user.user_type != 'customer':
        return Response({'detail': 'Only customers can create a booking reservation.'}, status=status.HTTP_403_FORBIDDEN)

    if not slot.space.is_active:
        return Response({'detail': 'Parking space is not active.'}, status=status.HTTP_400_BAD_REQUEST)

    if not slot.is_active:
        return Response({'detail': 'Parking slot is not active.'}, status=status.HTTP_400_BAD_REQUEST)

    if slot.is_occupied or _active_booking_exists(slot):
        return Response({'detail': 'Slot is not available for booking.'}, status=status.HTTP_400_BAD_REQUEST)

    now = timezone.now()
    reservation = Reservation.objects.create(
        user=user,
        slot=slot,
        reservation_id=f"PKG{now.strftime('%Y%m%d%H%M%S')}{user.id}{slot.id}",
        start_time=now,
        end_time=now,
        amount=Decimal('0.00'),
        is_paid=False,
        booking_fee=BOOKING_FEE,
        booking_fee_paid=False,
        hourly_rate=HOURLY_RATE,
        status=Reservation.STATUS_PENDING_BOOKING_PAYMENT,
    )

    notify_slot_update(slot.space_id, reason='reservation_pending')
    return Response(ReservationSerializer(reservation).data, status=status.HTTP_201_CREATED)


def _create_space_and_slots(request):
    serializer = ParkingSpaceCreateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    validated = serializer.validated_data
    user = request.user
    requested_vendor = validated.get('vendor')

    if user.user_type == 'vendor':
        vendor = user
    else:
        # Admin can assign a vendor, or upload the space as admin when vendor is omitted.
        vendor = requested_vendor or user

    number_of_slots = validated['number_of_slots']

    with transaction.atomic():
        parking_space = ParkingSpace.objects.create(
            name=validated['name'],
            vendor=vendor,
            total_slots=number_of_slots,
            address=validated['location'],
            location=validated['location'],
            open_time=validated.get('open_time'),
            close_time=validated.get('close_time'),
            google_map_link=validated.get('google_map_link', ''),
            parking_image=validated.get('parking_image'),
            cctv_video=validated.get('cctv_video'),
        )

        for idx in range(1, number_of_slots + 1):
            ParkingSlot.objects.create(
                space=parking_space,
                slot_id=f'S{parking_space.id:03d}-{idx:03d}',
                label=f'Slot {idx}',
            )

    notify_slot_update(parking_space.id, reason='space_slots_created')
    payload = ParkingSpaceSerializer(parking_space).data
    payload['slots_created'] = number_of_slots
    return Response(payload, status=status.HTTP_201_CREATED)


class ParkingSpaceCreateEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def post(self, request):
        return _create_space_and_slots(request)


class CustomerSlotBookingEndpoint(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, space_id, slot_id):
        slot = get_object_or_404(ParkingSlot, id=slot_id, space_id=space_id)
        return _create_pending_reservation(request.user, slot)


class ParkingSpaceDeleteEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]

    def delete(self, request, space_id):
        parking_space = get_object_or_404(ParkingSpace, id=space_id)
        if not _can_manage_space(request.user, parking_space):
            return Response({'detail': 'You do not have permission to delete this parking space.'}, status=status.HTTP_403_FORBIDDEN)

        slot_count = ParkingSlot.objects.filter(space=parking_space).count()
        parking_space.delete()
        return Response({'message': 'Parking space deleted successfully.', 'parking_space_id': space_id, 'slots_deleted': slot_count}, status=status.HTTP_200_OK)


class ParkingSpaceSlotsDeleteEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]

    def delete(self, request, space_id):
        parking_space = get_object_or_404(ParkingSpace, id=space_id)
        if not _can_manage_space(request.user, parking_space):
            return Response({'detail': 'You do not have permission to delete slots for this parking space.'}, status=status.HTTP_403_FORBIDDEN)

        slot_qs = ParkingSlot.objects.filter(space=parking_space)
        slot_count = slot_qs.count()
        slot_qs.delete()
        notify_slot_update(parking_space.id, reason='space_slots_deleted')
        parking_space.total_slots = 0
        parking_space.save(update_fields=['total_slots'])
        return Response({'message': 'Parking slots deleted successfully.', 'parking_space_id': space_id, 'slots_deleted': slot_count}, status=status.HTTP_200_OK)


class ParkingSlotDeleteEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]

    def delete(self, request, slot_id):
        slot = get_object_or_404(ParkingSlot, id=slot_id)
        parking_space = slot.space
        if not _can_manage_space(request.user, parking_space):
            return Response({'detail': 'You do not have permission to delete this parking slot.'}, status=status.HTTP_403_FORBIDDEN)

        slot.delete()
        notify_slot_update(parking_space.id, reason='slot_deleted')
        parking_space.total_slots = ParkingSlot.objects.filter(space=parking_space).count()
        parking_space.save(update_fields=['total_slots'])
        return Response({'message': 'Parking slot deleted successfully.', 'parking_slot_id': slot_id, 'parking_space_id': parking_space.id}, status=status.HTTP_200_OK)


class ParkingSpaceActivateEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsAdminUserType]

    def post(self, request, space_id):
        parking_space = get_object_or_404(ParkingSpace, id=space_id)
        parking_space.is_active = True
        parking_space.save(update_fields=['is_active'])
        notify_slot_update(parking_space.id, reason='space_activated')
        return Response({'message': 'Parking space activated.', 'parking_space_id': parking_space.id, 'is_active': parking_space.is_active}, status=status.HTTP_200_OK)


class ParkingSpaceDeactivateEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsAdminUserType]

    def post(self, request, space_id):
        parking_space = get_object_or_404(ParkingSpace, id=space_id)
        parking_space.is_active = False
        parking_space.save(update_fields=['is_active'])
        notify_slot_update(parking_space.id, reason='space_deactivated')
        return Response({'message': 'Parking space deactivated.', 'parking_space_id': parking_space.id, 'is_active': parking_space.is_active}, status=status.HTTP_200_OK)


class ParkingSpaceCCTVUploadEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request, space_id):
        parking_space = get_object_or_404(ParkingSpace, id=space_id)
        if not _can_manage_space(request.user, parking_space):
            return Response({'detail': 'You do not have permission to upload CCTV video for this parking space.'}, status=status.HTTP_403_FORBIDDEN)

        file_obj = request.FILES.get('cctv_video')
        if not file_obj:
            return Response({'detail': 'No CCTV video file provided. Expected field name "cctv_video".'}, status=status.HTTP_400_BAD_REQUEST)

        parking_space.cctv_video = file_obj
        parking_space.save(update_fields=['cctv_video'])

        notify_slot_update(parking_space.id, reason='cctv_video_uploaded')
        return Response(ParkingSpaceSerializer(parking_space).data, status=status.HTTP_200_OK)


class ParkingLotVideoProcessEndpoint(APIView):
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request):
        file_obj = request.FILES.get('video')
        if not file_obj:
            return Response(
                {'detail': 'No video file provided. Expected field name "video".'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Create a job record on disk first
        jobs_dir = os.path.join(settings.MEDIA_ROOT, 'parking_lot_jobs')
        os.makedirs(jobs_dir, exist_ok=True)
        job_id = uuid.uuid4().hex
        job_path = os.path.join(jobs_dir, f'{job_id}.json')

        # Save input video
        input_dir = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'uploads', job_id)
        os.makedirs(input_dir, exist_ok=True)
        input_storage = FileSystemStorage(location=input_dir)
        input_name = input_storage.save(file_obj.name, file_obj)
        input_path = input_storage.path(input_name)

        # Save polygons if provided
        polygons_data = request.POST.get('polygons')
        if polygons_data:
            try:
                polygons = json.loads(polygons_data)
                polygons_path = os.path.join(input_dir, 'polygons.json')
                with open(polygons_path, 'w', encoding='utf-8') as f:
                    json.dump(polygons, f)
            except (json.JSONDecodeError, ValueError):
                pass  # Ignore invalid polygons

        # Prepare output path inside MEDIA_ROOT so job status can serve it
        output_dir = os.path.join(settings.MEDIA_ROOT, 'parking_lot_output')
        os.makedirs(output_dir, exist_ok=True)
        base_name, _ = os.path.splitext(input_name)
        output_name = base_name + '_processed.mp4'
        output_path = os.path.join(output_dir, output_name)

        job_payload = {
            'job_id': job_id,
            'status': 'queued',
            'input_relative_path': os.path.join('uploads', job_id, input_name),
            'output_relative_path': os.path.join('parking_lot_output', output_name),
            'error': None,
        }
        try:
            with open(job_path, 'w', encoding='utf-8') as f:
                json.dump(job_payload, f)
        except OSError:
            return Response({'detail': 'Failed to create processing job.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        # Run the parking_lot-main processing script in the background
        script_path = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'process_video.py')
        subprocess.Popen(  # noqa: S603
            ['python', str(script_path), input_path, output_path, job_path],
        )

        input_url = None  # Since video is not in media root, no public URL

        return Response(
            {
                'job_id': job_id,
                'status': 'queued',
                'input_video_url': input_url,
            },
            status=status.HTTP_202_ACCEPTED,
        )


class ParkingLotPolygonsEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsVendorOrAdmin]
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def get(self, request):
        job_id = request.query_params.get('job_id')
        if job_id:
            polygons_path = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'uploads', job_id, 'polygons.json')
        else:
            polygons_path = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'uploads', 'polygons.json')
        if not os.path.exists(polygons_path):
            return Response({'polygons': []}, status=status.HTTP_200_OK)

        try:
            with open(polygons_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError, ValueError):
            return Response({'polygons': []}, status=status.HTTP_200_OK)

        return Response({'polygons': data}, status=status.HTTP_200_OK)

    def post(self, request):
        job_id = request.POST.get('job_id')
        polygons_str = request.POST.get('polygons')
        if not polygons_str:
            return Response({'detail': 'Polygons data is required.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            polygons = json.loads(polygons_str)
        except json.JSONDecodeError:
            return Response({'detail': 'Invalid polygons JSON.'}, status=status.HTTP_400_BAD_REQUEST)

        if not isinstance(polygons, list):
            return Response({'detail': 'Invalid payload: "polygons" must be a list.'}, status=status.HTTP_400_BAD_REQUEST)

        # Basic validation: each polygon should be a list of at least 3 points [x, y].
        for poly in polygons:
            if not isinstance(poly, list) or len(poly) < 3:
                return Response(
                    {'detail': 'Each polygon must be a list of at least 3 [x, y] points.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            for point in poly:
                if (
                    not isinstance(point, (list, tuple))
                    or len(point) != 2
                    or not isinstance(point[0], (int, float))
                    or not isinstance(point[1], (int, float))
                ):
                    return Response(
                        {'detail': 'Each point must be a two-element list [x, y] with numeric values.'},
                        status=status.HTTP_400_BAD_REQUEST,
                    )

        if job_id:
            dir_path = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'uploads', job_id)
            polygons_path = os.path.join(dir_path, 'polygons.json')
            video_path = os.path.join(dir_path, 'video.mp4')
        else:
            dir_path = os.path.join(settings.BASE_DIR, 'parking_lot-main', 'uploads')
            polygons_path = os.path.join(dir_path, 'polygons.json')
            video_path = os.path.join(dir_path, 'video.mp4')

        os.makedirs(dir_path, exist_ok=True)

        # Save polygons
        try:
            with open(polygons_path, 'w', encoding='utf-8') as f:
                json.dump(polygons, f)
        except OSError:
            return Response({'detail': 'Failed to write polygons configuration.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        # Save video if provided
        file_obj = request.FILES.get('video')
        if file_obj:
            try:
                with open(video_path, 'wb') as f:
                    for chunk in file_obj.chunks():
                        f.write(chunk)
            except OSError:
                return Response({'detail': 'Failed to save video file.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        return Response({'polygons': polygons}, status=status.HTTP_200_OK)


class ParkingLotVideoJobStatusEndpoint(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, job_id: str):
        jobs_dir = os.path.join(settings.MEDIA_ROOT, 'parking_lot_jobs')
        job_path = os.path.join(jobs_dir, f'{job_id}.json')

        if not os.path.exists(job_path):
            return Response({'detail': 'Job not found.'}, status=status.HTTP_404_NOT_FOUND)

        try:
            with open(job_path, 'r', encoding='utf-8') as f:
                data = json.load(f) or {}
        except (OSError, json.JSONDecodeError):
            return Response({'detail': 'Failed to read job status.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        status_value = data.get('status', 'queued')
        input_rel = data.get('input_relative_path')
        output_rel = data.get('output_relative_path')
        error = data.get('error')
        occupied = data.get('occupied')
        free = data.get('free')
        total = data.get('total')

        input_url = None
        output_url = None

        if input_rel:
            input_url = request.build_absolute_uri(settings.MEDIA_URL + input_rel.replace('\\', '/'))

        if output_rel:
            output_full_path = os.path.join(settings.MEDIA_ROOT, output_rel)
            if os.path.exists(output_full_path):
                output_url = request.build_absolute_uri(settings.MEDIA_URL + output_rel.replace('\\', '/'))

        return Response(
            {
                'job_id': job_id,
                'status': status_value,
                'input_video_url': input_url,
                'output_video_url': output_url,
                'error': error,
                'occupied': occupied,
                'free': free,
                'total': total,
            },
            status=status.HTTP_200_OK,
        )

class ParkingSlotActivateEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsAdminUserType]

    def post(self, request, slot_id):
        slot = get_object_or_404(ParkingSlot, id=slot_id)
        slot.is_active = True
        slot.save(update_fields=['is_active'])
        notify_slot_update(slot.space_id, reason='slot_activated')
        return Response({'message': 'Parking slot activated.', 'parking_slot_id': slot.id, 'is_active': slot.is_active}, status=status.HTTP_200_OK)


class ParkingSlotDeactivateEndpoint(APIView):
    permission_classes = [IsAuthenticated, IsAdminUserType]

    def post(self, request, slot_id):
        slot = get_object_or_404(ParkingSlot, id=slot_id)
        slot.is_active = False
        slot.save(update_fields=['is_active'])
        notify_slot_update(slot.space_id, reason='slot_deactivated')
        return Response({'message': 'Parking slot deactivated.', 'parking_slot_id': slot.id, 'is_active': slot.is_active}, status=status.HTTP_200_OK)


class UserViewSet(viewsets.ModelViewSet):
    queryset = User.objects.all()
    serializer_class = UserSerializer

    def get_permissions(self):
        if self.action in ['create', 'update', 'partial_update', 'destroy']:
            return [IsAuthenticated(), IsAdminUserType()]
        return [IsAuthenticated()]

    def get_serializer_class(self):
        if self.action == 'create':
            return UserRegistrationSerializer
        return UserSerializer

    @action(detail=False, methods=['get'])
    def profile(self, request):
        serializer = self.get_serializer(request.user)
        return Response(serializer.data)


@api_view(['POST'])
@permission_classes([AllowAny])
def register_user(request):
    serializer = UserRegistrationSerializer(data=request.data, context={'request': request})
    if serializer.is_valid():
        user = serializer.save()
        return Response({'message': 'User registered successfully', 'user': UserSerializer(user).data}, status=status.HTTP_201_CREATED)
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


class ParkingSpaceViewSet(viewsets.ModelViewSet):
    queryset = ParkingSpace.objects.all()
    serializer_class = ParkingSpaceSerializer
    permission_classes = [IsAuthenticated]

    def get_permissions(self):
        if self.action in ['create', 'update', 'partial_update', 'destroy', 'create_space']:
            return [IsAuthenticated(), IsVendorOrAdmin()]
        return [IsAuthenticated()]

    def get_queryset(self):
        queryset = ParkingSpace.objects.all()
        user = self.request.user

        if user.user_type == 'vendor':
            return queryset.filter(vendor=user)

        if user.user_type == 'admin' or user.is_staff:
            return queryset

        return queryset.filter(is_active=True)

    @action(
        detail=False,
        methods=['post'],
        url_path='create-space',
        parser_classes=[MultiPartParser, FormParser, JSONParser],
        permission_classes=[IsAuthenticated, IsVendorOrAdmin],
    )
    def create_space(self, request):
        return _create_space_and_slots(request)


class ParkingSlotViewSet(viewsets.ModelViewSet):
    queryset = ParkingSlot.objects.all()
    serializer_class = ParkingSlotSerializer
    permission_classes = [IsAuthenticated]

    def get_permissions(self):
        if self.action in ['create', 'update', 'partial_update', 'destroy']:
            return [IsAuthenticated(), IsVendorOrAdmin()]
        return [IsAuthenticated()]

    def get_queryset(self):
        queryset = ParkingSlot.objects.select_related('space').all()
        user = self.request.user
        space_id = self.request.query_params.get('space')

        if space_id:
            queryset = queryset.filter(space_id=space_id)

        if user.user_type == 'vendor':
            return queryset.filter(space__vendor=user)

        if user.user_type == 'admin' or user.is_staff:
            return queryset

        return queryset.filter(space__is_active=True, is_active=True)

    @action(detail=True, methods=['post'])
    def reserve(self, request, pk=None):
        slot = self.get_object()
        return _create_pending_reservation(request.user, slot)
class ReservationViewSet(viewsets.ModelViewSet):
    queryset = Reservation.objects.all()
    serializer_class = ReservationSerializer

    def get_queryset(self):
        user = self.request.user
        queryset = Reservation.objects.select_related('slot', 'slot__space', 'user').all()

        if user.user_type == 'admin' or user.is_staff:
            return queryset

        if user.user_type == 'vendor':
            return queryset.filter(slot__space__vendor=user)

        return queryset.filter(user=user)

    @action(detail=False, methods=['post'], url_path='scan')
    def scan(self, request):
        qr_data = request.data.get('qr_code', '').strip()
        if not qr_data:
            return Response({'error': 'qr_code is required.'}, status=status.HTTP_400_BAD_REQUEST)

        parts = qr_data.split('|')
        if len(parts) != 3 or parts[0] != 'BOOKING':
            return Response({'error': 'Invalid QR code format.'}, status=status.HTTP_400_BAD_REQUEST)

        reservation_id = parts[2]
        try:
            reservation = Reservation.objects.select_related('slot', 'slot__space', 'user').get(
                reservation_id=reservation_id
            )
        except Reservation.DoesNotExist:
            return Response({'error': 'Reservation not found.'}, status=status.HTTP_404_NOT_FOUND)

        if reservation.status == Reservation.STATUS_RESERVED:
            reservation.checkin_time = timezone.now()
            reservation.start_time = reservation.checkin_time
            reservation.status = Reservation.STATUS_CHECKED_IN
            reservation.save(update_fields=['checkin_time', 'start_time', 'status'])
            notify_slot_update(reservation.slot.space_id, reason='checked_in')
            return Response({
                'action': 'checkin',
                'message': 'Check-in successful.',
                'reservation': self.get_serializer(reservation).data,
            }, status=status.HTTP_200_OK)

        if reservation.status == Reservation.STATUS_CHECKED_IN:
            reservation.checkout_time = timezone.now()
            reservation.end_time = reservation.checkout_time
            duration_seconds = max((reservation.checkout_time - reservation.checkin_time).total_seconds(), 60)
            duration_hours = Decimal(str(duration_seconds / 3600)).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
            final_fee = (duration_hours * reservation.hourly_rate).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
            reservation.final_fee = final_fee
            reservation.amount = final_fee
            reservation.status = Reservation.STATUS_CHECKED_OUT
            reservation.save(update_fields=['checkout_time', 'end_time', 'final_fee', 'amount', 'status'])
            reservation.slot.is_occupied = False
            reservation.slot.save(update_fields=['is_occupied'])
            notify_slot_update(reservation.slot.space_id, reason='checked_out')
            return Response({
                'action': 'checkout',
                'message': 'Check-out successful.',
                'reservation': self.get_serializer(reservation).data,
            }, status=status.HTTP_200_OK)

        return Response({
            'error': f'No action available for reservation status: {reservation.status}.',
            'reservation': self.get_serializer(reservation).data,
        }, status=status.HTTP_400_BAD_REQUEST)

    @action(detail=True, methods=['get'], url_path='qr')
    def qr(self, request, pk=None):
        reservation = self.get_object()
        if not reservation.qr_image:
            return Response({'detail': 'QR image not generated yet.'}, status=status.HTTP_404_NOT_FOUND)
        url = request.build_absolute_uri(reservation.qr_image.url)
        return Response({'reservation_id': reservation.reservation_id, 'qr_image_url': url})

    @action(detail=True, methods=['post'])
    def pay_booking(self, request, pk=None):
        reservation = self.get_object()
        if reservation.status != Reservation.STATUS_PENDING_BOOKING_PAYMENT:
            return Response({'error': 'Booking payment is not allowed at current reservation stage.'}, status=status.HTTP_400_BAD_REQUEST)

        if reservation.booking_fee_paid:
            return Response({'error': 'Booking payment already completed.'}, status=status.HTTP_400_BAD_REQUEST)

        if reservation.slot.is_occupied or _active_booking_exists(reservation.slot):
            # allow current reservation itself
            others = Reservation.objects.filter(
                slot=reservation.slot,
                status__in=[Reservation.STATUS_RESERVED, Reservation.STATUS_CHECKED_IN],
            ).exclude(id=reservation.id)
            if others.exists():
                return Response({'error': 'Slot is no longer available for booking.'}, status=status.HTTP_400_BAD_REQUEST)

        reservation.booking_fee_paid = True
        reservation.status = Reservation.STATUS_RESERVED
        reservation.qr_code = f"BOOKING|{reservation.slot.slot_id}|{reservation.reservation_id}"
        _generate_qr_image(reservation)
        reservation.save(update_fields=['booking_fee_paid', 'status', 'qr_code', 'qr_image'])

        reservation.slot.is_occupied = True
        reservation.slot.save(update_fields=['is_occupied'])
        notify_slot_update(reservation.slot.space_id, reason='booking_paid')

        return Response(self.get_serializer(reservation).data, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'])
    def checkin(self, request, pk=None):
        reservation = self.get_object()
        if reservation.status != Reservation.STATUS_RESERVED:
            return Response({'error': 'Check-in is allowed only after booking payment.'}, status=status.HTTP_400_BAD_REQUEST)

        reservation.checkin_time = timezone.now()
        reservation.start_time = reservation.checkin_time
        reservation.status = Reservation.STATUS_CHECKED_IN
        reservation.save(update_fields=['checkin_time', 'start_time', 'status'])
        notify_slot_update(reservation.slot.space_id, reason='checked_in')
        return Response(self.get_serializer(reservation).data, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'])
    def checkout(self, request, pk=None):
        reservation = self.get_object()
        if reservation.status != Reservation.STATUS_CHECKED_IN:
            return Response({'error': 'Checkout is allowed only after check-in.'}, status=status.HTTP_400_BAD_REQUEST)

        reservation.checkout_time = timezone.now()
        reservation.end_time = reservation.checkout_time

        duration_seconds = max((reservation.checkout_time - reservation.checkin_time).total_seconds(), 60)
        duration_hours = Decimal(str(duration_seconds / 3600)).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
        final_fee = (duration_hours * reservation.hourly_rate).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)

        reservation.final_fee = final_fee
        reservation.amount = final_fee
        reservation.status = Reservation.STATUS_CHECKED_OUT
        reservation.save(update_fields=['checkout_time', 'end_time', 'final_fee', 'amount', 'status'])

        reservation.slot.is_occupied = False
        reservation.slot.save(update_fields=['is_occupied'])
        notify_slot_update(reservation.slot.space_id, reason='checked_out')

        return Response(self.get_serializer(reservation).data, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'])
    def pay_final(self, request, pk=None):
        reservation = self.get_object()
        if reservation.status != Reservation.STATUS_CHECKED_OUT:
            return Response({'error': 'Final payment is allowed only after checkout.'}, status=status.HTTP_400_BAD_REQUEST)

        if reservation.final_fee is None:
            return Response({'error': 'Final fee has not been generated yet.'}, status=status.HTTP_400_BAD_REQUEST)

        if reservation.final_fee_paid:
            return Response({'error': 'Final fee is already paid.'}, status=status.HTTP_400_BAD_REQUEST)

        reservation.final_fee_paid = True
        reservation.is_paid = True
        reservation.status = Reservation.STATUS_COMPLETED
        reservation.save(update_fields=['final_fee_paid', 'is_paid', 'status'])

        return Response(self.get_serializer(reservation).data, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'])
    def pay(self, request, pk=None):
        # Backward-compatible alias for booking payment.
        return self.pay_booking(request, pk)


class GateViewSet(viewsets.ModelViewSet):
    queryset = Gate.objects.all()
    serializer_class = GateSerializer

    @action(detail=True, methods=['post'])
    def access(self, request, pk=None):
        gate = self.get_object()
        gate.last_access = timezone.now()
        gate.access_count += 1
        gate.save()

        serializer = self.get_serializer(gate)
        return Response(serializer.data)


class CCTVFeedViewSet(viewsets.ModelViewSet):
    queryset = CCTVFeed.objects.all()
    serializer_class = CCTVFeedSerializer


class CustomTokenObtainPairView(TokenObtainPairView):
    serializer_class = CustomTokenObtainPairSerializer









