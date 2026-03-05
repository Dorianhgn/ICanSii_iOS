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

fragment float4 rgbFragment(
    FullscreenOut in [[stage_in]],
    texture2d<float, access::sample> yTex [[texture(0)]],
    texture2d<float, access::sample> cbcrTex [[texture(1)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float y = yTex.sample(s, in.uv).r;
    float2 cbcr = cbcrTex.sample(s, in.uv).rg - float2(0.5, 0.5);

    float3 rgb;
    rgb.r = y + 1.402 * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772 * cbcr.x;

    return float4(saturate(rgb), 1.0);
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

fragment float4 pointCloudFragment(
    PointOut in [[stage_in]],
    // Plan Y  : luminance (niveau de gris), pleine résolution, 1 canal (r8)
    texture2d<float, access::sample> yTex    [[texture(0)]],
    // Plan CbCr : chrominance (couleur), demi-résolution, 2 canaux (rg8)
    texture2d<float, access::sample> cbcrTex [[texture(1)]],
    float2 coord [[point_coord]]
) {
    // --- Forme circulaire des points ---
    // Par défaut, Metal dessine les points comme des carrés (quads).
    // `point_coord` va de (0,0) à (1,1) sur ce carré.
    // On rejette les fragments hors du cercle inscrit (rayon = 0.5) → disques propres.
    float2 delta = coord - 0.5;
    if (dot(delta, delta) > 0.25) {
        discard_fragment();
    }

    // --- Échantillonnage de la couleur réelle du point ---
    // L'image ARKit est en YCbCr bi-plan (format NV12/420v) :
    //   Y    = luminance seule (noir/blanc)
    //   CbCr = deux composantes de chrominance (couleur) à demi-résolution
    // On soustrait 0.5 à CbCr pour centrer les valeurs autour de zéro (espace signé).
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float  y    = yTex.sample(s, in.rgbUV).r;
    float2 cbcr = cbcrTex.sample(s, in.rgbUV).rg - float2(0.5, 0.5);

    // --- Conversion YCbCr → RGB (norme BT.601, coefficients standards iOS/ARKit) ---
    float3 rgb;
    rgb.r = y + 1.402    * cbcr.y;
    rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
    rgb.b = y + 1.772    * cbcr.x;

    // `saturate` = clamp(x, 0, 1) : évite les valeurs hors-gamut.
    return float4(saturate(rgb), 1.0);
}
