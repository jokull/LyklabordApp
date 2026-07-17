//
//  KeycapHeroView.swift
//  BetterKeyboard
//
//  The native interactive 3D hero for the "Byrjun" home screen: the Wave-6
//  AEK II Ð keycap (our brand mark) rendered in SceneKit and spun on its
//  Y axis by a horizontal drag — a turntable the user can flick.
//
//  Model pipeline (reproducible, run once, output committed as a brand asset):
//    Lyklabord-Keycap-Wave6.blend
//      -> Blender (Cycles) bakes the procedural platinum-PBT micrograin
//         material to albedo/roughness/normal PNGs (the legend stays REAL
//         geometry — resolution-independent, crisp)
//      -> exported to App/Resources/Keycap.usdz (~1.1 MB, textures packed)
//    See the wave-38 export script (mirrors site/scripts/export-keycap.py,
//    the web GLB path) for the exact bake + USD export.
//
//  Look: a warm studio image-based-light environment (warm top highlight,
//  cool underside) drives the satin PBT response; one crisp directional key
//  light lands a highlight on the charcoal Ð legend. The keycap floats over a
//  transparent SCNView so the app's system background shows through — the
//  "suspended in mid-air" contact shadow is drawn in SwiftUI beneath it
//  (see ContentView.hero), which keeps it theme-aware and reliable.
//
//  Battery: the SCNView is idle (rendersContinuously = false) at rest and only
//  runs the render loop while the finger is down or the flick is coasting.
//  Off-screen / backgrounded -> paused. Reduce Motion -> no inertial coast
//  (drag still works, and the resting angle is a composed 3/4 product shot).
//

import SwiftUI
import SceneKit

/// SwiftUI wrapper around an `SCNView` that shows the keycap and maps a
/// horizontal drag to Y-axis rotation. Reports load failure so the caller can
/// fall back to the flat `KeycapHero` image.
struct KeycapHeroView: UIViewRepresentable {
    /// Reduce Motion suppresses the post-flick inertial coast (the drag itself
    /// is always allowed; the resting frame is already a beautiful static angle).
    var reduceMotion: Bool
    /// Pause the render loop entirely when the scene is not active (backgrounded).
    var isActive: Bool
    /// Set to `true` when the model can't load / SceneKit can't build the scene.
    @Binding var loadFailed: Bool

    // Composed 3/4 product framing — the resting "beautiful angle".
    private static let camAzimuth: Float = -0.24   // ~ -14°, leads with the lower-left Ð
    private static let camElevation: Float = 0.52   // ~ 30° above the horizon
    private static let restYaw: Float = 0.17        // slight turn so the cap reads as 3D at rest

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = SCNScene() // placeholder; replaced below on success
        view.antialiasingMode = .multisampling4X
        view.isJitteringEnabled = true
        view.rendersContinuously = false // idle at rest — only spins while interacting
        view.preferredFramesPerSecond = 60
        view.isOpaque = false
        view.isAccessibilityElement = false // the SwiftUI container carries the a11y label

        guard let scene = Self.buildScene() else {
            DispatchQueue.main.async { loadFailed = true }
            return view
        }
        view.scene = scene
        // Set the point of view explicitly — SCNView otherwise renders from a
        // nil camera (blank) because our camera node is added during buildScene.
        view.pointOfView = scene.rootNode.childNode(withName: "heroCamera", recursively: true)

        let pivot = scene.rootNode.childNode(withName: "keycapPivot", recursively: true)
        pivot?.eulerAngles.y = Self.restYaw

        let coordinator = context.coordinator
        coordinator.scnView = view
        coordinator.keycapNode = pivot
        coordinator.reduceMotion = reduceMotion

        let pan = UIPanGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePan(_:))
        )
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.reduceMotion = reduceMotion
        if !isActive {
            context.coordinator.stopInertia()
            uiView.rendersContinuously = false
            uiView.isPlaying = false
        } else {
            uiView.isPlaying = true
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopInertia()
    }

    // MARK: - Scene construction

    private static func buildScene() -> SCNScene? {
        guard let url = Bundle.main.url(forResource: "Keycap", withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: nil) else {
            return nil
        }

        let root = scene.rootNode

        // Re-parent all imported content under a pivot centered on the model,
        // so the pivot rotates the keycap about its own centre (turntable).
        let content = SCNNode()
        for child in root.childNodes { content.addChildNode(child) } // moves them
        var minV = SCNVector3Zero
        var maxV = SCNVector3Zero
        content.__getBoundingBoxMin(&minV, max: &maxV)
        let center = SCNVector3(
            (minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2
        )
        content.position = SCNVector3(-center.x, -center.y, -center.z)

        let pivot = SCNNode()
        pivot.name = "keycapPivot"
        pivot.addChildNode(content)
        root.addChildNode(pivot)

        let maxDim = max(maxV.x - minV.x, max(maxV.y - minV.y, maxV.z - minV.z))

        // Camera: long-ish lens, 3/4 product angle (matches the web hero intent).
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 22
        camera.zNear = 0.01
        camera.zFar = Double(maxDim) * 40
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        // AEK II look: warm greige matte PBT, never blown-out white. Pull the
        // exposure down and kill highlight bloom so the plastic keeps its tone
        // instead of clipping to paper-white.
        camera.exposureOffset = -0.85           // EV bias, darkens the whole frame
        camera.whitePoint = 1.35                 // raise clip point so highlights roll off, not clip
        camera.bloomIntensity = 0                // no glow halo on the top edge
        camera.bloomThreshold = 1.0
        cameraNode.camera = camera
        let r = maxDim * 3.4
        let el = camElevation, az = camAzimuth
        cameraNode.position = SCNVector3(
            r * cosf(el) * sinf(az),
            r * sinf(el),
            r * cosf(el) * cosf(az)
        )
        cameraNode.look(at: SCNVector3Zero)
        root.addChildNode(cameraNode)

        // Warm studio image-based lighting drives the satin PBT reflections.
        scene.lightingEnvironment.contents = studioEnvironment()
        scene.lightingEnvironment.intensity = 0.95   // was 1.35 — softer studio, matte satin

        // Crisp warm key light -> the highlight on the Ð legend + cap edges.
        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = UIColor(red: 1.0, green: 0.97, blue: 0.91, alpha: 1.0)
        keyLight.intensity = 720   // was 1250 — the raking key was blowing the top edge
        keyLight.castsShadow = false // levitation shadow is drawn in SwiftUI
        key.light = keyLight
        key.eulerAngles = SCNVector3(-0.95, -0.5, 0.0) // upper-left, raking
        root.addChildNode(key)

        // Low warm ambient so the shadow side never goes muddy.
        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor(red: 0.62, green: 0.60, blue: 0.57, alpha: 1.0)
        ambientLight.intensity = 260
        ambient.light = ambientLight
        root.addChildNode(ambient)

        return scene
    }

    /// A soft equirectangular studio gradient: warm bright sky at the top,
    /// platinum mid, cool floor. Read by `lightingEnvironment` for PBR
    /// reflections — no external HDRI needed, works in light and dark app themes.
    private static func studioEnvironment() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [
                UIColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1).cgColor, // warm sky
                UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1).cgColor, // platinum
                UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1).cgColor, // horizon
                UIColor(red: 0.30, green: 0.30, blue: 0.33, alpha: 1).cgColor, // cool floor
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0.0, 0.45, 0.62, 1.0]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }
    }

    // MARK: - Coordinator (drag -> Y rotation, flick inertia)

    final class Coordinator: NSObject {
        weak var scnView: SCNView?
        weak var keycapNode: SCNNode?
        var reduceMotion = false

        private var startYaw: Float = 0
        private var angularVelocity: Float = 0 // rad/s, for the flick coast
        private var displayLink: CADisplayLink?
        private var lastFrameTime: CFTimeInterval = 0

        /// Radians of yaw per point of horizontal drag. ~200 pt ≈ 130°.
        private let sensitivity: Float = 0.0115

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let node = keycapNode, let view = scnView else { return }
            let translation = gesture.translation(in: view)

            switch gesture.state {
            case .began:
                stopInertia()
                view.rendersContinuously = true // spin smoothly while dragging
                startYaw = node.eulerAngles.y
            case .changed:
                // Drag right -> spins toward the viewer's right; left the other way.
                node.eulerAngles.y = startYaw + Float(translation.x) * sensitivity
            case .ended, .cancelled, .failed:
                let vx = Float(gesture.velocity(in: view).x)
                beginInertia(velocity: vx * sensitivity)
            default:
                break
            }
        }

        private func beginInertia(velocity: Float) {
            // Reduce Motion: no coast — settle immediately, drop back to idle.
            if reduceMotion || abs(velocity) < 0.25 {
                scnView?.rendersContinuously = false
                return
            }
            angularVelocity = velocity
            lastFrameTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(stepInertia))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepInertia() {
            guard let node = keycapNode else { stopInertia(); return }
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastFrameTime, 1.0 / 30.0))
            lastFrameTime = now

            node.eulerAngles.y += angularVelocity * dt
            // Exponential decay (~time-constant independent of frame rate).
            angularVelocity *= powf(0.06, dt) // ~94%/frame at 60fps

            if abs(angularVelocity) < 0.05 {
                stopInertia()
                scnView?.rendersContinuously = false
            }
        }

        func stopInertia() {
            displayLink?.invalidate()
            displayLink = nil
            angularVelocity = 0
        }
    }
}
