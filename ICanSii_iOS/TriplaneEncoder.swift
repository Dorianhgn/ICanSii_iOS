import Foundation
import Metal

final class TriplaneEncoder {
    struct ScatterUniforms {
        var pointCount: UInt32
        var resolution: UInt32
        var halfExtent: Float
        var pad: Float = 0
    }

    let resolution: Int
    let extent: Float

    private let device: MTLDevice
    private let clearPipeline: MTLComputePipelineState
    private let scatterPipeline: MTLComputePipelineState
    private let resolvePipeline: MTLComputePipelineState

    // Atomic grids are stored in linear buffers because iOS Metal toolchains
    // do not support texture2d<atomic_uint> in portable production builds.
    private var gridXY: MTLBuffer?
    private var gridYZ: MTLBuffer?
    private var gridZX: MTLBuffer?

    private var texXY: MTLTexture?
    private var texYZ: MTLTexture?
    private var texZX: MTLTexture?

    init?(device: MTLDevice, library: MTLLibrary, resolution: Int = 128, extent: Float = 4.0) {
        guard resolution > 0 else { return nil }

        guard let clearFn = library.makeFunction(name: "clearTriplaneAtomic"),
              let scatterFn = library.makeFunction(name: "triplaneScatter"),
              let resolveFn = library.makeFunction(name: "resolveTriplane") else {
            return nil
        }

        do {
            self.clearPipeline = try device.makeComputePipelineState(function: clearFn)
            self.scatterPipeline = try device.makeComputePipelineState(function: scatterFn)
            self.resolvePipeline = try device.makeComputePipelineState(function: resolveFn)
        } catch {
            return nil
        }

        self.device = device
        self.resolution = resolution
        self.extent = max(extent, 0.01)

        guard allocateTextures() else { return nil }
    }

    func encode(
        points: MTLBuffer,
        count: Int,
        commandBuffer: MTLCommandBuffer
    ) -> (MTLTexture, MTLTexture, MTLTexture) {
        guard let gridXY, let gridYZ, let gridZX,
              let texXY, let texYZ, let texZX else {
            preconditionFailure("Triplane textures must be allocated before encode")
        }

        var uniforms = ScatterUniforms(
            pointCount: UInt32(min(count, Int(UInt32.max))),
            resolution: UInt32(resolution),
            halfExtent: extent * 0.5
        )

        guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return (texXY, texYZ, texZX)
        }

        clearEncoder.label = "Triplane Clear"
        clearEncoder.setComputePipelineState(clearPipeline)
        clearEncoder.setBuffer(gridXY, offset: 0, index: 0)
        clearEncoder.setBuffer(gridYZ, offset: 0, index: 1)
        clearEncoder.setBuffer(gridZX, offset: 0, index: 2)
        clearEncoder.setBytes(&uniforms, length: MemoryLayout<ScatterUniforms>.stride, index: 3)

        let clearW = clearPipeline.threadExecutionWidth
        let clearCount = resolution * resolution
        clearEncoder.dispatchThreads(
            MTLSize(width: clearCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: clearW, height: 1, depth: 1)
        )
        clearEncoder.endEncoding()

        if count > 0 {
            guard let scatterEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return (texXY, texYZ, texZX)
            }

            scatterEncoder.label = "Triplane Scatter"
            uniforms.pointCount = UInt32(min(count, Int(UInt32.max)))

            scatterEncoder.setComputePipelineState(scatterPipeline)
            scatterEncoder.setBuffer(points, offset: 0, index: 0)
            scatterEncoder.setBytes(&uniforms, length: MemoryLayout<ScatterUniforms>.stride, index: 1)
            scatterEncoder.setBuffer(gridXY, offset: 0, index: 2)
            scatterEncoder.setBuffer(gridYZ, offset: 0, index: 3)
            scatterEncoder.setBuffer(gridZX, offset: 0, index: 4)

            let scatterW = scatterPipeline.threadExecutionWidth
            scatterEncoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: scatterW, height: 1, depth: 1)
            )
            scatterEncoder.endEncoding()
        }

        guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return (texXY, texYZ, texZX)
        }

        // Resolve converts ordered uint accumulators back to float textures
        // consumed by the debug overlay pipeline.
        resolveEncoder.label = "Triplane Resolve"
        resolveEncoder.setComputePipelineState(resolvePipeline)
        uniforms.pointCount = 0
        resolveEncoder.setBuffer(gridXY, offset: 0, index: 0)
        resolveEncoder.setBuffer(gridYZ, offset: 0, index: 1)
        resolveEncoder.setBuffer(gridZX, offset: 0, index: 2)
        resolveEncoder.setBytes(&uniforms, length: MemoryLayout<ScatterUniforms>.stride, index: 3)
        resolveEncoder.setTexture(texXY, index: 0)
        resolveEncoder.setTexture(texYZ, index: 1)
        resolveEncoder.setTexture(texZX, index: 2)

        let resolveW = resolvePipeline.threadExecutionWidth
        let resolveH = max(1, resolvePipeline.maxTotalThreadsPerThreadgroup / resolveW)
        resolveEncoder.dispatchThreads(
            MTLSize(width: resolution, height: resolution, depth: 1),
            threadsPerThreadgroup: MTLSize(width: resolveW, height: resolveH, depth: 1)
        )
        resolveEncoder.endEncoding()

        return (texXY, texYZ, texZX)
    }

    private func allocateTextures() -> Bool {
        let floatDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: resolution,
            height: resolution,
            mipmapped: false
        )
        floatDesc.usage = [.shaderRead, .shaderWrite]
        floatDesc.storageMode = .private

        let atomicByteCount = MemoryLayout<UInt32>.stride * resolution * resolution
        gridXY = device.makeBuffer(length: atomicByteCount, options: .storageModePrivate)
        gridYZ = device.makeBuffer(length: atomicByteCount, options: .storageModePrivate)
        gridZX = device.makeBuffer(length: atomicByteCount, options: .storageModePrivate)

        texXY = device.makeTexture(descriptor: floatDesc)
        texYZ = device.makeTexture(descriptor: floatDesc)
        texZX = device.makeTexture(descriptor: floatDesc)

        return gridXY != nil && gridYZ != nil && gridZX != nil && texXY != nil && texYZ != nil && texZX != nil
    }
}
