@preconcurrency import AppKit
import Observation
import simd

@Observable
final class InputState {
    var pressedKeys: Set<String> = []
    var isCameraLocked: Bool = true
    var lastMousePosition: NSPoint? = nil

    // Accumulated mouse deltas between updateCamera calls
    var mouseDeltaX: Float = 0
    var mouseDeltaY: Float = 0

    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var keyUpMonitor: Any?

    func install() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            guard let self else { return event }
            let currentMousePosition = event.locationInWindow

            if !self.isCameraLocked {
                if let lastPos = self.lastMousePosition {
                    let deltaX = Float(currentMousePosition.x - lastPos.x)
                    let deltaY = Float(currentMousePosition.y - lastPos.y)
                    self.mouseDeltaX += deltaX
                    self.mouseDeltaY += deltaY
                }
            }

            self.lastMousePosition = currentMousePosition
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if ["w", "a", "s", "d", "c"].contains(chars) {
                    if chars == "c" {
                        self.isCameraLocked.toggle()
                    } else {
                        self.pressedKeys.insert(chars)
                    }
                    return nil
                }
            }
            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) {
            [weak self] event in
            guard let self else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if ["w", "a", "s", "d"].contains(chars) {
                    self.pressedKeys.remove(chars)
                    return nil
                }
            }
            return event
        }
    }

    func updateCamera(_ camera: Camera) {
        // Apply mouse rotation
        let sensitivity: Float = 0.005
        camera.yaw += mouseDeltaX * sensitivity
        camera.pitch += mouseDeltaY * sensitivity
        let limit = Float.pi / 2 - 0.1
        if camera.pitch > limit { camera.pitch = limit }
        if camera.pitch < -limit { camera.pitch = -limit }
        mouseDeltaX = 0
        mouseDeltaY = 0

        // Apply WASD movement
        let speed: Float = 0.05
        var moveDirection = simd_float3(0, 0, 0)

        if pressedKeys.contains("w") { moveDirection += camera.forward }
        if pressedKeys.contains("s") { moveDirection -= camera.forward }
        if pressedKeys.contains("a") { moveDirection -= camera.right }
        if pressedKeys.contains("d") { moveDirection += camera.right }

        if length(moveDirection) > 0 {
            camera.position += normalize(moveDirection) * speed
        }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }
}
