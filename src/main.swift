import AppKit
import MetalKit
import simd
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    var infoLabel: NSTextField!
    
    var isCameraLocked: Bool = true
    var lastMousePosition: NSPoint?
    var pressedKeys = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowSize = NSMakeRect(0, 0, 1024, 768)
        window = NSWindow(
            contentRect: windowSize,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Swift Metal Renderer"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device.")
        }
        
        let metalView = MTKView(frame: windowSize, device: device)
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        metalView.depthStencilPixelFormat = .depth32Float
        window.contentView = metalView

        guard let renderer = Renderer(metalView: metalView) else {
            fatalError("Renderer failed to initialize.")
        }
        self.renderer = renderer
        metalView.delegate = self
        
        setupUI()
        setupInput()
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func setupUI() {
        let containerWidth: CGFloat = 280
        let containerHeight: CGFloat = 180
        let windowHeight: CGFloat = 768
        
        // Position at top-left: window height - container height - margin (20)
        let container = NSView(frame: NSRect(x: 20, y: windowHeight - containerHeight - 20, width: containerWidth, height: containerHeight))
        
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.layer?.cornerRadius = 8
        
        // Pins the box to the top-left corner during window resizing
        container.autoresizingMask = [.maxXMargin, .minYMargin]
        
        window.contentView?.addSubview(container)
        
        infoLabel = NSTextField(labelWithString: "Camera Info")
        infoLabel.frame = NSRect(x: 10, y: 50, width: 260, height: 120)
        infoLabel.textColor = .white
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        container.addSubview(infoLabel)
        
        let loadButton = NSButton(title: "Open Model...", target: self, action: #selector(openModelPicker))
        loadButton.frame = NSRect(x: 10, y: 10, width: 260, height: 30)
        container.addSubview(loadButton)
    }
    
    @objc func openModelPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "obj")!, .init(filenameExtension: "usdz")!]
        
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.renderer.loadModel(url: url)
            }
        }
    }
    
    func setupInput() {
        // Mouse Rotation
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return event }
            let currentMousePosition = event.locationInWindow
            
            if !self.isCameraLocked {
                if let lastPos = self.lastMousePosition {
                    let deltaX = Float(currentMousePosition.x - lastPos.x)
                    let deltaY = Float(currentMousePosition.y - lastPos.y)
                    let sensitivity: Float = 0.005
                    self.renderer.camera.yaw += deltaX * sensitivity
                    self.renderer.camera.pitch += deltaY * sensitivity
                    let limit = Float.pi / 2 - 0.1
                    if self.renderer.camera.pitch > limit { self.renderer.camera.pitch = limit }
                    if self.renderer.camera.pitch < -limit { self.renderer.camera.pitch = -limit }
                }
            }
            
            self.lastMousePosition = currentMousePosition
            return event
        }
        
        // Keyboard Tracking
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if ["w", "a", "s", "d", "c"].contains(chars) {
                    if chars == "c" {
                        self.isCameraLocked.toggle()
                    } else {
                        self.pressedKeys.insert(chars)
                    }
                    return nil // Consume the event to prevent the system beep
                }
            }
            return event
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if ["w", "a", "s", "d"].contains(chars) {
                    self.pressedKeys.remove(chars)
                    return nil // Consume the event
                }
            }
            return event
        }
    }

    func updateCameraPosition() {
        let speed: Float = 0.05
        var moveDirection = simd_float3(0, 0, 0)
        let cam = renderer.camera
        
        if pressedKeys.contains("w") { moveDirection += cam.forward }
        if pressedKeys.contains("s") { moveDirection -= cam.forward }
        if pressedKeys.contains("a") { moveDirection -= cam.right }
        if pressedKeys.contains("d") { moveDirection += cam.right }
        
        if length(moveDirection) > 0 {
            cam.position += normalize(moveDirection) * speed
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.mtkView(view, drawableSizeWillChange: size)
    }
    
    func draw(in view: MTKView) {
        updateCameraPosition()
        renderer.draw(in: view)
        
        let cam = renderer.camera
        let pos = cam.position
        let status = isCameraLocked ? "LOCKED" : "ACTIVE"
        infoLabel.stringValue = """
        CAMERA [\(status)]
        Pos: (\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)), \(String(format: "%.2f", pos.z)))
        Yaw: \(String(format: "%.2f", cam.yaw))
        Pitch: \(String(format: "%.2f", cam.pitch))
        
        [C] Toggle Lock
        [WASD] Move Camera
        Move mouse to rotate.
        """
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
