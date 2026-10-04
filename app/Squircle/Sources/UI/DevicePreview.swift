import UIKit
import SceneKit
import simd

/// Procedural, static product model. The screen is app identity, not an invented
/// screenshot. Shared transitions use a rendered bitmap rather than snapshotting
/// a Metal-backed UIKit layer, which may otherwise disappear during compositing.
final class DevicePreview: UIView {
    private let renderer = SCNView(frame: .zero)
    private let scene = SCNScene()
    private let phone = SCNNode()
    private static let viewportAspect: CGFloat = 0.82
    private static let canvas = UIColor(red: 0.974, green: 0.964, blue: 0.945, alpha: 1)

    var upright = false { didSet { applyPose() } }

    /// In this view's coordinates; always the same aspect ratio at both ends of
    /// the workspace transition, so one uniform scale preserves device geometry.
    var transitionContentFrame: CGRect {
        layoutIfNeeded()
        return renderer.frame
    }

    func transitionSnapshot() -> UIImage {
        layoutIfNeeded()
        SCNTransaction.flush()
        return renderer.snapshot()
    }

    init(name: String, probe: Bool = false) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        renderer.backgroundColor = .clear
        renderer.isOpaque = false
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        renderer.allowsCameraControl = false
        renderer.antialiasingMode = .multisampling4X
        renderer.preferredFramesPerSecond = 120
        renderer.rendersContinuously = false
        renderer.isPlaying = false
        renderer.isUserInteractionEnabled = false
        addSubview(renderer)
        scene.rootNode.addChildNode(phone)
        buildPhone(name: name, probe: probe)
        buildStudio()
        applyPose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(name:probe:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = min(bounds.height, bounds.width / Self.viewportAspect)
        let size = CGSize(width: height * Self.viewportAspect, height: height)
        let frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        if renderer.frame != frame { renderer.frame = frame; renderer.setNeedsDisplay() }
    }

    private func applyPose() {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        // Long lens and combined pitch/yaw produce the reference's slight
        // downward top edge, visible left side, and visible bottom face.
        let pitch: Float = upright ? -0.10 : -0.50
        let yaw: Float = upright ? 0.10 : 0.52
        let roll: Float = upright ? 0 : -0.085
        phone.simdOrientation = simd_quatf(angle: roll, axis: [0, 0, 1])
            * simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
        phone.position = SCNVector3(0, 0.15, 0)
        SCNTransaction.commit()
        renderer.setNeedsDisplay()
    }

    private func buildPhone(name: String, probe: Bool) {
        let titanium = Self.metal(UIColor(red: 0.53, green: 0.54, blue: 0.57, alpha: 1), roughness: 0.22)
        let polished = Self.metal(UIColor(white: 0.48, alpha: 1), roughness: 0.17)
        let darkEdge = Self.metal(UIColor(white: 0.075, alpha: 1), roughness: 0.24)
        let black = Self.matte(UIColor(white: 0.014, alpha: 1), roughness: 0.32)
        let antenna = Self.matte(UIColor(white: 0.39, alpha: 1), roughness: 0.6)

        // SCNShape keeps long edges truly straight and rounds only the outline.
        // Its chamfer is independent from the outline's corner radius; an SCNBox
        // would constrain the entire phone's corner radius to its thin depth.
        addSlab(width: 3.55, height: 7.42, radius: 0.51, depth: 0.39,
                chamfer: 0.044, z: 0, material: titanium, name: "Titanium chassis")
        addSlab(width: 3.52, height: 7.39, radius: 0.50, depth: 0.022,
                chamfer: 0.008, z: -0.195, material: darkEdge, name: "Back glass seam")
        addSlab(width: 3.54, height: 7.41, radius: 0.505, depth: 0.026,
                chamfer: 0.010, z: 0.185, material: polished, name: "Polished front bevel")
        addSlab(width: 3.49, height: 7.36, radius: 0.49, depth: 0.035,
                chamfer: 0.010, z: 0.205, material: darkEdge, name: "Black glass edge")

        let screen = SCNPlane(width: 3.34, height: 7.205)
        screen.cornerRadius = 0.425
        screen.cornerSegmentCount = 24
        let display = SCNMaterial()
        display.lightingModel = .constant
        display.diffuse.contents = Self.screenTexture(name: name, probe: probe)
        display.diffuse.magnificationFilter = .linear
        display.diffuse.minificationFilter = .linear
        display.diffuse.mipFilter = .linear
        screen.firstMaterial = display
        let screenNode = SCNNode(geometry: screen)
        screenNode.position.z = 0.232
        screenNode.castsShadow = false
        phone.addChildNode(screenNode)

        let island = addSlab(width: 1.00, height: 0.25, radius: 0.125, depth: 0.012,
                             chamfer: 0.004, z: 0.244, material: black, name: "Dynamic Island")
        island.position.y = 3.265
        let lens = SCNSphere(radius: 0.041)
        lens.segmentCount = 20
        lens.firstMaterial = Self.metal(UIColor(red: 0.025, green: 0.042, blue: 0.06, alpha: 1), roughness: 0.12)
        let lensNode = SCNNode(geometry: lens)
        lensNode.position = SCNVector3(0.343, 3.265, 0.223)
        lensNode.castsShadow = false
        phone.addChildNode(lensNode)

        func sideButton(x: Float, y: Float, length: CGFloat) {
            let recess = SCNBox(width: 0.024, height: length + 0.07, length: 0.166, chamferRadius: 0.010)
            recess.firstMaterial = black
            let recessNode = SCNNode(geometry: recess)
            recessNode.position = SCNVector3(x, y, -0.004)
            phone.addChildNode(recessNode)
            let button = SCNBox(width: 0.047, height: length, length: 0.121, chamferRadius: 0.020)
            button.firstMaterial = polished
            let buttonNode = SCNNode(geometry: button)
            buttonNode.position = SCNVector3(x + (x < 0 ? -0.019 : 0.019), y, -0.004)
            phone.addChildNode(buttonNode)
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

        func bottomInset(width: CGFloat, height: CGFloat, material: SCNMaterial, y: Float) -> SCNNode {
            let plane = SCNPlane(width: width, height: height)
            plane.cornerRadius = height / 2
            plane.cornerSegmentCount = 12
            plane.firstMaterial = material
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = .pi / 2
            node.position = SCNVector3(0, y, 0)
            phone.addChildNode(node)
            return node
        }
        _ = bottomInset(width: 0.57, height: 0.137, material: polished, y: -3.712)
        _ = bottomInset(width: 0.49, height: 0.090, material: black, y: -3.716)
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
    private func addSlab(width: CGFloat, height: CGFloat, radius: CGFloat, depth: CGFloat,
                         chamfer: CGFloat, z: Float, material: SCNMaterial, name: String) -> SCNNode {
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
        node.name = name
        phone.addChildNode(node)
        return node
    }

    private func buildStudio() {
        let camera = SCNCamera()
        camera.fieldOfView = 14.3
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 100
        // Preserve the unlit display/floor colors so the transparent viewport
        // blends into UIKit's identical ivory instead of exposing a rectangle.
        camera.wantsHDR = false
        camera.exposureOffset = 0
        camera.bloomIntensity = 0
        camera.wantsDepthOfField = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 32)
        scene.rootNode.addChildNode(cameraNode)
        renderer.pointOfView = cameraNode

        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.65

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1150
        key.temperature = 5700
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowColor = UIColor(red: 0.14, green: 0.125, blue: 0.12, alpha: 0.25)
        key.shadowRadius = 14
        key.shadowSampleCount = 32
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowBias = 0.15
        key.orthographicScale = 11
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-6, 12, 8)
        keyNode.look(at: SCNVector3(0, -1, 0))
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .area
        fill.intensity = 720
        fill.color = UIColor(red: 0.80, green: 0.87, blue: 1, alpha: 1)
        fill.areaExtents = SIMD3<Float>(7, 12, 0)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(6, 3, 5)
        fillNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fillNode)

        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .shadowOnly
        floorMaterial.diffuse.contents = UIColor.clear
        floor.firstMaterial = floorMaterial
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -3.73
        floorNode.castsShadow = false
        scene.rootNode.addChildNode(floorNode)

        // Broad ambient contact shadow complements the directional shadow. A
        // transparent falloff avoids a visible floor horizon on the open canvas.
        let contact = SCNPlane(width: 5.7, height: 1.4)
        let contactMaterial = SCNMaterial()
        contactMaterial.lightingModel = .constant
        contactMaterial.diffuse.contents = Self.contactShadow()
        contactMaterial.writesToDepthBuffer = false
        contact.firstMaterial = contactMaterial
        let contactNode = SCNNode(geometry: contact)
        contactNode.position = SCNVector3(-0.4, -3.4, -1.2)
        contactNode.castsShadow = false
        scene.rootNode.addChildNode(contactNode)
    }

    private static func contactShadow() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 192), format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 256, y: 96); cg.scaleBy(x: 1, y: 0.375)
            let colors = [UIColor.black.withAlphaComponent(0.23).cgColor, UIColor.black.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.38, 1])!
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 255, options: [])
        }
    }

    private static func metal(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = 0.95
        material.roughness.contents = roughness
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

    private static func screenTexture(name: String, probe: Bool) -> UIImage {
        let size = CGSize(width: 1024, height: 2210)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            canvas.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let ink = UIColor(red: 0.055, green: 0.058, blue: 0.057, alpha: 1)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 512, y: 1135)
            ink.setStroke()
            ink.setFill()
            if probe {
                let waveform = UIBezierPath()
                waveform.move(to: CGPoint(x: -215, y: 20))
                for point in [CGPoint(x: -135, y: 20), CGPoint(x: -77, y: -130), CGPoint(x: -10, y: 145), CGPoint(x: 70, y: -70), CGPoint(x: 126, y: 20), CGPoint(x: 215, y: 20)] { waveform.addLine(to: point) }
                waveform.lineWidth = 32
                waveform.lineJoinStyle = .round
                waveform.lineCapStyle = .round
                waveform.stroke()
            } else {
                context.cgContext.rotate(by: -0.18)
                let ring = UIBezierPath(roundedRect: CGRect(x: -183, y: -183, width: 366, height: 366), cornerRadius: 80)
                ring.lineWidth = 35
                ring.stroke()
                UIBezierPath(ovalIn: CGRect(x: 179, y: -247, width: 65, height: 65)).fill()
            }
            context.cgContext.restoreGState()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: name.count > 16 ? 49 : 59, weight: .light),
                .foregroundColor: ink,
                .kern: 9,
                .paragraphStyle: paragraph
            ]
            (name as NSString).draw(in: CGRect(x: 80, y: 1460, width: 864, height: 170), withAttributes: attributes)
        }
    }

    /// A compact procedural studio reflection map: broad soft boxes separated
    /// by darker panels give the thin metal edges readable highlights.
    private static func studioEnvironment() -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.32, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let colors = [UIColor(white: 0.85, alpha: 1).cgColor, UIColor(white: 0.22, alpha: 1).cgColor, UIColor(white: 0.10, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.58, 1])!
            context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 512), options: [])
            context.cgContext.setShadow(offset: .zero, blur: 44, color: UIColor.white.cgColor)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 100, y: 80, width: 170, height: 350), cornerRadius: 36).fill()
            UIColor(red: 0.78, green: 0.84, blue: 0.94, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 730, y: 90, width: 105, height: 300), cornerRadius: 24).fill()
        }
    }
}
