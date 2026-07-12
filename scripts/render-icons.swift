#!/usr/bin/env swift

// Renders the app icon (iOS only) into Sources/DuocbApp/Assets.xcassets/
// AppIcon.appiconset and emits a source-of-truth icon.svg, mirroring the flow
// in ../flextunnel-ios/scripts/render-icons.swift.
//
// Run:  swift scripts/render-icons.swift
//
// Motif: a clipboard (it's a clipboard-sharing app) with two content lines and
// a paired-sync arrow row, in a single bold white glyph over a teal gradient,
// with dark and tinted appearance variants for iOS.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024

// MARK: - Asset-catalog Contents.json model

struct Contents: Encodable {
    let images: [IconImage]
    let info: Info
}

struct IconImage: Encodable {
    let appearances: [Appearance]?
    let filename: String
    let idiom: String
    let platform: String?
    let size: String
}

struct Appearance: Encodable {
    let appearance: String
    let value: String
}

struct Info: Encodable {
    let author: String
    let version: Int
}

// MARK: - Paths

func absoluteURL(for path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return url.path.hasPrefix("/")
        ? url
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

let repoRoot = absoluteURL(for: CommandLine.arguments[0])
    .standardizedFileURL
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let outDir = repoRoot.appendingPathComponent("Sources/DuocbApp/Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing

func makeContext(size: Int) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 4 * size,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func savePNG(_ context: CGContext, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func fillGradient(in context: CGContext, size: Int, top: CGColor, bottom: CGColor) {
    let s = CGFloat(size)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
}

/// A clipboard: rounded board with a clip tab on top, two content lines, and a
/// two-way arrow row (the pairing) — all strokes, one glyph color.
func drawClipboard(in context: CGContext, size: Int, color: CGColor) {
    let s = CGFloat(size)
    let stroke = s * 0.042

    context.saveGState()
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineCap(.round)
    context.setLineWidth(stroke)

    // Board (CoreGraphics origin is bottom-left; the "top" is high y).
    let bw = s * 0.46
    let bh = s * 0.58
    let board = CGRect(x: (s - bw) / 2, y: (s - bh) / 2 - s * 0.02, width: bw, height: bh)
    context.addPath(CGPath(roundedRect: board, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
    context.strokePath()

    // Clip tab, straddling the board's top edge.
    let cw = s * 0.18
    let ch = s * 0.075
    let clip = CGRect(x: (s - cw) / 2, y: board.maxY - ch / 2, width: cw, height: ch)
    context.addPath(CGPath(roundedRect: clip, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil))
    context.setFillColor(color)
    context.fillPath()

    // Two content lines.
    let inset = s * 0.09
    for (i, width) in [bw - 2 * inset, (bw - 2 * inset) * 0.62].enumerated() {
        let y = board.maxY - s * 0.16 - CGFloat(i) * s * 0.10
        context.move(to: CGPoint(x: board.minX + inset, y: y))
        context.addLine(to: CGPoint(x: board.minX + inset + width, y: y))
        context.strokePath()
    }

    // Two-way arrow row near the board's bottom: the two paired devices.
    let ay = board.minY + s * 0.13
    let ax0 = board.minX + inset
    let ax1 = board.maxX - inset
    let head = s * 0.045
    context.move(to: CGPoint(x: ax0, y: ay))
    context.addLine(to: CGPoint(x: ax1, y: ay))
    context.strokePath()
    // Left arrowhead.
    context.move(to: CGPoint(x: ax0 + head, y: ay + head))
    context.addLine(to: CGPoint(x: ax0, y: ay))
    context.addLine(to: CGPoint(x: ax0 + head, y: ay - head))
    context.strokePath()
    // Right arrowhead.
    context.move(to: CGPoint(x: ax1 - head, y: ay + head))
    context.addLine(to: CGPoint(x: ax1, y: ay))
    context.addLine(to: CGPoint(x: ax1 - head, y: ay - head))
    context.strokePath()

    context.restoreGState()
}

func render(filename: String, background: (top: CGColor, bottom: CGColor)?, glyph: CGColor) {
    let context = makeContext(size: canvas)
    if let background {
        fillGradient(in: context, size: canvas, top: background.top, bottom: background.bottom)
    } else {
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }
    drawClipboard(in: context, size: canvas, color: glyph)
    savePNG(context, to: outDir.appendingPathComponent(filename))
}

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}
let white = rgb(1, 1, 1)

// MARK: - SVG source of truth

func writeSVG(to url: URL) throws {
    let s = Double(canvas)
    let bw = s * 0.46
    let bh = s * 0.58
    let bx = (s - bw) / 2
    // SVG y grows downward; mirror the CG layout.
    let by = (s - bh) / 2 + s * 0.02
    let cw = s * 0.18
    let ch = s * 0.075
    let inset = s * 0.09
    let stroke = s * 0.042
    let lineY1 = by + s * 0.16
    let lineY2 = by + s * 0.26
    let ay = by + bh - s * 0.13
    let head = s * 0.045
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
      <defs>
        <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0" stop-color="rgb(6%,62%,58%)"/>
          <stop offset="1" stop-color="rgb(3%,36%,40%)"/>
        </linearGradient>
      </defs>
      <rect width="\(canvas)" height="\(canvas)" fill="url(#bg)"/>
      <g fill="none" stroke="white" stroke-width="\(stroke)" stroke-linecap="round">
        <rect x="\(bx)" y="\(by)" width="\(bw)" height="\(bh)" rx="\(s * 0.05)"/>
        <line x1="\(bx + inset)" y1="\(lineY1)" x2="\(bx + bw - inset)" y2="\(lineY1)"/>
        <line x1="\(bx + inset)" y1="\(lineY2)" x2="\(bx + inset + (bw - 2 * inset) * 0.62)" y2="\(lineY2)"/>
        <line x1="\(bx + inset)" y1="\(ay)" x2="\(bx + bw - inset)" y2="\(ay)"/>
        <polyline points="\(bx + inset + head),\(ay - head) \(bx + inset),\(ay) \(bx + inset + head),\(ay + head)"/>
        <polyline points="\(bx + bw - inset - head),\(ay - head) \(bx + bw - inset),\(ay) \(bx + bw - inset - head),\(ay + head)"/>
      </g>
      <rect x="\((s - cw) / 2)" y="\(by - ch / 2)" width="\(cw)" height="\(ch)" rx="\(ch / 2)" fill="white"/>
    </svg>

    """
    try svg.data(using: .utf8)!.write(to: url, options: .atomic)
}

// MARK: - Contents.json

func writeContentsJSON() throws {
    let contents = Contents(
        images: [
            IconImage(appearances: nil, filename: "icon-light.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "dark")],
                filename: "icon-dark.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "tinted")],
                filename: "icon-tinted.png", idiom: "universal", platform: "ios", size: "1024x1024"),
        ],
        info: Info(author: "xcode", version: 1))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(contents)
    data.append(0x0A)
    try data.write(to: outDir.appendingPathComponent("Contents.json"), options: .atomic)
}

// MARK: - Run

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(filename: "icon-light.png", background: (rgb(0.06, 0.62, 0.58), rgb(0.03, 0.36, 0.40)), glyph: white)
render(filename: "icon-dark.png", background: (rgb(0.06, 0.20, 0.22), rgb(0.02, 0.09, 0.11)), glyph: rgb(0.80, 0.97, 0.94))
render(filename: "icon-tinted.png", background: nil, glyph: white)
try writeSVG(to: repoRoot.appendingPathComponent("icon.svg"))
try writeContentsJSON()

print("rendered icons to \(outDir.path)")
