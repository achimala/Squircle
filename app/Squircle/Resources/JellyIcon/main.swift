import AppKit
import Metal
import simd

// The app icon, drawn by the app's own jelly shader (JellyShader.swift), so
// the icon is the agent you see in the app. Run from app/Squircle:
//
//   swiftc -O Sources/UI/JellyShader.swift Resources/JellyIcon/main.swift -o /tmp/jelly-icon
//   /tmp/jelly-icon Resources/Assets.xcassets/AppIcon.appiconset
//
// writes the icon (layout A, user-chosen 2026-10-25) as AppIcon.png, with
// AppIcon-dark.png and AppIcon-tinted.png for iOS 26's appearances. Any other
// OUTPUT_DIR gets every candidate layout as NAME.png, NAME-dark.png and
// NAME-tinted.png, 1024 px square.

/// Pearl (Theme.swift), light and dark: the agent's violet "working" and the paper.
enum Pearl {
    static let working = (light: SIMD3<Float>(0x6E, 0x56, 0xF0) / 255, dark: SIMD3<Float>(0x9C, 0x8C, 0xFF) / 255)
    static let paper = (light: SIMD3<Float>(0xF5, 0xF5, 0xF2) / 255, dark: SIMD3<Float>(0x0E, 0x0F, 0x12) / 255)
}

enum Appearance { case light, dark, tinted }

/// The plain agent as the app draws it (JellyRenderer.uniforms in Jelly.swift),
/// its body `size` points square centred at `center`, `scale` pixels a point.
func agent(center: SIMD2<Float>, size: Float, scale: Float, appearance: Appearance,
           gaze: SIMD2<Float> = .zero, strength: Float = 0.85) -> JellyUniforms {
    let tint: SIMD3<Float> = switch appearance {
    case .light: Pearl.working.light
    case .dark: Pearl.working.dark
    // The system tints by luminance: a pale grey jelly, dark eyes.
    case .tinted: SIMD3(0.95, 0.95, 0.95)
    }
    // The app's default pose: turned a little left, its top showing.
    return JellyUniforms(
        // Denser when tinted, so it reads as the tint, not grey.
        tint: SIMD4(tint, appearance == .tinted ? 1.5 : strength), fill: SIMD4(1, 1, 1, 0),
        face: SIMD4(1, 0, 0, 0), inverse: SIMD4(1, 0, 0, 1),
        creature: SIMD4(center.x, center.y, 34, 0),
        pose: SIMD4(-0.3, -0.4, 0, 0),
        gaze: SIMD4(gaze.x, gaze.y, center.x, center.y),
        bridge: SIMD4(0, 1, 0, 0), stubs: SIMD4(0, 0, size / 34, 0),
        look: JellyUniforms.plainLook,
        // The app's agent wears its soap film, at the start of its drift.
        film: appearance == .tinted ? .zero : SIMD4(1, 1, 0, 0),
        center: SIMD2(-1e4, -1e4), half: SIMD2(1, 1), origin: SIMD2(0, 0),
        scale: scale, radius: 1, pillow: 0, time: 0, churn: 0, opened: 0,
        dark: appearance == .dark ? 1 : 0, mode: 0)
}

let pixels = 1024

/// Renders one jelly to a premultiplied BGRA image the icon's size.
func render(_ uniforms: JellyUniforms) -> CGImage {
    guard let device = JellyRenderer.device, let queue = JellyRenderer.queue, let pipeline = JellyRenderer.pipeline,
          let commands = queue.makeCommandBuffer() else { fatalError("No Metal") }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError("No texture") }
    var u = uniforms
    guard JellyRenderer.encode(&u, into: texture, on: commands, pipeline: pipeline) else { fatalError("No encoder") }
    commands.commit()
    commands.waitUntilCompleted()
    var bytes = Data(count: pixels * pixels * 4)
    bytes.withUnsafeMutableBytes { raw in
        texture.getBytes(raw.baseAddress!, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
    }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                   provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// A 1024 px canvas in top-left-origin pixels; `opaque` false leaves the
/// background transparent (the system's dark icon backdrop shows through).
func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    return context.makeImage()!
}

func color(_ c: SIMD3<Float>, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: a)
}

/// Draws a top-left-origin image into the flipped context.
func place(_ image: CGImage, in context: CGContext) {
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.restoreGState()
}

func background(_ appearance: Appearance, page: SIMD3<Float>, in context: CGContext) {
    switch appearance {
    case .light: context.setFillColor(color(page))
    case .dark: return
    case .tinted: context.setFillColor(CGColor(gray: 0, alpha: 1))
    }
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
}

/// One candidate, drawn for each appearance. The shader works in points
/// (its bevels and eyes are sized for the app), so each layout picks how many
/// points the icon spans and scales pixels to match.
struct Layout {
    let name: String
    let draw: (Appearance, CGContext) -> Void
}

/// Where the jelly's visual mass sits, in pixels: each pixel weighted by how
/// far it is from `page` once drawn on it (body, eyes, highlight, side),
/// rather than by its bounding box.
func massCentre(_ jelly: CGImage, on page: SIMD3<Float>) -> SIMD2<Float> {
    let data = jelly.dataProvider!.data! as Data
    var total: Float = 0, x: Float = 0, y: Float = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for row in 0..<pixels {
            for column in 0..<pixels {
                // BGRA, premultiplied: on the page it is rgb + page·(1 − a).
                let i = (row * pixels + column) * 4
                let a = Float(p[i + 3]) / 255
                guard a > 0 else { continue }
                let rgb = SIMD3(Float(p[i + 2]), Float(p[i + 1]), Float(p[i])) / 255
                let d = rgb - page * a
                let w = (d * d).sum().squareRoot()
                total += w; x += w * Float(column); y += w * Float(row)
            }
        }
    }
    return SIMD2(x, y) / total
}

/// One jelly, alone, `fraction` of the icon wide, its visual mass in the
/// middle (measured on its light look, so every appearance lines up), then
/// `nudge` of the icon's width to the right.
func lone(_ appearance: Appearance, fraction: Float, page: SIMD3<Float>, strength: Float, in context: CGContext,
          dark: Bool = false, nudge: Float = 0) {
    let size: Float = 40, width = size / fraction, scale = Float(pixels) / width
    background(appearance, page: page, in: context)
    let shown: Appearance = appearance == .light && dark ? .dark : appearance
    let measured: Appearance = dark ? .dark : .light
    func jelly(_ look: Appearance, at centre: SIMD2<Float>) -> JellyUniforms {
        agent(center: centre, size: size, scale: scale, appearance: look, gaze: SIMD2(0.3, 0.2), strength: strength)
    }
    let middle = SIMD2(width / 2, width / 2)
    let off = massCentre(render(jelly(measured, at: middle)), on: page) / scale - middle
    place(render(jelly(shown, at: middle - off + SIMD2(width * nudge, 0))), in: context)
}

let layouts: [Layout] = [
    // A: the soap-film agent on the app's pearl paper, a touch right of its
    // mass centre (user, 2026-10-25: it read slightly left).
    Layout(name: "a-cream") { appearance, context in
        lone(appearance, fraction: 0.6, page: Pearl.paper.light, strength: 1.15, in: context, nudge: 0.0125)
    },
    // B: the dark-mode jelly on the dark paper.
    Layout(name: "b-dark") { appearance, context in
        lone(appearance, fraction: 0.6, page: Pearl.paper.dark, strength: 1.0, in: context, dark: true)
    },
    // C: as on Home while it works, peeking over a device's top edge.
    Layout(name: "c-peek") { appearance, context in
        let size: Float = 40, width = size / 0.46, scale = Float(pixels) / width
        background(appearance, page: Pearl.paper.light, in: context)
        let edge = CGFloat(pixels) * 0.5
        let u = agent(center: SIMD2(width / 2, Float(edge) / scale - size * 0.02), size: size, scale: scale,
                      appearance: appearance, gaze: SIMD2(0, 1.0), strength: appearance == .dark ? 1.0 : 1.15)
        place(render(u), in: context)
        // The device: a dark bezel around a screen, its top edge across the middle.
        let device = CGRect(x: CGFloat(pixels) * 0.17, y: edge, width: CGFloat(pixels) * 0.66, height: CGFloat(pixels) * 0.8)
        let radius = device.width * 0.2
        let bezel: CGColor, screen: CGColor
        switch appearance {
        case .light: (bezel, screen) = (color(SIMD3(0.11, 0.114, 0.133)), color(SIMD3(0.91, 0.91, 0.90)))
        case .dark: (bezel, screen) = (color(SIMD3(0.33, 0.33, 0.35)), color(SIMD3(0.12, 0.12, 0.14)))
        case .tinted: (bezel, screen) = (CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.12, alpha: 1))
        }
        context.setFillColor(bezel)
        context.addPath(CGPath(roundedRect: device, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let inset = device.width * 0.045
        let glass = device.insetBy(dx: inset, dy: inset)
        context.setFillColor(screen)
        context.addPath(CGPath(roundedRect: glass, cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil))
        context.fillPath()
        // The island.
        let island = CGRect(x: device.midX - device.width * 0.14, y: glass.minY + inset * 0.9,
                            width: device.width * 0.28, height: inset * 1.5)
        context.setFillColor(bezel)
        context.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
        context.fillPath()
    },
]

/// PNG data; opaque appearances drop the alpha channel (the store rejects it).
func png(_ image: CGImage, opaque: Bool) -> Data {
    var image = image
    if opaque {
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        image = context.makeImage()!
    }
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("PNG") }
    return data
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let catalog = output.pathExtension == "appiconset"
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for layout in catalog ? [layouts[0]] : layouts {
    for (appearance, suffix) in [(Appearance.light, ""), (.dark, "-dark"), (.tinted, "-tinted")] {
        let image = canvas { layout.draw(appearance, $0) }
        let name = catalog ? "AppIcon" : layout.name
        try png(image, opaque: appearance != .dark).write(to: output.appendingPathComponent("\(name)\(suffix).png"))
    }
}
