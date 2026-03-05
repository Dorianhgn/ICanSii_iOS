import CoreVideo
import Metal

final class MetalTextureBridge {
    private let device: MTLDevice
    private var cache: CVMetalTextureCache?

    init?(device: MTLDevice) {
        self.device = device
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard status == kCVReturnSuccess, let textureCache else {
            return nil
        }
        cache = textureCache
    }

    func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let cache else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTexture)
    }

    func flush() {
        guard let cache else { return }
        CVMetalTextureCacheFlush(cache, 0)
    }
}
