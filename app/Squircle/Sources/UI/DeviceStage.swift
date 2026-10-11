import UIKit
import SceneKit
import CoreVideo
import Metal
import simd
import CoreImage
import os

/// Where one device stands, expressed in the stage view's points so UIKit
/// layout and the 3D scene share one coordinate system.
struct PhonePose: Equatable {
    var center: CGPoint
    /// On-screen height of the device at zero depth.
    var height: CGFloat
    /// Points away from the viewer; perspective shrinks and converges it.
    var depth: CGFloat = 0
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var roll: CGFloat = 0
    var shadow: CGFloat = 1
    var visible = true
    var opacity: CGFloat = 1

    static func interpolate(_ a: PhonePose, _ b: PhonePose, _ t: CGFloat) -> PhonePose {
        PhonePose(center: CGPoint(x: .lerp(a.center.x, b.center.x, t), y: .lerp(a.center.y, b.center.y, t)),
                  height: .lerp(a.height, b.height, t), depth: .lerp(a.depth, b.depth, t),
                  yaw: .lerp(a.yaw, b.yaw, t), pitch: .lerp(a.pitch, b.pitch, t), roll: .lerp(a.roll, b.roll, t),
                  shadow: .lerp(a.shadow, b.shadow, t), visible: a.visible || b.visible,
                  opacity: .lerp(a.opacity, b.opacity, t))
    }

    /// Device outline aspect (width / height) of the modeled hardware.
    static let aspect: CGFloat = 3.55 / 7.42
}

/// Real pixels only. Without a capture the display stays dark, or states
/// honestly that no screenshot exists; it never shows invented app art.
enum PhoneScreen: Equatable {
    case off
    case missing
    case unavailable
    case image(UIImage)

    var hasScreenshot: Bool { if case .image = self { return true }; return false }
}

/// One SceneKit view renders a device while it moves between places or shows
/// a live simulator. At rest in lists, devices are still portraits rendered
/// from the same scene (`portrait`) that UIKit places in scrolling content,
/// so they scroll, clip and blur exactly like the views around them.
@MainActor
final class DeviceStage: UIView, SCNSceneRendererDelegate {
    static let cameraDistance: CGFloat = 30
    static let fieldOfView: CGFloat = 22
    static let modelHeight: CGFloat = 7.42

    private let backdrop = CALayer()
    private let sceneView = SCNView(frame: .zero, options: [
        SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
    ])
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private var phones: [String: StagePhone] = [:]
    /// The rendered devices, kept separate from the backdrop so the host can
    /// place them above everything else: the phone always sits on top.
    let overlay = UIView()
    private var liveReasons = Set<String>()

    private var textureCache: CVMetalTextureCache?
    /// Which devices were visible in the poses being rendered, handed from
    /// the main thread to the render thread and back.
    private let frames = RenderedDevices()
    /// Devices visible in the poses the last completed render started from:
    /// drawn for certain, not merely posed.
    private(set) var drawn = Set<String>()
    /// Called on the main thread after each completed render.
    var onRendered: (() -> Void)?

    /// Renders single devices for `portrait`, lit exactly like the stage.
    private let portraitScene = SCNScene()
    private let portraitCamera = SCNNode()
    private let sitter = StagePhone()
    private lazy var portraitRenderer: SCNRenderer = {
        let renderer = SCNRenderer(device: sceneView.device ?? MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = portraitScene
        renderer.pointOfView = portraitCamera
        renderer.autoenablesDefaultLighting = false
        return renderer
    }()

    /// Off where the stage sits on glass over another app (the overlay).
    var showsBackdrop = true {
        didSet { backdrop.isHidden = !showsBackdrop }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.addSublayer(backdrop)

        scene.background.contents = UIColor.clear
        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = false
        sceneView.isUserInteractionEnabled = false
        sceneView.antialiasingMode = .multisampling4X
        // At rest, extra jittered passes smooth thin bezel highlights.
        sceneView.isJitteringEnabled = true
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        sceneView.delegate = self
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.addSubview(sceneView)
        buildStudio(scene, camera: cameraNode, fieldOfView: Self.fieldOfView)
        sceneView.pointOfView = cameraNode
        portraitScene.background.contents = UIColor.clear
        buildStudio(portraitScene, camera: portraitCamera, fieldOfView: Self.fieldOfView)
        portraitScene.rootNode.addChildNode(sitter.shadow)
        portraitScene.rootNode.addChildNode(sitter.root)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (stage: DeviceStage, _: UITraitCollection) in
            stage.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        CATransaction.commit()
        overlay.frame = frame
        if sceneView.frame != bounds {
            sceneView.frame = bounds
            sceneView.setNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneView.preferredFramesPerSecond = window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        // Render at the display's native pixel density.
        if let screen = window?.windowScene?.screen { sceneView.contentScaleFactor = screen.nativeScale }
    }

    /// Scene units per point at zero depth; the camera looks down -z.
    var unitsPerPoint: CGFloat {
        guard bounds.height > 0 else { return 0.01 }
        return 2 * Self.cameraDistance * tan(Self.fieldOfView * .pi / 360) / bounds.height
    }

    // MARK: Devices

    func sync(ids: [String]) {
        let wanted = Set(ids)
        for (id, phone) in phones where !wanted.contains(id) {
            phone.root.removeFromParentNode()
            phone.shadow.removeFromParentNode()
            phones[id] = nil
        }
        for id in ids where phones[id] == nil {
            let phone = StagePhone()
            phone.root.isHidden = true
            phone.shadow.isHidden = true
            scene.rootNode.addChildNode(phone.shadow)
            scene.rootNode.addChildNode(phone.root)
            phones[id] = phone
        }
    }

    func screen(for id: String) -> PhoneScreen { phones[id]?.screen ?? .off }

    private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

    // MARK: Portraits

    /// Size of a portrait of a device `height` points tall: room for any
    /// gentle turn and the contact shadow beneath it, the device centered.
    static func portraitSize(height: CGFloat) -> CGSize {
        CGSize(width: (height * PhonePose.aspect * 1.36).rounded(.up), height: (height * 1.34).rounded(.up))
    }

    /// One device alone, still, as an image with a transparent background.
    /// Drawn with the stage's own lights and perspective, so a portrait placed
    /// centered on a pose's center matches the stage rendering that pose.
    func portrait(for id: String, pose: PhonePose, scale: CGFloat) -> UIImage? {
        guard let phone = phones[id], pose.height > 4, bounds.height > 0 else { return nil }
        let size = Self.portraitSize(height: pose.height)
        sitter.setScreen(phone.screen, dark: dark)
        // Same scene units per point as the stage, with a camera narrowed to
        // the portrait: identical perspective, smaller frame.
        let u = unitsPerPoint
        portraitCamera.camera?.fieldOfView = 2 * atan(size.height * u / 2 / Self.cameraDistance) * 180 / .pi
        var centered = pose
        centered.center = CGPoint(x: size.width / 2, y: size.height / 2)
        centered.depth = 0
        centered.opacity = 1
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        Self.place(sitter, pose: centered, unitsPerPoint: u, size: size)
        SCNTransaction.commit()
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let image = portraitRenderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
        guard let cgImage = image.cgImage else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        frames.beginRender()
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let rendered = frames.endRender()
        Task { @MainActor [weak self] in
            guard let self, rendered != drawn else { return }
            drawn = rendered
            onRendered?()
        }
    }

    /// Asks for a render even when nothing moved, so `drawn` catches up.
    func requestRender() { sceneView.setNeedsDisplay() }

    // MARK: Live display

    /// Shows a decoded simulator picture on the device's display, in the scene.
    func setLiveFrame(_ buffer: CVPixelBuffer, for id: String) {
        guard let phone = phones[id], let device = sceneView.device ?? MTLCreateSystemDefaultDevice() else { return }
        if textureCache == nil { CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) }
        guard let textureCache else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm_srgb,
                                                  width, height, 0, &wrapped)
        guard let wrapped, let texture = CVMetalTextureGetTexture(wrapped), height > 0 else { return }
        phone.setLive(texture, backing: wrapped, aspect: CGFloat(width) / CGFloat(height))
        sceneView.setNeedsDisplay()
    }

    /// Returns the display to the published screenshot.
    func endLive(for id: String) {
        guard let phone = phones[id], phone.isLive else { return }
        phone.setScreen(phone.screen, dark: dark)
        sceneView.setNeedsDisplay()
    }

    func isLive(_ id: String) -> Bool { phones[id]?.isLive ?? false }

    /// Maps a point in this view to the picture shown on a device's display:
    /// normalized source coordinates with the origin at the top left. Exact
    /// for any pose because the scene itself is hit-tested.
    func displayPoint(at point: CGPoint, for id: String) -> CGPoint? {
        guard let phone = phones[id], !phone.root.isHidden else { return nil }
        let hit = sceneView.hitTest(point, options: [.rootNode: phone.displayNode, .ignoreHiddenNodes: true]).first
        guard let uv = hit?.textureCoordinates(withMappingChannel: 0) else { return nil }
        let crop = phone.display.diffuse.contentsTransform
        return CGPoint(x: CGFloat(crop.m41) + uv.x * CGFloat(crop.m11), y: CGFloat(crop.m42) + uv.y * CGFloat(crop.m22))
    }

    func setScreen(_ screen: PhoneScreen, for id: String) {
        guard let phone = phones[id], phone.screen != screen else { return }
        if phone.isLive { phone.remember(screen); return }
        phone.setScreen(screen, dark: dark)
        sceneView.setNeedsDisplay()
    }

    /// Phones absent from `poses` are hidden and cost nothing to render.
    func apply(_ poses: [String: PhonePose]) {
        let u = unitsPerPoint
        let size = bounds.size
        var changed = false
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (id, phone) in phones {
            let pose = poses[id]
            guard pose != phone.pose else { continue }
            changed = true
            phone.pose = pose
            guard let pose, pose.visible, pose.height > 1, pose.opacity > 0.005 else {
                phone.root.isHidden = true
                phone.shadow.isHidden = true
                continue
            }
            Self.place(phone, pose: pose, unitsPerPoint: u, size: size)
        }
        SCNTransaction.commit()
        frames.applied(Set(phones.compactMap { id, phone in phone.root.isHidden ? nil : id }))
        if changed { sceneView.setNeedsDisplay() }
    }

    /// Positions a device for a pose in a view of `size`. The device is turned
    /// to face the camera as it would at the center of the view, so the same
    /// pose looks identical anywhere on screen and in a centered portrait.
    private static func place(_ phone: StagePhone, pose: PhonePose, unitsPerPoint u: CGFloat, size: CGSize) {
        let scale = Float(pose.height * u / modelHeight)
        let position = SIMD3(Float((pose.center.x - size.width / 2) * u), Float((size.height / 2 - pose.center.y) * u),
                             Float(-pose.depth * u))
        let ray = simd_normalize(position - SIMD3(0, 0, Float(cameraDistance)))
        let facing = simd_quatf(from: [0, 0, -1], to: ray)
        phone.root.isHidden = false
        phone.root.simdPosition = position
        phone.root.simdScale = SIMD3(repeating: scale)
        phone.root.opacity = pose.opacity.clamped()
        phone.root.simdOrientation = facing
            * simd_quatf(angle: Float(pose.yaw), axis: [0, 1, 0])
            * simd_quatf(angle: Float(pose.pitch), axis: [1, 0, 0])
            * simd_quatf(angle: Float(pose.roll), axis: [0, 0, 1])
        let foot = phone.root.simdConvertPosition([0, -3.71, 0], to: nil)
        phone.shadow.isHidden = pose.shadow <= 0.01
        phone.shadow.simdPosition = SIMD3(foot.x, foot.y - 0.27 * scale, phone.root.simdPosition.z - 1.2 * scale)
        phone.shadow.simdScale = SIMD3(repeating: scale)
        phone.shadow.opacity = (pose.shadow * pose.opacity).clamped()
    }

    /// Continuous rendering only while something is actually moving.
    func setLive(_ live: Bool, reason: String) {
        if live { liveReasons.insert(reason) } else { liveReasons.remove(reason) }
        let continuous = !liveReasons.isEmpty
        guard sceneView.rendersContinuously != continuous else { return }
        sceneView.rendersContinuously = continuous
        if !continuous { sceneView.setNeedsDisplay() }
    }

    var isLive: Bool { sceneView.rendersContinuously }

    // MARK: Studio

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.backgroundColor = Theme.paper.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        PhoneAssets.contactMaterial.transparency = dark ? 1 : 0.85
        for phone in phones.values where !phone.isLive { phone.setScreen(phone.screen, dark: dark) }
        sceneView.setNeedsDisplay()
    }

    private func buildStudio(_ scene: SCNScene, camera cameraNode: SCNNode, fieldOfView: CGFloat) {
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = 1
        camera.zFar = 100
        // Keep unlit screenshot colors exact against UIKit's backdrop.
        camera.wantsHDR = false
        camera.bloomIntensity = 0
        camera.wantsDepthOfField = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Float(Self.cameraDistance))
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = PhoneAssets.environment
        scene.lightingEnvironment.intensity = 1.0

        func area(_ intensity: CGFloat, extents: SIMD3<Float>, at position: SCNVector3, lookAt: SCNVector3, white: CGFloat = 1) {
            let light = SCNLight()
            light.type = .area
            // A visible softbox would otherwise enter the frustum as a shape.
            light.drawsArea = false
            light.intensity = intensity
            light.color = UIColor(white: white, alpha: 1)
            light.areaExtents = extents
            let node = SCNNode()
            node.light = light
            node.position = position
            node.look(at: lookAt)
            scene.rootNode.addChildNode(node)
        }
        let key = SCNLight()
        key.type = .directional
        key.intensity = 820
        key.temperature = 5400
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-3, 12, 8)
        keyNode.look(at: SCNVector3(0, -1, 0))
        scene.rootNode.addChildNode(keyNode)
        area(950, extents: [1.6, 8, 0], at: SCNVector3(-4.3, 2.0, -1.15), lookAt: SCNVector3Zero)
        area(360, extents: [4.5, 0.6, 0], at: SCNVector3(0.9, -6, -1.5), lookAt: SCNVector3(0, -2.5, 0), white: 0.96)
        area(260, extents: [1.3, 3.8, 0], at: SCNVector3(7, 6.5, 2.4), lookAt: SCNVector3(0, 1, 0))
    }
}

/// A clone of the shared flattened hardware plus its own display material.
@MainActor
private final class StagePhone {
    let root = SCNNode()
    let shadow = SCNNode()
    let display = SCNMaterial()
    let displayNode: SCNNode
    var pose: PhonePose?
    private(set) var screen: PhoneScreen = .off
    private(set) var isLive = false
    private var liveBacking: CVMetalTexture?

    init() {
        root.addChildNode(PhoneAssets.body.clone())
        let geometry = PhoneAssets.displayGeometry.copy() as! SCNGeometry
        display.lightingModel = .constant
        display.diffuse.magnificationFilter = .linear
        display.diffuse.minificationFilter = .linear
        display.diffuse.mipFilter = .linear
        geometry.firstMaterial = display
        displayNode = SCNNode(geometry: geometry)
        displayNode.position.z = 0.240
        displayNode.castsShadow = false
        root.addChildNode(displayNode)
        shadow.geometry = PhoneAssets.contactGeometry
        shadow.castsShadow = false
        shadow.renderingOrder = -1
        setScreen(.off, dark: true)
    }

    /// A screenshot published while live is shown once the stream ends.
    func remember(_ next: PhoneScreen) { screen = next }

    func setLive(_ texture: MTLTexture, backing: CVMetalTexture, aspect: CGFloat) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        display.diffuse.contents = texture
        display.diffuse.contentsTransform = PhoneAssets.crop(sourceAspect: aspect)
        SCNTransaction.commit()
        liveBacking = backing
        isLive = true
    }

    func setScreen(_ next: PhoneScreen, dark: Bool) {
        screen = next
        isLive = false
        liveBacking = nil
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let contents: Any
        let aspect: CGFloat?
        switch next {
        case .off, .missing, .unavailable:
            let placeholder = dark ? PhoneAssets.darkPlaceholder : PhoneAssets.lightPlaceholder
            contents = placeholder; aspect = placeholder.size.width / placeholder.size.height
        case .image(let image):
            contents = image
            aspect = image.size.height > 0 ? image.size.width / image.size.height : nil
        }
        display.diffuse.contents = contents
        display.diffuse.contentsTransform = aspect.map(PhoneAssets.crop(sourceAspect:)) ?? SCNMatrix4Identity
        SCNTransaction.commit()
    }
}

/// Built once per process: hardware geometry, materials and studio images.
@MainActor
enum PhoneAssets {
    static let screenAspect: CGFloat = 3.34 / 7.205
    static let offColor = UIColor(white: 0.035, alpha: 1)

    /// Center-crop UVs instead of stretching a capture to the display shape.
    static func crop(sourceAspect: CGFloat) -> SCNMatrix4 {
        let scaleX = min(1, screenAspect / sourceAspect)
        let scaleY = min(1, sourceAspect / screenAspect)
        var crop = SCNMatrix4MakeScale(Float(scaleX), Float(scaleY), 1)
        crop.m41 = Float((1 - scaleX) / 2)
        crop.m42 = Float((1 - scaleY) / 2)
        return crop
    }

    static let displayGeometry: SCNGeometry = {
        let screen = SCNPlane(width: 3.34, height: 7.205)
        screen.cornerRadius = 0.425
        screen.cornerSegmentCount = 24
        return screen
    }()

    static let contactMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = contactShadowImage()
        material.writesToDepthBuffer = false
        return material
    }()

    static let contactGeometry: SCNGeometry = {
        let plane = SCNPlane(width: 4.3, height: 1.1)
        plane.firstMaterial = contactMaterial
        return plane
    }()

    /// Every non-display part merged into one node: a handful of draw calls
    /// per device instead of one per bezel, button and speaker hole.
    static let body: SCNNode = {
        let parts = SCNNode()
        PhoneModel.build(into: parts)
        let flat = parts.flattenedClone()
        flat.name = "Device body"
        return flat
    }()

    static let environment: UIImage = studioEnvironment()

    static let darkPlaceholder: UIImage = placeholder(dark: true)
    static let lightPlaceholder: UIImage = placeholder(dark: false)

    /// Until a real capture arrives: an app's screen so far out of focus that
    /// only soft, neutral masses of a header, content and a bar remain.
    /// Abstract on purpose; it never pretends to be the app.
    private static func placeholder(dark: Bool) -> UIImage {
        let size = CGSize(width: 360, height: 777)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let sharp = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let base: CGFloat = dark ? 0.085 : 0.93
            let ink: (CGFloat) -> UIColor = { amount in UIColor(white: dark ? base + amount : base - amount * 0.9, alpha: 1) }
            ink(0).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ amount: CGFloat, radius: CGFloat = 18) {
                ink(amount).setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius).fill()
            }
            block(28, 96, 190, 34, 0.16, radius: 12)
            block(24, 162, 312, 210, 0.10, radius: 28)
            for row in 0..<4 {
                let y = 402 + CGFloat(row) * 72
                block(28, y, 48, 48, 0.12, radius: 14)
                block(92, y + 6, 180 - CGFloat(row % 2) * 50, 14, 0.13, radius: 7)
                block(92, y + 28, 120, 10, 0.08, radius: 5)
            }
            block(20, 700, 320, 56, 0.09, radius: 28)
        }
        guard let input = CIImage(image: sharp) else { return sharp }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 16).cropped(to: input.extent)
        guard let output = CIContext().createCGImage(blurred, from: input.extent) else { return sharp }
        return UIImage(cgImage: output)
    }

    private static func contactShadowImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 96), format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 128, y: 48)
            cg.scaleBy(x: 1, y: 0.375)
            let colors = [UIColor.black.withAlphaComponent(0.38).cgColor, UIColor.black.withAlphaComponent(0.16).cgColor,
                          UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.24, 1])!
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 127, options: [])
        }
    }

    /// Neutral reflection cards with distinct dark gaps for crisp metal rims.
    private static func studioEnvironment() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: 0.5, y: 0.5)
            UIColor(white: 0.14, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
            let colors = [UIColor(white: 0.48, alpha: 1).cgColor, UIColor(white: 0.055, alpha: 1).cgColor,
                          UIColor(white: 0.22, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.53, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
            cg.setShadow(offset: .zero, blur: 9, color: UIColor.white.withAlphaComponent(0.65).cgColor)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 170, y: 90, width: 84, height: 330), cornerRadius: 14).fill()
            cg.setShadow(offset: .zero, blur: 4, color: UIColor.white.withAlphaComponent(0.55).cgColor)
            UIBezierPath(roundedRect: CGRect(x: 560, y: 52, width: 29, height: 408), cornerRadius: 8).fill()
            UIColor(white: 0.70, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 810, y: 140, width: 145, height: 245), cornerRadius: 22).fill()
        }
    }
}

/// The modeled device hardware, unchanged in proportion from version 5:
/// titanium chassis, glass seals, rounded rail, island, buttons and ports.
@MainActor
private enum PhoneModel {
    static func build(into phone: SCNNode) {
        let titanium = metal(UIColor(red: 0.39, green: 0.40, blue: 0.41, alpha: 1), roughness: 0.23, reflection: 0.75)
        let polished = metal(UIColor(white: 0.67, alpha: 1), roughness: 0.12, reflection: 1.05)
        let darkEdge = metal(UIColor(white: 0.012, alpha: 1), roughness: 0.08, reflection: 0.95)
        // Glass is a dielectric: dark face-on, with a bright grazing reflection.
        darkEdge.metalness.contents = 0.0
        darkEdge.clearCoat.contents = 1.0
        darkEdge.clearCoatRoughness.contents = 0.04
        let black = matte(UIColor(white: 0.014, alpha: 1), roughness: 0.32)
        let antenna = matte(UIColor(white: 0.39, alpha: 1), roughness: 0.6)

        // SCNShape keeps long edges straight and rounds only the outline.
        slab(phone, width: 3.55, height: 7.42, radius: 0.51, depth: 0.39, chamfer: 0.044, z: 0, material: titanium)
        slab(phone, width: 3.52, height: 7.39, radius: 0.50, depth: 0.022, chamfer: 0.008, z: -0.195, material: darkEdge)
        slab(phone, width: 3.552, height: 7.422, radius: 0.511, depth: 0.015, chamfer: 0.005, z: -0.154, material: polished)
        rim(phone, width: 3.504, height: 7.374, cornerRadius: 0.488, radialRadius: 0.023, depthRadius: 0.040, z: 0.180, material: polished)
        slab(phone, width: 3.49, height: 7.36, radius: 0.49, depth: 0.035, chamfer: 0.010, z: 0.205, material: darkEdge)
        slab(phone, width: 3.477, height: 7.347, radius: 0.483, depth: 0.030, chamfer: 0.013, z: 0.221, material: darkEdge)

        let island = slab(phone, width: 1.00, height: 0.25, radius: 0.125, depth: 0.012, chamfer: 0.004, z: 0.253, material: black)
        island.position.y = 3.265
        let lens = SCNSphere(radius: 0.041)
        lens.segmentCount = 20
        lens.firstMaterial = metal(UIColor(red: 0.025, green: 0.042, blue: 0.06, alpha: 1), roughness: 0.12, reflection: 0.55)
        let lensNode = SCNNode(geometry: lens)
        lensNode.position = SCNVector3(0.343, 3.265, 0.232)
        phone.addChildNode(lensNode)

        func sideButton(x: Float, y: Float, length: CGFloat) {
            let recess = slab(phone, width: 0.159, height: length + 0.065, radius: 0.077, depth: 0.018, chamfer: 0.005, z: 0, material: black)
            recess.eulerAngles.y = x < 0 ? -.pi / 2 : .pi / 2
            recess.position = SCNVector3(x, y, -0.004)
            let button = slab(phone, width: 0.121, height: length, radius: 0.059, depth: 0.038, chamfer: 0.009, z: 0, material: polished)
            button.eulerAngles.y = x < 0 ? -.pi / 2 : .pi / 2
            button.position = SCNVector3(x + (x < 0 ? -0.019 : 0.019), y, -0.004)
        }
        sideButton(x: -1.779, y: 2.36, length: 0.32)
        sideButton(x: -1.779, y: 1.63, length: 0.62)
        sideButton(x: -1.779, y: 0.82, length: 0.62)
        sideButton(x: 1.779, y: 1.42, length: 0.88)

        for x: Float in [-1.778, 1.778] {
            for y: Float in [-2.95, 2.98] {
                let band = SCNBox(width: 0.012, height: 0.038, length: 0.295, chamferRadius: 0.004)
                band.firstMaterial = antenna
                let node = SCNNode(geometry: band)
                node.position = SCNVector3(x, y, 0)
                phone.addChildNode(node)
            }
        }
        func bottomInset(width: CGFloat, height: CGFloat, material: SCNMaterial, y: Float) {
            let plane = SCNPlane(width: width, height: height)
            plane.cornerRadius = height / 2
            plane.cornerSegmentCount = 12
            plane.firstMaterial = material
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = .pi / 2
            node.position = SCNVector3(0, y, 0)
            phone.addChildNode(node)
        }
        bottomInset(width: 0.57, height: 0.137, material: polished, y: -3.712)
        bottomInset(width: 0.49, height: 0.090, material: black, y: -3.716)
        for direction: Float in [-1, 1] {
            for index in 0..<6 {
                let hole = SCNCylinder(radius: 0.029, height: 0.018)
                hole.radialSegmentCount = 16
                hole.firstMaterial = black
                let node = SCNNode(geometry: hole)
                node.position = SCNVector3(direction * (0.66 + Float(index) * 0.115), -3.711, 0)
                phone.addChildNode(node)
            }
        }
    }

    @discardableResult
    private static func slab(_ phone: SCNNode, width: CGFloat, height: CGFloat, radius: CGFloat, depth: CGFloat,
                             chamfer: CGFloat, z: Float, material: SCNMaterial) -> SCNNode {
        let path = UIBezierPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), cornerRadius: radius)
        path.flatness = 0.001
        let shape = SCNShape(path: path, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        shape.chamferMode = .both
        shape.firstMaterial = material
        let node = SCNNode(geometry: shape)
        let box = shape.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(0, 0, (box.min.z + box.max.z) / 2)
        node.position.z = z
        phone.addChildNode(node)
        return node
    }

    /// Sweeps an elliptical metal bead around a rounded rectangle; explicit
    /// normals keep a curved specular band even when it is a few pixels wide.
    private static func rim(_ phone: SCNNode, width: Float, height: Float, cornerRadius: Float,
                            radialRadius: Float, depthRadius: Float, z: Float, material: SCNMaterial) {
        let cornerSteps = 28, crossSteps = 20
        var centers: [SIMD2<Float>] = [], outward: [SIMD2<Float>] = []
        let halfWidth = width / 2 - cornerRadius, halfHeight = height / 2 - cornerRadius
        let corners: [SIMD2<Float>] = [[halfWidth, halfHeight], [-halfWidth, halfHeight], [-halfWidth, -halfHeight], [halfWidth, -halfHeight]]
        for (index, center) in corners.enumerated() {
            for step in 0...cornerSteps {
                let angle = (Float(index) + Float(step) / Float(cornerSteps)) * .pi / 2
                let normal = SIMD2<Float>(cos(angle), sin(angle))
                centers.append(center + normal * cornerRadius)
                outward.append(normal)
            }
        }
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        for (index, center) in centers.enumerated() {
            for step in 0..<crossSteps {
                let angle = Float(step) / Float(crossSteps) * 2 * .pi
                let radial = outward[index] * cos(angle)
                let position = center + radial * radialRadius
                vertices.append(SCNVector3(position.x, position.y, z + sin(angle) * depthRadius))
                let normal = simd_normalize(SIMD3<Float>(radial.x / radialRadius, radial.y / radialRadius, sin(angle) / depthRadius))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }
        var indices: [Int32] = []
        for ring in centers.indices {
            let nextRing = (ring + 1) % centers.count
            for step in 0..<crossSteps {
                let nextStep = (step + 1) % crossSteps
                let a = Int32(ring * crossSteps + step), b = Int32(nextRing * crossSteps + step)
                let c = Int32(nextRing * crossSteps + nextStep), d = Int32(ring * crossSteps + nextStep)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.firstMaterial = material
        phone.addChildNode(SCNNode(geometry: geometry))
    }

    private static func metal(_ color: UIColor, roughness: CGFloat, reflection: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = 0.95
        material.roughness.contents = roughness
        material.clearCoat.contents = 0.25
        material.clearCoatRoughness.contents = 0.10
        material.shaderModifiers = [.fragment: studioReflections]
        material.setValue(reflection, forKey: "studioReflectionStrength")
        return material
    }

    private static func matte(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = 0.04
        material.roughness.contents = roughness
        return material
    }

    /// Finite studio cards supplement the distant environment map so flat
    /// titanium sides get a falling highlight. Card positions are measured
    /// relative to each device's own origin and scale, so every phone on the
    /// shared stage is lit like the centered one.
    private static let studioReflections = """
    #pragma arguments
    float studioReflectionStrength;
    #pragma body
    float4x4 studioModel = scn_node.modelTransform;
    float3 studioOrigin = studioModel[3].xyz;
    float studioScale = max(0.0001, length(studioModel[0].xyz));
    float3 studioV = normalize(_surface.view);
    float3 studioN = normalize(_surface.normal);
    float3 studioR = normalize((scn_frame.inverseViewTransform * float4(reflect(-studioV, studioN), 0.0)).xyz);
    float3 studioP = ((scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz - studioOrigin) / studioScale;
    float studioBroad = 0.0;
    float studioStrip = 0.0;
    float studioLower = 0.0;
    float studioRim = 0.0;
    if (studioR.x < -0.001) {
        float studioT = (-4.3 - studioP.x) / studioR.x;
        if (studioT > 0.0) {
            float3 studioHit = studioP + studioR * studioT;
            float studioY = 1.0 - smoothstep(1.7, 3.3, abs(studioHit.y - 1.7));
            float studioZ = 1.0 - smoothstep(0.48, 1.18, abs(studioHit.z + 1.15));
            studioBroad = studioY * studioZ;
            float studioThin = 1.0 - smoothstep(0.10, 0.42, abs(studioHit.z - 0.40));
            studioStrip = studioThin * (1.0 - smoothstep(2.8, 4.8, abs(studioHit.y)));
        }
    }
    if (studioR.y < -0.001) {
        float studioT = (-5.8 - studioP.y) / studioR.y;
        if (studioT > 0.0) {
            float3 studioHit = studioP + studioR * studioT;
            float studioX = 1.0 - smoothstep(1.1, 2.3, abs(studioHit.x - 0.4));
            float studioZ = 1.0 - smoothstep(0.22, 1.10, abs(studioHit.z + 1.3));
            studioLower = studioX * studioZ;
        }
    }
    if (studioR.x > 0.001) {
        float studioT = (7.0 - studioP.x) / studioR.x;
        if (studioT > 0.0) {
            float3 studioHit = studioP + studioR * studioT;
            float studioY = 1.0 - smoothstep(1.45, 2.25, abs(studioHit.y - 6.5));
            float studioZ = 1.0 - smoothstep(0.48, 1.15, abs(studioHit.z - 2.4));
            studioRim = studioY * studioZ;
        }
    }
    float studioCoverage = max(max(studioBroad * 0.55, studioStrip), max(studioLower * 0.88, studioRim));
    float studioFacing = saturate(dot(studioN, studioV));
    float3 studioF0 = mix(float3(0.04), _surface.diffuse.rgb, saturate(_surface.metalness));
    float3 studioFresnel = studioF0 + (1.0 - studioF0) * pow(1.0 - studioFacing, 5.0);
    float3 studioRadiance = float3(1.0, 0.988, 0.972) * 1.45 * studioFresnel;
    _output.color.rgb = mix(_output.color.rgb, studioRadiance, saturate(studioCoverage * studioReflectionStrength));
    """
}

/// The visible set as last applied on the main thread, captured by the
/// render thread when a frame starts and returned when it completes.
private final class RenderedDevices: @unchecked Sendable {
    private struct State { var applied = Set<String>(); var rendering = Set<String>() }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    func applied(_ ids: Set<String>) { lock.withLock { $0.applied = ids } }
    func beginRender() { lock.withLock { $0.rendering = $0.applied } }
    func endRender() -> Set<String> { lock.withLock { $0.rendering } }
}
