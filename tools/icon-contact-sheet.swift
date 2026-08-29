// icon-contact-sheet.swift
//
// Standalone contact-sheet generator for the menu bar icon redesign. Renders every
// candidate glyph (SF Symbols + custom NSBezierPath marks) in ON/OFF states, at both
// true menu bar size (22x22pt) and 4x (88x88pt), against both a light and a dark menu
// bar background. This is an exploration tool only: it does not pick a winner and it
// is not part of the app build (`hotspotd menubar --rebuild` compiles only
// AutoHotspot.swift and Wifi.swift).
//
// Usage:
//   swiftc -O -o /tmp/ah-iconsheet tools/icon-contact-sheet.swift
//   /tmp/ah-iconsheet [output-directory]   # defaults to the repo's build/
//
// Writes exactly two files into the output directory:
//   icon-contact-sheet-light.png
//   icon-contact-sheet-dark.png

import AppKit
import Foundation

// MARK: - Candidates

struct Candidate {
    let name: String
    let symbolName: String?               // nil for a custom-drawn mark
    let hasSlashVariant: Bool              // true only for symbols with a real ".slash" glyph
    let customDraw: ((NSRect) -> Void)?    // nil for an SF Symbol
}

/// Verified to exist on the macOS 26 SDK by a compiled probe.
let sfSymbolNames = [
    "personalhotspot",
    "wifi",
    "antenna.radiowaves.left.and.right",
    "dot.radiowaves.left.and.right",
    "dot.radiowaves.up.forward",
    "iphone.radiowaves.left.and.right",
    "radiowaves.right",
    "badge.plus.radiowaves.right",
    "link",
    "point.3.connected.trianglepath.dotted",
    "cellularbars",
    "bolt.horizontal",
]

/// Only these three ship a real ".slash" counterpart; everything else gets a drawn slash.
let sfSymbolsWithSlashVariant: Set<String> = [
    "personalhotspot",
    "wifi",
    "antenna.radiowaves.left.and.right",
]

// MARK: - Custom marks

/// Concentric broadcast arcs rising from a centre dot near the bottom of the canvas.
func drawBroadcastArcs(in rect: NSRect) {
    let s = rect.width / 22.0
    let cx = rect.midX
    let cy = rect.minY + rect.height * 0.30
    let dotR = 2.0 * s
    NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
    for i in 1...3 {
        let r = CGFloat(i) * 3.1 * s + dotR
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: 35, endAngle: 145)
        arc.lineWidth = 1.6 * s
        arc.lineCapStyle = .round
        arc.stroke()
    }
}

/// A phone silhouette with radiating arcs off its top corner.
func drawPhoneWaves(in rect: NSRect) {
    let s = rect.width / 22.0
    let phoneRect = NSRect(x: rect.minX + 2.0 * s, y: rect.minY + 2.0 * s, width: 7.0 * s, height: 11.5 * s)
    NSBezierPath(roundedRect: phoneRect, xRadius: 1.6 * s, yRadius: 1.6 * s).fill()
    let cx = phoneRect.maxX
    let cy = phoneRect.maxY
    for i in 1...3 {
        let r = CGFloat(i) * 2.9 * s
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: -20, endAngle: 65)
        arc.lineWidth = 1.6 * s
        arc.lineCapStyle = .round
        arc.stroke()
    }
}

/// A solid signal wedge (filled pie slice) fanning out from the bottom-left corner.
func drawSignalWedge(in rect: NSRect) {
    let s = rect.width / 22.0
    let apex = NSPoint(x: rect.minX + 3.0 * s, y: rect.minY + 3.0 * s)
    let path = NSBezierPath()
    path.move(to: apex)
    path.appendArc(withCenter: apex, radius: 15.0 * s, startAngle: 20, endAngle: 70)
    path.close()
    path.fill()
}

/// A centre dot with a single sweeping arc, suggesting motion/searching.
func drawDotSweep(in rect: NSRect) {
    let s = rect.width / 22.0
    let cx = rect.midX
    let cy = rect.midY
    let dotR = 2.2 * s
    NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 8.0 * s, startAngle: -60, endAngle: 210)
    arc.lineWidth = 1.8 * s
    arc.lineCapStyle = .round
    arc.stroke()
}

let candidates: [Candidate] =
    sfSymbolNames.map { name in
        Candidate(name: name, symbolName: name, hasSlashVariant: sfSymbolsWithSlashVariant.contains(name), customDraw: nil)
    } + [
        Candidate(name: "Broadcast Arcs (custom)", symbolName: nil, hasSlashVariant: false, customDraw: drawBroadcastArcs),
        Candidate(name: "Phone + Waves (custom)", symbolName: nil, hasSlashVariant: false, customDraw: drawPhoneWaves),
        Candidate(name: "Signal Wedge (custom)", symbolName: nil, hasSlashVariant: false, customDraw: drawSignalWedge),
        Candidate(name: "Dot + Sweep (custom)", symbolName: nil, hasSlashVariant: false, customDraw: drawDotSweep),
    ]

// MARK: - Glyph rendering

/// Renders an SF Symbol into a canvasSize x canvasSize template image, scaling the
/// symbol's point size proportionally so the 4x canvas still reads as the same mark.
func sfSymbolImage(name: String, canvasSize: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name) else { return nil }
    let pointSize: CGFloat = 15.0 * (canvasSize / 22.0)
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let configured = base.withSymbolConfiguration(config) else { return nil }
    configured.isTemplate = true
    let symbolSize = configured.size
    let img = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
        let origin = NSPoint(x: (rect.width - symbolSize.width) / 2, y: (rect.height - symbolSize.height) / 2)
        configured.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
        return true
    }
    img.isTemplate = true
    return img
}

/// Draws a 1.5pt (at true size, scaled proportionally at 4x) diagonal slash across an
/// already-rendered glyph, for every candidate that has no real ".slash" artwork.
func addSlash(to image: NSImage, canvasSize: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        let s = rect.width / 22.0
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 1.5 * s, y: rect.minY + 1.5 * s))
        path.line(to: NSPoint(x: rect.maxX - 1.5 * s, y: rect.maxY - 1.5 * s))
        path.lineWidth = 1.5 * s
        path.lineCapStyle = .round
        NSColor.black.setStroke()
        path.stroke()
        return true
    }
    img.isTemplate = true
    return img
}

/// Renders a custom NSBezierPath mark into a canvasSize x canvasSize template image.
func customMarkImage(draw: @escaping (NSRect) -> Void, canvasSize: CGFloat, off: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
        NSColor.black.set()
        draw(rect)
        if off {
            let s = rect.width / 22.0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 1.5 * s, y: rect.minY + 1.5 * s))
            path.line(to: NSPoint(x: rect.maxX - 1.5 * s, y: rect.maxY - 1.5 * s))
            path.lineWidth = 1.5 * s
            path.lineCapStyle = .round
            path.stroke()
        }
        return true
    }
    img.isTemplate = true
    return img
}

func glyphImage(for candidate: Candidate, on: Bool, canvasSize: CGFloat) -> NSImage {
    if let symbolName = candidate.symbolName {
        if !on && candidate.hasSlashVariant, let slashImg = sfSymbolImage(name: symbolName + ".slash", canvasSize: canvasSize) {
            return slashImg
        }
        guard let base = sfSymbolImage(name: symbolName, canvasSize: canvasSize) else {
            return NSImage(size: NSSize(width: canvasSize, height: canvasSize))
        }
        return on ? base : addSlash(to: base, canvasSize: canvasSize)
    }
    if let draw = candidate.customDraw {
        return customMarkImage(draw: draw, canvasSize: canvasSize, off: !on)
    }
    return NSImage(size: NSSize(width: canvasSize, height: canvasSize))
}

/// Tints a template (black-on-transparent) image to a solid color, masked by its alpha.
func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    color.set()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .destinationIn, fraction: 1.0)
    result.unlockFocus()
    return result
}

// MARK: - Sheet layout

let sheetMargin: CGFloat = 30
let labelColumnWidth: CGFloat = 190
let trueSizeBox: CGFloat = 54     // cell box for the 22x22 true-menu-bar-size glyph
let fourxBox: CGFloat = 112       // cell box for the 88x88 (4x) glyph
let columnSpacing: CGFloat = 20
let rowSpacing: CGFloat = 14
let headerHeight: CGFloat = 40
let titleHeight: CGFloat = 34

let sheetWidth =
    sheetMargin * 2 + labelColumnWidth + trueSizeBox * 2 + fourxBox * 2 + columnSpacing * 3
let sheetHeight =
    titleHeight + headerHeight + sheetMargin * 2
    + CGFloat(candidates.count) * (fourxBox + rowSpacing) - rowSpacing

func buildSheet(background: NSColor, tint: NSColor, title: String) -> NSImage {
    NSImage(size: NSSize(width: sheetWidth, height: sheetHeight), flipped: false) { _ in
        background.setFill()
        NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: tint,
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(at: NSPoint(x: sheetMargin, y: sheetHeight - titleHeight))

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tint,
        ]
        let headerY = sheetHeight - titleHeight - headerHeight + 12
        let xOn1 = sheetMargin + labelColumnWidth
        let xOff1 = xOn1 + trueSizeBox + columnSpacing
        let xOn4 = xOff1 + trueSizeBox + columnSpacing
        let xOff4 = xOn4 + fourxBox + columnSpacing
        NSAttributedString(string: "ON", attributes: headerAttrs)
            .draw(at: NSPoint(x: xOn1 + trueSizeBox / 2 - 8, y: headerY))
        NSAttributedString(string: "OFF", attributes: headerAttrs)
            .draw(at: NSPoint(x: xOff1 + trueSizeBox / 2 - 11, y: headerY))
        NSAttributedString(string: "ON 4x", attributes: headerAttrs)
            .draw(at: NSPoint(x: xOn4 + fourxBox / 2 - 16, y: headerY))
        NSAttributedString(string: "OFF 4x", attributes: headerAttrs)
            .draw(at: NSPoint(x: xOff4 + fourxBox / 2 - 20, y: headerY))

        let contentTop = sheetHeight - titleHeight - headerHeight - sheetMargin
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: tint,
        ]
        let borderColor = tint.withAlphaComponent(0.15)

        for (i, candidate) in candidates.enumerated() {
            let rowTop = contentTop - CGFloat(i) * (fourxBox + rowSpacing)
            let rowBottom = rowTop - fourxBox

            let labelStr = NSAttributedString(string: candidate.name, attributes: labelAttrs)
            labelStr.draw(at: NSPoint(x: sheetMargin, y: rowBottom + (fourxBox - labelStr.size().height) / 2))

            func drawCell(x: CGFloat, boxWidth: CGFloat, canvasSize: CGFloat, on: Bool) {
                let cellRect = NSRect(x: x, y: rowBottom, width: boxWidth, height: fourxBox)
                borderColor.setStroke()
                let borderPath = NSBezierPath(rect: cellRect.insetBy(dx: 0.5, dy: 0.5))
                borderPath.lineWidth = 1
                borderPath.stroke()

                let glyph = glyphImage(for: candidate, on: on, canvasSize: canvasSize)
                let tintedGlyph = tinted(glyph, color: tint)
                let origin = NSPoint(x: cellRect.midX - canvasSize / 2, y: cellRect.midY - canvasSize / 2)
                tintedGlyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            drawCell(x: xOn1, boxWidth: trueSizeBox, canvasSize: 22, on: true)
            drawCell(x: xOff1, boxWidth: trueSizeBox, canvasSize: 22, on: false)
            drawCell(x: xOn4, boxWidth: fourxBox, canvasSize: 88, on: true)
            drawCell(x: xOff4, boxWidth: fourxBox, canvasSize: 88, on: false)
        }
        return true
    }
}

// MARK: - PNG export

func savePNG(_ image: NSImage, to path: String, pixelScale: CGFloat) {
    let width = Int(image.size.width * pixelScale)
    let height = Int(image.size.height * pixelScale)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        FileHandle.standardError.write("error: could not allocate bitmap rep for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = image.size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("error: could not encode PNG for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("error: could not write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
let outputDir: String
if arguments.count > 1 {
    outputDir = arguments[1]
} else {
    let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = sourceDir.deletingLastPathComponent()
    outputDir = repoRoot.appendingPathComponent("build").path
}

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let lightBackground = NSColor(calibratedWhite: 0.949, alpha: 1.0)
let darkBackground = NSColor(calibratedWhite: 0.13, alpha: 1.0)

let lightSheet = buildSheet(background: lightBackground, tint: .black, title: "Auto Hotspot — Icon Candidates (Light Menu Bar)")
let darkSheet = buildSheet(background: darkBackground, tint: .white, title: "Auto Hotspot — Icon Candidates (Dark Menu Bar)")

savePNG(lightSheet, to: outputDir + "/icon-contact-sheet-light.png", pixelScale: 2.0)
savePNG(darkSheet, to: outputDir + "/icon-contact-sheet-dark.png", pixelScale: 2.0)

print("Wrote icon-contact-sheet-light.png and icon-contact-sheet-dark.png to \(outputDir)")
