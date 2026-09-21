// 生成一版简单的 App 图标（1024x1024 PNG）
// 用法: makeicon <输出路径>

import Cocoa

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角渐变底
let inset: CGFloat = size * 0.055
let bgRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.225, yRadius: size * 0.225)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.99, alpha: 1.0),
                          ending:   NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.60, alpha: 1.0))!
gradient.draw(in: bg, angle: -90)

// 笔记本图形（SF Symbol 染白）
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .medium)
if let base = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil),
   let sym = base.withSymbolConfiguration(cfg) {
    let s = sym.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()

    tinted.draw(in: NSRect(x: (size - s.width) / 2,
                           y: (size - s.height) / 2,
                           width: s.width, height: s.height))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("生成图标失败\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon -> \(outPath)")
