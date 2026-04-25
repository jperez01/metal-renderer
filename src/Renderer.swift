import Metal
import MetalKit
import ModelIO

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    let samplerState: MTLSamplerState
    
    let camera = Camera()
    
    // Support for multiple meshes and their submesh data
    struct MeshData {
        let mtkMesh: MTKMesh
        let textures: [MTLTexture?]
        let colors: [simd_float4]
        let transform: simd_float4x4  // Local transform from USDZ hierarchy
    }
    var renderData: [MeshData] = []
    
    init?(metalView: MTKView) {
        guard let device = metalView.device else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        let mtlVertexDescriptor = MTLVertexDescriptor()
        // Attribute 0: Position (float3)
        mtlVertexDescriptor.attributes[0].format = .float3
        mtlVertexDescriptor.attributes[0].offset = 0
        mtlVertexDescriptor.attributes[0].bufferIndex = 0
        // Attribute 1: Normal (float3)
        mtlVertexDescriptor.attributes[1].format = .float3
        mtlVertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        mtlVertexDescriptor.attributes[1].bufferIndex = 0
        // Attribute 2: TexCoord (float2)
        mtlVertexDescriptor.attributes[2].format = .float2
        mtlVertexDescriptor.attributes[2].offset = MemoryLayout<Float>.size * 6
        mtlVertexDescriptor.attributes[2].bufferIndex = 0
        // Layout: 3 (position) + 3 (normal) + 2 (texCoord) = 8 floats
        mtlVertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 8

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            return nil
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
            return nil
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
        loadModel()
    }

    func loadModel(url: URL? = nil) {
        let allocator = MTKMeshBufferAllocator(device: device)
        let textureLoader = MTKTextureLoader(device: device)
        
        let meshDescriptor = MDLVertexDescriptor()
        // Attribute 0: Position (float3)
        meshDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        // Attribute 1: Normal (float3)
        meshDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
        // Attribute 2: TexCoord (float2)
        meshDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<Float>.size * 6, bufferIndex: 0)
        // Layout: 3 + 3 + 2 = 8 floats
        meshDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 8)
        
        var mdlMeshes: [(mesh: MDLMesh, transform: simd_float4x4)] = []
        
        if let url = url {
            // First load without vertex descriptor to preserve original structure
            let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
            asset.loadTextures()
            
            print("Loading USDZ from: \(url)")
            
            // Recursively find all meshes in the asset and accumulate their transforms
            func collectMeshes(object: MDLObject, parentTransform: simd_float4x4) {
                let localTransform = object.transform?.matrix ?? matrix_identity_float4x4
                let worldTransform = parentTransform * localTransform
                
                if let mesh = object as? MDLMesh {
                    print("Found mesh: \(object.name)")
                    // Apply vertex descriptor to convert mesh format
                    mesh.vertexDescriptor = meshDescriptor
                    mdlMeshes.append((mesh, worldTransform))
                }
                
                for child in object.children.objects {
                    collectMeshes(object: child, parentTransform: worldTransform)
                }
            }
            
            // Start from the root object (index 0), not all child objects
            if asset.count > 0 {
                let rootObject = asset.object(at: 0)
                collectMeshes(object: rootObject, parentTransform: matrix_identity_float4x4)
            }
            
            print("Collected \(mdlMeshes.count) meshes")
        } else {
            let box = MDLMesh.newBox(withDimensions: simd_float3(1, 1, 1), segments: simd_uint3(1, 1, 1), geometryType: .triangles, inwardNormals: false, allocator: allocator)
            box.vertexDescriptor = meshDescriptor
            mdlMeshes.append((box, matrix_identity_float4x4))
        }
        
        var newRenderData: [MeshData] = []
        for (mdlMesh, transform) in mdlMeshes {
            do {
                let mtkMesh = try MTKMesh(mesh: mdlMesh, device: device)
                var textures: [MTLTexture?] = []
                var colors: [simd_float4] = []
                
                guard let submeshes = mdlMesh.submeshes as? [MDLSubmesh] else {
                    continue
                }
                
                for mdlSubmesh in submeshes {
                    var loadedTexture: MTLTexture? = nil
                    var loadedColor: simd_float4 = [1, 1, 1, 1]
                    
                    if let material = mdlSubmesh.material {
                        if let baseColorProperty = material.property(with: .baseColor) {
                            // 1. Try embedded texture sampler
                            if let textureSampler = baseColorProperty.textureSamplerValue,
                               let mdlTexture = textureSampler.texture {
                                loadedTexture = try? textureLoader.newTexture(texture: mdlTexture, options: [.generateMipmaps: true, .SRGB: true])
                            }
                            
                            // 2. Try URL texture if still nil
                            if loadedTexture == nil, let textureUrl = baseColorProperty.urlValue {
                                loadedTexture = try? textureLoader.newTexture(URL: textureUrl, options: [.generateMipmaps: true, .SRGB: true])
                            }
                            
                            // 3. Extract float color
                            if baseColorProperty.type == .float4 {
                                loadedColor = baseColorProperty.float4Value
                            } else if baseColorProperty.type == .float3 {
                                let v3 = baseColorProperty.float3Value
                                loadedColor = [v3.x, v3.y, v3.z, 1.0]
                            }
                        }
                    }
                    textures.append(loadedTexture)
                    colors.append(loadedColor)
                }
                newRenderData.append(MeshData(mtkMesh: mtkMesh, textures: textures, colors: colors, transform: transform))
            } catch {
                print("Failed to create MTKMesh for a model component.")
            }
        }
        self.renderData = newRenderData
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
}
