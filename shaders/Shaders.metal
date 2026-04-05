#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
};

vertex VertexOut vertex_main(Vertex v [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(v.position, 1.0);
    out.color = v.color;
    out.texCoord = v.texCoord;
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
    
    // 2. Use Material Color if provided (not zero alpha)
    if (materialColor.a > 0.0) {
        return materialColor;
    }
    
    // 3. Fallback to Vertex Color
    return in.color;
}
