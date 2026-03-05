//
//  ContentView.swift
//  ICanSii_iOS
//
//  Created by Dorian Hugonnet on 05/03/2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var arManager = ARManager()
    @State private var mode: SpatialDisplayMode = .rgb
    @State private var maxDistance: Float = 6.0

    var body: some View {
        ZStack(alignment: .top) {
            if arManager.supportsSceneDepth {
                SpatialMetalView(arManager: arManager, mode: mode, maxDistance: maxDistance)
                    .ignoresSafeArea()
                    // --- Point rouge central (repère du centre de mesure) ---
                    // Visible en mode RGB et Depth uniquement.
                    // Ce point rouge correspond exactement au pixel central analysé
                    // par `readCenterDepth` dans ARManager (utilisé dans "Distance centre").
                    // `.allowsHitTesting(false)` : le cercle ne capte pas les gestes,
                    // le panGestureRecognizer du point cloud reste actif sous-jacent.
                    .overlay {
                        if mode == .rgb || mode == .depth {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                unsupportedView
            }

            hud
        }
        .onAppear {
            arManager.start()
        }
        .onDisappear {
            arManager.stop()
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("LiDAR sceneDepth non disponible")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Ce mode necessite un appareil compatible depth ARKit (ex: iPhone 15 Pro).")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var hud: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(SpatialDisplayMode.allCases) { displayMode in
                    Text(displayMode.rawValue).tag(displayMode)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 8) {
                HStack {
                    Text("Portee")
                    Spacer()
                    Text(String(format: "%.1f m", maxDistance))
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(maxDistance) },
                    set: { maxDistance = Float($0) }
                ), in: 0.1...20.0)
            }

            if mode == .rgb || mode == .depth {
                HStack {
                    Text("Distance centre")
                    Spacer()
                    Text(centerDistanceText)
                        .monospacedDigit()
                }
            }

            HStack {
                Circle()
                    .fill(arManager.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(arManager.trackingStateText)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
        }
        .font(.callout.weight(.medium))
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var centerDistanceText: String {
        guard let d = arManager.centerDistanceMeters else {
            return "--"
        }
        return String(format: "%.2f m", d)
    }
}

#Preview {
    ContentView()
}
