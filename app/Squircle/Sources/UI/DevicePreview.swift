import UIKit
import SceneKit
import simd

/// Live device geometry with a real app screenshot on its display. Move this
/// view between transition containers instead of snapshotting its Metal layer.
final class DevicePreview: UIView {
    private let sceneView = SCNView(frame: .zero, options: [
        SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
    ])
    private let scene = SCNScene()
    private let phone = SCNNode()
    private let cameraNode = SCNNode()
    private let contactShadowNode = SCNNode()
    private let display = SCNMaterial()
    private let previewStatus = UILabel()
    private var animationRequested = false
    private(set) var screenshot: UIImage?
    private(set) var hasScreenshot = false
    private(set) var poseProgress: CGFloat = 0
    private static let viewportAspect: CGFloat = 0.82
    private static let screenAspect: CGFloat = 3.34 / 7.205
    private static let canvas = UIColor(red: 0.974, green: 0.964, blue: 0.945, alpha: 1)

    var upright: Bool {
        get { poseProgress == 1 }
        set { setPose(newValue ? 1 : 0) }
    }

    /// The live viewport is moved into the transition stage, then restored to
    /// this owner. Its drawable stays live throughout the handoff.
    var viewportView: UIView { sceneView }

    /// In this view's coordinates; always the same aspect ratio at both ends of
    /// the workspace transition, so resizing preserves the camera composition.
    var transitionContentFrame: CGRect {
        layoutIfNeeded()
        return sceneView.frame
    }

    init(name _: String, probe _: Bool = false) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        scene.background.contents = UIColor.clear
        sceneView.scene = scene
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = false
        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.isUserInteractionEnabled = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        addSubview(sceneView)
        previewStatus.text = "No screenshot published"
        previewStatus.textColor = .secondaryLabel
        previewStatus.font = .preferredFont(forTextStyle: .subheadline)
        previewStatus.textAlignment = .center
        previewStatus.numberOfLines = 0
        previewStatus.adjustsFontForContentSizeCategory = true
        addSubview(previewStatus)
        sceneView.isHidden = true
        scene.rootNode.addChildNode(phone)
        buildPhone()
        buildStudio()
        setPose(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(name:probe:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewStatus.frame = bounds.insetBy(dx: 20, dy: 20)
        let height = min(bounds.height, bounds.width / Self.viewportAspect)
        let size = CGSize(width: height * Self.viewportAspect, height: height)
        let frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        if sceneView.superview === self, sceneView.frame != frame {
            sceneView.frame = frame
            sceneView.setNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneView.preferredFramesPerSecond = min(120, window?.screen.maximumFramesPerSecond ?? 60)
        updatePlayback()
        sceneView.setNeedsDisplay()
    }

    /// Only real screenshots enter the display. Without one the screen remains
    /// neutral and empty; the enclosing UI can show its own unavailable state.
    func setScreenshot(_ image: UIImage?) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        display.diffuse.contentsTransform = SCNMatrix4Identity
        if let image, image.size.width > 0, image.size.height > 0 {
            screenshot = image
            hasScreenshot = true
            display.diffuse.contents = image
            // Center-crop UVs instead of stretching the screenshot. For the
            // matching iPhone capture ratio this removes only a narrow edge.
            let sourceAspect = image.size.width / image.size.height
            let scaleX = min(1, Self.screenAspect / sourceAspect)
            let scaleY = min(1, sourceAspect / Self.screenAspect)
            var crop = SCNMatrix4MakeScale(Float(scaleX), Float(scaleY), 1)
            crop.m41 = Float((1 - scaleX) / 2)
            crop.m42 = Float((1 - scaleY) / 2)
            display.diffuse.contentsTransform = crop
        } else {
            screenshot = nil
            hasScreenshot = false
            display.diffuse.contents = Self.canvas
        }
        SCNTransaction.commit()
        sceneView.isHidden = !hasScreenshot
        previewStatus.isHidden = hasScreenshot
        sceneView.setNeedsDisplay()
    }

    func setPreviewStatus(_ message: String) { previewStatus.text = message }

    /// Gallery (0) to workspace (1). A transition driver supplies progress each
    /// frame; slerp rotates the actual mesh, its normals, and its reflections.
    func setPose(_ progress: CGFloat) {
        poseProgress = progress.isFinite ? min(1, max(0, progress)) : 0
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let gallery = simd_quatf(angle: -0.085, axis: [0, 0, 1])
            * simd_quatf(angle: 0.52, axis: [0, 1, 0])
            * simd_quatf(angle: -0.50, axis: [1, 0, 0])
        let workspace = simd_quatf(angle: 0.10, axis: [0, 1, 0])
            * simd_quatf(angle: -0.10, axis: [1, 0, 0])
        phone.simdOrientation = simd_slerp(gallery, workspace, Float(poseProgress))
        phone.position = SCNVector3(0, 0.15, 0)
        // The upright phone has a taller projected silhouette. A small physical
        // dolly preserves breathing room without scaling or warping the mesh.
        cameraNode.position.z = 32 + 3 * Float(poseProgress)
        let foot = phone.convertPosition(SCNVector3(0, -3.71, 0), to: nil)
        contactShadowNode.position = SCNVector3(foot.x, foot.y - 0.27, -1.2)
        SCNTransaction.commit()
        sceneView.setNeedsDisplay()
    }

    /// Continuous rendering is limited to the transition or direct interaction.
    /// Normal scene changes still request a frame while the view is idle.
    func setAnimating(_ animating: Bool) {
        animationRequested = animating
        updatePlayback()
        if !animating {
            SCNTransaction.flush()
            sceneView.setNeedsDisplay()
        }
    }

    private func updatePlayback() {
        let playing = animationRequested && sceneView.window != nil
        sceneView.rendersContinuously = playing
        sceneView.isPlaying = playing
    }

    private func buildPhone() {
        let titanium = Self.metal(UIColor(red: 0.39, green: 0.40, blue: 0.41, alpha: 1), roughness: 0.23)
        titanium.setValue(0.75, forKey: "studioReflectionStrength")
        let polished = Self.metal(UIColor(white: 0.67, alpha: 1), roughness: 0.12)
        polished.setValue(1.05, forKey: "studioReflectionStrength")
        let darkEdge = Self.metal(UIColor(white: 0.012, alpha: 1), roughness: 0.08)
        // Glass is a dielectric: dark face-on, with a bright grazing reflection.
        // Treating this seal as dark metal made it a uniformly black outline.
        darkEdge.metalness.contents = 0.0
        darkEdge.clearCoat.contents = 1.0
        darkEdge.clearCoatRoughness.contents = 0.04
        darkEdge.setValue(0.95, forKey: "studioReflectionStrength")
        let black = Self.matte(UIColor(white: 0.014, alpha: 1), roughness: 0.32)
        let antenna = Self.matte(UIColor(white: 0.39, alpha: 1), roughness: 0.6)

        // SCNShape keeps long edges truly straight and rounds only the outline.
        // Its chamfer is independent from the outline's corner radius; an SCNBox
        // would constrain the entire phone's corner radius to its thin depth.
        addSlab(width: 3.55, height: 7.42, radius: 0.51, depth: 0.39,
                chamfer: 0.044, z: 0, material: titanium, name: "Titanium chassis")
        addSlab(width: 3.52, height: 7.39, radius: 0.50, depth: 0.022,
                chamfer: 0.008, z: -0.195, material: darkEdge, name: "Back glass seam")
        addSlab(width: 3.552, height: 7.422, radius: 0.511, depth: 0.015,
                chamfer: 0.005, z: -0.154, material: polished, name: "Rear titanium hairline")
        // An exposed rounded rail has continuously varying normals. The old
        // flat slab sat behind the glass and could only produce a hard hairline.
        addRim(width: 3.504, height: 7.374, cornerRadius: 0.488,
               radialRadius: 0.023, depthRadius: 0.040, z: 0.180,
               material: polished)
        addSlab(width: 3.49, height: 7.36, radius: 0.49, depth: 0.035,
                chamfer: 0.010, z: 0.205, material: darkEdge, name: "Black glass edge")
        addSlab(width: 3.477, height: 7.347, radius: 0.483, depth: 0.030,
                chamfer: 0.013, z: 0.221, material: darkEdge, name: "Cover glass seal")

        let screen = SCNPlane(width: 3.34, height: 7.205)
        screen.cornerRadius = 0.425
        screen.cornerSegmentCount = 24
        display.lightingModel = .constant
        display.diffuse.contents = Self.canvas
        display.diffuse.magnificationFilter = .linear
        display.diffuse.minificationFilter = .linear
        display.diffuse.mipFilter = .linear
        screen.firstMaterial = display
        let screenNode = SCNNode(geometry: screen)
        screenNode.position.z = 0.240
        screenNode.castsShadow = false
        phone.addChildNode(screenNode)

        let island = addSlab(width: 1.00, height: 0.25, radius: 0.125, depth: 0.012,
                             chamfer: 0.004, z: 0.253, material: black, name: "Dynamic Island")
        island.position.y = 3.265
        let lens = SCNSphere(radius: 0.041)
        lens.segmentCount = 20
        lens.firstMaterial = Self.metal(UIColor(red: 0.025, green: 0.042, blue: 0.06, alpha: 1), roughness: 0.12)
        let lensNode = SCNNode(geometry: lens)
        lensNode.position = SCNVector3(0.343, 3.265, 0.232)
        lensNode.castsShadow = false
        phone.addChildNode(lensNode)

        func sideButton(x: Float, y: Float, length: CGFloat) {
            let recessNode = addSlab(width: 0.159, height: length + 0.065, radius: 0.077,
                                    depth: 0.018, chamfer: 0.005, z: 0, material: black, name: "Button recess")
            recessNode.eulerAngles.y = x < 0 ? -.pi / 2 : .pi / 2
            recessNode.position = SCNVector3(x, y, -0.004)
            let buttonNode = addSlab(width: 0.121, height: length, radius: 0.059,
                                   depth: 0.038, chamfer: 0.009, z: 0, material: polished, name: "Titanium button")
            buttonNode.eulerAngles.y = x < 0 ? -.pi / 2 : .pi / 2
            buttonNode.position = SCNVector3(x + (x < 0 ? -0.019 : 0.019), y, -0.004)
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

    /// Sweeps an elliptical metal bead around a rounded rectangle. Explicit
    /// normals preserve the curved specular band even when it is only a few
    /// screen pixels wide; the inner half disappears beneath the glass seal.
    private func addRim(width: Float, height: Float, cornerRadius: Float,
                        radialRadius: Float, depthRadius: Float, z: Float,
                        material: SCNMaterial) {
        let cornerSteps = 28
        let crossSteps = 20
        var centers: [SIMD2<Float>] = []
        var outward: [SIMD2<Float>] = []
        let halfWidth = width / 2 - cornerRadius
        let halfHeight = height / 2 - cornerRadius
        let corners: [SIMD2<Float>] = [
            [halfWidth, halfHeight], [-halfWidth, halfHeight],
            [-halfWidth, -halfHeight], [halfWidth, -halfHeight]
        ]
        for (index, center) in corners.enumerated() {
            for step in 0...cornerSteps {
                let angle = (Float(index) + Float(step) / Float(cornerSteps)) * .pi / 2
                let normal = SIMD2<Float>(cos(angle), sin(angle))
                centers.append(center + normal * cornerRadius)
                outward.append(normal)
            }
        }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for (index, center) in centers.enumerated() {
            for step in 0..<crossSteps {
                let angle = Float(step) / Float(crossSteps) * 2 * .pi
                let radial = outward[index] * cos(angle)
                let position = center + radial * radialRadius
                vertices.append(SCNVector3(position.x, position.y, z + sin(angle) * depthRadius))
                let normal = simd_normalize(SIMD3<Float>(radial.x / radialRadius,
                                                        radial.y / radialRadius,
                                                        sin(angle) / depthRadius))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }
        var indices: [Int32] = []
        for ring in centers.indices {
            let nextRing = (ring + 1) % centers.count
            for step in 0..<crossSteps {
                let nextStep = (step + 1) % crossSteps
                let a = Int32(ring * crossSteps + step)
                let b = Int32(nextRing * crossSteps + step)
                let c = Int32(nextRing * crossSteps + nextStep)
                let d = Int32(ring * crossSteps + nextStep)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                            SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.name = "Rounded titanium front rail"
        phone.addChildNode(node)
    }

    private func buildStudio() {
        let camera = SCNCamera()
        camera.fieldOfView = 13.75
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 100
        // Preserve the unlit display/floor colors so the transparent viewport
        // blends into UIKit's identical ivory instead of exposing a rectangle.
        camera.wantsHDR = false
        camera.exposureOffset = 0
        camera.bloomIntensity = 0
        camera.wantsDepthOfField = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 32)
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode

        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.0

        let key = SCNLight()
        key.type = .directional
        key.intensity = 850
        key.temperature = 5400
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
        keyNode.position = SCNVector3(-3, 12, 8)
        keyNode.look(at: SCNVector3(0, -1, 0))
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .area
        // SceneKit defaults drawsArea to true: the tilted softbox itself can
        // enter the camera frustum as a clipped, cream-colored triangle.
        fill.drawsArea = false
        fill.intensity = 950
        fill.color = UIColor(white: 1, alpha: 1)
        fill.temperature = 5400
        fill.areaExtents = SIMD3<Float>(1.6, 8, 0)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(-4.3, 2.0, -1.15)
        fillNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fillNode)

        let lowerStrip = SCNLight()
        lowerStrip.type = .area
        lowerStrip.drawsArea = false
        lowerStrip.intensity = 360
        lowerStrip.color = UIColor(white: 0.96, alpha: 1)
        lowerStrip.areaExtents = SIMD3<Float>(4.5, 0.6, 0)
        let lowerNode = SCNNode()
        lowerNode.light = lowerStrip
        lowerNode.position = SCNVector3(0.9, -6, -1.5)
        lowerNode.look(at: SCNVector3(0, -2.5, 0))
        scene.rootNode.addChildNode(lowerNode)

        let rim = SCNLight()
        rim.type = .area
        rim.drawsArea = false
        rim.intensity = 260
        rim.color = UIColor(white: 1, alpha: 1)
        rim.areaExtents = SIMD3<Float>(1.3, 3.8, 0)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(7, 6.5, 2.4)
        rimNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(rimNode)

        // Broad ambient contact shadow anchors the floating device. A
        // transparent falloff avoids a visible floor horizon on the open canvas.
        let contact = SCNPlane(width: 4.3, height: 1.1)
        let contactMaterial = SCNMaterial()
        contactMaterial.lightingModel = .constant
        contactMaterial.diffuse.contents = Self.contactShadow()
        contactMaterial.writesToDepthBuffer = false
        contact.firstMaterial = contactMaterial
        contactShadowNode.geometry = contact
        contactShadowNode.castsShadow = false
        scene.rootNode.addChildNode(contactShadowNode)
    }

    private static func contactShadow() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 192), format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 256, y: 96); cg.scaleBy(x: 1, y: 0.375)
            let colors = [UIColor.black.withAlphaComponent(0.38).cgColor, UIColor.black.withAlphaComponent(0.16).cgColor, UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.24, 1])!
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 255, options: [])
        }
    }

    private static func metal(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = 0.95
        material.roughness.contents = roughness
        material.clearCoat.contents = 0.25
        material.clearCoatRoughness.contents = 0.10
        material.shaderModifiers = [.fragment: studioReflections]
        material.setValue(0.55, forKey: "studioReflectionStrength")
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

    /// Finite studio cards supplement the distant environment map. A perfectly
    /// flat titanium side otherwise samples almost one environment color along
    /// its entire height. Ray/card intersections give that side a broad falling
    /// highlight and the curved bevels narrow, view-dependent reflections.
    /// Card coverage replaces the corresponding distant reflection; Fresnel
    /// reflectance keeps dark glass and metal distinct without additive glow.
    /// Uses SceneKit's documented Metal fragment-modifier surface/view uniforms.
    private static let studioReflections = """
    #pragma arguments
    float studioReflectionStrength;
    #pragma body
    float3 studioV = normalize(_surface.view);
    float3 studioN = normalize(_surface.normal);
    float3 studioR = normalize((scn_frame.inverseViewTransform * float4(reflect(-studioV, studioN), 0.0)).xyz);
    float3 studioP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
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
    float studioCoverage = max(max(studioBroad * 0.55, studioStrip),
                               max(studioLower * 0.88, studioRim));
    float studioFacing = saturate(dot(studioN, studioV));
    float3 studioF0 = mix(float3(0.04), _surface.diffuse.rgb, saturate(_surface.metalness));
    float3 studioFresnel = studioF0 + (1.0 - studioF0) * pow(1.0 - studioFacing, 5.0);
    float3 studioRadiance = float3(1.0, 0.988, 0.972) * 1.45 * studioFresnel;
    _output.color.rgb = mix(_output.color.rgb, studioRadiance,
                           saturate(studioCoverage * studioReflectionStrength));
    """

    /// Neutral reflection cards with distinct dark gaps. The narrow vertical
    /// strip produces a crisp rim instead of a uniformly pale plastic edge.
    private static func studioEnvironment() -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.14, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let colors = [UIColor(white: 0.48, alpha: 1).cgColor, UIColor(white: 0.055, alpha: 1).cgColor, UIColor(white: 0.22, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.53, 1])!
            context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 512), options: [])
            context.cgContext.setShadow(offset: .zero, blur: 18, color: UIColor.white.withAlphaComponent(0.65).cgColor)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 170, y: 90, width: 84, height: 330), cornerRadius: 14).fill()
            context.cgContext.setShadow(offset: .zero, blur: 8, color: UIColor.white.withAlphaComponent(0.55).cgColor)
            UIBezierPath(roundedRect: CGRect(x: 560, y: 52, width: 29, height: 408), cornerRadius: 8).fill()
            UIColor(white: 0.70, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 810, y: 140, width: 145, height: 245), cornerRadius: 22).fill()
        }
    }
}
