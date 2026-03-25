import json
import os
import sys
from typing import Any, Dict, Optional

import cv2
import numpy as np
from ultralytics import YOLO
import cvzone


def _update_job(job_path: Optional[str], **fields: Any) -> None:
  if not job_path:
    return

  data: Dict[str, Any] = {}
  if os.path.exists(job_path):
    try:
      with open(job_path, "r", encoding="utf-8") as f:
        data = json.load(f) or {}
    except Exception:
      data = {}

  data.update(fields)
  os.makedirs(os.path.dirname(job_path), exist_ok=True)
  with open(job_path, "w", encoding="utf-8") as f:
    json.dump(data, f)


def process_video(input_path: str, output_path: str, polygons_path: Optional[str] = None) -> None:
  """
  Run the parking_lot-main YOLO pipeline on a video file and
  write an annotated output video to output_path.
  This is a non-interactive version intended for backend use.
  """
  if polygons_path is None:
    polygons_path = os.path.join(os.path.dirname(__file__), "uploads", "polygons.json")

  if not os.path.exists(input_path):
    raise FileNotFoundError(f"Input video not found: {input_path}")

  # Load polygons (zones), if available
  polygons: list[list[list[int]]] = []
  if os.path.exists(polygons_path):
    try:
      with open(polygons_path, "r", encoding="utf-8") as f:
        polygons = json.load(f)
    except (json.JSONDecodeError, ValueError):
      polygons = []

  # Load YOLO model
  model_path = os.path.join(os.path.dirname(__file__), "best.pt")
  model = YOLO(model_path)

  cap = cv2.VideoCapture(input_path)
  if not cap.isOpened():
    raise RuntimeError(f"Could not open video: {input_path}")

  # Use a fixed output size similar to the original script
  frame_width = 1020
  frame_height = 500

  fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
  fourcc = cv2.VideoWriter_fourcc(*"mp4v")
  os.makedirs(os.path.dirname(output_path), exist_ok=True)
  out = cv2.VideoWriter(output_path, fourcc, fps, (frame_width, frame_height))

  frame_count = 0

  while True:
    ret, frame = cap.read()
    if not ret:
      break

    frame_count += 1
    # Downsample frames like the original script (every 3rd frame)
    if frame_count % 3 != 0:
      continue

    frame = cv2.resize(frame, (frame_width, frame_height))
    results = model.track(frame, persist=True)

    # Draw saved polygons
    for poly in polygons:
      pts = np.array(poly, np.int32).reshape((-1, 1, 2))
      cv2.polylines(frame, [pts], isClosed=True, color=(0, 255, 0), thickness=2)

    # Track how many zones are occupied
    occupied_zones = 0
    if results and results[0].boxes.id is not None:
      ids = results[0].boxes.id.cpu().numpy().astype(int)
      boxes = results[0].boxes.xyxy.cpu().numpy().astype(int)
      class_ids = results[0].boxes.cls.int().cpu().tolist()

      for track_id, box, class_id in zip(ids, boxes, class_ids):
        x1, y1, x2, y2 = box
        cx = int((x1 + x2) / 2)
        cy = int((y1 + y2) / 2)

        for poly in polygons:
          pts = np.array(poly, np.int32).reshape((-1, 1, 2))
          if cv2.pointPolygonTest(pts, (cx, cy), False) >= 0:
            cv2.circle(frame, (cx, cy), 4, (255, 0, 255), -1)
            cv2.polylines(frame, [pts], isClosed=True, color=(0, 0, 255), thickness=2)
            occupied_zones += 1
            break

    total_zones = len(polygons)
    free_zones = total_zones - occupied_zones

    cvzone.putTextRect(frame, f"FREEZONE:{free_zones}", (30, 40), 2, 2)
    cvzone.putTextRect(frame, f"OCC:{occupied_zones}", (30, 140), 2, 2)

    out.write(frame)

  cap.release()
  out.release()
  return {'occupied': occupied_zones, 'free': free_zones, 'total': total_zones}


def main(argv: list[str]) -> None:
  if len(argv) < 4:
    print(
      "Usage: python process_video.py <input_path> <output_path> <job_path>",
      file=sys.stderr,
    )
    raise SystemExit(1)

  input_path = argv[1]
  output_path = argv[2]
  job_path = argv[3]

  # Read job_id from job_path
  job_id = None
  if os.path.exists(job_path):
    try:
      with open(job_path, 'r', encoding='utf-8') as f:
        job_data = json.load(f)
        job_id = job_data.get('job_id')
    except Exception:
      pass

  polygons_path = None
  if job_id:
    polygons_path = os.path.join(os.path.dirname(__file__), "uploads", job_id, "polygons.json")

  _update_job(job_path, status="running")
  try:
    counts = process_video(input_path, output_path, polygons_path)
  except Exception as exc:  # noqa: BLE001
    _update_job(job_path, status="failed", error=str(exc))
    raise
  else:
    _update_job(job_path, status="completed", occupied=counts['occupied'], free=counts['free'], total=counts['total'])


if __name__ == "__main__":
  main(sys.argv)

