import AppKit
import ImageIO

// usage: iconrender <template|original> <in.svg> <out.png> <size> <fgHex> <bgHex>
//
//   template —— 模拟 SwiftUI `.renderingMode(.template)`：丢掉 SVG 的全部颜色，
//               只取 alpha 当遮罩，填成 fg 色。app 里绝大多数图标走这条。
//   original —— 保留 SVG 自带配色，直接渲染。Homebrew / Tray 走这条。
//
// 两种模式都把结果合成到 bg 底色上（深色版白色图标在白底上会隐形，必须带底色）。
//
// ⚠️ 全程用 NSBitmapImageRep + 逐像素，不要用 CGContext 画 CGImage。
//    实测：纯 CGContext 里 `draw(cgImage)` 会把图整个上下翻过来（`NSGraphicsContext(cgContext:flipped:)`
//    的 flipped 传真传假都一样），Homebrew 的苹果会跑到杯子底下去。
//    逐像素慢一点，但方向由 colorAt 的左上角原点定义，没有歧义。
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

// ---- 1. 渲染 SVG 到透明画布，aspect-fit 居中 ----
let svgRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
// planes 传 nil 时这块内存是「未初始化」的，必须自己清零，否则透明区是随机噪声
memset(svgRep.bitmapData!, 0, svgRep.bytesPerRow * size)
// NSImage 的 size 对 SVG 就是 viewBox 尺寸；万一拿到 0 就退回用 1024 方阵
var s = img.size
if s.width <= 0 || s.height <= 0 { s = NSSize(width: 1024, height: 1024) }
// 内缩一点，别让方形图标贴边（方形图标 fit 后会顶满画布，看着很挤）
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

// ---- 2. 逐像素：template 换色 + 合成到底色 ----
// NSBitmapImageRep 默认 RGBA 非预乘、行序从上到下，跟 PNG 一致，所以直接按字节读写不用管翻转。
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
