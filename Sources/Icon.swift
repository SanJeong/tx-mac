import AppKit
import Foundation
let destination = CommandLine.arguments[1]
let fm = FileManager.default
try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width:size,height:size))
    image.lockFocus()
    let scale = CGFloat(size)/1024
    let transform=NSAffineTransform();transform.scale(by:scale);transform.concat()
    NSColor(calibratedRed:0.85,green:0.85,blue:0.82,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:30,y:30,width:964,height:964),xRadius:180,yRadius:180).fill()
    NSColor(calibratedWhite:0.13,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:122,y:156,width:780,height:710),xRadius:32,yRadius:32).fill()
    let colors:[NSColor] = [NSColor(calibratedRed:0.37,green:0.55,blue:0.65,alpha:1),NSColor(calibratedRed:0.95,green:0.42,blue:0.18,alpha:1),NSColor(calibratedWhite:0.92,alpha:1)]
    for i in 0..<6 {
        let x=CGFloat(191+i*126)
        for j in 0..<3 {colors[j].setFill();NSBezierPath(ovalIn:NSRect(x:x-20,y:CGFloat(752-j*84),width:40,height:40)).fill()}
        NSColor(calibratedWhite:0.4,alpha:1).setStroke();let path=NSBezierPath();path.lineWidth=7;path.move(to:NSPoint(x:x,y:290));path.line(to:NSPoint(x:x,y:556));path.stroke()
        NSColor(calibratedWhite:0.91,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:x-32,y:CGFloat(330+(i%3)*48),width:64,height:34),xRadius:5,yRadius:5).fill()
        NSColor(calibratedRed:0.95,green:0.42,blue:0.18,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:x-24,y:216,width:48,height:26),xRadius:4,yRadius:4).fill()
    }
    image.unlockFocus()
    let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data=bitmap.representation(using:.png,properties:[:])!
    var names:[String]=[]
    if size<=512 {names.append("icon_\(size)x\(size).png")}
    if size>=32 {names.append("icon_\(size/2)x\(size/2)@2x.png")}
    for name in names {try data.write(to:URL(fileURLWithPath:destination).appendingPathComponent(name))}
}
