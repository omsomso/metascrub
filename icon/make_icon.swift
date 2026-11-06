// Draws the MetaScrub app icon (1024×1024 PNG): a document whose metadata lines are being wiped
// away by a sparkle, on an indigo-to-teal rounded square. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: the shape is inset from the canvas and has rounded corners.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.45, alpha: 1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.33, green: 0.30, blue: 0.86, alpha: 1), CGColor(red: 0.10, green: 0.55, blue: 0.70, alpha: 1)] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(background, start: CGPoint(x: inset, y: size - inset), end: CGPoint(x: size - inset, y: inset), options: [])
// Soft top highlight, like light on glass.
let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(shine, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: size / 2), options: [])
cg.restoreGState()

// The document.
let page = CGRect(x: 300, y: 215, width: 400, height: 520)
let fold: CGFloat = 110
let paper = CGMutablePath()
paper.move(to: CGPoint(x: page.minX + 36, y: page.minY))
paper.addLine(to: CGPoint(x: page.maxX - 36, y: page.minY))
paper.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + 36), control: CGPoint(x: page.maxX, y: page.minY))
paper.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
paper.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
paper.addLine(to: CGPoint(x: page.minX + 36, y: page.maxY))
paper.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - 36), control: CGPoint(x: page.minX, y: page.maxY))
paper.addLine(to: CGPoint(x: page.minX, y: page.minY + 36))
paper.addQuadCurve(to: CGPoint(x: page.minX + 36, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.28))
cg.addPath(paper); cg.setFillColor(CGColor(gray: 1, alpha: 0.97)); cg.fillPath()
cg.restoreGState()
let corner = CGMutablePath()
corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 18))
corner.addQuadCurve(to: CGPoint(x: page.maxX - fold + 18, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
corner.closeSubpath()
cg.addPath(corner); cg.setFillColor(CGColor(red: 0.80, green: 0.83, blue: 0.95, alpha: 1)); cg.fillPath()

// Metadata lines: solid at the top, fading into the sweep at the bottom.
cg.setLineCap(.round)
cg.setLineWidth(34)
let lines: [(CGFloat, CGFloat, CGFloat)] = [(612, 545, 1), (532, 610, 1), (452, 560, 0.55), (372, 470, 0.25)]
for (y, end, alpha) in lines {
    cg.setStrokeColor(CGColor(red: 0.33, green: 0.30, blue: 0.86, alpha: alpha))
    cg.move(to: CGPoint(x: 370, y: y)); cg.addLine(to: CGPoint(x: end, y: y)); cg.strokePath()
}

// The sparkle that does the wiping.
func sparkle(_ center: CGPoint, _ radius: CGFloat) {
    let star = CGMutablePath()
    let points = 4
    for index in 0..<(points * 2) {
        let angle = CGFloat(index) * .pi / CGFloat(points) + .pi / 2
        let r = index % 2 == 0 ? radius : radius * 0.22
        let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
    }
    star.closeSubpath()
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 24, color: CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 0.9))
    cg.addPath(star); cg.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.35, alpha: 1)); cg.fillPath()
    cg.restoreGState()
}
sparkle(CGPoint(x: 700, y: 330), 120)
sparkle(CGPoint(x: 790, y: 470), 52)
sparkle(CGPoint(x: 610, y: 225), 40)

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
