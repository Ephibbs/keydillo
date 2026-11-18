// Turns the old app icon (a rounded tile with transparent margins) into full-bleed square artwork, which macOS
// masks into its own rounded shape. Without this, macOS 26 and later put the old icon inside a grey tile.
// Usage: swift scripts/full-bleed-icon.swift <old icon_1024.png> <out.png> [--glyph]
// With --glyph it writes only the white glyph on a transparent canvas, for the Icon Composer icon (App/Sources/AppIcon.icon).
import AppKit

let args = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let W = 1024
func px(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
  let c = src.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
  return (c.redComponent, c.greenComponent, c.blueComponent)
}
// The old tile spans 100...924; its vertical gradient is sampled down the middle, clear of the glyph.
let top = px(200, 130), bottom = px(200, 894)
func bg(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
  (top.0 + (bottom.0 - top.0) * t, top.1 + (bottom.1 - top.1) * t, top.2 + (bottom.2 - top.2) * t)
}
let scale: CGFloat = 1024.0 / 824.0   // the tile fills the whole canvas; the glyph keeps its size relative to it
let glyph = (x: 250...780, y: 440...590)  // where the white glyph sits in the old icon

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: W, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<W {
  let sy = Int((CGFloat(y) - 512) / scale + 512)
  let base = bg(CGFloat(y) / CGFloat(W - 1))
  for x in 0..<W {
    let sx = Int((CGFloat(x) - 512) / scale + 512)
    var a: CGFloat = 0
    if glyph.x.contains(sx) && glyph.y.contains(sy) {
      let p = px(sx, sy), local = bg((CGFloat(sy) - 100) / 824)
      let l = (p.0 + p.1 + p.2) / 3, lb = (local.0 + local.1 + local.2) / 3
      // Ignore the faint difference between the old background and our estimate of it, so no box shows.
      a = max(0, min(1, (l - lb - 0.06) / (1 - lb - 0.06)))
    }
    if args.contains("--glyph") {
      out.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: a), atX: x, y: y)
    } else {
      out.setColor(NSColor(deviceRed: base.0 + (1 - base.0) * a, green: base.1 + (1 - base.1) * a,
                           blue: base.2 + (1 - base.2) * a, alpha: 1), atX: x, y: y)
    }
  }
}
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
print("background top", top, "bottom", bottom)
