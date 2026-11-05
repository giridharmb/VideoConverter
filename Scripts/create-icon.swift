#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Assets.xcassets")
let directory = root.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 212, yRadius: 212)
        NSGradient(starting: NSColor(red: 0.04, green: 0.15, blue: 0.30, alpha: 1), ending: NSColor(red: 0.05, green: 0.69, blue: 0.81, alpha: 1))!.draw(in: background, angle: 45)
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let rear = NSBezierPath(roundedRect: NSRect(x: 202, y: 340, width: 530, height: 410), xRadius: 65, yRadius: 65)
        rear.lineWidth = 24; rear.stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let frame = NSBezierPath(roundedRect: NSRect(x: 286, y: 252, width: 530, height: 410), xRadius: 65, yRadius: 65)
        frame.lineWidth = 28; frame.stroke()
        NSColor.white.setFill()
        let play = NSBezierPath(); play.move(to: NSPoint(x: 482, y: 354)); play.line(to: NSPoint(x: 482, y: 566)); play.line(to: NSPoint(x: 662, y: 460)); play.close(); play.fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
        entries.append(["size": "\(size)x\(size)", "idiom": "mac", "filename": filename, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: .prettyPrinted).write(to: root.appendingPathComponent("Contents.json"))
