// Rebuild the geometric app icon without external artwork or tools.
// swift -module-cache-path /tmp/agent-icon-module-cache scripts/generate-app-icons.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("agent comm ios/Assets.xcassets")
let teal = CGColor(red: 0.02, green: 0.43, blue: 0.42, alpha: 1)
let mint = CGColor(red: 0.50, green: 0.91, blue: 0.82, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)
let info: [String: Any] = ["author": "xcode", "version": 1]

func writeJSON(_ object: [String: Any], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data([10])).write(to: directory.appendingPathComponent("Contents.json"))
}

func bubble(_ context: CGContext, rect: CGRect, color: CGColor, rightTail: Bool) {
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 76, cornerHeight: 76, transform: nil))
    context.fillPath()
    let x = rightTail ? rect.maxX - 62 : rect.minX + 62
    context.move(to: CGPoint(x: x, y: rect.minY + 50))
    context.addLine(to: CGPoint(x: x, y: rect.minY - 64))
    context.addLine(to: CGPoint(x: rightTail ? x - 116 : x + 116, y: rect.minY + 12))
    context.closePath()
    context.fillPath()
}

func draw(_ context: CGContext, layer: String) {
    if layer == "all" || layer == "back" {
        context.setFillColor(teal)
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    if layer == "all" || layer == "dark" || layer == "middle" {
        bubble(context, rect: CGRect(x: 220, y: 424, width: 454, height: 324), color: white, rightTail: false)
    }
    if layer == "all" || layer == "dark" || layer == "front" {
        bubble(context, rect: CGRect(x: 378, y: 292, width: 426, height: 306), color: mint, rightTail: true)
        context.setFillColor(teal)
        for x in [CGFloat(491), 591, 691] {
            context.fillEllipse(in: CGRect(x: x - 24, y: 421, width: 48, height: 48))
        }
    }
}

func render(size: Int, layer: String = "all", opaque: Bool = true, to url: URL) throws {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: alpha.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(context, layer: layer)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
var images: [[String: Any]] = [
    ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "AppIcon-1024.png"],
    ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "AppIcon-dark.png",
     "appearances": [["appearance": "luminosity", "value": "dark"]]]
]
try writeJSON(["images": images, "info": info], to: appIcon)
try render(size: 1024, to: appIcon.appendingPathComponent("AppIcon-1024.png"))
try render(size: 1024, layer: "dark", opaque: false, to: appIcon.appendingPathComponent("AppIcon-dark.png"))
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "AppIcon-mac-\(points)@\(scale)x.png"
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
        try render(size: points * scale, to: appIcon.appendingPathComponent(filename))
    }
}
try writeJSON(["images": images, "info": info], to: appIcon)

let stack = catalog.appendingPathComponent("VisionAppIcon.solidimagestack")
try writeJSON(["info": info, "layers": ["Front", "Middle", "Back"].map {
    ["filename": "\($0).solidimagestacklayer"]
}], to: stack)
for name in ["Front", "Middle", "Back"] {
    let layer = stack.appendingPathComponent("\(name).solidimagestacklayer")
    try writeJSON(["info": info], to: layer)
    let content = layer.appendingPathComponent("Content.imageset")
    try writeJSON(["info": info, "images": [["filename": "\(name).png", "idiom": "vision", "scale": "2x"]]], to: content)
    try render(size: 1024, layer: name.lowercased(), opaque: name == "Back", to: content.appendingPathComponent("\(name).png"))
}
print("Generated iOS, macOS, and visionOS app icons.")
