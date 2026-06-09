import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    @Binding var renderer: Renderer?
    let inputState: InputState

    func makeCoordinator() -> Coordinator {
        Coordinator(inputState: inputState)
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device.")
        }

        let metalView = MTKView()
        metalView.device = device
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.framebufferOnly = false

        do {
            let renderer = try Renderer(metalView: metalView)
            context.coordinator.renderer = renderer
            metalView.delegate = context.coordinator
            DispatchQueue.main.async {
                self.renderer = renderer
            }
        } catch {
            fatalError("Renderer failed to initialize: \(error)")
        }

        return metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.window?.acceptsMouseMovedEvents = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let inputState: InputState
        var renderer: Renderer?

        init(inputState: InputState) {
            self.inputState = inputState
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.mtkView(view, drawableSizeWillChange: size)
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }
            inputState.updateCamera(renderer.camera)
            
            if inputState.useRayTracing {
                renderer.drawRayTraced(in: view)
            } else {
                renderer.draw(in: view)
            }
        }
    }
}
