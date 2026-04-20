import SwiftUI
import Vision

struct ContentView: View {
    @ObservedObject var arManager: ARManager
    @ObservedObject var visionManager: VisionManager
    @ObservedObject var trackingManager: TrackingManager
    
    @State private var mode: SpatialDisplayMode = .rgb
    @State private var maxDistance: Float = 6.0
    @State private var isRecording: Bool = false
    @State private var showSegmentation3D: Bool = true
    
    // NOUVEAU : États pour contrôler l'ouverture des bulles
    @State private var showYoloPanel: Bool = false
    @State private var showSettingsPanel: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                
                // --- VUE 3D / CAMERA ---
                if arManager.supportsSceneDepth {
                    SpatialMetalView(
                        arManager: arManager,
                        mode: mode,
                        maxDistance: maxDistance,
                        isRecording: isRecording,
                        showSegmentation3D: showSegmentation3D,
                        visionDetections: visionManager.detections,
                        visionPrototypes: visionManager.currentPrototypes
                    )
                    .ignoresSafeArea()
                    .overlay {
                        if mode == .rgb || mode == .depth {
                            Circle().fill(Color.red).frame(width: 12, height: 12).allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if mode == .rgb && visionManager.activeModel != .none {
                            ZStack {
                                boundingBoxOverlay
                                SpatialOverlayView(tracking: trackingManager, arManager: arManager)
                            }
                        }
                    }
                } else {
                    unsupportedView
                }

                // --- LES HUD FLOTTANTS ---
                VStack(alignment: .leading, spacing: 16) {
                    FloatingPanel(icon: "brain.head.profile", isExpanded: $showYoloPanel) {
                        yoloHUD
                    }
                    FloatingPanel(icon: "camera.filters", isExpanded: $showSettingsPanel) {
                        hud
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 60) // Pour passer sous la Dynamic Island
            }
            
            // --- BOUTON ENREGISTRER ---
            recordButton
        }
    }
    
    // --- VUES DES PANNEAUX INTERNES (Débarrassées de leurs anciens fonds) ---
    
    private var yoloHUD: some View {
        VStack(spacing: 8) {
            Text(visionManager.activeModel == .none ? "YOLO Seg (Off)" : visionManager.activeModel.rawValue)
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            
            if visionManager.activeModel != .none {
                Text(String(format: "%.1f FPS - %.1f ms", visionManager.fps, visionManager.inferenceTimeMs))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(visionManager.fps > 20 ? .green : .yellow)
            }
            
            Picker("YOLO Model", selection: $visionManager.activeModel) {
                ForEach(YoloModelType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
        }
    }

    private var hud: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(SpatialDisplayMode.allCases) { displayMode in
                    Text(displayMode.rawValue).tag(displayMode)
                }
            }
            .pickerStyle(.segmented)
            
            if mode != .accumulatedPointCloud {
                VStack(spacing: 8) {
                    HStack {
                        Text("Portée")
                        Spacer()
                        Text(String(format: "%.1f m", maxDistance)).monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(maxDistance) }, set: { maxDistance = Float($0) }), in: 0.1...20.0)
                }
                
                HStack {
                    Text("Distance centre")
                    Spacer()
                    Text(centerDistanceText).monospacedDigit()
                }
            }
            
            if mode == .livePointCloud {
                VStack(spacing: 8) {
                    Text("Rotation Caméra").font(.caption)
                    Slider(value: Binding(
                        get: { Double(arManager.liveOrbitAngle) },
                        set: { arManager.liveOrbitAngle = Float($0) }
                    ), in: -Double.pi...Double.pi)
                }
            }
            
            if mode == .accumulatedPointCloud || mode == .livePointCloud {
                Toggle("Masques 3D (YOLO)", isOn: $showSegmentation3D)
                    .tint(.cyan)
                    .padding(.vertical, 4)
            }

            HStack {
                Circle().fill(arManager.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(arManager.trackingStateText).font(.caption).lineLimit(1)
                Spacer()
            }
        }
        .font(.callout.weight(.medium))
    }
    
    // --- LE RESTE DES COMPOSANTS (Inchangé) ---
    
    private var boundingBoxOverlay: some View {
        GeometryReader { geometry in
            ForEach(visionManager.detections) { detection in
                let screenUVRect = detection.boundingBox.transformedToScreen(using: arManager.displayTransform)
                let convertedRect = CGRect(
                    x: screenUVRect.minX * geometry.size.width,
                    y: screenUVRect.minY * geometry.size.height,
                    width: screenUVRect.width * geometry.size.width,
                    height: screenUVRect.height * geometry.size.height
                )
                
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .path(in: convertedRect)
                        .stroke(Color.cyan, lineWidth: 2)
                    
                    Text(String(format: "%@ %.0f%%", detection.label, detection.confidence * 100))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.cyan)
                        .position(x: convertedRect.minX + 20, y: convertedRect.minY - 10)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var recordButton: some View {
        Button(action: {
            withAnimation {
                isRecording.toggle()
                if !isRecording { mode = .accumulatedPointCloud }
            }
        }) {
            Circle()
                .fill(isRecording ? Color.red : Color.white)
                .frame(width: 60, height: 60)
                .overlay(Circle().stroke(Color.white, lineWidth: 3).frame(width: 70, height: 70))
                .shadow(radius: 5)
        }
        .padding(.bottom, 30)
    }

    private var unsupportedView: some View {
        Color.black
    }

    private var centerDistanceText: String {
        guard let d = arManager.centerDistanceMeters else { return "--" }
        return String(format: "%.2f m", d)
    }
}

// MARK: - NOUVEAU COMPOSANT : Panneau Flottant
struct FloatingPanel<Content: View>: View {
    let icon: String
    @Binding var isExpanded: Bool
    
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    let content: Content

    init(icon: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self._isExpanded = isExpanded
        self.content = content()
    }

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    var body: some View {
        Group {
            if isExpanded {
                VStack(spacing: 0) {
                    // En-tête : C'est la seule zone qu'on peut glisser quand le panneau est ouvert
                    HStack {
                        Image(systemName: "line.3.horizontal") // Indicateur de "drag"
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 12)
                        
                        Spacer()
                        
                        Button(action: { withAnimation(.spring()) { isExpanded = false } }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .padding(12)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture) 

                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .frame(width: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                
            } else {
                // La bulle : on peut cliquer dessus ou la glisser
                Button(action: { withAnimation(.spring()) { isExpanded = true } }) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 5)
                }
                .gesture(dragGesture)
            }
        }
        .offset(offset)
    }
}

