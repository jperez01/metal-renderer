#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float2 texCoord;
};

vertex VertexOut vertex_main(Vertex v [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(v.position, 1.0);
    out.normal = v.normal;
    // Flip V coordinate: USDZ uses bottom-left origin, Metal uses top-left
    out.texCoord = float2(v.texCoord.x, 1.0 - v.texCoord.y);
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                             constant float4 &materialColor [[buffer(0)]],
                             texture2d<float> baseColorTexture [[texture(0)]],
                             sampler textureSampler [[sampler(0)]]) {
    // 1. Use Texture if available
    if (!is_null_texture(baseColorTexture)) {
        return baseColorTexture.sample(textureSampler, in.texCoord);
    }
    
    // 2. Use Material Color if provided (not white/default)
    if (materialColor.a > 0.0 && any(materialColor.rgb != float3(1.0))) {
        return materialColor;
    }
    
    // 3. Fallback to simple shading with normal
    float3 lightDir = normalize(float3(0.5, 0.5, 1.0));
    float diffuse = max(dot(normalize(in.normal), lightDir), 0.3); // ambient + diffuse
    return float4(float3(0.8, 0.8, 0.8) * diffuse, 1.0);
}
