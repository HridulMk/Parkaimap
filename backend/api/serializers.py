from rest_framework import serializers
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

from .models import CCTVFeed, Gate, ParkingSlot, ParkingSpace, Reservation, User


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ['id', 'username', 'email', 'first_name', 'last_name', 'phone', 'user_type', 'is_active', 'is_staff']
        read_only_fields = ['id']


class UserRegistrationSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=6)
    password_confirm = serializers.CharField(write_only=True)
    full_name = serializers.CharField(write_only=True)
    is_active = serializers.BooleanField(default=False)

    class Meta:
        model = User
        fields = ['username', 'email', 'full_name', 'phone', 'user_type', 'password', 'password_confirm', 'is_active']

    def validate(self, data):
        if data['password'] != data['password_confirm']:
            raise serializers.ValidationError('Passwords do not match')
        return data

    def create(self, validated_data):
        validated_data.pop('password_confirm')
        full_name = validated_data.pop('full_name')

        name_parts = full_name.strip().split(' ', 1)
        first_name = name_parts[0]
        last_name = name_parts[1] if len(name_parts) > 1 else ''

        is_active = validated_data.pop('is_active', False)
        request = self.context.get('request')
        if not request or not request.user.is_authenticated or request.user.user_type != 'admin':
            is_active = False

        user = User.objects.create_user(
            username=validated_data['username'],
            email=validated_data['email'],
            first_name=first_name,
            last_name=last_name,
            phone=validated_data.get('phone', ''),
            user_type=validated_data.get('user_type', 'customer'),
            password=validated_data['password'],
            is_active=is_active,
        )
        return user


class ParkingSpaceSerializer(serializers.ModelSerializer):
    vendor_name = serializers.CharField(source='vendor.username', read_only=True)

    class Meta:
        model = ParkingSpace
        fields = [
            'id',
            'name',
            'vendor',
            'vendor_name',
            'address',
            'location',
            'total_slots',
            'open_time',
            'close_time',
            'google_map_link',
            'parking_image',
            'cctv_video',
            'is_active',
            'created_at',
        ]


class ParkingSpaceCreateSerializer(serializers.ModelSerializer):
    number_of_slots = serializers.IntegerField(min_value=1, write_only=True)
    location = serializers.CharField()

    class Meta:
        model = ParkingSpace
        fields = [
            'id',
            'name',
            'number_of_slots',
            'location',
            'open_time',
            'close_time',
            'google_map_link',
            'parking_image',
            'cctv_video',
            'vendor',
            'total_slots',
            'address',
            'created_at',
        ]
        read_only_fields = ['id', 'total_slots', 'address', 'created_at']
        extra_kwargs = {'vendor': {'required': False}}

    def validate(self, attrs):
        open_time = attrs.get('open_time')
        close_time = attrs.get('close_time')
        if open_time and close_time and open_time == close_time:
            raise serializers.ValidationError({'close_time': 'Close time must be different from open time.'})
        return attrs


class ParkingSlotSerializer(serializers.ModelSerializer):
    space_name = serializers.CharField(source='space.name', read_only=True)
    is_reserved = serializers.SerializerMethodField()

    class Meta:
        model = ParkingSlot
        fields = ['id', 'space', 'space_name', 'slot_id', 'label', 'is_occupied', 'is_reserved', 'is_active', 'created_at']

    def get_is_reserved(self, obj):
        return Reservation.objects.filter(
            slot=obj,
            status__in=[
                Reservation.STATUS_PENDING_BOOKING_PAYMENT,
                Reservation.STATUS_RESERVED,
                Reservation.STATUS_CHECKED_IN,
            ],
        ).exists()


class ReservationSerializer(serializers.ModelSerializer):
    user_name = serializers.CharField(source='user.username', read_only=True)
    slot_label = serializers.CharField(source='slot.label', read_only=True)

    class Meta:
        model = Reservation
        fields = [
            'id',
            'user',
            'user_name',
            'slot',
            'slot_label',
            'reservation_id',
            'start_time',
            'end_time',
            'amount',
            'is_paid',
            'booking_fee',
            'booking_fee_paid',
            'checkin_time',
            'checkout_time',
            'final_fee',
            'final_fee_paid',
            'hourly_rate',
            'status',
            'qr_code',
            'qr_image',
            'created_at',
        ]


class GateSerializer(serializers.ModelSerializer):
    space_name = serializers.CharField(source='space.name', read_only=True)

    class Meta:
        model = Gate
        fields = ['id', 'name', 'space', 'space_name', 'is_active', 'last_access', 'access_count']


class CCTVFeedSerializer(serializers.ModelSerializer):
    space_name = serializers.CharField(source='space.name', read_only=True)

    class Meta:
        model = CCTVFeed
        fields = ['id', 'space', 'space_name', 'camera_id', 'name', 'stream_url', 'is_active']


class CustomTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        username = attrs.get(self.username_field)
        if username and '@' in username:
            try:
                user = User.objects.get(email=username)
                attrs[self.username_field] = user.username
            except User.DoesNotExist:
                pass
                
        username_val = attrs.get(self.username_field)
        password_val = attrs.get('password')
        if username_val and password_val:
            try:
                user = User.objects.get(username=username_val)
                if not user.is_active and user.check_password(password_val):
                    from rest_framework.exceptions import AuthenticationFailed
                    raise AuthenticationFailed('Your account is pending admin approval. Please wait for an administrator to activate your account.')
            except User.DoesNotExist:
                pass

        return super().validate(attrs)



