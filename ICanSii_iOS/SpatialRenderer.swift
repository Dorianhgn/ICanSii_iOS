import Combine
import Foundation
import Metal
import MetalKit
import simd

// Utilitaires mathématiques SIMD pour générer nos matrices (sans passer par SceneKit)
extension simd_float4x4 {
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1 / tan(fovy * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange
        return simd_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        )
    }
    
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }
    
    static func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(angle); let s = sin(angle); let t = 1 - c
        let x = axis.x, y = axis.y, z = axis.z
        return simd_float4x4(
            SIMD4<Float>(t*x*x + c, t*x*y + z*s, t*x*z - y*s, 0),
            SIMD4<Float>(t*x*y - z*s, t*y*y + c, t*y*z + x*s, 0),
            SIMD4<Float>(t*x*z + y*s, t*y*z - x*s, t*z*z + c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

final class SpatialRenderer: NSObject, MTKViewDelegate {
    // ... Garder les structures Uniforms existantes ...
    struct DepthUniforms { var minDepth: Float; var maxDepth: Float }
    struct DisplayUniforms { var transform: simd_float3x3 }
    struct PointCloudUniforms {
        var depthIntrinsics: SIMD4<Float>; var depthSize: SIMD2<UInt32>
        var minDepth: Float; var maxDepth: Float; var pointSize: Float
        var yaw: Float; var pitch: Float
    }
    
    // Nouvelles structures
    struct AccumulateUniforms {
        var cameraTransform: simd_float4x4
        var depthIntrinsics: SIMD4<Float>
        var depthSize: SIMD2<UInt32>
        var minDepth: Float
        var maxDepth: Float
    }
    
    struct AccumulatedRenderUniforms {
        var viewProjection: simd_float4x4
        var pointSize: Float
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureBridge: MetalTextureBridge
    private let frameLock = NSLock()

    private var rgbPipeline: MTLRenderPipelineState
    private var depthPipeline: MTLRenderPipelineState
    private var pointPipeline: MTLRenderPipelineState
    
    // Pipelines d'accumulation
    private var accumulateComputePipeline: MTLComputePipelineState
    private var accumulatedRenderPipeline: MTLRenderPipelineState
    
    // Buffers d'accumulation (5 millions de points max)
    private let maxPoints = 5_000_000
    private var pointBuffer: MTLBuffer?
    private var pointCountBuffer: MTLBuffer?

    private var currentFrame: SpatialFrame?
    private var mode: SpatialDisplayMode = .rgb
    private var maxDistance: Float = 6.0
    
    // Caméra de navigation
    private var yaw: Float = 0.0
    private var pitch: Float = 0.0
    private var cameraDistance: Float = 3.0
    private var targetOffset = SIMD2<Float>(0, 0)
    
    // Etat d'enregistrement
    private var isRecording: Bool = false
    private var frameSkipCounter = 0
    private var cancellable: AnyCancellable?

    init?(arManager: ARManager, mtkView: MTKView) {
        guard let device = mtkView.device,
              let queue = device.makeCommandQueue(),
              let textureBridge = MetalTextureBridge(device: device),
              let library = device.makeDefaultLibrary() else { return nil }

        self.device = device
        self.queue = queue
        self.textureBridge = textureBridge

        do {
            // Ajout de `useDepthStencil: true` ici 👇
            rgbPipeline = try SpatialRenderer.makePipeline(device: device, library: library, vertexFunction: "fullscreenVertex", fragmentFunction: "rgbFragment", colorFormat: mtkView.colorPixelFormat, useDepthStencil: true)
            depthPipeline = try SpatialRenderer.makePipeline(device: device, library: library, vertexFunction: "fullscreenVertex", fragmentFunction: "depthFragment", colorFormat: mtkView.colorPixelFormat, useDepthStencil: true)
            pointPipeline = try SpatialRenderer.makePipeline(device: device, library: library, vertexFunction: "pointCloudVertex", fragmentFunction: "pointCloudFragment", colorFormat: mtkView.colorPixelFormat, useDepthStencil: true)
            
            // Initialisation des nouveaux pipelines
            let computeFunction = library.makeFunction(name: "accumulatePointCloud")!
            accumulateComputePipeline = try device.makeComputePipelineState(function: computeFunction)
            
            accumulatedRenderPipeline = try SpatialRenderer.makePipeline(device: device, library: library, vertexFunction: "accumulatedVertex", fragmentFunction: "accumulatedFragment", colorFormat: mtkView.colorPixelFormat, useDepthStencil: true)
            
            // On s'assure que la vue gère le format de profondeur pour que le point cloud 3D s'affiche bien
            mtkView.depthStencilPixelFormat = .depth32Float
            
        } catch { return nil }

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

    deinit { cancellable?.cancel() }

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

    func setRecording(_ recording: Bool) {
        frameLock.lock()
        defer { frameLock.unlock() }
        if recording && !isRecording {
            // Début d'enregistrement : Réinitialiser le buffer de compteur
            let stride = 24 // sizeof(PackedPoint) : 2 * packed_float3
            pointBuffer = device.makeBuffer(length: maxPoints * stride, options: .storageModePrivate)
            pointCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            
            if let ptr = pointCountBuffer?.contents().assumingMemoryBound(to: UInt32.self) {
                ptr.pointee = 0
            }
        }
        isRecording = recording
    }

    // CORRECTION DE L'INVERSION DES GESTES ICI !
    func rotate(deltaX: Float, deltaY: Float) {
        frameLock.lock()
        // Sur le téléphone (Portrait) :
        // Le mouvement Horizontal (X) doit faire tourner autour de l'axe vertical => modifier Yaw.
        // Le mouvement Vertical (Y) doit incliner la caméra vers le haut/bas => modifier Pitch.
        // On swap deltaX et deltaY avec les signes adéquats pour que ça paraisse naturel :
        yaw -= deltaX
        pitch = min(max(pitch - deltaY, -1.5), 1.5)
        frameLock.unlock()
    }
    
    func zoom(factor: Float) {
        frameLock.lock()
        // Un pinch (agrandir) réduit la distance (on avance), réduire l'écran l'augmente
        cameraDistance = min(max(cameraDistance / factor, 0.5), 15.0)
        frameLock.unlock()
    }

    func translate(deltaX: Float, deltaY: Float) {
        frameLock.lock()
        // Inversion des signes pour que le nuage suive naturellement les doigts :
        // Swipe droite (+X) = Déplace le nuage à droite (+X)
        // Swipe bas (+Y écran) = Déplace le nuage vers le bas (-Y 3D)
        targetOffset.x += deltaX
        targetOffset.y -= deltaY
        frameLock.unlock()
    }

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        frameLock.lock()
        let frame = currentFrame
        let mode = self.mode
        let maxDist = self.maxDistance
        let currentYaw = self.yaw
        let currentPitch = self.pitch
        let curDist = self.cameraDistance
        let isRec = self.isRecording
        frameLock.unlock()

        guard let frame else { return }
        
        // --- ETAPE 1 : ACCUMULATION COMPUTE SHADER ---
        // Exécuté si on enregistre, sans bloquer le main thread, 1 frame sur 3
        if isRec {
            frameSkipCounter += 1
            if frameSkipCounter % 3 == 0, let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                dispatchAccumulation(frame: frame, encoder: computeEncoder)
                computeEncoder.endEncoding()
            }
        }

        // --- ETAPE 2 : RENDU GRAPHIQUE ---
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        switch mode {
        case .rgb:
            renderRGB(frame: frame, encoder: encoder, view: view)
        case .depth:
            renderDepth(frame: frame, encoder: encoder, view: view, maxDistance: maxDist)
        case .pointCloud:
            // S'il n'y a pas de buffer ou qu'on est au début, on affiche le direct, 
            // sinon on affiche la reconstruction naviguable.
            let count = getPointCount()
            if count > 0 && !isRec {
                renderAccumulatedPointCloud(encoder: encoder, view: view, pointCount: count, yaw: currentYaw, pitch: currentPitch, distance: curDist)
            } else {
                renderPointCloud(frame: frame, encoder: encoder, maxDistance: maxDist, yaw: currentYaw, pitch: currentPitch)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        textureBridge.flush()
    }
    
    private func getPointCount() -> Int {
        guard let ptr = pointCountBuffer?.contents().assumingMemoryBound(to: UInt32.self) else { return 0 }
        return min(Int(ptr.pointee), maxPoints)
    }

    private func dispatchAccumulation(frame: SpatialFrame, encoder: MTLComputeCommandEncoder) {
        guard let pointBuffer, let pointCountBuffer else { return }
        
        let depthMap = frame.depthMap
        let rgbImage = frame.capturedImage
        
        guard let depthTexture = textureBridge.makeTexture(from: depthMap, pixelFormat: .r32Float, planeIndex: 0, width: CVPixelBufferGetWidth(depthMap), height: CVPixelBufferGetHeight(depthMap)),
              let yTexture = textureBridge.makeTexture(from: rgbImage, pixelFormat: .r8Unorm, planeIndex: 0, width: CVPixelBufferGetWidthOfPlane(rgbImage, 0), height: CVPixelBufferGetHeightOfPlane(rgbImage, 0)),
              let cbcrTexture = textureBridge.makeTexture(from: rgbImage, pixelFormat: .rg8Unorm, planeIndex: 1, width: CVPixelBufferGetWidthOfPlane(rgbImage, 1), height: CVPixelBufferGetHeightOfPlane(rgbImage, 1)) else { return }
        
        let sx = Float(CVPixelBufferGetWidth(depthMap)) / Float(max(frame.imageResolution.x, 1))
        let sy = Float(CVPixelBufferGetHeight(depthMap)) / Float(max(frame.imageResolution.y, 1))
        
        var uniforms = AccumulateUniforms(
            cameraTransform: frame.cameraTransform,
            depthIntrinsics: SIMD4<Float>(frame.intrinsics.columns.0.x * sx, frame.intrinsics.columns.1.y * sy, frame.intrinsics.columns.2.x * sx, frame.intrinsics.columns.2.y * sy),
            depthSize: SIMD2<UInt32>(UInt32(CVPixelBufferGetWidth(depthMap)), UInt32(CVPixelBufferGetHeight(depthMap))),
            minDepth: 0.1, maxDepth: 10.0
        )
        
        encoder.setComputePipelineState(accumulateComputePipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<AccumulateUniforms>.stride, index: 0)
        encoder.setBuffer(pointBuffer, offset: 0, index: 1)
        encoder.setBuffer(pointCountBuffer, offset: 0, index: 2)
        encoder.setTexture(depthTexture, index: 0)
        encoder.setTexture(yTexture, index: 1)
        encoder.setTexture(cbcrTexture, index: 2)
        
        let w = accumulateComputePipeline.threadExecutionWidth
        let h = accumulateComputePipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(CVPixelBufferGetWidth(depthMap), CVPixelBufferGetHeight(depthMap), 1)
        
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
    }

    private func renderAccumulatedPointCloud(encoder: MTLRenderCommandEncoder, view: MTKView, pointCount: Int, yaw: Float, pitch: Float, distance: Float) {
        guard let pointBuffer else { return }
        
        // Configuration de la matrice de vue-projection
        let aspect = Float(view.bounds.width / view.bounds.height)
        let projection = simd_float4x4.perspective(fovy: .pi / 3, aspect: aspect, near: 0.05, far: 50.0)
        
        // Caméra orbitale en espace ARKit (Monde absolu) avec support du décalage cible (Target Offset)
        let orbitTranslation = simd_float4x4.translation(SIMD3<Float>(0, 0, -distance))
        let rotationX = simd_float4x4.rotation(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let rotationY = simd_float4x4.rotation(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let targetTranslation = simd_float4x4.translation(SIMD3<Float>(targetOffset.x, targetOffset.y, 0))
        
        let viewMatrix = orbitTranslation * rotationX * rotationY * targetTranslation
        
        var uniforms = AccumulatedRenderUniforms(
            viewProjection: projection * viewMatrix,
            pointSize: 3.0
        )
        
        encoder.setRenderPipelineState(accumulatedRenderPipeline)
        encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AccumulatedRenderUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
    }

    // Garder les méthodes de rendu originales intactes
    private func getDisplayUniforms(frame: SpatialFrame, view: MTKView) -> DisplayUniforms {
        let affine = frame.displayTransform
        let transform = simd_float3x3(
            simd_float3(Float(affine.a), Float(affine.b), 0),
            simd_float3(Float(affine.c), Float(affine.d), 0),
            simd_float3(Float(affine.tx), Float(affine.ty), 1)
        )
        return DisplayUniforms(transform: transform)
    }

    private func renderRGB(frame: SpatialFrame, encoder: MTLRenderCommandEncoder, view: MTKView) {
        let image = frame.capturedImage
        guard let yTexture = textureBridge.makeTexture(from: image, pixelFormat: .r8Unorm, planeIndex: 0, width: CVPixelBufferGetWidthOfPlane(image, 0), height: CVPixelBufferGetHeightOfPlane(image, 0)),
              let cbcrTexture = textureBridge.makeTexture(from: image, pixelFormat: .rg8Unorm, planeIndex: 1, width: CVPixelBufferGetWidthOfPlane(image, 1), height: CVPixelBufferGetHeightOfPlane(image, 1)) else { return }
        var uniforms = getDisplayUniforms(frame: frame, view: view)
        encoder.setRenderPipelineState(rgbPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderDepth(frame: SpatialFrame, encoder: MTLRenderCommandEncoder, view: MTKView, maxDistance: Float) {
        let depth = frame.depthMap
        guard let depthTexture = textureBridge.makeTexture(from: depth, pixelFormat: .r32Float, planeIndex: 0, width: CVPixelBufferGetWidth(depth), height: CVPixelBufferGetHeight(depth)) else { return }
        var displayUniforms = getDisplayUniforms(frame: frame, view: view)
        var depthUniforms = DepthUniforms(minDepth: 0.1, maxDepth: maxDistance)
        encoder.setRenderPipelineState(depthPipeline)
        encoder.setVertexBytes(&displayUniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(depthTexture, index: 0)
        encoder.setFragmentBytes(&depthUniforms, length: MemoryLayout<DepthUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderPointCloud(frame: SpatialFrame, encoder: MTLRenderCommandEncoder, maxDistance: Float, yaw: Float, pitch: Float) {
        let depthMap = frame.depthMap
        guard let depthTexture = textureBridge.makeTexture(from: depthMap, pixelFormat: .r32Float, planeIndex: 0, width: CVPixelBufferGetWidth(depthMap), height: CVPixelBufferGetHeight(depthMap)) else { return }
        let sx = Float(CVPixelBufferGetWidth(depthMap)) / Float(max(frame.imageResolution.x, 1))
        let sy = Float(CVPixelBufferGetHeight(depthMap)) / Float(max(frame.imageResolution.y, 1))
        let intrinsics = frame.intrinsics
        var uniforms = PointCloudUniforms(
            depthIntrinsics: SIMD4<Float>(intrinsics.columns.0.x * sx, intrinsics.columns.1.y * sy, intrinsics.columns.2.x * sx, intrinsics.columns.2.y * sy),
            depthSize: SIMD2<UInt32>(UInt32(CVPixelBufferGetWidth(depthMap)), UInt32(CVPixelBufferGetHeight(depthMap))),
            minDepth: 0.1, maxDepth: maxDistance, pointSize: 2.0, yaw: yaw, pitch: pitch
        )
        let rgbImage = frame.capturedImage
        guard let yTexture = textureBridge.makeTexture(from: rgbImage, pixelFormat: .r8Unorm, planeIndex: 0, width: CVPixelBufferGetWidthOfPlane(rgbImage, 0), height: CVPixelBufferGetHeightOfPlane(rgbImage, 0)),
              let cbcrTexture = textureBridge.makeTexture(from: rgbImage, pixelFormat: .rg8Unorm, planeIndex: 1, width: CVPixelBufferGetWidthOfPlane(rgbImage, 1), height: CVPixelBufferGetHeightOfPlane(rgbImage, 1)) else { return }
        encoder.setRenderPipelineState(pointPipeline)
        encoder.setVertexTexture(depthTexture, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: CVPixelBufferGetWidth(depthMap) * CVPixelBufferGetHeight(depthMap))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, vertexFunction: String, fragmentFunction: String, colorFormat: MTLPixelFormat, useDepthStencil: Bool = false) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        if useDepthStencil { descriptor.depthAttachmentPixelFormat = .depth32Float }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}