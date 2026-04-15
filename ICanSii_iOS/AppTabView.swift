import SwiftUI
import QuartzCore

struct AppTabView: View {
    @StateObject private var arManager = ARManager()
    @StateObject private var visionManager = VisionManager()
    @StateObject private var trackingManager = TrackingManager()
    @StateObject private var transport = PreviewTransport()

    @State private var didBind = false

    private let vestEngine = VestMappingEngine()
    private let vestTick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ContentView(arManager: arManager, visionManager: visionManager, trackingManager: trackingManager)
                .tabItem {
                    Label("Spatial", systemImage: "view.3d")
                }

            VestPreviewView(transport: transport)
                .tabItem {
                    Label("Vest", systemImage: "dot.radiowaves.left.and.right")
                }
        }
        .onAppear {
            guard !didBind else { return }
            didBind = true

            arManager.start()
            arManager.setSemanticConsumer { frame in
                visionManager.process(frame: frame)
            }
            trackingManager.bind(arManager: arManager, visionManager: visionManager)
        }
        .onDisappear {
            arManager.stop()
            arManager.setSemanticConsumer(nil)
        }
        .onReceive(vestTick) { _ in
            let ts = CACurrentMediaTime()
            let state = vestEngine.map(objects: trackingManager.trackedObjects, timestamp: ts)
            transport.send(state, timestamp: ts)
        }
    }
}
