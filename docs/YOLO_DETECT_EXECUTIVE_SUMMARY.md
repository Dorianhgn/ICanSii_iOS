# YOLO Detect v4 — Résumé Exécutif
## Pour la Migration Swift/Metal sur iOS 17 Pro

---

## 🎯 Objectif Principal
Node ROS 2 de **détection et tracking d'objets 3D en temps réel** combinant:
- **YOLO segmentation** (détection 2D + masques)
- **Profondeur RealSense** (conversion 3D)
- **Tracking persistant** avec IDs stables entre frames
- **Estimation de vitesse** (vélocité + lissage)
- **Visualisation RViz** (marqueurs + FOV)

---

## 🏗️ Architecture Globale

```
Image Couleur (ROS) → YOLO Detection + Tracking
                        ↓
                   Extract Boxes/Masks
                        ↓
Image Profondeur → Get Robust Depth (médiane ROI)
                        ↓
                   Kalman 1D Filter (z)
                        ↓
Depth Intrinsics → Deproject to 3D (x,y,z en mm)
                        ↓
                   Smooth Position per Track ID
                        ↓
                   Estimate Velocity/Speed
                        ↓
                   Update MarkerTracker DB
                        ↓
                   Publish RViz Markers + Alerts
```

---

## 🔄 Pipeline de Traitement par Frame

### 1️⃣ **YOLO Detection & Tracking** [`detection()`]
- **Modèle**: YOLO11s-seg ou YOLO26s-seg (ultralytics)
- **Mode**: `.track(persist=True, tracker="bytetrack.yaml")`
- **Output**: 
  - Boxes (xyxy) → convertir en (cx, cy, w, h)
  - Confidence scores
  - Class IDs (0-80, filtrés sur ~20 classes utiles)
  - **Track IDs persistants** (CLEF: ByteTrack réassigne IDs entre frames)
  - Masques segmentation (liste de polygones)

### 2️⃣ **Extraction de Profondeur** [`get_robust_depth_mm()`]
- ROI centré sur détection (±10% largeur/hauteur bbox)
- Médiane des pixels valides (0 < depth < 10000 mm)
- **Garde-fou**: Rejette si ROI invalide ou aucune donnée valide
- **Output**: Profondeur brute en mm

### 3️⃣ **Kalman Filtre 1D sur Z** [`Kalman1D`]
- **État**: [position_z, vitesse_z]
- **Model**: dt=1 frame, lissage process/measurement variance
- **Effet**: Réduit jitter depth, stabilise profondeur entre frames
- **Output**: z filtré en mm

### 4️⃣ **Déprojection 3D** [`rs2_deproject_pixel_to_point()`]
- Input: (pixel_x, pixel_y, depth_z) + intrinsics caméra
- Output: (x, y, z) en mm (frame caméra)
- **Note**: RealSense SDK, à adapter pour ARKit/Vision sur iOS

### 5️⃣ **Lissage Position par Track ID** [`smooth_point_for_marker()`]
- FIFO circulaire par ID (taille 5 frames)
- Médiane adaptative (moy entre 25e-75e centile)
- **Objectif**: Éviter bruit détection sans lag
- **Output**: Point 3D lissé en mm

### 6️⃣ **Estimation Vitesse** [`speed_estimation()`]
- Comparaison position(t) vs position(t-1)
- Calcul: `velocity_m_s = (Δposition_mm / 1000) / Δtime_s`
- **Garde-fou**: Clampe vitesse max à 6 m/s (outliers)
- **Filtre temporel**: Ignore Δt < 40ms (jitter)
- **Output**: Vecteur vitesse (m/s) + norme vitesse

### 7️⃣ **Lissage EMA Vitesse** [`update_smoothed_speed()`]
- **Coefficient**: α=0.45 (45% nouvelle mesure)
- FIFO par ID (stocke 7 dernières vitesses)
- **Objectif**: Vitesse lisses pour UX
- **Output**: Speed m/s lissée

### 8️⃣ **Tracking Prédictif** [`MarkerTracker.predict()`]
- Si objet **perd de vue** (pas détecté):
  - Mode `is_predictive=True` + timestamp `lost_time`
  - Extrapolation: `position + avg_velocity × dt`
  - Prédiction pendant **3 secondes max**
  - Hysteresis grace period: **0.2s** (évite flickering)
- Après 3s: Suppression marker + nettoyage

### 9️⃣ **Publication RViz**
- **Markers**: 
  - Sphère verte (in FOV) ou rouge (hors FOV), Ø 0.25m
  - Texte ID + classe au-dessus
- **Predicted Markers**: 
  - Sphère orange, expires 3s
  - Publié si durée hors FOV > 0.2s
- **FOV Visualizer**: 
  - Cône champ vision avec zones (1m/2m/4m)
  - Divisions horizontales/verticales (aide debug)
- **Alerts**: String topic si danger détecté

---

## 📊 État Interne — `MarkerTracker` Class

```python
class MarkerTracker:
    marker_id: int              # ID unique du suivi
    position: np.array[3]       # (x,y,z) mm, actuelle
    in_fov: bool                # Visible ce frame?
    is_predictive: bool         # Mode extrapolation?
    velocity: np.array[3]       # (vx,vy,vz) m/s
    last_positions: deque[5]    # Historique positions
    last_velocities: deque[7]   # Historique vitesses
    score: float                # Confiance YOLO
    class_name: str             # "person", "car", etc.
    lost_time: float            # Timestamp perte
    out_of_fov_duration: float  # Temps hors champ
```

---

## 🎚️ Seuils & Paramètres Critiques

| Paramètre | Valeur | Impact |
|-----------|--------|--------|
| `score_threshold` | 0.5 | Rejette détections faibles |
| `prediction_timeout` | 3.0 s | Durée max extrapolation |
| `hysteresis_time` | 0.2 s | Délai avant pub prédiction |
| `max_speed_m_s` | 6.0 m/s | Clamp vitesse (outliers) |
| `min_speed_dt` | 0.04 s | Δt min pour actualiser vitesse |
| `speed_ema_alpha` | 0.45 | Lissage vitesse EMA |
| `fifo_position_size` | 5 | Fenêtre lissage position |
| `fifo_velocity_size` | 7 | Historique vitesses |
| Kalman process_var | 0.05 | Bruit modèle profondeur |
| Kalman meas_var | 0.1 | Bruit capteur profondeur |

---

## 🛠️ Dépendances Externes (Non-triviaux)

### ROS 2 Message Types
- `sensor_msgs.Image` → OpenCV format
- `sensor_msgs.CameraInfo` → Intrinsics caméra
- `geometry_msgs.Point, PointStamped`
- `visualization_msgs.Marker, MarkerArray`

### Librairies Python
- **ultralytics** — YOLO v11 models + ByteTrack
- **pyrealsense2** — RealSense SDK (déprojection 3D, intrinsics)
- **pykalman** — Kalman filters (1D position)
- **shapely** — Polygon geometry (masques, centroids)
- **cv2** (OpenCV) — Image processing

### Modèles YOLO
- `yolo11s-seg.engine` / `yolo26s-seg.engine`
- Format: TensorRT (.engine) ⚠️ **Pré-compilé GPU TensorRT**
- Entrée: Image RGB (640×480 ou custom)

---

## ⚠️ Défis Clés pour Migration iOS

### 1. **Remplacement PyRealSense2 → ARKit/Vision API**
- `rs2_deproject_pixel_to_point()` → Apple Vision depth + intrinsics
- `CameraInfo` (ROS) → `ARCamera.intrinsics` (ARKit)
- **Considération**: ARKit donne depth map en fragments, pas full resolution

### 2. **Remplacement YOLO PyTorch → CoreML ou Metal**
- Modèle `.engine` (TensorRT) non portable
- **Options**:
  - YOLO CoreML (conversion ultralytics → .mlpackage, déjà présent)
  - YOLO Metal (custom shader, plus complexe)
  - Vérifier version YOLO11s-seg compatible avec iOS

### 3. **Kalman Filtre 1D**
- Implémentation numpy → **Accelerate.framework** (matrix ops) ou **simple math**
- Simple suffisant: state 2×1, transitions 2×2

### 4. **Tracking Persistent (ByteTrack)**
- Dépend de `ultralytics`
- **Alternative iOS**: Implémenter logique matching simple (distance euclidienne + temporal window)
- Ou wrapper YOLO.track() via CoreML pipeline

### 5. **Lissage Position/Vitesse**
- FIFO + médiane adaptative → implémentable en Swift puur
- EMA lissage trivial

### 6. **Profondeur Robuste (Médiane ROI)**
- ARKit depth maps sparse → adaptation nécessaire
- Fallback: Si ROI invalide, utiliser dernier depth valide ou prédire

### 7. **Visualisation RViz → ARKit/Metal**
- Markers sphères → Metal instantiation ou ARKit geometry
- FOV cone → Metal wireframe ou ARKit plane anchors

---

## 📤 Topics ROS Publiés (pour iOS: Remplacer par local buffers/delegates)

| Topic | Type | Fréquence | Usage |
|-------|------|-----------|-------|
| `icansii_v4/yolo_detect_node/points` | PointStamped | Per-detection | Single point (legacy?) |
| `icansii_v4/yolo_detect_node/markers` | MarkerArray | Per-frame (~30Hz) | RViz visualization |
| `icansii_v4/yolo_detect_node/predicted_markers` | Marker | Per-prediction | Out-of-FOV extrapolation |
| `icansii_v4/camera/fov` | Marker | Per-frame | FOV visualization |
| `icansii_v4/yolo_detect_node/alerts` | String | On-event | Warnings (proximity, etc.) |
| `icansii_v4/yolo_detect_node/objects_info` | String | Per-frame | Debug dump (object list) |

---

## 🎬 Cicle de Vie Une Frame

```
t=0ms   : Color image arrive (ROS callback)
t=1ms   : YOLO detect + track (30-50ms inference)
t=45ms  : Depth image arrive (async)
t=46ms  : Extract depth per detection
t=47ms  : Kalman predict/update
t=48ms  : Deproject 3D
t=49ms  : Smooth position
t=50ms  : Estimate velocity
t=51ms  : Update MarkerTrackers
t=52ms  : Publish markers + info
t=53ms  : Check out-of-FOV, prédictions
```

**Bottleneck**: YOLO inference (~40-50ms sur GPU TensorRT)

---

## 📌 Classes Reconnues (Filtrées)

Seulement ~20 classes utilisables:
```
person, bicycle, car, motorcycle, airplane, bus, train, truck, boat,
traffic light, fire hydrant, stop sign, parking meter, bench,
bird, cat, dog, horse, chair, couch, potted plant, bed,
dining table, refrigerator
```

---

## 💾 État Persistant Entre Frames

```python
self.markers = {track_id: MarkerTracker}     # DB active
self.previous_points = {track_id: (pos, time)}  # Vitesse calc
self.depth_kalmans = {track_id: Kalman1D}   # Profondeur filtrée
self.position_history_by_marker = {track_id: deque}  # Lissage
self.last_velocities_by_marker = {track_id: [...]}  # EMA
self.predicted_markers = {track_id: {expiration}}  # Timeout pred
```

---

## 🚀 Recommandations pour Swift/Metal iOS

1. **Ordre Migration Prioritaire**:
   - ✅ Vision API (depth) + CoreML (YOLO)
   - ✅ Tracking simple (distance + time-window)
   - ✅ Kalman 1D (trivial, Accelerate)
   - ✅ Smooth + EMA velocity
   - ✅ Metal visualization
   - ⚠️ Prédiction extrapolation (3s timeout)

2. **Architecture**:
   - `SpatialFrameProcessor` orchestrates pipeline
   - `YOLODetector` (CoreML wrapper)
   - `DepthProcessor` (Vision API)
   - `TrackingEngine` (MarkerTracker equivalent)
   - `ARVisualization` (Metal rendering)

3. **Performance Targets**:
   - YOLO inference < 40ms (iOS GPU)
   - Depth extraction < 5ms
   - Total latency < 80ms (target: 12.5 FPS min)

4. **Testing**:
   - Unit test Kalman (vs PyKalman)
   - Integration test tracking ID persistence
   - Bench depth robustness vs ARKit camera jitter

---

**Document créé**: 2026-04-14  
**Target**: Claude Opus planning v4 Swift/Metal iOS 17 Pro
