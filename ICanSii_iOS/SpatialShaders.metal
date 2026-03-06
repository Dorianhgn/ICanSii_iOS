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
    float4 depthIntrinsics;
    uint2 depthSize;
    float minDepth;
    float maxDepth;
    float pointSize;
    float yaw;
    float pitch;
};

struct PointOut {
    float4 position [[position]];
    // UV en espace paysage natif (landscape) pour aller chercher la couleur RGB
    // dans la texture caméra ARKit. Même repère que le depth map (même FOV, même orientation).
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
    int strideC; // Le saut mémoire pour changer de coefficient
    int strideY; // Le saut mémoire pour changer de ligne (Y)
    int strideX; // Le saut mémoire pour changer de pixel (X)
};

vertex FullscreenOut fullscreenVertex(
    uint id [[vertex_id]],
    constant DisplayUniforms& uniforms [[buffer(0)]]
) {
    // --- Définition des coordonnées d'écran (Vertices) ---
    // Metal utilise un système de coordonnées normalisé (NDC) où :
    // (-1, -1) est en bas à gauche, (1, 1) est en haut à droite.
    const float2 positions[4] = {
        float2(-1.0, -1.0), // Triangle 1 : Bas-gauche
        float2(1.0, -1.0),  // Triangle 1 : Bas-droite
        float2(-1.0, 1.0),  // Triangle 2 : Haut-gauche
        float2(1.0, 1.0)    // Triangle 2 : Haut-droite
    };

    // --- Définition des coordonnées de texture (UVs) ---
    // (0, 0) est en haut à gauche, (1, 1) est en bas à droite pour l'image d'origine.
    // L'ordre correspond aux positions : Bas-gauche, Bas-droite, Haut-gauche, Haut-droite.
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    FullscreenOut out;
    out.position = float4(positions[id], 0.0, 1.0);
    
    // --- Application de la matrice de transformation (displayTransform) ---
    // Cette matrice convertit les coordonnées de l'image (en paysage natif)
    // vers les bonnes coordonnées d'affichage (portrait).
    float3 uv = float3(uvs[id], 1.0);
    float2 transformedUV = (uniforms.transform * uv).xy;
    
    // --- Rotation de 180° ---
    // L'image s'affichait à l'envers, on inverse donc horizontalement 
    // et verticalement (1.0 - x, 1.0 - y) ce qui équivaut à une rotation de 180°.
    out.uv = float2(1.0 - transformedUV.x, 1.0 - transformedUV.y);
    return out;
}

// --- FONCTION DE SEGMENTATION (Logique spatiale corrigée) ---
inline float3 applySegmentation(
    float2 portraitUV, // Coordonnée strictement en espace Portrait (YOLO)
    float3 baseColor,
    constant SegUniforms& segUniforms,
    constant YoloDetectionMetal* detections,
    device const void* prototypesRaw
) {
    if (segUniforms.show != 1 || segUniforms.count <= 0) return baseColor;

    for (int d = 0; d < segUniforms.count; d++) {
        YoloDetectionMetal det = detections[d];
        
        // 1. La Bounding Box et l'UV sont maintenant tous les deux en Portrait ! Plus de décalage.
        if (portraitUV.x >= det.minX && portraitUV.x <= det.maxX && portraitUV.y >= det.minY && portraitUV.y <= det.maxY) {
            
            // 2. Projection directe sur la grille 160x160 (Plus besoin de bidouiller les axes)
            int px = clamp(int(portraitUV.x * 160.0), 0, 159);
            int py = clamp(int(portraitUV.y * 160.0), 0, 159);
            
            float maskVal = 0.0;
            for (int c = 0; c < 32; c++) {
                int index = c * segUniforms.strideC + py * segUniforms.strideY + px * segUniforms.strideX;
                
                float protoVal = 0.0;
                if (segUniforms.isFloat16 == 1) {
                    protoVal = float(((device const half*)prototypesRaw)[index]);
                } else {
                    protoVal = ((device const float*)prototypesRaw)[index];
                }
                    
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

// --- MISE À JOUR : RGB FRAGMENT ---
fragment float4 rgbFragment(
    FullscreenOut in [[stage_in]],
    texture2d<float, access::sample> yTex [[texture(0)]],
    texture2d<float, access::sample> cbcrTex [[texture(1)]],
    constant SegUniforms& segUniforms [[buffer(0)]],
    constant YoloDetectionMetal* detections [[buffer(1)]],
    device const void* prototypes [[buffer(2)]] // <-- Pense bien à mettre void* ici aussi si ce n'était pas le cas
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float y = yTex.sample(s, in.uv).r;
    float2 cbcr = cbcrTex.sample(s, in.uv).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402 * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772 * cbcr.x;
    
    float3 finalColor = saturate(rgb);
    
    // MAGIE SPATIALE : in.uv est le capteur brut (Paysage).
    // On le fait pivoter à 90° mathématiquement pour obtenir l'UV YOLO (Portrait).
    float2 portraitUV = float2(1.0 - in.uv.y, in.uv.x);
    
    finalColor = applySegmentation(portraitUV, finalColor, segUniforms, detections, prototypes);

    return float4(finalColor, 1.0);
}

float3 inferno(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c0 = float3(0.001, 0.000, 0.014);
    float3 c1 = float3(0.275, 0.051, 0.364);
    float3 c2 = float3(0.659, 0.212, 0.255);
    float3 c3 = float3(0.988, 0.998, 0.645);

    if (t < 0.33) {
        return mix(c0, c1, t / 0.33);
    }
    if (t < 0.66) {
        return mix(c1, c2, (t - 0.33) / 0.33);
    }
    return mix(c2, c3, (t - 0.66) / 0.34);
}

fragment float4 depthFragment(
    FullscreenOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant DepthUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float depth = depthTex.sample(s, in.uv).r;

    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float normalized = (depth - uniforms.minDepth) / max(uniforms.maxDepth - uniforms.minDepth, 1e-4);
    float3 color = inferno(normalized);
    return float4(color, 1.0);
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
    // On mémorise l'UV paysage natif pour colorer ce point avec sa vraie couleur RGB.
    // Les textures RGB (capturedImage) et depth partagent le même espace UV car
    // elles proviennent du même capteur, même champ de vision, même orientation.
    out.rgbUV = uv;
    out.pointSize = uniforms.pointSize;

    // --- Rejet des points hors-plage ---
    // Les points invalides (NaN, infini, trop proche ou trop loin) sont
    // envoyés hors-écran en NDC (2, 2) → Metal les clippe et ne les dessine pas.
    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) {
        out.position = float4(2.0, 2.0, 1.0, 1.0);
        return out;
    }

    float fx = uniforms.depthIntrinsics.x;
    float fy = uniforms.depthIntrinsics.y;
    float cx = uniforms.depthIntrinsics.z;
    float cy = uniforms.depthIntrinsics.w;

    float px = (float(x) - cx) / fx * depth;
    float py = -(float(y) - cy) / fy * depth;
    float pz = -depth;

    float cosYaw = cos(uniforms.yaw);
    float sinYaw = sin(uniforms.yaw);
    float3 p1 = float3(
        cosYaw * px + sinYaw * pz,
        py,
        -sinYaw * px + cosYaw * pz
    );

    float cosPitch = cos(uniforms.pitch);
    float sinPitch = sin(uniforms.pitch);
    float3 p2 = float3(
        p1.x,
        cosPitch * p1.y - sinPitch * p1.z,
        sinPitch * p1.y + cosPitch * p1.z
    );

    float z = max(-p2.z, 0.05);
    float scale = 1.2;
    float2 ndc = float2(p2.x / (z * scale), p2.y / (z * scale));

    // --- Correction d'orientation : paysage → portrait ---
    // Le capteur LiDAR est nativement paysage (X = droite, Y = haut en paysage).
    // L'iPhone est tenu en portrait → rotation 90° dans le sens CW en espace NDC :
    //   portrait_ndc_x =  landscape_ndc_y   (le haut paysage = la droite portrait)
    //   portrait_ndc_y = -landscape_ndc_x   (la droite paysage = le bas portrait)
    // C'est la même rotation qu'implique le displayTransform dans les modes RGB/Depth.
    out.position = float4(ndc.y, -ndc.x, 0.0, 1.0);
    return out;
}

// --- POINT CLOUD FRAGMENT ---
fragment float4 pointCloudFragment(
    PointOut in [[stage_in]],
    texture2d<float, access::sample> yTex    [[texture(0)]],
    texture2d<float, access::sample> cbcrTex [[texture(1)]],
    constant SegUniforms& segUniforms [[buffer(0)]],
    constant YoloDetectionMetal* detections [[buffer(1)]],
    device const void* prototypes [[buffer(2)]], // <-- Pense bien à mettre void* ici aussi
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

    // CORRECTION DÉFINITIVE : L'UV du Point Cloud n'est pas inversé comme celui de l'écran.
    // La rotation correcte pour s'aligner sur YOLO dans cet espace 3D est :
    float2 portraitUV = float2(in.rgbUV.y, 1.0 - in.rgbUV.x);
    
    finalColor = applySegmentation(portraitUV, finalColor, segUniforms, detections, prototypes);

    return float4(finalColor, 1.0);
}

// --- STRUCTURES POUR L'ACCUMULATION DE NUAGE DE POINTS ---
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

// --- COMPUTE SHADER : DÉPROJECTION ET ACCUMULATION (ZERO-COPY) ---
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

    // Échantillonnage sous-résolution (ex: un pixel sur 2) pour économiser la mémoire et l'affichage
    if (gid.x % 2 != 0 || gid.y % 2 != 0) return;

    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(gid) + 0.5) / float2(uniforms.depthSize);
    float depth = depthTex.sample(s, uv).r;

    // Filtre des points non valides
    if (!isfinite(depth) || depth < uniforms.minDepth || depth > uniforms.maxDepth) return;

    // Déprojection (Intrinsics -> Coordonnées locales Caméra)
    float fx = uniforms.depthIntrinsics.x;
    float fy = uniforms.depthIntrinsics.y;
    float cx = uniforms.depthIntrinsics.z;
    float cy = uniforms.depthIntrinsics.w;

    float px = (float(gid.x) - cx) / fx * depth;
    float py = -(float(gid.y) - cy) / fy * depth;
    float pz = -depth;

    float4 localPos = float4(px, py, pz, 1.0);
    
    // Transformation en coordonnées du monde (ARKit World Space)
    float4 worldPos = uniforms.cameraTransform * localPos;

    // Échantillonnage de la couleur YCbCr vers RGB
    constexpr sampler sColor(address::clamp_to_edge, filter::linear);
    float y = yTex.sample(sColor, uv).r;
    float2 cbcr = cbcrTex.sample(sColor, uv).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402 * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772 * cbcr.x;
    rgb = saturate(rgb);

    // Ajout thread-safe dans le buffer global (Limite stricte : 5 millions de points)
    uint index = atomic_fetch_add_explicit(pointCount, 1, memory_order_relaxed);
    if (index < 5000000) {
        outPoints[index].position = packed_float3(worldPos.xyz);
        outPoints[index].color = packed_float3(rgb);
    }
}

// --- RENDU DU NUAGE DE POINTS ACCUMULÉ (3D MONDE) ---
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