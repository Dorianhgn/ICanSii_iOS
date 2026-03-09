import ARKit
import Combine
import Foundation

final class ARManager: NSObject, ObservableObject {
    typealias FrameConsumer = @Sendable (SpatialFrame) -> Void

    let framePublisher = PassthroughSubject<SpatialFrame, Never>()

    @Published private(set) var isRunning = false
    @Published private(set) var centerDistanceMeters: Float?
    @Published private(set) var trackingStateText = "Not running"
    @Published private(set) var supportsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    @Published var liveOrbitAngle: Float = 0.0
    var displayTransform: CGAffineTransform = .identity

    private let session = ARSession()
    private let processingQueue = DispatchQueue(label: "sii.arkit.processing", qos: .userInteractive)
    private let geometricQueue = DispatchQueue(label: "sii.pipeline.geometric", qos: .userInitiated)
    private let semanticQueue = DispatchQueue(label: "sii.pipeline.semantic", qos: .userInitiated)

    private let geometricSemaphore = DispatchSemaphore(value: 1)
    private let semanticSemaphore = DispatchSemaphore(value: 1)

    private var geometricConsumer: FrameConsumer?
    private var semanticConsumer: FrameConsumer?

    private let stateLock = NSLock()
    private var lastCenterPublishTimestamp: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingStateText = "World tracking unavailable"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.frameSemantics = enabledSemantics()
        configuration.environmentTexturing = .none

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        trackingStateText = "Starting"
    }

    func stop() {
        session.pause()
        isRunning = false
        trackingStateText = "Paused"
    }

    func setGeometricConsumer(_ consumer: FrameConsumer?) {
        stateLock.lock()
        geometricConsumer = consumer
        stateLock.unlock()
    }

    func setSemanticConsumer(_ consumer: FrameConsumer?) {
        stateLock.lock()
        semanticConsumer = consumer
        stateLock.unlock()
    }

    private func enabledSemantics() -> ARConfiguration.FrameSemantics {
        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }
        return semantics
    }

    private func publishCenterDistanceIfNeeded(_ depthMap: CVPixelBuffer, timestamp: TimeInterval) {
        let elapsed = timestamp - lastCenterPublishTimestamp
        if elapsed >= 0.1 {
            lastCenterPublishTimestamp = timestamp
            centerDistanceMeters = readCenterDepth(depthMap)
        }
    }

    private func readCenterDepth(_ depthMap: CVPixelBuffer) -> Float? {
        // --- Zero-Copy Mémoire ---
        // Verrouiller la mémoire sans copier.
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        // --- Récupère l'adresse de base du bloc raw en RAM (Pointeur C) --
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let centerX = width / 2
        let centerY = height / 2

        // Accès O(1) sans boucles interdites ! Pointeur arithmétique pour trouver la ligne.
        let rowPointer = baseAddress.advanced(by: centerY * bytesPerRow)
        // Convertit la ligne de UInt8 vers Float32 (Format du Depth Map d'ARKit).
        let floatPointer = rowPointer.assumingMemoryBound(to: Float32.self)
        let value = floatPointer[centerX]

        // Ignorer les valeurs de vide spatial.
        guard value.isFinite, value > 0 else {
            return nil
        }
        return value
    }

    private func trackingText(from state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "Tracking normal"
        case .notAvailable:
            return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "Tracking initializing"
            case .relocalizing:
                return "Tracking relocalizing"
            case .excessiveMotion:
                return "Tracking limited: motion"
            case .insufficientFeatures:
                return "Tracking limited: features"
            @unknown default:
                return "Tracking limited"
            }
        }
    }
}

extension ARManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // --- Traitement des images provenant directement du capteur LiDAR ---
        // On préfère la profondeur lissée (`smoothedSceneDepth`) mais la première 
        // option (`sceneDepth`) est utilisée si la première n'est pas encore dispo.
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return
        }

        // --- Résolution de la caméra et matrice d'affichage de l'écran ---
        let imageResolution = SIMD2<Int>(
            Int(frame.camera.imageResolution.width),
            Int(frame.camera.imageResolution.height)
        )

        // On obtient la bonne transformation (Rotation / Crop) pour passer du 
        // format natif de la caméra (paysage) à l'orientation affichée de l'iPhone.
        // Récupération moderne de la taille de l'écran sans utiliser UIScreen.main
        let viewportSize: CGSize
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            viewportSize = windowScene.screen.bounds.size
        } else {
            viewportSize = CGSize(width: 393, height: 852) // Fallback standard iPhone Pro
        }
        
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize)

        self.displayTransform = displayTransform

        // Création de notre objet "SpatialFrame" intermédiaire. Cet objet va encapsuler 
        // la photo (couleur), la matrice de profondeur, et les infos spatiales.
        let spatialFrame = SpatialFrame(
            timestamp: frame.timestamp,
            capturedImage: frame.capturedImage,
            depthMap: depthData.depthMap,
            intrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform,
            imageResolution: imageResolution,
            displayTransform: displayTransform
        )

        framePublisher.send(spatialFrame)

        // --- Mise en File d'Attente ("Dispatch" queues) ---
        // On récupère les deux fonctions "blocs" responsables du traitement asynchrone.
        // ex: YOLO IA.
        let geometric = geometricConsumer
        let semantic = semanticConsumer

        // --- Stratégie "Frame Dropping" pour éviter de saturer la mémoire ---
        // L'utilisation des sémaphores vérifie si le thread asynchrone (QoS background)
        // a terminé la tâche précédente. S'il n'a pas terminé (`timeout: .now()` -> direct fail),
        // alors la frame actuelle saute, évitant ainsi un crash causé par la saturation RAM/CPU.
        
        if let geometric {
            if geometricSemaphore.wait(timeout: .now()) == .success {
                geometricQueue.async {
                    // Force la libération des variables lourdes le plus tôt possible
                    // (Surtout les ponts ARKit/CVPixelBuffer qui demandent des références C).
                    autoreleasepool {
                        geometric(spatialFrame)
                    }
                    // Le sémaphore annonce que c'est fini, on peut lacher la prochaine frame.
                    self.geometricSemaphore.signal()
                }
            }
        }

        // --- Même stratégie pour la queue sémantique (Machine Learning) ---
        if let semantic {
            if semanticSemaphore.wait(timeout: .now()) == .success {
                semanticQueue.async {
                    // Libération précoce (autorelease) après l'exécution.
                    autoreleasepool {
                        semantic(spatialFrame)
                    }
                    self.semanticSemaphore.signal()
                }
            }
        }

        publishCenterDistanceIfNeeded(depthData.depthMap, timestamp: frame.timestamp)
        trackingStateText = trackingText(from: frame.camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingStateText = "Session error: \(error.localizedDescription)"
        isRunning = false
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingStateText = "Session interrupted"
        isRunning = false
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        trackingStateText = "Session resumed"
        isRunning = true
    }
}
