import MetalKit
import SwiftUI
import CoreML

struct SpatialMetalView: UIViewRepresentable {
    @ObservedObject var arManager: ARManager
    var mode: SpatialDisplayMode
    var maxDistance: Float
    var isRecording: Bool
    
    var showSegmentation3D: Bool = true
    var visionDetections: [YoloDetection] = []
    var visionPrototypes: MLMultiArray?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView(frame: .zero) }

        let view = MTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1.0)
        view.colorPixelFormat = .bgra8Unorm
        // Important pour l'occlusion 3D du nuage enregistré
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = false

        context.coordinator.renderer = SpatialRenderer(arManager: arManager, mtkView: view)
        view.delegate = context.coordinator.renderer
        context.coordinator.renderer?.setMode(mode)
        context.coordinator.renderer?.setMaxDistance(maxDistance)
        context.coordinator.renderer?.setRecording(isRecording)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        
        // Ajout du Pinch pour Zoomer/Avancer dans le nuage
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // Ajout du Pan à 2 doigts pour la translation (déplacement X/Y)
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(twoFingerPan)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setMode(mode)
        context.coordinator.renderer?.setMaxDistance(maxDistance)
        context.coordinator.renderer?.setRecording(isRecording)
        context.coordinator.renderer?.showSegmentation3D = showSegmentation3D
        context.coordinator.renderer?.visionDetections = visionDetections
        context.coordinator.renderer?.visionPrototypes = visionPrototypes
    }

    final class Coordinator: NSObject {
        var renderer: SpatialRenderer?

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            let dx = Float(translation.x) * 0.005
            let dy = Float(translation.y) * 0.005
            renderer?.rotate(deltaX: dx, deltaY: dy)
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            let scale = Float(gesture.scale)
            gesture.scale = 1.0 // Reset après application
            renderer?.zoom(factor: scale)
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            let dx = Float(translation.x) * 0.005
            let dy = Float(translation.y) * 0.005
            renderer?.translate(deltaX: dx, deltaY: dy)
        }
    }
}