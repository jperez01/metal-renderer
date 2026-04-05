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
    }
    var renderData: [MeshData] = []
    
    init?(metalView: MTKView) {
        guard let device = metalView.device else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        let mtlVertexDescriptor = MTLVertexDescriptor()
        mtlVertexDescriptor.attributes[0].format = .float3
        mtlVertexDescriptor.attributes[0].offset = 0
        mtlVertexDescriptor.attributes[0].bufferIndex = 0
        mtlVertexDescriptor.attributes[1].format = .float4
        mtlVertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        mtlVertexDescriptor.attributes[1].bufferIndex = 0
        mtlVertexDescriptor.attributes[2].format = .float2
        mtlVertexDescriptor.attributes[2].offset = MemoryLayout<Float>.size * 7
        mtlVertexDescriptor.attributes[2].bufferIndex = 0
        mtlVertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 9

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
        self.samplerState = device.makeSamplerState(descriptor: samplerDescriptor)!

        super.init()
        loadModel()
    }

    func loadModel(url: URL? = nil) {
        let allocator = MTKMeshBufferAllocator(device: device)
        let textureLoader = MTKTextureLoader(device: device)
        
        let meshDescriptor = MDLVertexDescriptor()
        meshDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        meshDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float4, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
        meshDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<Float>.size * 7, bufferIndex: 0)
        meshDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 9)
        
        var mdlMeshes: [MDLMesh] = []
        
        if let url = url {
            let asset = MDLAsset(url: url, vertexDescriptor: meshDescriptor, bufferAllocator: allocator)
            // Recursively find all meshes in the asset
            func collectMeshes(object: MDLObject) {
                if let mesh = object as? MDLMesh {
                    mdlMeshes.append(mesh)
                }
                for child in object.children.objects {
                    collectMeshes(object: child)
                }
            }
            for object in asset.childObjects(of: MDLObject.self) {
                collectMeshes(object: object)
            }
        } else {
            let box = MDLMesh.newBox(withDimensions: simd_float3(1, 1, 1), segments: simd_uint3(1, 1, 1), geometryType: .triangles, inwardNormals: false, allocator: allocator)
            box.vertexDescriptor = meshDescriptor
            mdlMeshes.append(box)
        }
        
        var newRenderData: [MeshData] = []
        for mdlMesh in mdlMeshes {
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
                newRenderData.append(MeshData(mtkMesh: mtkMesh, textures: textures, colors: colors))
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
        let modelMatrix = simd_float4x4.identity()
        var uniforms = Uniforms(modelViewProjectionMatrix: projectionMatrix * viewMatrix * modelMatrix)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)
        renderEncoder.setFragmentSamplerState(samplerState, index: 0)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        
        for data in renderData {
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
