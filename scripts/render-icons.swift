#!/usr/bin/env swift

// Renders the app icon (iOS only) into Sources/DuocbApp/Assets.xcassets/
// AppIcon.appiconset and emits a source-of-truth icon.svg, mirroring the flow
// in ../flextunnel-ios/scripts/render-icons.swift.
//
// Run:  swift scripts/render-icons.swift
//
// Motif: two overlapping clipboard cards (it's a clipboard-sharing app
// between two devices) over a blue gradient, matching the sibling desktop
// app's icon (../duocb/crates/duocb/icons/icon.svg). Dark and tinted
// appearance variants are provided for iOS.

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

/// One clipboard card: a rounded board with a clip tab straddling its top
/// edge, and optionally a stroked tab outline and content lines. Drawn in a
/// local frame centered on the card, +y up — the caller translates/rotates.
func drawCard(
    in context: CGContext, size s: CGFloat,
    boardFill: CGColor, tabFill: CGColor, tabStroke: CGColor?, contentFill: CGColor?
) {
    let bw = s * 0.3633
    let bh = s * 0.4375
    let board = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
    context.setFillColor(boardFill)
    context.addPath(CGPath(roundedRect: board, cornerWidth: s * 0.0527, cornerHeight: s * 0.0527, transform: nil))
    context.fillPath()

    // Clip tab, straddling the board's top edge.
    let cw = s * 0.1523
    let ch = s * 0.0547
    let tab = CGRect(x: -cw / 2, y: board.maxY - ch * 0.5, width: cw, height: ch)
    let tabPath = CGPath(roundedRect: tab, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil)
    context.setFillColor(tabFill)
    context.addPath(tabPath)
    context.fillPath()
    if let tabStroke {
        context.setStrokeColor(tabStroke)
        context.setLineWidth(s * 0.0039)
        context.addPath(tabPath)
        context.strokePath()
    }

    // Content lines, evenly spaced below the tab.
    if let contentFill {
        context.setFillColor(contentFill)
        let inset = s * 0.0605
        let lineH = s * 0.0293
        let widths = [bw - 2 * inset, bw - 2 * inset, (bw - 2 * inset) * 0.66]
        for (i, width) in widths.enumerated() {
            let y = board.maxY - s * 0.1602 - CGFloat(i) * s * 0.0605
            let line = CGRect(x: board.minX + inset, y: y, width: width, height: lineH)
            context.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
            context.fillPath()
        }
    }
}

/// Two overlapping clipboard cards — the "duo" in duocb — matching the
/// sibling desktop app's icon (../duocb/crates/duocb/icons/icon.svg).
func drawDuoClipboards(in context: CGContext, size: Int, palette: CardPalette) {
    let s = CGFloat(size)
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.0137), blur: s * 0.0176, color: palette.shadow)

    context.saveGState()
    context.translateBy(x: s * 0.4219, y: s * 0.5586)
    context.rotate(by: 11 * .pi / 180)
    drawCard(in: context, size: s, boardFill: palette.backBoard, tabFill: palette.backTab, tabStroke: nil, contentFill: nil)
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: s * 0.5625, y: s * 0.4258)
    context.rotate(by: -9 * .pi / 180)
    drawCard(
        in: context, size: s, boardFill: palette.frontBoard, tabFill: palette.frontTab,
        tabStroke: palette.frontTabStroke, contentFill: palette.content)
    context.restoreGState()
}

struct CardPalette {
    let backBoard: CGColor
    let backTab: CGColor
    let frontBoard: CGColor
    let frontTab: CGColor
    let frontTabStroke: CGColor?
    let content: CGColor
    let shadow: CGColor
}

func render(filename: String, background: (top: CGColor, bottom: CGColor)?, palette: CardPalette) {
    let context = makeContext(size: canvas)
    if let background {
        fillGradient(in: context, size: canvas, top: background.top, bottom: background.bottom)
    } else {
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }
    drawDuoClipboards(in: context, size: canvas, palette: palette)
    savePNG(context, to: outDir.appendingPathComponent(filename))
}

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}
func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
let white = rgb(1, 1, 1)

// MARK: - SVG source of truth

/// One `<g>` for a card, in SVG's native y-down space (mirrors `drawCard`).
func svgCard(cx: Double, cy: Double, rotateDeg: Double, s: Double, boardFill: String, tabFill: String, tabStroke: String?, contentFill: String?) -> String {
    let bw = s * 0.3633
    let bh = s * 0.4375
    let brx = s * 0.0527
    let cw = s * 0.1523
    let ch = s * 0.0547
    var out = """
      <g transform="translate(\(cx),\(cy)) rotate(\(rotateDeg))">
        <rect x="\(-bw / 2)" y="\(-bh / 2)" width="\(bw)" height="\(bh)" rx="\(brx)" fill="\(boardFill)"/>
        <rect x="\(-cw / 2)" y="\(-bh / 2 - ch / 2)" width="\(cw)" height="\(ch)" rx="\(ch / 2)" fill="\(tabFill)"\(tabStroke.map { " stroke=\"\($0)\" stroke-width=\"\(s * 0.0039)\"" } ?? "")/>
    """
    if let contentFill {
        let inset = s * 0.0605
        let lineH = s * 0.0293
        let widths = [bw - 2 * inset, bw - 2 * inset, (bw - 2 * inset) * 0.66]
        for (i, width) in widths.enumerated() {
            let y = -bh / 2 + s * 0.1602 - lineH + Double(i) * s * 0.0605
            out += "\n    <rect x=\"\(-bw / 2 + inset)\" y=\"\(y)\" width=\"\(width)\" height=\"\(lineH)\" rx=\"\(lineH / 2)\" fill=\"\(contentFill)\"/>"
        }
    }
    out += "\n  </g>"
    return out
}

func writeSVG(to url: URL) throws {
    let s = Double(canvas)
    // SVG y grows downward; card centers mirror the CG translations.
    let backCard = svgCard(
        cx: s * 0.4219, cy: s * (1 - 0.5586), rotateDeg: -11, s: s,
        boardFill: "#eaf3fe", tabFill: "#bcd8f7", tabStroke: nil, contentFill: nil)
    let frontCard = svgCard(
        cx: s * 0.5625, cy: s * (1 - 0.4258), rotateDeg: 9, s: s,
        boardFill: "#ffffff", tabFill: "#dcebfc", tabStroke: "#b7d6f6", contentFill: "#bcdafb")
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
      <defs>
        <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0" stop-color="#2E8BF0"/>
          <stop offset="1" stop-color="#1746C8"/>
        </linearGradient>
      </defs>
      <rect width="\(canvas)" height="\(canvas)" rx="\(s * 0.2227)" fill="url(#bg)"/>
    \(backCard)
    \(frontCard)
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

// Matches the sibling desktop app's blue gradient (../duocb/crates/duocb/icons/icon.svg).
let lightPalette = CardPalette(
    backBoard: rgba(0.918, 0.953, 0.996, 0.92), backTab: rgb(0.737, 0.847, 0.969),
    frontBoard: white, frontTab: rgb(0.863, 0.922, 0.988), frontTabStroke: rgb(0.718, 0.839, 0.965),
    content: rgb(0.737, 0.855, 0.984), shadow: rgba(0.047, 0.165, 0.388, 0.30))
let darkPalette = CardPalette(
    backBoard: rgba(0.851, 0.902, 0.965, 0.90), backTab: rgb(0.612, 0.706, 0.831),
    frontBoard: rgb(0.965, 0.976, 0.996), frontTab: rgb(0.784, 0.859, 0.961), frontTabStroke: rgb(0.596, 0.706, 0.878),
    content: rgb(0.643, 0.749, 0.902), shadow: rgba(0.0, 0.0, 0.02, 0.45))
let tintedPalette = CardPalette(
    backBoard: rgba(1, 1, 1, 0.55), backTab: rgba(1, 1, 1, 0.75),
    frontBoard: white, frontTab: rgba(1, 1, 1, 0.85), frontTabStroke: nil,
    content: rgba(1, 1, 1, 0.75), shadow: rgba(0, 0, 0, 0.35))

render(filename: "icon-light.png", background: (rgb(0.180, 0.545, 0.941), rgb(0.090, 0.275, 0.784)), palette: lightPalette)
render(filename: "icon-dark.png", background: (rgb(0.075, 0.184, 0.412), rgb(0.031, 0.078, 0.235)), palette: darkPalette)
render(filename: "icon-tinted.png", background: nil, palette: tintedPalette)
try writeSVG(to: repoRoot.appendingPathComponent("icon.svg"))
try writeContentsJSON()

print("rendered icons to \(outDir.path)")
