//
//  RayTracing.metal
//  swift-metal-renderer
//
//  Created by Juan Pablo Perez Martinez on 6/3/26.
//

#include <metal_raytracing>
#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

struct Light {
    float3 position;
    float3 color;
};

struct RayTraceUniforms {
    float4x4 inverseViewProjection;
    float4 cameraPosition;
    uint width;
    uint height;
    Light lights[4];
};

kernel void raytrace_kernel(
                            uint2 tid [[thread_position_in_grid]],
                            constant RayTraceUniforms &uniforms [[buffer(0)]],
                            instance_acceleration_structure scene [[buffer(1)]],
                            texture2d<float, access::write> output [[texture(0)]]
                            ) {
    if (tid.x >= uniforms.width || tid.y >= uniforms.height) return;
    
    float2 uv = (float2(tid) + 0.5) / float2(uniforms.width, uniforms.height);
    uv = uv * 2.0 - 1.0;
    uv.y = -uv.y;
    
    float4 worldSpaceCoords = uniforms.inverseViewProjection * float4(uv, 0.0, 1.0);
    worldSpaceCoords /= worldSpaceCoords.w;
    
    ray r;
    r.origin = uniforms.cameraPosition.xyz;
    r.direction = normalize(worldSpaceCoords.xyz - r.origin);
    r.min_distance = 0.001;
    r.max_distance = 100.0;
    
    intersector<instancing, triangle_data> inter;
    inter.assume_geometry_type(geometry_type::triangle);
    auto hit = inter.intersect(r, scene);
    
    float4 color;

    auto light = uniforms.lights[0];
    ray shadowRay;
    shadowRay.origin = r.origin + r.direction * hit.distance; // Offset to avoid self-intersection
    shadowRay.direction = normalize(light.position - shadowRay.origin);
    shadowRay.min_distance = 0.001;
    shadowRay.max_distance = length(light.position - shadowRay.origin);
    auto shadowHit = inter.intersect(shadowRay, scene);

    if (shadowHit.type == intersection_type::triangle) {
        color = float4(0.05, 0.05, 0.05, 1.0); // In shadow
    } else {
        if (hit.type == intersection_type::triangle) {
            float t = hit.distance;
            float shade = 1.0 / (1.0 + t * 0.3);
            color = float4(shade, shade, shade, 1.0);
        } else {
            color = float4(0.1, 0.1, 0.1, 1.0);
        }
    }
    
    output.write(color, tid);
}
