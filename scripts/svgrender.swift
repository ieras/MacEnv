import AppKit
import WebKit

// 用法: svgrender.swift <svg路径> <输出png> <边长px>
let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else {
    FileHandle.standardError.write("usage: render.swift <svg> <out.png> <px>\n".data(using: .utf8)!)
    exit(1)
}
let svgURL = URL(fileURLWithPath: args[1])
let outPath = args[2]
let svgData = try! Data(contentsOf: svgURL)
let b64 = svgData.base64EncodedString()

let html = """
<!doctype html><html><head><style>
html,body{margin:0;padding:0;background:transparent}
img{width:\(size)px;height:\(size)px;display:block;object-fit:contain}
</style></head><body><img src="data:image/svg+xml;base64,\(b64)"></body></html>
"""

let config = WKWebViewConfiguration()
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size), configuration: config)
web.setValue(false, forKey: "drawsBackground")

final class State {
    var navDone = false
    var rep: NSBitmapImageRep?
    var failed = false
}
let state = State()

let handler = DoneHandler { ok in
    if !ok { state.failed = true; state.navDone = true; return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        web.takeSnapshot(with: nil) { image, _ in
            if let image,
               let data = image.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: data) {
                state.rep = bmp
            } else {
                state.failed = true
            }
            state.navDone = true
        }
    }
}
web.navigationDelegate = handler
web.loadHTMLString(html, baseURL: nil)

let deadline = Date().addingTimeInterval(30)
while !state.navDone && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard state.navDone, !state.failed, let rep = state.rep,
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render failed (navDone=\(state.navDone) failed=\(state.failed) hasRep=\(state.rep != nil))\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("OK \(outPath)")

final class DoneHandler: NSObject, WKNavigationDelegate {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("didFail: \(error)\n".data(using: .utf8)!)
        done(false)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("didFailProvisional: \(error)\n".data(using: .utf8)!)
        done(false)
    }
}
