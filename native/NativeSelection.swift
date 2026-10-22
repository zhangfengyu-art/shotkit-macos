import Cocoa

final class SelectionOverlayView: NSView {
    weak var session: NativeSelectionSession?
    let display: CGRect
    let image: CGImage
    let snapshot: NSImage
    let shade=CAShapeLayer(),border=CAShapeLayer(),grips=CAShapeLayer()
    let label=NSTextField(labelWithString:""),hint=NSTextField(labelWithString:"")
    var tracking: NSTrackingArea?
    var paintCount=0
    private var last: ShotTarget?
    private var lastLocked=false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: ShotFrame) {
        display=frame.rect; image=frame.image; snapshot=NSImage(cgImage:frame.image,size:frame.rect.size)
        super.init(frame:NSRect(origin:.zero,size:display.size)); wantsLayer=true
        // The opaque root paints the detached snapshot; no transparent region can
        // reveal live windows while selection layers move above it.
        let chrome=NSView(frame:bounds); chrome.wantsLayer=true; chrome.layer?.isGeometryFlipped=true; chrome.autoresizingMask=[.width,.height]; addSubview(chrome)
        shade.fillColor=CGColor(gray:0,alpha:0.28); shade.fillRule = .evenOdd
        border.fillColor=NSColor.clear.cgColor; border.strokeColor=NSColor.white.cgColor; border.lineWidth=1; border.lineJoin = .round
        grips.fillColor=NSColor.white.cgColor; grips.strokeColor=NSColor.controlAccentColor.cgColor; grips.lineWidth=1.2
        for l in [shade,border,grips] { l.frame=bounds; chrome.layer?.addSublayer(l) }
        for text in [label,hint] {
            text.font = .systemFont(ofSize:12,weight:.medium); text.textColor = .white; text.alignment = .center
            text.drawsBackground=true; text.backgroundColor=NSColor(white:0.08,alpha:0.94); text.wantsLayer=true; text.layer?.cornerRadius=8; text.layer?.masksToBounds=true
            text.setAccessibilityElement(false); addSubview(text)
        }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("截图选区。拖动框选，Return 复制，Esc 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        snapshot.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none])
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        if let tracking {removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self); addTrackingArea(area); tracking=area; super.updateTrackingAreas()
    }
    func paint(_ target: ShotTarget?,locked: Bool,dragging: Bool,animated: Bool) {
        guard !ShotTarget.close(last,target) || locked != lastLocked || dragging else { return }
        paintCount+=1; last=target; lastLocked=locked
        let path=CGMutablePath(); path.addRect(bounds)
        let scale=window?.backingScaleFactor ?? CGFloat(image.width)/display.width
        let local=target.map { target -> CGRect in
            let r=target.rect.offsetBy(dx:-display.minX,dy:-display.minY)
            let x=(r.minX*scale).rounded()/scale,y=(r.minY*scale).rounded()/scale
            return CGRect(x:x,y:y,width:(r.maxX*scale).rounded()/scale-x,height:(r.maxY*scale).rounded()/scale-y)
        }
        let hit=local?.intersection(bounds)
        // Shape paths draw in bottom-left coordinates; labels and mouse input use the flipped view.
        func shapeRect(_ r: CGRect) -> CGRect {CGRect(x:r.minX,y:bounds.height-r.maxY,width:r.width,height:r.height)}
        if let hit,!hit.isNull,hit.width>0,hit.height>0 { path.addRect(shapeRect(hit)) }
        let oldBorder=border.presentation()?.path ?? border.path,oldShade=shade.presentation()?.path ?? shade.path
        let oldLabelPosition=label.layer?.presentation()?.position ?? label.layer?.position
        let animate=animated && !locked && !dragging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.path=path; border.path=local.map {CGPath(rect:shapeRect($0.insetBy(dx:0.5,dy:0.5)),transform:nil)}
        let handles=CGMutablePath()
        if locked,let local { for (_,p) in ShotGeometry.handles(local) { handles.addRoundedRect(in:shapeRect(CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7)),cornerWidth:2,cornerHeight:2) } }
        grips.path=handles; CATransaction.commit()
        if animate {
            for (layer,old,new) in [(border,oldBorder,border.path),(shade,oldShade,shade.path)] {
                if let old,let new { let a=CABasicAnimation(keyPath:"path"); a.fromValue=old; a.toValue=new; a.duration=ShotSelectionMotion.duration; a.timingFunction=ShotSelectionMotion.timing; layer.add(a,forKey:"selection") }
            }
        } else { border.removeAllAnimations(); shade.removeAllAnimations() }
        if let target,let hit,!hit.isNull,hit.width>0,hit.height>0 {
            let names=["AXWindow":"窗口","AXImage":"图片","AXButton":"按钮","AXTextArea":"文本区域","AXStaticText":"文字"]
            let scale=CGFloat(image.width)/display.width
            label.stringValue=(locked ? "" : (names[target.role] ?? "内容块")+" · ")+"\(Int((target.rect.width*scale).rounded())) × \(Int((target.rect.height*scale).rounded()))"
            let w=min(bounds.width-16,max(100,label.intrinsicContentSize.width+18)),x=min(bounds.width-w-8,max(8,hit.minX))
            let hadLabel = !label.isHidden
            label.frame=CGRect(x:x,y:hit.minY>=32 ? hit.minY-28 : min(bounds.height-25,hit.minY+7),width:w,height:23); label.isHidden=false
            if animate,hadLabel,let oldLabelPosition,let layer=label.layer {
                let animation=CABasicAnimation(keyPath:"position"); animation.fromValue=NSValue(point:oldLabelPosition); animation.toValue=NSValue(point:layer.position)
                animation.duration=ShotSelectionMotion.duration;animation.timingFunction=ShotSelectionMotion.timing;layer.add(animation,forKey:"selection-label")
            } else {label.layer?.removeAnimation(forKey:"selection-label")}
        } else { label.isHidden=true }
        hint.stringValue=dragging ? "松开鼠标确定选区，然后选择要做的操作" : "单击确定 · 拖动框选 · 滚轮换范围（灵敏度可调）· Esc 退出"
        hint.isHidden=locked
        let w=min(490,bounds.width-32); hint.frame=CGRect(x:(bounds.width-w)/2,y:bounds.height-55,width:w,height:32)
    }
    func point(for event: NSEvent) -> CGPoint {
        guard let window else {return ShotCoordinates.mouse}
        return ShotCoordinates.quartz(window.convertPoint(toScreen:event.locationInWindow))
    }
    override func mouseMoved(with event: NSEvent) { session?.hover(point(for:event)) }
    override func mouseEntered(with event: NSEvent) { session?.hover(point(for:event)) }
    override func mouseDown(with event: NSEvent) { session?.down(point(for:event),event:event) }
    override func mouseDragged(with event: NSEvent) { session?.drag(point(for:event)) }
    override func mouseUp(with event: NSEvent) { session?.up(event:event) }
    override func rightMouseDown(with event: NSEvent) { if session?.locked==true {session?.reselect()} else {session?.cancel()} }
    override func scrollWheel(with event: NSEvent) { session?.scroll(event) }
    override func keyDown(with event: NSEvent) { _=session?.key(event) }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
}

final class NativeSelectionSession {
    let id=Int.random(in:1...Int(Int32.max))
    var frames: [ShotFrame]
    let windows: [ShotWindow]
    let toolbar: NativeCaptureUI
    var overlays=[CapturePanel](),views=[SelectionOverlayView]()
    var action: ((String,CGRect,CGImage?)->Void)?
    var ended: (()->Void)?
    var target: ShotTarget?
    var currentWindow: ShotWindow?
    var candidates=[ShotTarget]()
    var locked=false,closed=false,menuOpen=false
    var anchor: CGPoint?,downTarget: ShotTarget?,handle: String?,moving=false,dragged=false
    var hoverPoint=ShotCoordinates.mouse
    var levelPoint: CGPoint?
    var keyMonitor: Any?
    let axQueue=DispatchQueue(label:"local.shotkit.selection.ax",qos:.userInteractive)
    var axBusy=false,axGeneration=0,lastAXPoint: CGPoint?,lastAXAt: TimeInterval=0
    var axTimer: Timer?,adoptTimer: Timer?
    var pending: ShotTarget?
    var motion: Bool
    var allowsAX = true
    var scrollIntent=ShotScrollIntent()
    let scrollTuning: ShotScrollTuning
    var quickCopy: Bool
    let tuning: ShotSelectionTuning
    var presentUI=true
    var closedPaintCount=0
    var cropMilliseconds: Double=0
    var paintCount: Int {closed ? closedPaintCount : views.reduce(0) {$0+$1.paintCount}}
    init(frames: [ShotFrame],windows: [ShotWindow],motion: Bool,quickCopy: Bool,tuning: ShotSelectionTuning?=nil,scrollTuning: ShotScrollTuning?=nil) {
        self.tuning=tuning ?? ShotSelectionTuning(UserDefaults.standard.object(forKey:"hoverSelectionSensitivity") as? Double ?? ShotSelectionTuning.defaultValue)
        self.scrollTuning=scrollTuning ?? ShotScrollTuning(UserDefaults.standard.object(forKey:"scrollSelectionSensitivity") as? Double ?? ShotScrollTuning.defaultValue)
        self.frames=frames; self.windows=windows; self.motion=motion; self.quickCopy=quickCopy; toolbar=NativeCaptureUI(kind:"toolbar")
        toolbar.send = { [weak self] event in
            guard let self,!self.closed else {return}
            if event["event"] as? String=="menu" {self.menuOpen=event["open"] as? Bool ?? false}
            if let value=event["action"] as? String {self.perform(value)}
        }
    }
    func start(show: Bool = true) {
        presentUI=show
        for frame in frames {
            let panel=CapturePanel(contentRect:ShotCoordinates.appKit(frame.rect),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false; panel.isOpaque=true; panel.backgroundColor = .black; panel.hasShadow=false; panel.hidesOnDeactivate=false
            panel.level=NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.overlayWindow))); panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]; panel.acceptsMouseMovedEvents=true
            panel.title="ShotKit 截图选区"; let view=SelectionOverlayView(frame:frame); view.session=self; panel.contentView=view; panel.makeFirstResponder(view)
            overlays.append(panel); views.append(view)
            if show {view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); panel.orderFrontRegardless(); panel.displayIfNeeded()}
        }
        let index=frames.firstIndex {ShotGeometry.inside($0.rect,hoverPoint)} ?? 0
        if show {overlays[index].makeKey()}
        if show {keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,!self.closed,!self.menuOpen else {return event}; return self.key(event) ? nil : event
        }}
        hover(hoverPoint,immediate:true); paint(false)
    }
    func cancel() { close(); ended?() }
    func close() {
        guard !closed else {return}; closedPaintCount=paintCount; closed=true; axGeneration+=1; axTimer?.invalidate(); adoptTimer?.invalidate()
        if let keyMonitor {NSEvent.removeMonitor(keyMonitor)}; keyMonitor=nil
        toolbar.hide(); toolbar.send=nil
        overlays.forEach {$0.orderOut(nil); $0.contentView=nil}; overlays=[]; views=[]; frames=[]
    }
    func paint(_ animated: Bool) {
        guard !closed else {return}
        views.forEach {$0.paint(target,locked:locked,dragging:anchor != nil,animated:animated && motion)}
        if presentUI && locked && anchor==nil,let target {
            let screen=NSScreen.screens.first {ShotGeometry.inside(ShotCoordinates.frame($0),CGPoint(x:target.rect.midX,y:target.rect.midY))} ?? NSScreen.screens[0]
            let frame=ShotGeometry.toolbarFrame(for:target.rect,in:[ShotCoordinates.frame(screen)],size:toolbar.panel.frame.size)
            toolbar.show(at:frame.origin,session:id,motion:motion)
        } else { toolbar.hide() }
    }
    func adopt(_ value: ShotTarget?, immediate: Bool) {
        guard !closed,!locked,anchor==nil else {return}
        if ShotTarget.close(value,target) {adoptTimer?.invalidate();pending=nil;return}
        if immediate {adoptTimer?.invalidate(); pending=nil; target=value; paint(false); return}
        if ShotTarget.close(value,pending),adoptTimer?.isValid==true {return}
        adoptTimer?.invalidate(); pending=value
        adoptTimer=Timer.scheduledTimer(withTimeInterval:tuning.dwell,repeats:false) { [weak self] _ in
            guard let self,!self.closed,!self.locked,self.anchor==nil else {return}
            if let pending=self.pending,!ShotGeometry.inside(pending.rect,self.hoverPoint) {self.pending=nil;return}
            self.target=self.pending; self.pending=nil; self.paint(true)
        }
    }
    func hover(_ point: CGPoint,immediate: Bool = false) {
        guard !closed,!locked,anchor==nil else {return}; hoverPoint=point
        if let levelPoint,hypot(point.x-levelPoint.x,point.y-levelPoint.y)<12 {return}; levelPoint=nil
        let win=ShotGeometry.window(windows,at:point,current:currentWindow,tuning:tuning)
        if win?.id != currentWindow?.id {currentWindow=win; axGeneration+=1; lastAXPoint=nil; candidates=win.map {ShotGeometry.normalize([],in:$0.frame)} ?? []; adopt(candidates.first,immediate:true)}
        if let win {
            adopt(ShotGeometry.choose(candidates,at:point,window:win.frame,current:target,tuning:tuning),immediate:immediate)
            scheduleAX()
        } else if let frame=frames.first(where:{ShotGeometry.inside($0.rect,point)}) {adopt(ShotTarget(rect:frame.rect,role:"AXWindow"),immediate:immediate)}
    }
    func scheduleAX() {
        guard allowsAX,AXIsProcessTrusted(),!axBusy,!closed,!locked,anchor==nil,currentWindow != nil else {return}
        if let lastAXPoint,hypot(hoverPoint.x-lastAXPoint.x,hoverPoint.y-lastAXPoint.y)<5 {return}
        let wait=max(0,0.065-(ProcessInfo.processInfo.systemUptime-lastAXAt))
        if wait>0 { if axTimer?.isValid != true {axTimer=Timer.scheduledTimer(withTimeInterval:wait,repeats:false) { [weak self] _ in self?.queryAX() }} }
        else {queryAX()}
    }
    func queryAX() {
        guard !closed,!locked,anchor==nil,!axBusy,let win=currentWindow else {return}
        let point=hoverPoint,generation=axGeneration; axBusy=true; lastAXPoint=point; lastAXAt=ProcessInfo.processInfo.systemUptime
        axQueue.async { [weak self] in
            let values=accessibilityTargets(win.pid,at:point)
            DispatchQueue.main.async {
                guard let self else {return}; self.axBusy=false
                guard !self.closed,!self.locked,self.anchor==nil,self.axGeneration==generation,self.currentWindow?.id==win.id else {return}
                self.candidates=ShotGeometry.normalize(Array((values+self.candidates).prefix(96)),in:win.frame)
                self.adopt(ShotGeometry.choose(self.candidates,at:self.hoverPoint,window:win.frame,current:self.target,tuning:self.tuning),immediate:false); self.scheduleAX()
            }
        }
    }
    func reselect() { scrollIntent.reset(); locked=false; anchor=nil; handle=nil; moving=false; pending=nil; adoptTimer?.invalidate(); lastAXPoint=nil; levelPoint=nil; paint(false); hover(ShotCoordinates.mouse,immediate:true) }
    func confirm(_ value: ShotTarget?) {
        guard let value,valid(value.rect) else {return}; scrollIntent.reset(); target=value; locked=true; anchor=nil; axGeneration+=1; axTimer?.invalidate(); adoptTimer?.invalidate(); pending=nil; paint(false)
    }
    func valid(_ r: CGRect) -> Bool { r.width>=2 && r.height>=2 && frames.contains {ShotGeometry.area($0.rect.intersection(r))>0} }
    func down(_ p: CGPoint,event: NSEvent) {
        adoptTimer?.invalidate(); scrollIntent.reset(); axGeneration+=1
        handle=locked ? target.flatMap { t in ShotGeometry.handles(t.rect).first {abs($0.1.x-p.x)<=9 && abs($0.1.y-p.y)<=9}?.0} : nil
        moving=locked && handle==nil && target.map {ShotGeometry.inside($0.rect,p)}==true
        if locked && !moving && handle==nil {reselect(); hover(p,immediate:true)}
        anchor=p; downTarget=target; dragged=false; paint(false)
    }
    func drag(_ p: CGPoint) {
        guard let anchor else {return}; let dx=p.x-anchor.x,dy=p.y-anchor.y
        guard abs(dx)>2 || abs(dy)>2 || dragged else {return}; dragged=true
        let r: CGRect
        if let handle,let downTarget {r=ShotGeometry.resize(downTarget.rect,handle:handle,to:p)}
        else if moving,let downTarget {r=downTarget.rect.offsetBy(dx:dx,dy:dy)}
        else {r=ShotGeometry.drag(from:anchor,to:p)}
        target=ShotTarget(rect:r); paint(false)
    }
    func up(event: NSEvent) {
        guard anchor != nil else {return}; anchor=nil
        let value=dragged ? target : downTarget
        if let value,valid(value.rect) {
            target=value
            if (event.clickCount>=2 && !dragged) || event.modifierFlags.contains(.option) || (quickCopy && !event.modifierFlags.contains(.shift)) {perform("copy")}
            else {confirm(value)}
        } else {reselect()}
    }
    func scroll(_ event: NSEvent) {
        guard !closed,!locked,anchor==nil else {scrollIntent.reset();return}
        let y=event.scrollingDeltaY
        guard abs(y)>=abs(event.scrollingDeltaX) else {scrollIntent.reset();return}
        if let direction=scrollIntent.consume(delta:y,precise:event.hasPreciseScrollingDeltas,momentum:!event.momentumPhase.isEmpty,began:event.phase.contains(.began),ended:event.phase.contains(.ended) || event.phase.contains(.cancelled),at:event.timestamp,tuning:scrollTuning) {step(direction)}
    }
    func step(_ delta: Int) {
        let chain=candidates.filter {ShotGeometry.inside($0.rect,hoverPoint)}.sorted {ShotGeometry.area($0.rect)<ShotGeometry.area($1.rect)}
        guard !chain.isEmpty else {return}; let index=chain.firstIndex {ShotTarget.close($0,target)} ?? 0
        adoptTimer?.invalidate(); axTimer?.invalidate(); axGeneration+=1; pending=nil; target=chain[min(chain.count-1,max(0,index+delta))]; levelPoint=hoverPoint; paint(true)
    }
    func key(_ event: NSEvent) -> Bool {
        let code=event.keyCode,flags=event.modifierFlags
        if code==0,flags.contains([.command,.control]) {return true} // Carbon owns the capture/history hotkeys.
        if flags.contains(.command),code != 8 {
            if code==13 {cancel(); return true}
            return false
        }
        if code==53 {cancel(); return true}
        if code==49 {confirm(target); return true}
        if code==46 {if locked {reselect()} else {confirm(target)}; return true}
        if [123,124,125,126].contains(code),locked,let t=target {
            var r=t.rect; let d: CGFloat=flags.contains(.option) ? 10 : 1
            if flags.contains(.shift) {if code==123 {r.size.width=max(2,r.width-d)}; if code==124 {r.size.width+=d}; if code==126 {r.size.height=max(2,r.height-d)}; if code==125 {r.size.height+=d}}
            else {if code==123 {r.origin.x-=d}; if code==124 {r.origin.x+=d}; if code==126 {r.origin.y-=d}; if code==125 {r.origin.y+=d}}
            target=ShotTarget(rect:r); paint(false); return true
        }
        if !locked,[126,125,48].contains(code) {step(code==126 || (code==48 && flags.contains(.shift)) ? 1 : -1); return true}
        let actions: [UInt16:String]=[36:"copy",76:"copy",8:"copy",1:"save",31:"ocr",12:"qr",17:"translate",35:"pin",14:"edit",37:"long",2:"delay",0:"ai"]
        if let a=actions[code] {perform(a); return true}; return true
    }
    func perform(_ name: String) {
        if name=="cancel" {cancel(); return}; if name=="reselect" {reselect(); return}
        guard let target,valid(target.rect) else {return}
        if name=="long" || name=="delay" {let r=target.rect; close(); action?(name,r,nil); return}
        do {let start=ProcessInfo.processInfo.systemUptime; let image=try ShotPixels.crop(target.rect,from:frames),r=target.rect; cropMilliseconds=(ProcessInfo.processInfo.systemUptime-start)*1000; close(); action?(name,r,image)}
        catch {cancel(); action?("error:"+error.localizedDescription,.zero,nil)}
    }
}
