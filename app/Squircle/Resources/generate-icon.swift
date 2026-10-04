import AppKit

// Reproducible vector source for the app icon; run from app/Squircle.
let size = NSSize(width: 1024, height: 1024)
guard let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                             bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Could not create icon bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
NSColor(calibratedRed: 0.068, green: 0.073, blue: 0.089, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor(calibratedRed: 0.750, green: 0.711, blue: 0.953, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 166, y: 166, width: 692, height: 692), xRadius: 222, yRadius: 222).fill()
NSGraphicsContext.saveGraphicsState()
let transform = AffineTransform(translationByX: 512, byY: 512)
var rotated = transform
rotated.rotate(byDegrees: 12)
(rotated as NSAffineTransform).concat()
let ring = NSBezierPath(roundedRect: NSRect(x: -165, y: -165, width: 330, height: 330), xRadius: 101, yRadius: 101)
ring.lineWidth = 43
NSColor(calibratedRed: 0.068, green: 0.073, blue: 0.089, alpha: 1).setStroke()
ring.stroke()
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedRed: 0.068, green: 0.073, blue: 0.089, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 636, y: 636, width: 71, height: 71)).fill()
NSGraphicsContext.restoreGraphicsState()
guard let rendered = canvas.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
try png.write(to: URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset/Squircle.png"))
