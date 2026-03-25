from django.urls import include, path, re_path
from rest_framework.routers import DefaultRouter
from rest_framework_simplejwt.views import TokenRefreshView  # pyright: ignore[reportMissingImports]

from . import views
from .views import CustomTokenObtainPairView

router = DefaultRouter()
router.register(r'users', views.UserViewSet)
router.register(r'spaces', views.ParkingSpaceViewSet)
router.register(r'slots', views.ParkingSlotViewSet)
router.register(r'reservations', views.ReservationViewSet)
router.register(r'gates', views.GateViewSet)
router.register(r'cctv', views.CCTVFeedViewSet)

urlpatterns = [
    path('', include(router.urls)),

    re_path(r'^spaces/create-space/?$', views.ParkingSpaceCreateEndpoint.as_view(), name='spaces_create_space_explicit'),
    re_path(r'^spaces/(?P<space_id>\d+)/slots/(?P<slot_id>\d+)/book/?$', views.CustomerSlotBookingEndpoint.as_view(), name='customer_slot_book'),
    re_path(r'^spaces/(?P<space_id>\d+)/upload-cctv-video/?$', views.ParkingSpaceCCTVUploadEndpoint.as_view(), name='spaces_upload_cctv_video'),

    re_path(r'^parking-lot/process-video/?$', views.ParkingLotVideoProcessEndpoint.as_view(), name='parking_lot_process_video'),
    re_path(r'^parking-lot/polygons/?$', views.ParkingLotPolygonsEndpoint.as_view(), name='parking_lot_polygons'),
    re_path(r'^parking-lot/jobs/(?P<job_id>[0-9a-f]+)/?$', views.ParkingLotVideoJobStatusEndpoint.as_view(), name='parking_lot_video_job_status'),

    re_path(r'^spaces/(?P<space_id>\d+)/delete/?$', views.ParkingSpaceDeleteEndpoint.as_view(), name='spaces_delete'),
    re_path(r'^spaces/(?P<space_id>\d+)/slots/delete/?$', views.ParkingSpaceSlotsDeleteEndpoint.as_view(), name='spaces_slots_delete'),
    re_path(r'^slots/(?P<slot_id>\d+)/delete/?$', views.ParkingSlotDeleteEndpoint.as_view(), name='slot_delete'),

    re_path(r'^spaces/(?P<space_id>\d+)/activate/?$', views.ParkingSpaceActivateEndpoint.as_view(), name='spaces_activate'),
    re_path(r'^spaces/(?P<space_id>\d+)/deactivate/?$', views.ParkingSpaceDeactivateEndpoint.as_view(), name='spaces_deactivate'),
    re_path(r'^slots/(?P<slot_id>\d+)/activate/?$', views.ParkingSlotActivateEndpoint.as_view(), name='slots_activate'),
    re_path(r'^slots/(?P<slot_id>\d+)/deactivate/?$', views.ParkingSlotDeactivateEndpoint.as_view(), name='slots_deactivate'),

    re_path(r'^reservations/scan/?$', views.ReservationViewSet.as_view({'post': 'scan'}), name='reservation_scan'),
    re_path(r'^reservations/(?P<pk>\d+)/qr/?$', views.ReservationViewSet.as_view({'get': 'qr'}), name='reservation_qr'),
    re_path(r'^reservations/(?P<pk>\d+)/pay_booking/?$', views.ReservationViewSet.as_view({'post': 'pay_booking'}), name='reservation_pay_booking_explicit'),
    re_path(r'^reservations/(?P<pk>\d+)/checkin/?$', views.ReservationViewSet.as_view({'post': 'checkin'}), name='reservation_checkin_explicit'),
    re_path(r'^reservations/(?P<pk>\d+)/checkout/?$', views.ReservationViewSet.as_view({'post': 'checkout'}), name='reservation_checkout_explicit'),
    re_path(r'^reservations/(?P<pk>\d+)/pay_final/?$', views.ReservationViewSet.as_view({'post': 'pay_final'}), name='reservation_pay_final_explicit'),

    path('auth/token/', CustomTokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('auth/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
    path('auth/register/', views.register_user, name='register_user'),
]
