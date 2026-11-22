// Render-test comparison: swift imgdiff.swift base.tif other.tif …   (changed pixels, mean |Δ| brightness)
//   --stats a.tif …  mean brightness and standard deviation (contrast)
//   --grain a.tif …  mean squared difference from a 3×3 box blur (grain variance)
//   --sat a.tif …    mean HSB saturation
import AppKit
func load(_ p: String) -> NSBitmapImageRep { NSBitmapImageRep(data: NSImage(contentsOfFile: p)!.tiffRepresentation!)! }
func luma(_ r: NSBitmapImageRep) -> [[Double]] {
  (0..<r.pixelsHigh).map { y in (0..<r.pixelsWide).map { x in Double(r.colorAt(x: x, y: y)!.brightnessComponent) } }
}
let a = Array(CommandLine.arguments.dropFirst())
switch a.first {
case "--stats":
  for p in a.dropFirst() {
    let v = luma(load(p)).flatMap { $0 }
    let m = v.reduce(0, +) / Double(v.count)
    let sd = (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    print(p, String(format: "mean %.4f stdev %.4f", m, sd))
  }
case "--grain":
  for p in a.dropFirst() {
    let l = luma(load(p)); var s = 0.0, n = 0
    for y in 1..<(l.count - 1) { for x in 1..<(l[0].count - 1) {
      var b = 0.0
      for dy in -1...1 { for dx in -1...1 { b += l[y + dy][x + dx] } }
      let d = l[y][x] - b / 9; s += d * d; n += 1
    } }
    print(p, String(format: "grain %.6e", s / Double(n)))
  }
case "--sat":
  for p in a.dropFirst() {
    let r = load(p); var s = 0.0
    for y in 0..<r.pixelsHigh { for x in 0..<r.pixelsWide { s += Double(r.colorAt(x: x, y: y)!.saturationComponent) } }
    print(p, String(format: "saturation %.4f", s / Double(r.pixelsWide * r.pixelsHigh)))
  }
default:
  let b = load(a[0])
  for p in a.dropFirst() {
    let r = load(p); var n = 0, big = 0; var sum = 0.0
    for y in 0..<r.pixelsHigh { for x in 0..<r.pixelsWide {
      let d = abs(r.colorAt(x: x, y: y)!.brightnessComponent - b.colorAt(x: x, y: y)!.brightnessComponent)
      if d > 0.01 { n += 1; sum += d }; if d > 0.2 { big += 1 } } }
    print(p, "changed", n, "strong", big, String(format: "mean %.3f", n > 0 ? sum / Double(n) : 0))
  }
}
