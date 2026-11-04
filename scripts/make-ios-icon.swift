// Run from the repository root: swift scripts/make-ios-icon.swift
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0.035, green: 0.055, blue: 0.065, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let mint = NSColor(srgbRed: 0.48, green: 0.93, blue: 0.75, alpha: 1)
mint.setStroke()
let heights: [CGFloat] = [90, 180, 290, 400, 260, 180, 310, 190, 90]
for (index, height) in heights.enumerated() {
    let path = NSBezierPath()
    path.lineWidth = 30
    path.lineCapStyle = .round
    let x = CGFloat(280 + index * 58)
    path.move(to: NSPoint(x: x, y: 620 - height / 2))
    path.line(to: NSPoint(x: x, y: 620 + height / 2))
    path.stroke()
}
let text = "CJ" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 190, weight: .semibold), .foregroundColor: NSColor.white]
let textSize = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024 - textSize.width) / 2, y: 170), withAttributes: attributes)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("ios-app/CJ/Assets.xcassets")
let folder = root.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("AppIcon.png"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try #"{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
