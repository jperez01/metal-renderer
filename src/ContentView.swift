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
        }
        .padding(10)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
