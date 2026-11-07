// Release 包侧栏点击验收
import AppKit
import ApplicationServices
import CoreGraphics

let bundleID = "local.macenv.app"

func axAttribute(_ el: AXUIElement, _ key: CFString) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, key, &value) == .success ? value : nil
}

func axRole(_ el: AXUIElement) -> String {
    axAttribute(el, kAXRoleAttribute as CFString) as? String ?? ""
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    axAttribute(el, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axAttribute(el, kAXPositionAttribute as CFString),
          let s = axAttribute(el, kAXSizeAttribute as CFString) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func axBool(_ el: AXUIElement, _ key: CFString) -> Bool {
    (axAttribute(el, key) as? NSNumber)?.boolValue ?? false
}

func axString(_ el: AXUIElement, _ key: CFString) -> String? {
    axAttribute(el, key) as? String
}

func findFirst(_ root: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
    if axRole(root) == role { return root }
    guard depth < 10 else { return nil }
    for child in axChildren(root) {
        if let hit = findFirst(child, role: role, depth: depth + 1) { return hit }
    }
    return nil
}

func collect(_ root: AXUIElement, role: String, depth: Int = 0, into: inout [AXUIElement]) {
    if axRole(root) == role { into.append(root) }
    guard depth < 12 else { return }
    for child in axChildren(root) { collect(child, role: role, depth: depth + 1, into: &into) }
}

struct Row {
    let frame: CGRect
    let selected: Bool
}

func outlineRows(_ window: AXUIElement) -> [Row] {
    guard let outline = findFirst(window, role: "AXOutline") else { return [] }
    return axChildren(outline).compactMap { el in
        guard axRole(el) == "AXRow", let f = axFrame(el), f.height >= 24 else { return nil }
        return Row(frame: f, selected: axBool(el, kAXSelectedAttribute as CFString))
    }.sorted { $0.frame.minY < $1.frame.minY }
}

func visibleRows(_ window: AXUIElement, _ bounds: CGRect) -> [Row] {
    guard let outline = findFirst(window, role: "AXOutline"), let clip = axFrame(outline) else { return [] }
    return outlineRows(window).filter {
        $0.frame.minY >= max(clip.minY, bounds.minY) &&
        $0.frame.maxY <= min(clip.maxY, bounds.maxY)
    }
}

func detailTitle(_ window: AXUIElement, _ bounds: CGRect) -> String {
    var texts: [AXUIElement] = []
    collect(window, role: "AXStaticText", into: &texts)
    for el in texts {
        guard let f = axFrame(el),
              f.minX > bounds.minX + 240,
              f.minY > bounds.minY + 100, f.minY < bounds.minY + 230,
              let value = axString(el, kAXValueAttribute as CFString),
              !value.isEmpty else { continue }
        return value
    }
    return "-"
}

func click(_ point: CGPoint) {
    _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?.activate(options: [])
    usleep(150_000)
    let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                       mouseCursorPosition: point, mouseButton: .left)
    move?.post(tap: .cghidEventTap)
    usleep(60_000)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                       mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                     mouseCursorPosition: point, mouseButton: .left)
    up?.post(tap: .cghidEventTap)
}

func scrollSidebar(_ point: CGPoint, lines: Int32, times: Int) {
    _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?.activate(options: [])
    usleep(150_000)
    for _ in 0..<times {
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        wheel?.location = point
        wheel?.post(tap: .cghidEventTap)
        usleep(70_000)
    }
    usleep(400_000)
}

func fail(_ message: String) -> Never {
    print("验收失败：\(message)")
    exit(1)
}

guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fail("\(bundleID) 没在运行。先启动 Release 包再跑本工具")
}
_ = running.activate(options: [])
usleep(500_000)

let app = AXUIElementCreateApplication(pid_t(running.processIdentifier))
let windows = axAttribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
guard let window = windows.first, let bounds = axFrame(window) else {
    fail("拿不到主窗口 AX 元素（检查辅助功能权限，以及主窗口是否被隐藏）")
}

func verifyVisible(_ window: AXUIElement, _ bounds: CGRect, _ label: String) -> (Int, Int, [String]) {
    let visible = visibleRows(window, bounds)
    guard visible.count >= 8 else {
        fail("\(label)只识别到 \(visible.count) 行可见菜单，AX 树可能不完整")
    }
    print("\(label)：\(visible.count) 行可见，逐行点击其 AX frame 中心并回读选中态")
    var passed = 0
    var failed: [String] = []

    for index in visible.indices {
        let current = visibleRows(window, bounds)
        guard index < current.count else { fail("\(label)第 \(index + 1) 行在切页后从 AX 树里消失了") }
        var row = current[index]
        let point = CGPoint(x: row.frame.minX + 84, y: row.frame.midY)
        click(point)
        usleep(450_000)

        var selectedY: CGFloat?
        var title = "-"
        for _ in 0..<3 {
            selectedY = outlineRows(window).first { $0.selected }?.frame.midY
            title = detailTitle(window, bounds)
            if let y = selectedY, abs(y - row.frame.midY) < 4 { break }
            usleep(300_000)
        }

        if !(selectedY.map({ abs($0 - row.frame.midY) < 4 }) ?? false) {
            let retry = visibleRows(window, bounds)
            if index < retry.count {
                row = retry[index]
                click(CGPoint(x: row.frame.minX + 84, y: row.frame.midY))
                usleep(450_000)
                for _ in 0..<3 {
                    selectedY = outlineRows(window).first { $0.selected }?.frame.midY
                    title = detailTitle(window, bounds)
                    if let y = selectedY, abs(y - row.frame.midY) < 4 { break }
                    usleep(300_000)
                }
            }
        }

        let localY = row.frame.midY - bounds.minY
        let ok = selectedY.map { abs($0 - row.frame.midY) < 4 } ?? false
        let status = ok ? "PASS" : "FAIL"
        let selectedText = selectedY.map { String(format: "%.0f", $0 - bounds.minY) } ?? "none"
        print(String(format: "[%02d] 点击局部 y=%.0f → 选中 y=%@ / 详情 %@  %@",
                     index + 1, localY, selectedText, title, status))
        if ok { passed += 1 }
        else { failed.append("\(label)第 \(index + 1) 行 y=\(Int(localY))（选中落在 \(selectedText)）") }
    }
    return (passed, visible.count, failed)
}

print("窗口 frame=(\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))x\(Int(bounds.height)))")
let wheelPoint = CGPoint(x: bounds.minX + 84, y: bounds.midY)
scrollSidebar(wheelPoint, lines: 40, times: 10)
let top = verifyVisible(window, bounds, "顶部")

scrollSidebar(wheelPoint, lines: -10, times: 8)
let bottom = verifyVisible(window, bounds, "滚动后")

let passed = top.0 + bottom.0
let total = top.1 + bottom.1
let failed = top.2 + bottom.2
print("验收：\(passed)/\(total) 行点击命中一致（顶部 + 滚动后）")
if !failed.isEmpty {
    print("错位明细：\n  " + failed.joined(separator: "\n  "))
    exit(1)
}
print("PASS：视觉行与点击命中行一致，无 52pt 偏移")
