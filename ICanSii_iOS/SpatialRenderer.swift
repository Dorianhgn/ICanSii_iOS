import Combine
import Foundation
import Metal
import MetalKit
import simd

final class SpatialRenderer: NSObject, MTKViewDelegate {
    struct DepthUniforms {
        var minDepth: Float
        var maxDepth: Float
    }

    struct DisplayUniforms {
        var transform: simd_float3x3
    }

    struct PointCloudUniforms {
        var depthIntrinsics: SIMD4<Float>
        var depthSize: SIMD2<UInt32>
        var minDepth: Float
        var maxDepth: Float
        var pointSize: Float
        var yaw: Float
        var pitch: Float
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureBridge: MetalTextureBridge
    private let frameLock = NSLock()

    private var rgbPipeline: MTLRenderPipelineState
    private var depthPipeline: MTLRenderPipelineState
    private var pointPipeline: MTLRenderPipelineState
    private var currentFrame: SpatialFrame?
    private var mode: SpatialDisplayMode = .rgb
    private var maxDistance: Float = 6.0
    private var yaw: Float = 0.2
    private var pitch: Float = -0.2
    private var cancellable: AnyCancellable?

    init?(arManager: ARManager, mtkView: MTKView) {
        guard let device = mtkView.device,
              let queue = device.makeCommandQueue(),
              let textureBridge = MetalTextureBridge(device: device),
              let library = device.makeDefaultLibrary() else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.textureBridge = textureBridge

        do {
            rgbPipeline = try SpatialRenderer.makePipeline(
                device: device,
                library: library,
                vertexFunction: "fullscreenVertex",
                fragmentFunction: "rgbFragment",
                colorFormat: mtkView.colorPixelFormat
            )
            depthPipeline = try SpatialRenderer.makePipeline(
                device: device,
                library: library,
                vertexFunction: "fullscreenVertex",
                fragmentFunction: "depthFragment",
                colorFormat: mtkView.colorPixelFormat
            )
            pointPipeline = try SpatialRenderer.makePipeline(
                device: device,
                library: library,
                vertexFunction: "pointCloudVertex",
                fragmentFunction: "pointCloudFragment",
                colorFormat: mtkView.colorPixelFormat
            )
        } catch {
            return nil
        }

        super.init()

        cancellable = arManager.framePublisher
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] frame in
                guard let self else { return }
                self.frameLock.lock()
                self.currentFrame = frame
                self.frameLock.unlock()
            }
    }

    deinit {
        cancellable?.cancel()
    }

    func setMode(_ mode: SpatialDisplayMode) {
        frameLock.lock()
        self.mode = mode
        frameLock.unlock()
    }

    func setMaxDistance(_ maxDistance: Float) {
        frameLock.lock()
        self.maxDistance = max(0.1, maxDistance)
        frameLock.unlock()
    }

    func rotate(deltaX: Float, deltaY: Float) {
        frameLock.lock()
        yaw += deltaX
        pitch = min(max(pitch + deltaY, -1.2), 1.2)
        frameLock.unlock()
    }

    func draw(in view: MTKView) {
        // --- Vérification des prérequis de rendu ---
        // Avant de dessiner, on vérifie qu'on possède bien un `RenderPassDescriptor`
        // et un `drawable` actif pour l'écran actuel, ansi qu'un `commandBuffer`.
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else {
            return
        }

        // --- Récupérer les données courantes en évitant les accès concurrents ---
        // L'utilisation de `NSLock` permet d'éviter un crash potentiel si l'image
        // est mise à jour sur un autre processeur au milieu de la boucle de rendu.
        frameLock.lock()
        let frame = currentFrame     // Dernière image capturée (RGB/Profondeur)
        let mode = self.mode         // Mode d'affichage (.rgb, .depth, .pointCloud)
        let maxDistance = self.maxDistance // Distance maximale pour la couleur
        let yaw = self.yaw           // Rotation X du point cloud
        let pitch = self.pitch       // Rotation Y du point cloud
        frameLock.unlock()

        // Si on n'a pas encore reçu d'image (le temps qu'ARKit s'initialise), on annule.
        guard let frame else { return }

        // --- Création de l'encodeur de rendu ---
        // L'encodeur va écrire les commandes pour le GPU (Metal).
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // --- Choix de la fonction de dessin selon le mode demandé par l'interface ---
        switch mode {
        case .rgb:
            renderRGB(frame: frame, encoder: encoder, view: view)
        case .depth:
            renderDepth(frame: frame, encoder: encoder, view: view, maxDistance: maxDistance)
        case .pointCloud:
            renderPointCloud(frame: frame, encoder: encoder, maxDistance: maxDistance, yaw: yaw, pitch: pitch)
        }

        // --- Finitions : Transmission de l'image préparée (Commit & Present) ---
        // Signale au GPU qu'on a terminé d'encoder ce que l'on voulait afficher.
        encoder.endEncoding()
        // Affiche l'image finie (`drawable`) sur l'écran au prochain cycle de rafraichissement.
        commandBuffer.present(drawable)
        // Lance toutes les instructions accumulées dans la mémoire GPU.
        commandBuffer.commit()
        
        // --- VRAIMENT IMPORTANT (Fix fuite de mémoire) ---
        // Le pont de textures conserve des images en cache pour aller plus vite.
        // Si on ne nettoie pas, les textures empilées feront crasher l'app (XPC interruted).
        // Cela résout les crash dûs à "Jetsam" tuant l'application à cause de l'excès de RAM.
        textureBridge.flush()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func getDisplayUniforms(frame: SpatialFrame, view: MTKView) -> DisplayUniforms {
        // --- Récupération de la matrice de transformation affine (displayTransform) ---
        // ARKit capture les images dans une orientation paysage fixe par rapport
        // au capteur physique. Pour afficher correctement l'image sans l'étirer 
        // ou la déformer, on récupère la matrice calculée par ARKit (.displayTransform).
        let affine = frame.displayTransform
        
        // Convertit l'objet CGAffineTransform (utilisé par CoreGraphics dans CPU)
        // vers un type simd_float3x3 compréhensible par les shaders (GPU, Metal).
        // Cela sert à projeter correctement les pixels lors du rendu !
        let transform = simd_float3x3(
            simd_float3(Float(affine.a), Float(affine.b), 0),
            simd_float3(Float(affine.c), Float(affine.d), 0),
            simd_float3(Float(affine.tx), Float(affine.ty), 1)
        )
        return DisplayUniforms(transform: transform)
    }

    private func renderRGB(frame: SpatialFrame, encoder: MTLRenderCommandEncoder, view: MTKView) {
        let image = frame.capturedImage
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)

        guard let yTexture = textureBridge.makeTexture(
            from: image,
            pixelFormat: .r8Unorm,
            planeIndex: 0,
            width: width,
            height: height
        ),
        let cbcrTexture = textureBridge.makeTexture(
            from: image,
            pixelFormat: .rg8Unorm,
            planeIndex: 1,
            width: chromaWidth,
            height: chromaHeight
        ) else {
            return
        }

        var uniforms = getDisplayUniforms(frame: frame, view: view)

        encoder.setRenderPipelineState(rgbPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderDepth(frame: SpatialFrame, encoder: MTLRenderCommandEncoder, view: MTKView, maxDistance: Float) {
        let depth = frame.depthMap
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)

        guard let depthTexture = textureBridge.makeTexture(
            from: depth,
            pixelFormat: .r32Float,
            planeIndex: 0,
            width: width,
            height: height
        ) else {
            return
        }

        var displayUniforms = getDisplayUniforms(frame: frame, view: view)
        var depthUniforms = DepthUniforms(minDepth: 0.1, maxDepth: maxDistance)

        encoder.setRenderPipelineState(depthPipeline)
        encoder.setVertexBytes(&displayUniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(depthTexture, index: 0)
        encoder.setFragmentBytes(&depthUniforms, length: MemoryLayout<DepthUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderPointCloud(
        frame: SpatialFrame,
        encoder: MTLRenderCommandEncoder,
        maxDistance: Float,
        yaw: Float,
        pitch: Float
    ) {
        let depthMap = frame.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        guard let depthTexture = textureBridge.makeTexture(
            from: depthMap,
            pixelFormat: .r32Float,
            planeIndex: 0,
            width: depthWidth,
            height: depthHeight
        ) else {
            return
        }

        let imageWidth = max(frame.imageResolution.x, 1)
        let imageHeight = max(frame.imageResolution.y, 1)
        let sx = Float(depthWidth) / Float(imageWidth)
        let sy = Float(depthHeight) / Float(imageHeight)

        let intrinsics = frame.intrinsics
        var uniforms = PointCloudUniforms(
            depthIntrinsics: SIMD4<Float>(
                intrinsics.columns.0.x * sx,
                intrinsics.columns.1.y * sy,
                intrinsics.columns.2.x * sx,
                intrinsics.columns.2.y * sy
            ),
            depthSize: SIMD2<UInt32>(UInt32(depthWidth), UInt32(depthHeight)),
            minDepth: 0.1,
            maxDepth: maxDistance,
            pointSize: 2.0,
            yaw: yaw,
            pitch: pitch
        )

        encoder.setRenderPipelineState(pointPipeline)
        encoder.setVertexTexture(depthTexture, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: depthWidth * depthHeight)
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String,
        colorFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = colorFormat

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
