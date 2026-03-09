#include <metal_stdlib>
using namespace metal;

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

struct DepthUniforms {
    float minDepth;
    float maxDepth;
};

struct DisplayUniforms {
    float3x3 transform;
};

struct PointCloudUniforms {
    float4x4 viewProjection;
    float4 depthIntrinsics;
    uint2 depthSize;
    float minDepth;
    float maxDepth;
    float pointSize;
};

struct PointOut {
    float4 position [[position]];
    float2 rgbUV; 
    float pointSize [[point_size]];
};

struct YoloDetectionMetal {
    float minX, minY, maxX, maxY;
    float coeffs[32];
    float r, g, b, a; 
};

struct SegUniforms {
    int count;
    int show;
    int isFloat16; 
    int strideC; 
    int strideY; 
    int strideX; 
};

// --- FONCTION DE SEGMENTATION (DÉFINITIVE) ---
inline float3 applySegmentation(
    float2 yoloUV, // <- On lui passe directement l'UV converti
    float3 baseColor,
    constant SegUniforms& segUniforms,
    constant YoloDetectionMetal* detections,
    device const void* prototypesRaw
) {
    if (segUniforms.show != 1 || segUniforms.count <= 0) return baseColor;

    for (int d = 0; d < segUniforms.count; d++) {
        YoloDetectionMetal det = detections[d];
        
        if (yoloUV.x >= det.minX && yoloUV.x <= det.maxX && yoloUV.y >= det.minY && yoloUV.y <= det.maxY) {
            
            int px = clamp(int(yoloUV.x * 160.0), 0, 159);
            int py = clamp(int(yoloUV.y * 160.0), 0, 159);
            
            float maskVal = 0.0;
            for (int c = 0; c < 32; c++) {
                int index = c * segUniforms.strideC + py * segUniforms.strideY + px * segUniforms.strideX;
                
                float protoVal = segUniforms.isFloat16 == 1 ? 
                    float(((device const half*)prototypesRaw)[index]) : 
                    ((device const float*)prototypesRaw)[index];
                    
                maskVal += protoVal * det.coeffs[c];
            }
            
            float sigmoid = 1.0 / (1.0 + exp(-maskVal));
            
            if (sigmoid > 0.5) {
                float3 maskColor = float3(det.r, det.g, det.b);
                return mix(baseColor, maskColor, 0.45); 
            }
        }
    }
    return baseColor;
}

vertex FullscreenOut fullscreenVertex(
    uint id [[vertex_id]],
    constant DisplayUniforms& uniforms [[buffer(0)]]
) {
    const float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)
    };

    FullscreenOut out;
    out.position = float4(positions[id], 0.0, 1.0);
    
    float3 uv = float3(uvs[id], 1.0);
    float2 transformedUV = (uniforms.transform * uv).xy;
    out.uv = float2(1.0 - transformedUV.x, 1.0 - transformedUV.y);
    return out;
}

fragment float4 rgbFragment(
    FullscreenOut in [[stage_in]],
    texture2d<float, access::sample> yTex [[texture(0)]],
    texture2d<float, access::sample> cbcrTex [[texture(1)]],
    constant SegUniforms& segUniforms [[buffer(0)]],
    constant YoloDetectionMetal* detections [[buffer(1)]],
    device const void* prototypes [[buffer(2)]] 
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float y = yTex.sample(s, in.uv).r;
    float2 cbcr = cbcrTex.sample(s, in.uv).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402 * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772 * cbcr.x;
    
    float3 finalColor = saturate(rgb);
    
    // MAGIE : On reconstruit l'UV de YOLO en appliquant une rotation de 90° à la mémoire brute
    float2 yoloUV = float2(1.0 - in.uv.y, in.uv.x);
    
    finalColor = applySegmentation(yoloUV, finalColor, segUniforms, detections, prototypes);

    return float4(finalColor, 1.0);
}

float3 inferno(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c0 = float3(0.001, 0.000, 0.014);
    float3 c1 = float3(0.275, 0.051, 0.364);
    float3 c2 = float3(0.659, 0.212, 0.255);
    float3 c3 = float3(0.988, 0.998, 0.645);
    if (t < 0.33) { return mix(c0, c1, t / 0.33); }
    if (t < 0.66) { return mix(c1, c2, (t - 0.33) / 0.33); }
    return mix(c2, c3, (t - 0.66) / 0.34);
}

fragment float4 depthFragment(FullscreenOut in [[stage_in]], texture2d<float, access::sample> depthTex [[texture(0)]], constant DepthUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float depth = depthTex.sample(s, in.uv).r;
    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) { return float4(0.0, 0.0, 0.0, 1.0); }
    float normalized = (depth - uniforms.minDepth) / max(uniforms.maxDepth - uniforms.minDepth, 1e-4);
    return float4(inferno(normalized), 1.0);
}

vertex PointOut pointCloudVertex(
    uint vid [[vertex_id]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant PointCloudUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    uint width = uniforms.depthSize.x;
    uint x = vid % width;
    uint y = vid / width;
    float2 uv = (float2(x, y) + 0.5) / float2(uniforms.depthSize);
    float depth = depthTex.sample(s, uv).r;

    PointOut out;
    out.rgbUV = uv;
    out.pointSize = uniforms.pointSize;

    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) {
        out.position = float4(2.0, 2.0, 1.0, 1.0);
        return out;
    }

    float px = (float(x) - uniforms.depthIntrinsics.z) / uniforms.depthIntrinsics.x * depth;
    float py = -(float(y) - uniforms.depthIntrinsics.w) / uniforms.depthIntrinsics.y * depth;
    float pz = -depth;

    float4 localPos = float4(py, -px, pz, 1.0);
    out.position = uniforms.viewProjection * localPos;
    return out;
}

fragment float4 pointCloudFragment(
    PointOut in [[stage_in]],
    texture2d<float, access::sample> yTex    [[texture(0)]],
    texture2d<float, access::sample> cbcrTex [[texture(1)]],
    constant SegUniforms& segUniforms [[buffer(0)]],
    constant YoloDetectionMetal* detections [[buffer(1)]],
    device const void* prototypes [[buffer(2)]],
    float2 coord [[point_coord]]
) {
    float2 delta = coord - 0.5;
    if (dot(delta, delta) > 0.25) { discard_fragment(); }

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float  y    = yTex.sample(s, in.rgbUV).r;
    float2 cbcr = cbcrTex.sample(s, in.rgbUV).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402    * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772    * cbcr.x;
    float3 finalColor = saturate(rgb);

    // MÊME MAGIE : Rotation de l'UV brute du capteur vers YOLO
    float2 yoloUV = float2(1.0 - in.rgbUV.y, in.rgbUV.x);
    
    finalColor = applySegmentation(yoloUV, finalColor, segUniforms, detections, prototypes);

    return float4(finalColor, 1.0);
}

struct PackedPoint {
    packed_float3 position;
    packed_float3 color;
};

struct AccumulateUniforms {
    float4x4 cameraTransform;
    float4 depthIntrinsics;
    uint2 depthSize;
    float minDepth;
    float maxDepth;
};

struct AccumulatedRenderUniforms {
    float4x4 viewProjection;
    float pointSize;
};

struct AccumulatedPointOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

kernel void accumulatePointCloud(
    texture2d<float, access::sample> depthTex [[texture(0)]],
    texture2d<float, access::sample> yTex [[texture(1)]],
    texture2d<float, access::sample> cbcrTex [[texture(2)]],
    constant AccumulateUniforms& uniforms [[buffer(0)]],
    device PackedPoint* outPoints [[buffer(1)]],
    device atomic_uint* pointCount [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.depthSize.x || gid.y >= uniforms.depthSize.y) return;

    if (gid.x % 2 != 0 || gid.y % 2 != 0) return;

    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(gid) + 0.5) / float2(uniforms.depthSize);
    float depth = depthTex.sample(s, uv).r;

    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) return;

    float fx = uniforms.depthIntrinsics.x;
    float fy = uniforms.depthIntrinsics.y;
    float cx = uniforms.depthIntrinsics.z;
    float cy = uniforms.depthIntrinsics.w;

    float px = (float(gid.x) - cx) / fx * depth;
    float py = -(float(gid.y) - cy) / fy * depth;
    float pz = -depth;

    float4 localPos = float4(px, py, pz, 1.0);
    float4 worldPos = uniforms.cameraTransform * localPos;

    constexpr sampler sColor(address::clamp_to_edge, filter::linear);
    float y = yTex.sample(sColor, uv).r;
    float2 cbcr = cbcrTex.sample(sColor, uv).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402 * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772 * cbcr.x;
    rgb = saturate(rgb);

    uint index = atomic_fetch_add_explicit(pointCount, 1, memory_order_relaxed);
    if (index < 5000000) {
        outPoints[index].position = packed_float3(worldPos.xyz);
        outPoints[index].color = packed_float3(rgb);
    }
}

vertex AccumulatedPointOut accumulatedVertex(
    uint vid [[vertex_id]],
    device const PackedPoint* points [[buffer(0)]],
    constant AccumulatedRenderUniforms& uniforms [[buffer(1)]]
) {
    PackedPoint pt = points[vid];

    AccumulatedPointOut out;
    out.position = uniforms.viewProjection * float4(pt.position, 1.0);
    out.color = pt.color;
    out.pointSize = uniforms.pointSize;
    return out;
}

fragment float4 accumulatedFragment(AccumulatedPointOut in [[stage_in]], float2 coord [[point_coord]]) {
    float2 delta = coord - 0.5;
    if (dot(delta, delta) > 0.25) {
        discard_fragment();
    }
    return float4(in.color, 1.0);
}
