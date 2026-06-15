import Metal
import MetalKit
import ModelIO

enum RendererError: Error {
    case noDevice
    case noCommandQueue
    case shaderLoadFailed
    case pipelineCreationFailed(Error)
}

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}


struct Light {
    var position: simd_float3
    var color: simd_float3
}

struct RayTracingUniforms {
    var inverseViewProjectionMatrix: simd_float4x4
    var cameraPosition: simd_float4
    var width: UInt32
    var height: UInt32
    var lights: (Light, Light, Light, Light)
}

@Observable
final class SceneLighting {
    var lightPosition: simd_float3 = [0, 5, 0]
    var lightColor: simd_float3 = [1, 1, 1]
}

@MainActor class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    let samplerState: MTLSamplerState
    
    // Lighting State
    let sceneLighting = SceneLighting()
    // Ray Tracing Properties
    private var rayTracePipelineState: MTLComputePipelineState?
    private var instanceAccelerationStructure: MTLAccelerationStructure?
    private var primitiveAccelerationStructures: [MTLAccelerationStructure] = []
    
    let camera = Camera()
    
    // Support for multiple meshes and their submesh data
    struct MeshData: @unchecked Sendable {
        let mtkMesh: MTKMesh
        let textures: [MTLTexture?]
        let colors: [simd_float4]
        let transform: simd_float4x4  // Local transform from USDZ hierarchy
    }
    var renderData: [MeshData] = []
    

    init(metalView: MTKView) throws {
        guard let device = metalView.device else { throw RendererError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        self.commandQueue = queue

        let mtlVertexDescriptor = MTLVertexDescriptor.standard

        // Xcode compiles .metal → .metallib; SPM copies raw .metal source.
        let library: MTLLibrary
        if let compiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = compiled
        } else if let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
                  let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) {
            // Concatenate all .metal sources — SPM copies raw source, doesn't compile to .metallib
            let rayURL = Bundle.module.url(forResource: "RayTracing", withExtension: "metal")
            let raySource = rayURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            library = try device.makeLibrary(source: shaderSource + "\n" + raySource, options: nil)
        } else {
            throw RendererError.shaderLoadFailed
        }
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            throw RendererError.shaderLoadFailed
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalView.depthStencilPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw RendererError.pipelineCreationFailed(error)
        }
        
        if let rayTraceFunction = library.makeFunction(name: "raytrace_kernel") {
            rayTracePipelineState = try? device.makeComputePipelineState(function: rayTraceFunction)
        }
        
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.normalizedCoordinates = true
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        self.samplerState = device.makeSamplerState(descriptor: samplerDescriptor)!

        super.init()
        Task { await loadModel()}
    }

    func loadModel(url: URL? = nil) async {
        let device = self.device

        let newRenderData = await Task.detached { () -> [MeshData] in
            let mdlMeshes = self.loadMDLMeshes(url: url, device: device)

            let textureLoader = MTKTextureLoader(device: device)
            return self.processMeshResources(device: device, textureLoader: textureLoader, mdlMeshes: mdlMeshes)
        }.value

        // 3. Update the UI / rendering state
        self.renderData = newRenderData
        self.buildAccelerationStructures()
    }
    
    nonisolated private func loadMDLMeshes(url: URL?, device: MTLDevice) -> [(mesh: MDLMesh, transform: simd_float4x4)] {
        let allocator = MTKMeshBufferAllocator(device: device)
        let meshDescriptor = MDLVertexDescriptor.standard
        
        var mdlMeshes: [(mesh: MDLMesh, transform: simd_float4x4)] = []
        
        if let url = url {
            let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
            asset.loadTextures()
            
            print("Loading USDZ from: \(url)")
            
            func collectMeshes(object: MDLObject, parentTransform: simd_float4x4) {
                let localTransform = object.transform?.matrix ?? matrix_identity_float4x4
                let worldTransform = parentTransform * localTransform
                
                if let mesh = object as? MDLMesh {
                    print("Found mesh: \(object.name)")
                    mesh.vertexDescriptor = meshDescriptor
                    mdlMeshes.append((mesh, worldTransform))
                }
                
                for child in object.children.objects {
                    collectMeshes(object: child, parentTransform: worldTransform)
                }
            }
            
            if asset.count > 0 {
                let bbox = asset.boundingBox
                let extents = bbox.maxBounds - bbox.minBounds
                let center = (bbox.maxBounds + bbox.minBounds) / 2.0
                let maxExtent = max(extents.x, max(extents.y, extents.z))
                let scale = maxExtent > 0 ? (2.0 / maxExtent) : 1.0
                
                var translationMatrix = matrix_identity_float4x4
                translationMatrix.columns.3 = [-center.x, -center.y, -center.z, 1.0]
                
                var scaleMatrix = matrix_identity_float4x4
                scaleMatrix.columns.0.x = scale
                scaleMatrix.columns.1.y = scale
                scaleMatrix.columns.2.z = scale
                
                let normalizationTransform = scaleMatrix * translationMatrix
                collectMeshes(object: asset.object(at: 0), parentTransform: normalizationTransform)
            }
            print("Collected \(mdlMeshes.count) meshes")
        } else {
            let box = MDLMesh.newBox(withDimensions: simd_float3(1, 1, 1), segments: simd_uint3(1, 1, 1), geometryType: .triangles, inwardNormals: false, allocator: allocator)
            box.vertexDescriptor = meshDescriptor
            mdlMeshes.append((box, matrix_identity_float4x4))
        }
        
        return mdlMeshes
    }
    
    nonisolated func processMeshResources(device: MTLDevice, textureLoader: MTKTextureLoader, mdlMeshes: [(mesh: MDLMesh, transform: simd_float4x4)]) -> [MeshData] {
        var processedData: [MeshData] = []
        for (mdlMesh, transform) in mdlMeshes {
            do {
                let mtkMesh = try MTKMesh(mesh: mdlMesh, device: device)
                var textures: [MTLTexture?] = []
                var colors: [simd_float4] = []
                
                guard let submeshes = mdlMesh.submeshes as? [MDLSubmesh] else { continue }
                
                for mdlSubmesh in submeshes {
                    var loadedTexture: MTLTexture? = nil
                    var loadedColor: simd_float4 = [1, 1, 1, 1]
                    
                    if let material = mdlSubmesh.material, let baseColorProperty = material.property(with: .baseColor) {
                        if let textureSampler = baseColorProperty.textureSamplerValue,
                           let mdlTexture = textureSampler.texture {
                            loadedTexture = try? textureLoader.newTexture(texture: mdlTexture, options: [.generateMipmaps: true, .SRGB: true])
                        }
                        if loadedTexture == nil, let textureUrl = baseColorProperty.urlValue {
                            loadedTexture = try? textureLoader.newTexture(URL: textureUrl, options: [.generateMipmaps: true, .SRGB: true])
                        }
                        if baseColorProperty.type == .float4 {
                            loadedColor = baseColorProperty.float4Value
                        } else if baseColorProperty.type == .float3 {
                            let v3 = baseColorProperty.float3Value
                            loadedColor = [v3.x, v3.y, v3.z, 1.0]
                        }
                    }
                    textures.append(loadedTexture)
                    colors.append(loadedColor)
                }
                processedData.append(MeshData(mtkMesh: mtkMesh, textures: textures, colors: colors, transform: transform))
            } catch {
                print("Failed to create MTKMesh for a model component.")
            }
        }
        return processedData
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let projectionMatrix = simd_float4x4.perspective(fovy: Float.pi / 3, aspect: aspect, near: 0.1, far: 100)
        let viewMatrix = camera.viewMatrix()

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)
        renderEncoder.setFragmentSamplerState(samplerState, index: 0)
        
        for data in renderData {
            // Apply mesh-specific transform
            let modelMatrix = data.transform
            var uniforms = Uniforms(modelViewProjectionMatrix: projectionMatrix * viewMatrix * modelMatrix)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            
            renderEncoder.setVertexBuffer(data.mtkMesh.vertexBuffers[0].buffer, offset: 0, index: 0)
            
            for (idx, submesh) in data.mtkMesh.submeshes.enumerated() {
                // Bind Texture
                if idx < data.textures.count, let texture = data.textures[idx] {
                    renderEncoder.setFragmentTexture(texture, index: 0)
                } else {
                    renderEncoder.setFragmentTexture(nil, index: 0)
                }
                
                // Bind Material Color
                var color = idx < data.colors.count ? data.colors[idx] : [1, 1, 1, 1]
                renderEncoder.setFragmentBytes(&color, length: MemoryLayout<simd_float4>.size, index: 0)
                
                renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer, indexBufferOffset: submesh.indexBuffer.offset)
            }
        }
        
        renderEncoder.endEncoding()
        if let drawable = view.currentDrawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }
    
    func buildAccelerationStructures() {
        guard !renderData.isEmpty else { return }
        
        var primStructures: [MTLAccelerationStructure] = []
        for data in renderData {
            let mesh = data.mtkMesh
            let vertexBuffer = mesh.vertexBuffers[0]
            
            var geometries: [MTLAccelerationStructureTriangleGeometryDescriptor] = []
            
            for submesh in mesh.submeshes {
                let geomDescriptor = MTLAccelerationStructureTriangleGeometryDescriptor()
                geomDescriptor.vertexBuffer = vertexBuffer.buffer
                geomDescriptor.vertexBufferOffset = vertexBuffer.offset
                geomDescriptor.vertexStride = MemoryLayout<Float>.size * 8
                geomDescriptor.vertexFormat = .float3
                
                geomDescriptor.indexBuffer = submesh.indexBuffer.buffer
                geomDescriptor.indexBufferOffset = submesh.indexBuffer.offset
                geomDescriptor.indexType = submesh.indexType == .uint16 ? .uint16 : .uint32
                geomDescriptor.triangleCount = submesh.indexCount / 3
                
                geometries.append(geomDescriptor)
            }
            
            let primDesc = MTLPrimitiveAccelerationStructureDescriptor()
            primDesc.geometryDescriptors = geometries
            
            let sizes = device.accelerationStructureSizes(descriptor: primDesc)
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate) else { continue }
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else { continue }
            
            encoder.build(accelerationStructure: accel, descriptor: primDesc, scratchBuffer: scratch, scratchBufferOffset: 0)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            primStructures.append(accel)
        }
        
        let instanceCount = primStructures.count
        let stride = MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride
        
        guard let instanceBuffer = device.makeBuffer(length: instanceCount * stride, options: .storageModeShared) else { return }
        var instances = [MTLAccelerationStructureInstanceDescriptor](
            repeating: MTLAccelerationStructureInstanceDescriptor(), count: instanceCount
        )
        
        for i in 0..<instanceCount {
            instances[i].accelerationStructureIndex = UInt32(i)
            instances[i].mask = 0xFF
            instances[i].intersectionFunctionTableOffset = 0
            instances[i].options = .opaque
            
            let m = renderData[i].transform
            instances[i].transformationMatrix = MTLPackedFloat4x3(columns: (
               MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z),
               MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z),
               MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z),
               MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)
           ))
        }

        instances.withUnsafeBufferPointer { ptr in
            instanceBuffer.contents().copyMemory(
                from: ptr.baseAddress!,
                byteCount: instanceCount * stride
            )
        }

        let instDesc = MTLInstanceAccelerationStructureDescriptor()
        instDesc.instancedAccelerationStructures = primStructures
        instDesc.instanceCount = instanceCount
        instDesc.instanceDescriptorBuffer = instanceBuffer

        let instSizes = device.accelerationStructureSizes(descriptor: instDesc)

        guard let accel = device.makeAccelerationStructure(size: instSizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: instSizes.buildScratchBufferSize,
                                              options: .storageModePrivate) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeAccelerationStructureCommandEncoder() else { return }

        enc.build(accelerationStructure: accel,
                  descriptor: instDesc,
                  scratchBuffer: scratch,
                  scratchBufferOffset: 0)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        self.primitiveAccelerationStructures = primStructures
        self.instanceAccelerationStructure = accel
    }
    
    func drawRayTraced(in view: MTKView) {
        guard let pipeline = rayTracePipelineState,
              let accelerationStructure = instanceAccelerationStructure,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        let texture = drawable.texture
        let width = texture.width
        let height = texture.height
        
        let aspect = Float(width) / Float(height)
        let projection = simd_float4x4.perspective(fovy: Float.pi / 3, aspect: aspect, near: 0.1, far: 100.0)
        let view = camera.viewMatrix()
        let vp = projection * view
        

        let light = Light(position: sceneLighting.lightPosition, color: sceneLighting.lightColor)
        let defaultLight = Light(position: [0,0,0], color: [0,0,0])
        var uniforms = RayTracingUniforms(
            inverseViewProjectionMatrix: simd_inverse(vp), 
            cameraPosition: simd_float4(camera.position, 0), 
            width: UInt32(width), 
            height: UInt32(height),
            lights: (light, defaultLight, defaultLight, defaultLight)
        )
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<RayTracingUniforms>.stride, index: 0)
        encoder.setAccelerationStructure(accelerationStructure, bufferIndex: 1)
        encoder.setTexture(texture, index: 0)
        
        for primitiveAccelerationStructure in primitiveAccelerationStructures {
            encoder.useResource(primitiveAccelerationStructure, usage: .read)
        }
        for data in renderData {
            encoder.useResource(data.mtkMesh.vertexBuffers[0].buffer, usage: .read)
            for submesh in data.mtkMesh.submeshes {
                encoder.useResource(submesh.indexBuffer.buffer, usage: .read)
            }
        }
        
        let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let treadgroups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(treadgroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension MTLVertexDescriptor {
    static var standard: MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        // Attribute 0: Position (float3)
        d.attributes[0].format = .float3
        d.attributes[0].offset = 0
        d.attributes[0].bufferIndex = 0
        // Attribute 1: Normal (float3)
        d.attributes[1].format = .float3
        d.attributes[1].offset = MemoryLayout<Float>.size * 3
        d.attributes[1].bufferIndex = 0
        // Attribute 2: TexCoord (float2)
        d.attributes[2].format = .float2
        d.attributes[2].offset = MemoryLayout<Float>.size * 6
        d.attributes[2].bufferIndex = 0
        // Layout: 3 (position) + 3 (normal) + 2 (texCoord) = 8 floats
        d.layouts[0].stride = MemoryLayout<Float>.size * 8
        return d
    }
}

extension MDLVertexDescriptor {
    static var standard: MDLVertexDescriptor {
        let d = MDLVertexDescriptor()
        // Attribute 0: Position (float3)
        d.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        // Attribute 1: Normal (float3)
        d.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
        // Attribute 2: TexCoord (float2)
        d.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<Float>.size * 6, bufferIndex: 0)
        // Layout: 3 + 3 + 2 = 8 floats
        d.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 8)
        return d
    }
}
