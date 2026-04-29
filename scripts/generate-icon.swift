import AppKit
import Foundation

let masterSize: CGFloat = 1024
let cornerRatio: CGFloat = 0.225

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * cornerRatio, yRadius: size * cornerRatio)

    // Background gradient
    let top = NSColor(red: 0.14, green: 0.40, blue: 0.76, alpha: 1.0)
    let bot = NSColor(red: 0.10, green: 0.28, blue: 0.60, alpha: 1.0)
    if let grad = NSGradient(colors: [top, bot]) {
        grad.draw(in: path, angle: -90)
    }

    // White SF Symbol book icon — use hierarchical rendering via tintColor on a configured symbol
    if let book = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: nil) {
        // Create a palette configuration: single color = white
        let cfg = book.withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: .white))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .medium))
        if let configured = cfg {
            let s = configured.size
            configured.draw(in: NSRect(x: (size - s.width) / 2,
                                        y: (size - s.height) / 2,
                                    width: s.width, height: s.height))
        }
    }

    image.unlockFocus()
    return image
}

let icon = makeIcon(size: masterSize)
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/icon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

if let tiff = icon.tiffRepresentation,
   let bmp = NSBitmapImageRep(data: tiff),
   let png = bmp.representation(using: .png, properties: [:]) {
    try png.write(to: iconset.appendingPathComponent("icon_512x512@2x.png"))
    print("Done: icon_512x512@2x.png")
}
