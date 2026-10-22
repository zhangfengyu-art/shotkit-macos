import Cocoa
import ImageIO

// Quartz global points: origin at the main display's top left.
struct ShotTarget: Equatable {
    var rect: CGRect
    var role: String = "AXGroup"
    static func close(_ a: ShotTarget?, _ b: ShotTarget?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.rect.minX-b.rect.minX)<1.5 && abs(a.rect.minY-b.rect.minY)<1.5 && abs(a.rect.width-b.rect.width)<2 && abs(a.rect.height-b.rect.height)<2
    }
}
struct ShotWindow { let id: CGWindowID; let pid: pid_t; let frame: CGRect }
struct ShotDisplayLayout: Equatable {let id: CGDirectDisplayID;let frame: CGRect;let scale: CGFloat}
struct ShotSelectionTuning {
    static let defaultValue=0.9
    let value: Double
    init(_ value: Double=Self.defaultValue) {self.value=value.isFinite ? min(1,max(0,value)) : Self.defaultValue}
    var dwell: TimeInterval {0.06+(1-value)*0.16}
    var edgeMargin: CGFloat {CGFloat(8+(1-value)*8)}
    var windowMargin: CGFloat {CGFloat(2+(1-value)*6)}
    var controlInset: CGFloat {CGFloat(4+(1-value)*6)}
    var scoreMargin: Double {0.3+(1-value)*0.8}
    var label: String {value<=0.35 ? "更稳" : value<0.7 ? "适中" : "灵敏"}
}
// Scroll intent is independent of hover recognition. Precise deltas are pixels;
// discrete wheel events count as ticks so device acceleration cannot skip levels.
struct ShotScrollTuning {
    static let defaultValue=0.35
    let value: Double
    init(_ value: Double=Self.defaultValue) {self.value=value.isFinite ? min(1,max(0,value)) : Self.defaultValue}
    var preciseThreshold: CGFloat {CGFloat(28+(1-value)*72)}
    var wheelThreshold: CGFloat {CGFloat(1+(1-value)*2)}
    var repeatInterval: TimeInterval {0.12+(1-value)*0.28}
    var label: String {value<=0.35 ? "更稳" : value<0.7 ? "适中" : "灵敏"}
}
struct ShotScrollIntent {
    private var total: CGFloat=0
    private var direction=0
    private var precise: Bool?
    private var lastInput: TimeInterval?
    private var lastStep: TimeInterval?
    mutating func reset() {self=ShotScrollIntent()}
    mutating func consume(delta: CGFloat,precise: Bool,momentum: Bool=false,began: Bool=false,ended: Bool=false,at now: TimeInterval,tuning: ShotScrollTuning) -> Int? {
        guard now.isFinite,delta.isFinite else {reset();return nil}
        // Momentum must never change a range after fingers leave the trackpad.
        if momentum || ended {total=0;direction=0;lastInput=now;return nil}
        guard delta != 0 else {return nil}
        if began || self.precise != precise || lastInput.map({now-$0>0.35 || now<$0}) == true {total=0;direction=0}
        self.precise=precise;lastInput=now
        let next=delta>0 ? 1 : -1
        if direction != next {total=0;direction=next}
        // Discard input during the repeat guard instead of banking a later jump.
        if let lastStep,now-lastStep<tuning.repeatInterval {total=0;return nil}
        let threshold=precise ? tuning.preciseThreshold : tuning.wheelThreshold
        total += precise ? min(abs(delta),threshold) : 1
        guard total+0.0001>=threshold else {return nil}
        total=0;lastStep=now
        return next
    }
}
struct ShotSelectionMotion {
    static let duration: CFTimeInterval=0.16
    static var timing: CAMediaTimingFunction {CAMediaTimingFunction(controlPoints:0.16,0.8,0.25,1)}
}
enum ShotCoordinates {
    static var top: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func quartz(_ point: NSPoint) -> CGPoint { CGPoint(x:point.x,y:top-point.y) }
    static func appKit(_ rect: CGRect) -> NSRect { NSRect(x:rect.minX,y:top-rect.maxY,width:rect.width,height:rect.height) }
    static func frame(_ screen: NSScreen) -> CGRect { CGRect(x:screen.frame.minX,y:top-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height) }
    static var mouse: CGPoint { quartz(NSEvent.mouseLocation) }
    static var layout: [ShotDisplayLayout] {
        NSScreen.screens.map {ShotDisplayLayout(id:($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,frame:$0.frame,scale:$0.backingScaleFactor)}.sorted {$0.id<$1.id}
    }
}
enum ShotGeometry {
    static let excluded: Set<String> = ["AXSplitter","AXScrollBar","AXRuler","AXGrowArea","AXHandle","AXSeparator"]
    static let weights: [String:Double] = ["AXImage":5,"AXRow":3.8,"AXCell":3.6,"AXTextArea":4.6,"AXTextField":6,"AXGroup":2.3,"AXScrollArea":2.1,"AXList":2.7,"AXTable":2.8,"AXButton":6.5,"AXPopUpButton":6.5,"AXComboBox":6.5,"AXStaticText":3.4,"AXWebArea":1.2,"AXToolbar":1.1,"AXWindow":0]
    static func inside(_ r: CGRect, _ p: CGPoint, margin: CGFloat = 0) -> Bool { p.x>=r.minX+margin && p.x<r.maxX-margin && p.y>=r.minY+margin && p.y<r.maxY-margin }
    static func area(_ r: CGRect) -> CGFloat { max(0,r.width)*max(0,r.height) }
    static func edge(_ r: CGRect, _ p: CGPoint, _ d: CGFloat) -> Bool { inside(r,p,margin:-d) && !inside(r,p,margin:d) }
    static func window(_ windows: [ShotWindow], at p: CGPoint, current: ShotWindow?,tuning: ShotSelectionTuning = .init()) -> ShotWindow? {
        let top=windows.first { inside($0.frame,p) }
        if let current, current.id != top?.id, inside(current.frame,p,margin:-tuning.windowMargin), top == nil || !inside(top!.frame,p,margin:tuning.windowMargin+2) || edge(current.frame,p,tuning.windowMargin) { return current }; return top
    }
    static func normalize(_ raw: [ShotTarget], in window: CGRect) -> [ShotTarget] {
        var result=[ShotTarget]()
        for item in raw {
            let r=item.rect
            guard [r.minX,r.minY,r.width,r.height].allSatisfy({$0.isFinite && abs($0)<1_000_000}),r.width>=24,r.height>=20,!excluded.contains(item.role),(r.width/r.height<18 || (item.role=="AXToolbar" && r.height>=32)),r.height/r.width<12 else { continue }
            let clipped=r.intersection(window)
            guard clipped.width>=24,clipped.height>=20,area(clipped)>=area(r)*0.92,area(clipped)<area(window)*0.97 else { continue }
            let candidate=ShotTarget(rect:clipped,role:item.role)
            if !result.contains(where:{ShotTarget.close($0,candidate)}) { result.append(candidate) }
        }
        result.append(ShotTarget(rect:window,role:"AXWindow")); return result.sorted {area($0.rect)<area($1.rect)}
    }
    static func score(_ t: ShotTarget, window: CGRect) -> Double {
        if t.role=="AXWindow" { return -10 }
        let a=Double(area(t.rect)),fraction=a/max(1,Double(area(window)))
        return (weights[t.role] ?? 2)+min(0.8,a/8000)-abs(log(max(0.0001,fraction)/0.12))*0.22-(min(t.rect.width,t.rect.height)<24 ? 1 : 0)
    }
    static func choose(_ candidates: [ShotTarget], at p: CGPoint, window: CGRect, current: ShotTarget?,tuning: ShotSelectionTuning = .init()) -> ShotTarget? {
        let eligible=candidates.filter {inside($0.rect,p,margin:$0.role=="AXWindow" ? 0 : min(5,$0.rect.height*0.12,$0.rect.width*0.12))}
        let best=eligible.max {score($0,window:window)<score($1,window:window)}
        if let current,candidates.contains(where:{ShotTarget.close($0,current)}) {
            let edgeMargin=min(tuning.edgeMargin,min(current.rect.width,current.rect.height)/4)
            if edge(current.rect,p,edgeMargin) && inside(window,p,margin:-2) { return current }
            let controls=eligible.filter {["AXButton","AXPopUpButton","AXComboBox","AXTextField"].contains($0.role) && area($0.rect)<area(current.rect)*0.5 && inside($0.rect,p,margin:min(tuning.controlInset,min($0.rect.width,$0.rect.height)/4))}
            if let control=controls.max(by:{score($0,window:window)<score($1,window:window)}) {return control}
            if let best,inside(current.rect,p,margin:5),current.role != "AXWindow",score(current,window:window)+tuning.scoreMargin>=score(best,window:window) { return current }
        }; return best
    }
    static func handles(_ r: CGRect) -> [(String,CGPoint)] { [("nw",CGPoint(x:r.minX,y:r.minY)),("n",CGPoint(x:r.midX,y:r.minY)),("ne",CGPoint(x:r.maxX,y:r.minY)),("e",CGPoint(x:r.maxX,y:r.midY)),("se",CGPoint(x:r.maxX,y:r.maxY)),("s",CGPoint(x:r.midX,y:r.maxY)),("sw",CGPoint(x:r.minX,y:r.maxY)),("w",CGPoint(x:r.minX,y:r.midY))] }
    static func toolbarFrame(for selection: CGRect,in screens: [CGRect],size: CGSize) -> CGRect {
        let screen=screens.max {area($0.intersection(selection))<area($1.intersection(selection))} ?? selection
        let visible=selection.intersection(screen),center=visible.isNull ? selection.midX : visible.midX
        let x=max(screen.minX+10,min(screen.maxX-size.width-10,center-size.width/2))
        var y=selection.maxY+12
        if y+size.height>screen.maxY-10 {y=selection.minY-size.height-12}
        y=max(screen.minY+10,min(screen.maxY-size.height-10,y))
        return CGRect(x:x,y:y,width:size.width,height:size.height)
    }
    static func drag(from a: CGPoint,to b: CGPoint) -> CGRect { CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)) }
    static func resize(_ r: CGRect, handle: String, to p: CGPoint) -> CGRect {
        var x=r.minX,y=r.minY,right=r.maxX,bottom=r.maxY
        if handle.contains("w") { x=min(p.x,right-2) }; if handle.contains("e") { right=max(p.x,x+2) }
        if handle.contains("n") { y=min(p.y,bottom-2) }; if handle.contains("s") { bottom=max(p.y,y+2) }
        return CGRect(x:x,y:y,width:right-x,height:bottom-y)
    }
}
struct ShotFrame {
    let id: CGDirectDisplayID; let rect: CGRect; let image: CGImage
    var scale: CGFloat { CGFloat(image.width)/rect.width }
}
enum ShotPixels {
    // ScreenCaptureKit may supply provider-backed pixels. Materialize a private
    // bitmap before showing selection so its display and export share one frame.
    static func freeze(_ image: CGImage) throws -> CGImage {
        guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw ShotError.message("无法冻结屏幕画面")}
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let result=context.makeImage() else {throw ShotError.message("无法冻结屏幕画面")}; return result
    }
    // Copy just the selected pixels. No full-display buffer survives selection completion.
    static func crop(_ selection: CGRect, from frames: [ShotFrame]) throws -> CGImage {
        guard selection.width>=2,selection.height>=2,[selection.minX,selection.minY,selection.width,selection.height].allSatisfy({$0.isFinite && abs($0)<1_000_000}) else { throw ShotError.message("选区无效") }
        let touched=frames.filter {!$0.rect.intersection(selection).isNull && ShotGeometry.area($0.rect.intersection(selection))>0}
        guard let scale=touched.map(\.scale).max() else { throw ShotError.message("原屏幕已断开") }
        guard scale.isFinite,scale>0,selection.width*scale<=32000,selection.height*scale<=32000 else {throw ShotError.message("选区过大，请缩小后重试")}
        let width=Int((selection.width*scale).rounded()),height=Int((selection.height*scale).rounded())
        guard width>0,height>0,width<=32000,height<=32000,width*height<=100_000_000,let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError.message("选区过大，请缩小后重试") }
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        for frame in touched {
            let hit=frame.rect.intersection(selection),s=frame.scale
            let source=CGRect(x:(hit.minX-frame.rect.minX)*s,y:(hit.minY-frame.rect.minY)*s,width:hit.width*s,height:hit.height*s).integral
            guard let cut=frame.image.cropping(to:source) else { continue }
            let dest=CGRect(x:(hit.minX-selection.minX)*scale,y:CGFloat(height)-(hit.maxY-selection.minY)*scale,width:hit.width*scale,height:hit.height*scale)
            context.interpolationQuality=s==scale ? .none : .high; context.draw(cut,in:dest)
        }
        guard let result=context.makeImage() else { throw ShotError.message("无法裁出截图") }; return result
    }
    static func png(_ image: CGImage) throws -> Data {
        let data=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { throw ShotError.message("PNG 编码失败") }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else { throw ShotError.message("PNG 编码失败") }; return data as Data
    }
}
