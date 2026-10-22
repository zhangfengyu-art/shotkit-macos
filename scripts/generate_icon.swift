import Cocoa

// Reproducible vector artwork. Run: xcrun swift scripts/generate_icon.swift native/Resources
let destination=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "native/Resources",isDirectory:true)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
let iconset=destination.appendingPathComponent("ShotKit.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
let space=CGColorSpace(name:CGColorSpace.sRGB)!
func color(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat=1) -> CGColor {CGColor(colorSpace:space,components:[r,g,b,a])!}
func squircle(_ rect: CGRect) -> CGPath {
    let p=CGMutablePath()
    for i in 0...256 {
        let angle=CGFloat(i)*2 * .pi/256,c=cos(angle),s=sin(angle)
        let x=rect.midX+rect.width/2*(c<0 ? -1:1)*pow(abs(c),2/4.4)
        let y=rect.midY+rect.height/2*(s<0 ? -1:1)*pow(abs(s),2/4.4)
        if i==0 {p.move(to:CGPoint(x:x,y:y))} else {p.addLine(to:CGPoint(x:x,y:y))}
    }
    p.closeSubpath();return p
}
func gradient(_ context: CGContext,_ path: CGPath,_ colors: [CGColor],from: CGPoint,to: CGPoint) {
    context.saveGState();context.addPath(path);context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace:space,colors:colors as CFArray,locations:nil)!,start:from,end:to,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    context.restoreGState()
}
func render(_ pixels: Int) throws -> Data {
    let c=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024);c.setAllowsAntialiasing(true)
    let plate=squircle(CGRect(x:64,y:64,width:896,height:896))
    c.saveGState();c.setShadow(offset:CGSize(width:0,height:-14),blur:30,color:color(0.05,0.11,0.23,0.22));c.setFillColor(color(0.92,0.94,0.98));c.addPath(plate);c.fillPath();c.restoreGState()
    gradient(c,plate,[color(1,1,1),color(0.88,0.92,0.98)],from:CGPoint(x:360,y:950),to:CGPoint(x:680,y:64))
    c.setStrokeColor(color(1,1,1,0.9));c.setLineWidth(3);c.addPath(squircle(CGRect(x:67,y:67,width:890,height:890)));c.strokePath()
    let panel=CGPath(roundedRect:CGRect(x:170,y:190,width:684,height:644),cornerWidth:112,cornerHeight:112,transform:nil)
    c.saveGState();c.setShadow(offset:CGSize(width:0,height:-20),blur:36,color:color(0.02,0.23,0.65,0.28));c.setFillColor(color(0.08,0.42,0.94));c.addPath(panel);c.fillPath();c.restoreGState()
    gradient(c,panel,[color(0.12,0.75,1),color(0.08,0.43,0.98),color(0.08,0.22,0.82)],from:CGPoint(x:230,y:820),to:CGPoint(x:780,y:180))
    c.setStrokeColor(color(1,1,1,0.62));c.setLineWidth(3);c.addPath(panel);c.strokePath()
    gradient(c,panel,[color(1,1,1,0.24),color(1,1,1,0)],from:CGPoint(x:200,y:830),to:CGPoint(x:550,y:430))
    let corners=CGMutablePath(),left:CGFloat=283,right:CGFloat=741,bottom:CGFloat=319,top:CGFloat=711,leg:CGFloat=91
    for (x,y,dx,dy) in [(left,top,leg,-leg),(right,top,-leg,-leg),(left,bottom,leg,leg),(right,bottom,-leg,leg)] {
        corners.move(to:CGPoint(x:x,y:y+dy));corners.addLine(to:CGPoint(x:x,y:y));corners.addLine(to:CGPoint(x:x+dx,y:y))
    }
    c.saveGState();c.setShadow(offset:CGSize(width:0,height:-3),blur:5,color:color(0.02,0.20,0.6,0.16));c.setStrokeColor(color(1,1,1,0.98));c.setLineWidth(31);c.setLineCap(.round);c.setLineJoin(.round);c.addPath(corners);c.strokePath();c.restoreGState()
    let arrow=CGMutablePath();arrow.move(to:CGPoint(x:492,y:561))
    for p in [CGPoint(x:500,y:337),CGPoint(x:561,y:388),CGPoint(x:615,y:285),CGPoint(x:663,y:310),CGPoint(x:611,y:411),CGPoint(x:686,y:423)] {arrow.addLine(to:p)}
    arrow.closeSubpath()
    c.saveGState();c.setShadow(offset:CGSize(width:0,height:-7),blur:14,color:color(0.02,0.12,0.36,0.34));c.setFillColor(color(1,1,1));c.setStrokeColor(color(0.03,0.23,0.57,0.35));c.setLineWidth(7);c.setLineJoin(.round);c.addPath(arrow);c.drawPath(using:.fillStroke);c.restoreGState()
    guard let image=c.makeImage(),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw NSError(domain:"ShotKitIcon",code:1)}
    return png
}
for size in [16,32,128,256,512] {
    try render(size).write(to:iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to:iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to:destination.appendingPathComponent("ShotKitIcon1024.png"))
try render(256).write(to:destination.appendingPathComponent("ShotKitIcon256.png"))
let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil");task.arguments=["-c","icns",iconset.path,"-o",destination.appendingPathComponent("ShotKit.icns").path]
try task.run();task.waitUntilExit();guard task.terminationStatus==0 else {fputs("macOS iconutil could not package the iconset. Run outside a restricted sandbox.\n",stderr);exit(1)}
try FileManager.default.removeItem(at:iconset)
print("Generated ShotKit.icns and 1024 px preview")
