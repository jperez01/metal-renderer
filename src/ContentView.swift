import SwiftUI
import simd
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var renderer: Renderer? = nil
    @State private var inputState = InputState()
    @State private var isFileImporterPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalView(renderer: $renderer, inputState: inputState)
                .ignoresSafeArea()

            overlay
                .padding(20)
        }
        .onAppear {
            inputState.install()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                .usdz,
                UTType(filenameExtension: "obj")!,
            ]
        ) { result in
            if case .success(let url) = result {
                Task { await renderer?.loadModel(url: url)}
            }
        }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            cameraInfoView
            Button("Open Model...") {
                isFileImporterPresented = true
            }

            if inputState.useRayTracing {
                lightingControls
            }
        }
        .padding(10)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 300)
    }
    
    private var cameraInfoView: some View {
        let cam = renderer?.camera
        let pos = cam?.position ?? simd_float3(0, 0, 0)
        let yaw = cam?.yaw ?? 0
        let pitch = cam?.pitch ?? 0
        let status = inputState.isCameraLocked ? "LOCKED" : "ACTIVE"

        return Text("""
        CAMERA [\(status)]
        Pos: (\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)), \(String(format: "%.2f", pos.z)))
        Yaw: \(String(format: "%.2f", yaw))
        Pitch: \(String(format: "%.2f", pitch))
        Mode: \(inputState.useRayTracing ? "RAY_TRACED" : "RASTERIZED")

        [C] Toggle Lock
        [WASD] Move Camera
        [R] Toggle Ray Tracing
        Move mouse to rotate.
        """)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var lightingControls: some View {
        if let sceneLighting = renderer?.sceneLighting {
            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("LIGHTING").bold()
                
                HStack {
                    Text("X:").frame(width: 20, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(sceneLighting.lightPosition.x) },
                        set: { sceneLighting.lightPosition.x = Float($0) }
                    ), in: -20...20)
                    Text(String(format: "%.1f", sceneLighting.lightPosition.x)).frame(width: 40, alignment: .trailing)
                }
                
                HStack {
                    Text("Y:").frame(width: 20, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(sceneLighting.lightPosition.y) },
                        set: { sceneLighting.lightPosition.y = Float($0) }
                    ), in: -20...20)
                    Text(String(format: "%.1f", sceneLighting.lightPosition.y)).frame(width: 40, alignment: .trailing)
                }
                
                HStack {
                    Text("Z:").frame(width: 20, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(sceneLighting.lightPosition.z) },
                        set: { sceneLighting.lightPosition.z = Float($0) }
                    ), in: -20...20)
                    Text(String(format: "%.1f", sceneLighting.lightPosition.z)).frame(width: 40, alignment: .trailing)
                }
                
                ColorPicker("Color", selection: Binding(
                    get: {
                        Color(red: Double(sceneLighting.lightColor.x),
                              green: Double(sceneLighting.lightColor.y),
                              blue: Double(sceneLighting.lightColor.z))
                    },
                    set: { newColor in
                        if let nsColor = NSColor(newColor).usingColorSpace(.deviceRGB) {
                            sceneLighting.lightColor = simd_float3(Float(nsColor.redComponent), Float(nsColor.greenComponent), Float(nsColor.blueComponent))
                        }
                    }
                ))
            }
            .foregroundStyle(.white)
            .font(.system(.body, design: .monospaced))
        }
    }
}
