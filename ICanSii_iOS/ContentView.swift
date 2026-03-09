//
//  ContentView.swift
//  ICanSii_iOS
//
//  Created by Dorian Hugonnet on 05/03/2026.
//

import SwiftUI
import Vision

struct ContentView: View {
    @StateObject private var arManager = ARManager()
    @StateObject private var visionManager = VisionManager() // Notre nouveau manager IA
    
    @State private var mode: SpatialDisplayMode = .rgb
    @State private var maxDistance: Float = 6.0
    @State private var isRecording: Bool = false
    @State private var showSegmentation3D: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                if arManager.supportsSceneDepth {
                    SpatialMetalView(arManager: arManager, mode: mode, maxDistance: maxDistance, isRecording: isRecording, showSegmentation3D: showSegmentation3D, visionDetections: visionManager.detections, visionPrototypes: visionManager.currentPrototypes)
                        .ignoresSafeArea()
                        .overlay {
                            // Point central (visée)
                            if mode == .rgb || mode == .depth {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            // Affiche les Bounding Boxes uniquement en mode RGB si un modèle est actif
                            if mode == .rgb && visionManager.activeModel != .none {
                                boundingBoxOverlay
                            }
                        }
                } else {
                    unsupportedView
                }

                VStack(spacing: 8) {
                    yoloHUD // Le HUD style "Appli YOLO" tout en haut
                    hud     // Ton HUD existant en dessous
                }
            }
            
            recordButton
        }
        .onAppear {
            arManager.start()
            // On connecte la sortie sémantique de l'ARManager à notre VisionManager !
            arManager.setSemanticConsumer { spatialFrame in
                visionManager.process(frame: spatialFrame)
            }
        }
        .onDisappear {
            arManager.stop()
            arManager.setSemanticConsumer(nil)
        }
    }
    
    // --- NOUVEAU : HUD YOLO (FPS, ms, Sélecteur) ---
    private var yoloHUD: some View {
        VStack(spacing: 4) {
            Text(visionManager.activeModel == .none ? "YOLO Seg (Off)" : visionManager.activeModel.rawValue)
                .font(.title2.weight(.bold))
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
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 40) // Espace pour la notch/dynamic island
    }

    // --- Overlay des Bounding Boxes ---
    private var boundingBoxOverlay: some View {
        GeometryReader { geometry in
            ForEach(visionManager.detections) { detection in
                
                // MAGIE : On convertit la boîte 4:3 de YOLO vers la boîte croppée de l'écran 19.5:9
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

    // --- LE RESTE EST INCHANGÉ ---
    private var hud: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(SpatialDisplayMode.allCases) { displayMode in
                    Text(displayMode.rawValue).tag(displayMode)
                }
            }
            .pickerStyle(.segmented)
            
            if mode == .rgb || mode == .depth {
                VStack(spacing: 8) {
                    HStack {
                        Text("Portée")
                        Spacer()
                        Text(String(format: "%.1f m", maxDistance))
                            .monospacedDigit()
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
                    Text("Rotation Caméra")
                        .font(.caption)
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
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
    }
    
    private var recordButton: some View {
        Button(action: {
            withAnimation {
                isRecording.toggle()
                // Transition automatique vers le nuage cumule apres l'enregistrement
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

// Formule mathématique pour annuler le recadrage (Crop) et aligner YOLO avec l'écran
extension CGRect {
    func transformedToScreen(using displayTransform: CGAffineTransform) -> CGRect {
        let inverted = displayTransform.inverted()
        let corners = [
            CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)
        ]
        
        var minSx: CGFloat = 10000, minSy: CGFloat = 10000
        var maxSx: CGFloat = -10000, maxSy: CGFloat = -10000
        
        for corner in corners {
            // Conversion Portrait (YOLO) -> Paysage (Capteur)
            let tx = 1.0 - corner.y
            let ty = corner.x
            // Application de la matrice inversée d'ARKit
            let screenUV = CGPoint(x: tx, y: ty).applying(inverted)
            
            minSx = min(minSx, screenUV.x)
            minSy = min(minSy, screenUV.y)
            maxSx = max(maxSx, screenUV.x)
            maxSy = max(maxSy, screenUV.y)
        }
        return CGRect(x: minSx, y: minSy, width: maxSx - minSx, height: maxSy - minSy)
    }
}