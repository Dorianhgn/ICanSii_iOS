#include <metal_stdlib>
using namespace metal;

struct PackedPoint {
    packed_float3 position;
    packed_float3 color;
};

struct TriplaneScatterUniforms {
    uint pointCount;
    uint resolution;
    float halfExtent;
    float pad;
};

struct DebugQuadOut {
    float4 position [[position]];
    float2 uv;
};

struct DebugScalarUniforms {
    float minValue;
    float maxValue;
};

inline uint floatToOrderedUInt(float v) {
    // Bit trick: map IEEE754 float to monotonic uint order so atomic max can be
    // used as a proxy for float max/min reductions.
    uint bits = as_type<uint>(v);
    uint signMask = bits >> 31;
    return signMask != 0 ? ~bits : (bits | 0x80000000u);
}

inline float orderedUIntToFloat(uint v) {
    uint bits = (v & 0x80000000u) != 0 ? (v & 0x7fffffffu) : ~v;
    return as_type<float>(bits);
}

inline bool mapToGrid(float coord, float halfExtent, uint res, thread uint& outPx) {
    float t = (coord + halfExtent) / max(2.0f * halfExtent, 1e-6f);
    if (t < 0.0f || t >= 1.0f) {
        return false;
    }
    outPx = min(uint(floor(t * float(res))), res - 1);
    return true;
}

kernel void clearTriplaneAtomic(
    device atomic_uint* gridXY [[buffer(0)]],
    device atomic_uint* gridYZ [[buffer(1)]],
    device atomic_uint* gridZX [[buffer(2)]],
    constant TriplaneScatterUniforms& uniforms [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint total = uniforms.resolution * uniforms.resolution;
    if (tid >= total) return;

    const uint clearValue = floatToOrderedUInt(-INFINITY);
    atomic_store_explicit(&gridXY[tid], clearValue, memory_order_relaxed);
    atomic_store_explicit(&gridYZ[tid], clearValue, memory_order_relaxed);
    atomic_store_explicit(&gridZX[tid], clearValue, memory_order_relaxed);
}

kernel void triplaneScatter(
    device const PackedPoint* points [[buffer(0)]],
    constant TriplaneScatterUniforms& uniforms [[buffer(1)]],
    device atomic_uint* gridXY [[buffer(2)]],
    device atomic_uint* gridYZ [[buffer(3)]],
    device atomic_uint* gridZX [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= uniforms.pointCount) return;

    float3 p = float3(points[tid].position);

    uint px = 0;
    uint py = 0;
    uint pz = 0;

    bool inX = mapToGrid(p.x, uniforms.halfExtent, uniforms.resolution, px);
    bool inY = mapToGrid(p.y, uniforms.halfExtent, uniforms.resolution, py);
    bool inZ = mapToGrid(p.z, uniforms.halfExtent, uniforms.resolution, pz);

    // Front view (XY), value = max Z.
    if (inX && inY) {
        uint zEncoded = floatToOrderedUInt(p.z);
        uint idx = py * uniforms.resolution + px;
        atomic_fetch_max_explicit(&gridXY[idx], zEncoded, memory_order_relaxed);
    }

    // Side view (YZ), value = min X via max(-X).
    if (inY && inZ) {
        uint negXEncoded = floatToOrderedUInt(-p.x);
        uint idx = pz * uniforms.resolution + py;
        atomic_fetch_max_explicit(&gridYZ[idx], negXEncoded, memory_order_relaxed);
    }

    // Top view (ZX), value = max Y.
    if (inZ && inX) {
        uint yEncoded = floatToOrderedUInt(p.y);
        uint idx = px * uniforms.resolution + pz;
        atomic_fetch_max_explicit(&gridZX[idx], yEncoded, memory_order_relaxed);
    }
}

kernel void resolveTriplane(
    device atomic_uint* gridXY [[buffer(0)]],
    device atomic_uint* gridYZ [[buffer(1)]],
    device atomic_uint* gridZX [[buffer(2)]],
    constant TriplaneScatterUniforms& uniforms [[buffer(3)]],
    texture2d<float, access::write> texXY [[texture(0)]],
    texture2d<float, access::write> texYZ [[texture(1)]],
    texture2d<float, access::write> texZX [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.resolution || gid.y >= uniforms.resolution) return;

    const uint clearValue = floatToOrderedUInt(-INFINITY);
    // Linear row-major index for the atomic grids.
    uint idx = gid.y * uniforms.resolution + gid.x;

    uint xyRaw = atomic_load_explicit(&gridXY[idx], memory_order_relaxed);
    uint yzRaw = atomic_load_explicit(&gridYZ[idx], memory_order_relaxed);
    uint zxRaw = atomic_load_explicit(&gridZX[idx], memory_order_relaxed);

    float xyValue = (xyRaw == clearValue) ? 0.0f : orderedUIntToFloat(xyRaw);
    float yzValue = (yzRaw == clearValue) ? 0.0f : -orderedUIntToFloat(yzRaw);
    float zxValue = (zxRaw == clearValue) ? 0.0f : orderedUIntToFloat(zxRaw);

    texXY.write(xyValue, gid);
    texYZ.write(yzValue, gid);
    texZX.write(zxValue, gid);
}

vertex DebugQuadOut debugQuadVertex(uint id [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)
    };

    DebugQuadOut out;
    out.position = float4(positions[id], 0.0, 1.0);
    out.uv = uvs[id];
    return out;
}

inline float3 debugRamp(float t) {
    t = clamp(t, 0.0f, 1.0f);
    float3 a = float3(0.02, 0.03, 0.08);
    float3 b = float3(0.06, 0.35, 0.85);
    float3 c = float3(0.10, 0.82, 0.55);
    float3 d = float3(0.98, 0.92, 0.28);
    if (t < 0.33f) return mix(a, b, t / 0.33f);
    if (t < 0.66f) return mix(b, c, (t - 0.33f) / 0.33f);
    return mix(c, d, (t - 0.66f) / 0.34f);
}

fragment float4 debugScalarFragment(
    DebugQuadOut in [[stage_in]],
    texture2d<float, access::sample> scalarTex [[texture(0)]],
    constant DebugScalarUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float raw = scalarTex.sample(s, in.uv).r;

    float span = max(uniforms.maxValue - uniforms.minValue, 1e-5f);
    float t = (raw - uniforms.minValue) / span;
    float3 col = debugRamp(t);

    if (!isfinite(raw) || raw == 0.0f) {
        col = float3(0.02, 0.02, 0.02);
    }

    return float4(col, 0.95);
}
