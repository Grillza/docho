// Draws numbered test pages (JPEG) for the test comics made by test-servers.sh.
// usage: make-test-pages <outdir> <count> <label> <hue 0-1> [width height]
import AppKit
let args = CommandLine.arguments
let out = args[1], count = Int(args[2])!, label = args[3], hue = Double(args[4])!
let width = args.count > 5 ? Double(args[5])! : 800, height = args.count > 6 ? Double(args[6])! : 1200
for page in 1...count {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1).setStroke()
    let border = NSBezierPath(rect: NSRect(x: 20, y: 20, width: width - 40, height: height - 40)); border.lineWidth = 12; border.stroke()
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 200), .foregroundColor: NSColor.black]
    let number = NSAttributedString(string: "\(page)", attributes: style)
    number.draw(at: NSPoint(x: (width - number.size().width) / 2, y: height / 2 - 60))
    let caption = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.darkGray])
    caption.draw(at: NSPoint(x: (width - caption.size().width) / 2, y: height / 2 - 160))
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!.write(to: URL(fileURLWithPath: "\(out)/\(String(format: "%03d", page)).jpg"))
}
