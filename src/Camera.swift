import simd

class Camera {
    var position: simd_float3 = [0, 0, 5]
    var yaw: Float = -Float.pi / 2 // Pointing towards negative Z
    var pitch: Float = 0
    
    var forward: simd_float3 {
        return normalize(simd_float3(
            cos(yaw) * cos(pitch),
            sin(pitch),
            sin(yaw) * cos(pitch)
        ))
    }
    
    var right: simd_float3 {
        return normalize(cross(forward, [0, 1, 0]))
    }
    
    func viewMatrix() -> simd_float4x4 {
        return .lookAt(eye: position, center: position + forward, up: [0, 1, 0])
    }
}
