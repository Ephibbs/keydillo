// Draws the disk image window background: an arrow from the app to Applications, and one line of text.
// Usage: swift scripts/dmg-background.swift <out-dir>   (writes background.png and background@2x.png)
import AppKit

let size = NSSize(width: 660, height: 400)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  // Flip so y runs top to bottom, like Finder's icon positions.
  let t = NSAffineTransform(); t.translateX(by: 0, yBy: size.height); t.scaleX(by: 1, yBy: -1); t.concat()

  NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
  NSRect(origin: .zero, size: size).fill()

  // Arrow between the two icons (icon centres are at x 180 and 480, y 185).
  let gray = NSColor(calibratedWhite: 0.62, alpha: 1)
  gray.setStroke(); gray.setFill()
  let shaft = NSBezierPath()
  shaft.move(to: NSPoint(x: 262, y: 185)); shaft.line(to: NSPoint(x: 388, y: 185))
  shaft.lineWidth = 3; shaft.lineCapStyle = .round; shaft.stroke()
  let head = NSBezierPath()
  head.move(to: NSPoint(x: 400, y: 185)); head.line(to: NSPoint(x: 384, y: 175)); head.line(to: NSPoint(x: 384, y: 195)); head.close()
  head.fill()

  let style = NSMutableParagraphStyle(); style.alignment = .center
  let text = NSAttributedString(string: "Drag keydillo to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1),
    .paragraphStyle: style,
  ])
  // Text draws upright inside the flipped context only if we flip it back locally.
  NSGraphicsContext.saveGraphicsState()
  let u = NSAffineTransform(); u.translateX(by: 0, yBy: 318); u.scaleX(by: 1, yBy: -1); u.concat()
  text.draw(in: NSRect(x: 0, y: -10, width: size.width, height: 24))
  NSGraphicsContext.restoreGraphicsState()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out + "/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out + "/background@2x.png"))
print("wrote \(out)/background.png and background@2x.png")
