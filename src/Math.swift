import simd

extension simd_float4x4 {
    static func identity() -> simd_float4x4 {
        return matrix_identity_float4x4
    }
    
    static func rotation(radians: Float, axis: simd_float3) -> simd_float4x4 {
        let unitAxis = normalize(axis)
        let ct = cosf(radians)
        let st = sinf(radians)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        
        return simd_float4x4(columns: (
            simd_float4(ct + x * x * ci,     y * x * ci + z * st, z * x * ci - y * st, 0),
            simd_float4(x * y * ci - z * st, ct + y * y * ci,     z * y * ci + x * st, 0),
            simd_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci,     0),
            simd_float4(0,                   0,                   0,                   1)
        ))
    }
    
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        
        return simd_float4x4(columns: (
            simd_float4(xs,  0,  0,  0),
            simd_float4( 0, ys,  0,  0),
            simd_float4( 0,  0, zs, -1),
            simd_float4( 0,  0, near * zs, 0)
        ))
    }
    
    static func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        
        return simd_float4x4(columns: (
            simd_float4(x.x, y.x, z.x, 0),
            simd_float4(x.y, y.y, z.y, 0),
            simd_float4(x.z, y.z, z.z, 0),
            simd_float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }
}
