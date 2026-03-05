import MetalKit
import SwiftUI

struct SpatialMetalView: UIViewRepresentable {
    @ObservedObject var arManager: ARManager
    var mode: SpatialDisplayMode
    var maxDistance: Float

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return MTKView(frame: .zero)
        }

        let view = MTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = false

        context.coordinator.renderer = SpatialRenderer(arManager: arManager, mtkView: view)
        view.delegate = context.coordinator.renderer
        context.coordinator.renderer?.setMode(mode)
        context.coordinator.renderer?.setMaxDistance(maxDistance)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setMode(mode)
        context.coordinator.renderer?.setMaxDistance(maxDistance)
    }

    final class Coordinator: NSObject {
        var renderer: SpatialRenderer?

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            let dx = Float(translation.x) * 0.01
            let dy = Float(translation.y) * 0.01
            renderer?.rotate(deltaX: dx, deltaY: dy)
        }
    }
}
