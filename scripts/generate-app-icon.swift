#!/usr/bin/env swift
import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "TokenMeter/Resources/TokenMeter.icns")
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")
let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

func image(size: Int) -> NSImage {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()
    defer { canvas.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = CGFloat(size) * 0.225
    NSGradient(
        starting: NSColor(calibratedRed: 0.04, green: 0.11, blue: 0.23, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.47, blue: 0.65, alpha: 1)
    )!.draw(in: NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner), angle: -45)

    let meterWidth = CGFloat(size) * 0.58
    let meterHeight = CGFloat(size) * 0.32
    let meter = NSRect(x: (CGFloat(size) - meterWidth) / 2, y: CGFloat(size) * 0.34, width: meterWidth, height: meterHeight)
    let stroke = CGFloat(size) * 0.055
    NSColor.white.withAlphaComponent(0.92).setStroke()
    let outline = NSBezierPath(roundedRect: meter, xRadius: meterHeight / 2, yRadius: meterHeight / 2)
    outline.lineWidth = stroke
    outline.stroke()

    let fill = NSRect(x: meter.minX + stroke, y: meter.minY + stroke, width: meter.width * 0.58, height: meter.height - stroke * 2)
    NSColor(calibratedRed: 0.35, green: 0.94, blue: 0.78, alpha: 1).setFill()
    NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()

    let tickX = meter.minX + meter.width * 0.76
    NSColor.white.withAlphaComponent(0.92).setStroke()
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: tickX, y: meter.minY + meter.height * 0.28))
    tick.line(to: NSPoint(x: tickX, y: meter.maxY - meter.height * 0.28))
    tick.lineWidth = stroke * 0.72
    tick.lineCapStyle = .round
    tick.stroke()
    return canvas
}

for (size, filename) in sizes {
    let bitmap = NSBitmapImageRep(data: image(size: size).tiffRepresentation!)!
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode \(filename)") }
    try data.write(to: iconsetURL.appendingPathComponent(filename))
}

let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", "-o", outputURL.path, iconsetURL.path]
try result.run()
result.waitUntilExit()
guard result.terminationStatus == 0 else { exit(result.terminationStatus) }
try fileManager.removeItem(at: iconsetURL)
