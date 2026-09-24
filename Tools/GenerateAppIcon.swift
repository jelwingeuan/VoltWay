import AppKit

let size = NSSize(width: 1_024, height: 1_024)
let image = NSImage(size: size, flipped: false) { bounds in
    NSGraphicsContext.current?.imageInterpolation = .high

    let background = NSBezierPath(rect: bounds)
    NSGradient(
        starting: NSColor(red: 0.13, green: 0.37, blue: 0.97, alpha: 1),
        ending: NSColor(red: 0.07, green: 0.25, blue: 0.72, alpha: 1)
    )!.draw(in: background, angle: 130)

    let route = NSBezierPath()
    route.lineWidth = 62
    route.lineCapStyle = .round
    route.lineJoinStyle = .round
    route.move(to: NSPoint(x: 225, y: 300))
    route.curve(
        to: NSPoint(x: 450, y: 490),
        controlPoint1: NSPoint(x: 388, y: 300),
        controlPoint2: NSPoint(x: 315, y: 505)
    )
    route.curve(
        to: NSPoint(x: 664, y: 692),
        controlPoint1: NSPoint(x: 590, y: 465),
        controlPoint2: NSPoint(x: 555, y: 655)
    )
    NSColor.white.setStroke()
    route.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 176, y: 251, width: 98, height: 98)).fill()
    NSColor(red: 0.11, green: 0.30, blue: 0.80, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 201, y: 276, width: 48, height: 48)).fill()

    NSColor(red: 0.045, green: 0.09, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 594, y: 590, width: 316, height: 316)).fill()

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 775, y: 845))
    bolt.line(to: NSPoint(x: 673, y: 733))
    bolt.line(to: NSPoint(x: 735, y: 733))
    bolt.line(to: NSPoint(x: 705, y: 651))
    bolt.line(to: NSPoint(x: 822, y: 771))
    bolt.line(to: NSPoint(x: 759, y: 771))
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Could not render VoltWay app icon") }

let destination = CommandLine.arguments.dropFirst().first
    ?? "VoltWay/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
try png.write(to: URL(fileURLWithPath: destination))
