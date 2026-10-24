// Renders the Vital line app icons (spec 30 → Logo and icon): the V heartbeat mark, run once by hand.
// swift scripts/gen-app-icon.swift <output dir>
import AppKit

func render(_ path: String, background: CGColor?, stroke: CGColor) {
    let size = 1024
    // Opaque 1024 px for the default and tinted icons (App Store rejects alpha); the dark variant keeps transparency.
    let info = background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    // One heartbeat: flat in, one symmetric dip, flat out (brand board 00, app icon row).
    let y = 590.0, depth = 250.0, half = 150.0
    ctx.move(to: CGPoint(x: 170, y: y))
    ctx.addLine(to: CGPoint(x: 512 - half, y: y))
    ctx.addLine(to: CGPoint(x: 512, y: y - depth))
    ctx.addLine(to: CGPoint(x: 512 + half, y: y))
    ctx.addLine(to: CGPoint(x: 854, y: y))
    ctx.setLineWidth(78); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(stroke); ctx.strokePath()
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
let pulse = CGColor(srgbRed: 1, green: 0x52 / 255.0, blue: 0x33 / 255.0, alpha: 1)
let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
render("\(out)/icon-default.png", background: black, stroke: pulse)
render("\(out)/icon-dark.png", background: nil, stroke: pulse)
render("\(out)/icon-tinted.png", background: black, stroke: white)
