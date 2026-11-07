import AppKit
import ImageIO

// 用法: iconrender <template|original> <in.svg> <out.png> <size> <fgHex> <bgHex>
let a = CommandLine.arguments
guard a.count >= 7 else { fatalError("usage: iconrender <template|original> <in.svg> <out.png> <size> <fgHex> <bgHex>") }
let mode = a[1], svgPath = a[2], outPath = a[3]
let size = Int(a[4])!
let fgHex = a[5], bgHex = a[6]

func rgb(_ s: String) -> (CGFloat, CGFloat, CGFloat) {
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    let v = UInt32(h, radix: 16)!
    return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
}
let fg = rgb(fgHex), bg = rgb(bgHex)

guard let img = NSImage(contentsOfFile: svgPath) else { fatalError("load fail: \(svgPath)") }

// MARK: - 渲染 SVG
let svgRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
memset(svgRep.bitmapData!, 0, svgRep.bytesPerRow * size)
var s = img.size
if s.width <= 0 || s.height <= 0 { s = NSSize(width: 1024, height: 1024) }
let inset = CGFloat(size) / 16
let avail = CGFloat(size) - inset * 2
let scale = min(avail / s.width, avail / s.height)
let w = s.width * scale, h = s.height * scale
let fit = CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: svgRep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// MARK: - 换色合成
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let src = svgRep.bitmapData!, dst = out.bitmapData!
let srcBPR = svgRep.bytesPerRow, dstBPR = out.bytesPerRow
let isTemplate = (mode == "template")
for y in 0..<size {
    for x in 0..<size {
        let i = y * srcBPR + x * 4
        let o = y * dstBPR + x * 4
        let al = CGFloat(src[i + 3]) / 255
        let (r, g, b) = isTemplate ? fg : (CGFloat(src[i]) / 255, CGFloat(src[i + 1]) / 255, CGFloat(src[i + 2]) / 255)
        dst[o]     = UInt8(((r * al + bg.0 * (1 - al)) * 255).rounded())
        dst[o + 1] = UInt8(((g * al + bg.1 * (1 - al)) * 255).rounded())
        dst[o + 2] = UInt8(((b * al + bg.2 * (1 - al)) * 255).rounded())
        dst[o + 3] = 255
    }
}

guard let png = out.representation(using: .png, properties: [:]) else { fatalError("png fail") }
try! png.write(to: URL(fileURLWithPath: outPath))
