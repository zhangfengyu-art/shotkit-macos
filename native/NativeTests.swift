import Cocoa

@MainActor func nativeSelfTest(_ directory: String) throws {
    try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
    var assertions=0
    func check(_ value: @autoclosure ()->Bool,_ label: String) throws {guard value() else {throw ShotError.message("Native test failed: "+label)}; assertions+=1}
    let win=CGRect(x:0,y:0,width:1000,height:800)
    let imageTarget=ShotTarget(rect:CGRect(x:100,y:100,width:300,height:240),role:"AXImage")
    let raw=[imageTarget,ShotTarget(rect:CGRect(x:100,y:100,width:300,height:240),role:"AXGroup"),ShotTarget(rect:CGRect(x:398,y:100,width:2,height:240),role:"AXSplitter"),ShotTarget(rect:CGRect(x:-100,y:0,width:800,height:900),role:"AXGroup"),ShotTarget(rect:CGRect(x:10,y:5,width:700,height:6),role:"AXScrollBar"),ShotTarget(rect:CGRect(x:CGFloat.nan,y:5,width:40,height:40))]
    let normalized=ShotGeometry.normalize(raw,in:win)
    try check(normalized.count==2,"filter decorative, duplicate, nonfinite and clipped ancestor frames")
    try check(normalized.last?.role=="AXWindow","window fallback")
    try check(ShotGeometry.choose(normalized,at:CGPoint(x:200,y:150),window:win,current:nil)==imageTarget,"useful image target wins")
    for x in stride(from:396.0,through:404,by:0.25) {try check(ShotGeometry.choose(normalized,at:CGPoint(x:x,y:180),window:win,current:imageTarget)==imageTarget,"border hysteresis")}
    try check(ShotGeometry.choose(normalized,at:CGPoint(x:500,y:180),window:win,current:imageTarget)?.role=="AXWindow","leave border band normally")
    let buttonTarget=ShotTarget(rect:CGRect(x:140,y:180,width:120,height:32),role:"AXButton")
    let fine=ShotGeometry.normalize([imageTarget,buttonTarget,ShotTarget(rect:CGRect(x:80,y:80,width:700,height:600),role:"AXGroup")],in:win)
    try check(ShotGeometry.choose(fine,at:CGPoint(x:170,y:195),window:win,current:imageTarget)==buttonTarget,"native button inside a large image or group remains individually selectable")
    let barSize=CGSize(width:508,height:94),barSelection=CGRect(x:300,y:100,width:600,height:300)
    let barFrame=ShotGeometry.toolbarFrame(for:barSelection,in:[win],size:barSize)
    try check(barFrame.midX==barSelection.midX && barFrame.minY==barSelection.maxY+12,"toolbar is centered directly below selected pixels")
    let above=ShotGeometry.toolbarFrame(for:CGRect(x:100,y:650,width:600,height:140),in:[win],size:barSize)
    try check(above.maxY==638,"toolbar moves above a selection at the bottom edge")
    let negativeBar=ShotGeometry.toolbarFrame(for:CGRect(x:-900,y:100,width:400,height:300),in:[CGRect(x:-1200,y:0,width:1200,height:800),win],size:barSize)
    try check(negativeBar.midX == -700 && negativeBar.minY==412,"toolbar uses Quartz coordinates on a negative-origin display")
    let old=ShotWindow(id:1,pid:1,frame:CGRect(x:0,y:0,width:500,height:500)),new=ShotWindow(id:2,pid:2,frame:CGRect(x:500,y:0,width:500,height:500))
    try check(ShotGeometry.window([new,old],at:CGPoint(x:502,y:200),current:old)?.id==1,"window edge stability")
    try check(ShotGeometry.window([new,old],at:CGPoint(x:520,y:200),current:old)?.id==2,"window switch after crossing border")
    try check(ShotGeometry.resize(CGRect(x:10,y:10,width:100,height:100),handle:"nw",to:CGPoint(x:200,y:200))==CGRect(x:108,y:108,width:2,height:2),"resize never inverts")
    func fixture(_ w: Int,_ h: Int,_ split: Bool,_ green: Bool=false) -> CGImage {
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(green ? NSColor.green.cgColor : NSColor.blue.cgColor); c.fill(CGRect(x:0,y:0,width:w,height:h))
        if split {c.setFillColor(NSColor.red.cgColor); c.fill(CGRect(x:0,y:h/2,width:w,height:h/2))}; return c.makeImage()!
    }
    let left=ShotFrame(id:1,rect:CGRect(x:-100,y:0,width:100,height:100),image:fixture(100,100,true))
    let right=ShotFrame(id:2,rect:CGRect(x:0,y:0,width:100,height:100),image:fixture(200,200,false,true))
    let stitched=try ShotPixels.crop(CGRect(x:-50,y:20,width:100,height:50),from:[left,right]),rep=NSBitmapImageRep(cgImage:stitched)
    try check(stitched.width==200 && stitched.height==100,"cross-display export retains higher Retina scale")
    let red=rep.colorAt(x:20,y:10)!.usingColorSpace(.deviceRGB)!,green=rep.colorAt(x:180,y:10)!.usingColorSpace(.deviceRGB)!,blue=rep.colorAt(x:20,y:90)!.usingColorSpace(.deviceRGB)!
    try check(red.redComponent>0.9 && red.blueComponent<0.1,"top-left orientation")
    try check(blue.blueComponent>0.9 && blue.redComponent<0.1,"bottom-left orientation")
    try check(green.greenComponent>0.9 && green.redComponent<0.1,"right display composition")
    let bytes=try ShotPixels.png(stitched); try bytes.write(to:URL(fileURLWithPath:directory+"/native-multidisplay.png"))
    try check(NSBitmapImageRep(data:bytes)?.pixelsWide==200,"PNG export")
    var invalidRejected=false
    do {_=try ShotPixels.crop(CGRect(x:10000,y:10000,width:100,height:100),from:[left,right])} catch {invalidRejected=true}
    try check(invalidRejected,"disconnected display rejection")
    let mutable=UnsafeMutablePointer<UInt8>.allocate(capacity:16)
    defer {mutable.deallocate()}
    for i in 0..<4 {mutable[i*4]=255;mutable[i*4+1]=0;mutable[i*4+2]=0;mutable[i*4+3]=255}
    let provider=CGDataProvider(dataInfo:nil,data:mutable,size:16,releaseData:{_,_,_ in})!
    let live=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let frozen=try ShotPixels.freeze(live)
    for i in 0..<4 {mutable[i*4]=0;mutable[i*4+2]=255}
    let frozenColor=NSBitmapImageRep(cgImage:frozen).colorAt(x:0,y:0)!.usingColorSpace(.deviceRGB)!
    try check(frozenColor.redComponent>0.9 && frozenColor.blueComponent<0.1,"frozen snapshot pixels survive changes to the original provider")
    var times=[Double]()
    let large=ShotFrame(id:3,rect:CGRect(x:0,y:0,width:1440,height:900),image:fixture(2880,1800,false))
    for _ in 0..<50 {let start=ProcessInfo.processInfo.systemUptime; _=try ShotPixels.crop(CGRect(x:150,y:150,width:800,height:500),from:[large]); times.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
    times.sort()
    // The retained image must be detached from a full-screen selection's lifetime.
    let session=NativeSelectionSession(frames:[left,right],windows:[],motion:false,quickCopy:false)
    session.close(); try check(session.closed && session.frames.isEmpty && session.overlays.isEmpty && session.keyMonitor==nil,"cancel releases surfaces, observers and windows")
    let synthetic=ShotFrame(id:4,rect:CGRect(x:0,y:0,width:1000,height:700),image:fixture(1000,700,true))
    let selection=NativeSelectionSession(frames:[synthetic],windows:[],motion:false,quickCopy:false)
    selection.allowsAX=false; selection.start(show:false); selection.confirm(imageTarget)
    let event=NSEvent.mouseEvent(with:.mouseMoved,location:NSPoint(x:12,y:20),modifierFlags:[],timestamp:0,windowNumber:selection.overlays[0].windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
    try check(selection.views[0].point(for:event)==CGPoint(x:12,y:680),"pointer geometry uses the delivered event instead of a later global cursor position")
    let paints=selection.paintCount
    for _ in 0..<120 {selection.paint(false)}
    try check(selection.paintCount==paints,"idle updates never mutate selection layers")
    func render(_ view: NSView,_ name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw ShotError.message("Cannot render native preview")}
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let bytes=rep.representation(using:.png,properties:[:]) else {throw ShotError.message("Cannot encode preview")}
        try bytes.write(to:URL(fileURLWithPath:directory+"/"+name+".png"))
    }
    try render(selection.views[0],"native-selection")
    let preview=NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:directory+"/native-selection.png")))!
    let previewScale=CGFloat(preview.pixelsWide)/1000
    let selectedColor=preview.colorAt(x:Int(200*previewScale),y:Int(200*previewScale))!.usingColorSpace(.deviceRGB)!
    let outsideColor=preview.colorAt(x:Int(600*previewScale),y:Int(200*previewScale))!.usingColorSpace(.deviceRGB)!
    let dimmedColor=preview.colorAt(x:Int(200*previewScale),y:Int(500*previewScale))!.usingColorSpace(.deviceRGB)!
    try check(selectedColor.redComponent>outsideColor.redComponent+0.12 && selectedColor.redComponent>selectedColor.blueComponent+0.5,"rendered selection hole aligns with actual top-left mouse coordinates")
    try check(dimmedColor.blueComponent<0.85,"rendered dim mask covers pixels outside the selection")
    selection.close(); try check(selection.frames.isEmpty && selection.views.isEmpty && selection.overlays.isEmpty,"full session cancellation releases all windows and snapshots")
    let calm=NativeSelectionSession(frames:[synthetic],windows:[],motion:false,quickCopy:false,tuning:.init(0.25))
    calm.allowsAX=false; calm.start(show:false); calm.adopt(imageTarget,immediate:true); calm.hoverPoint=CGPoint(x:170,y:195); calm.adopt(buttonTarget,immediate:false)
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))
    try check(calm.target==imageTarget,"brief hover movement does not immediately change a fine selection")
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.10))
    try check(calm.target==buttonTarget,"a settled pointer still adopts the fine target promptly")
    calm.adopt(imageTarget,immediate:true); calm.adopt(buttonTarget,immediate:false)
    calm.hoverPoint=CGPoint(x:300,y:250); calm.adopt(imageTarget,immediate:false)
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.23))
    try check(calm.target==imageTarget && calm.pending==nil,"returning to the current target cancels a pending switch")
    calm.hoverPoint=CGPoint(x:170,y:195); calm.adopt(buttonTarget,immediate:false)
    calm.hoverPoint=CGPoint(x:600,y:400)
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.23))
    try check(calm.target==imageTarget,"a delayed target cannot adopt after the pointer has left it")
    calm.close()
    let hierarchy=NativeSelectionSession(frames:[synthetic],windows:[],motion:false,quickCopy:false)
    hierarchy.allowsAX=false;hierarchy.start(show:false)
    hierarchy.hoverPoint=CGPoint(x:170,y:195);hierarchy.candidates=ShotGeometry.normalize([buttonTarget,imageTarget],in:win)
    hierarchy.adopt(buttonTarget,immediate:true);hierarchy.adopt(imageTarget,immediate:false)
    let beforeStep=hierarchy.axGeneration
    hierarchy.step(1)
    try check(hierarchy.target==imageTarget && hierarchy.pending==nil && hierarchy.axGeneration>beforeStep,"manual range change cancels delayed hover and invalidates in-flight AX results")
    hierarchy.hover(hierarchy.hoverPoint)
    try check(hierarchy.target==imageTarget,"a stationary pointer cannot immediately undo manual range switching")
    hierarchy.step(-1)
    try check(hierarchy.target==buttonTarget,"keyboard hierarchy stepping stays immediate without scroll accumulation")
    hierarchy.close()
    let owner=StandaloneApp(demo:true),escaping=NativeSelectionSession(frames:[synthetic],windows:[],motion:false,quickCopy:false)
    escaping.start(show:false); escaping.confirm(imageTarget); owner.selection=escaping
    let pendingDelay=Timer.scheduledTimer(withTimeInterval:100,repeats:false) {_ in}
    owner.delay=pendingDelay; owner.handleHotkey(3)
    try check(owner.selection==nil && escaping.closed && owner.delay==nil && !pendingDelay.isValid,"global Escape dispatcher cancels a locked selection and pending delayed capture")
    let screenSession=NativeSelectionSession(frames:[synthetic],windows:[],motion:false,quickCopy:false)
    screenSession.start(show:false);owner.selection=screenSession
    let layout=[ShotDisplayLayout(id:1,frame:win,scale:2)];owner.screenLayout=layout
    owner.handleScreenChange(layout)
    try check(owner.selection===screenSession && !screenSession.closed,"screen notifications without a physical geometry change preserve the frozen selection")
    owner.handleScreenChange([ShotDisplayLayout(id:1,frame:win,scale:1)])
    try check(owner.selection==nil && screenSession.closed,"a real display scale change still cancels obsolete selection coordinates")
    let ui=NativeCaptureUI(kind:"toolbar"); var actions=[String]()
    ui.setOrigin(barFrame.origin)
    try check(ShotCoordinates.quartz(CGPoint(x:ui.panel.frame.minX,y:ui.panel.frame.maxY))==barFrame.origin,"typed toolbar placement reaches the real AppKit panel without a CGFloat dictionary cast")
    ui.panel.contentView?.layoutSubtreeIfNeeded()
    for button in ui.buttons.values {
        let center=button.convert(NSPoint(x:button.bounds.midX,y:button.bounds.midY),to:button.superview)
        let outside=button.convert(NSPoint(x:button.bounds.maxX+1,y:button.bounds.midY),to:button.superview)
        try check(button.hitTest(center)===button && button.hitTest(outside)==nil && !button.containsPointer(NSPoint(x:0.1,y:0.1)),"button hit region follows its visible rounded boundary")
    }
    ui.send = {if let action=$0["action"] as? String {actions.append(action)}}
    ui.buttons["translate"]?.performClick(nil)
    try check(actions==["translate"],"toolbar action fires once without waiting for press animation")
    try render(ui.panel.contentView!,"native-toolbar")
    let storage=NativeShotStore(root:URL(fileURLWithPath:directory+"/store",isDirectory:true)); try storage.prepare()
    let external=URL(fileURLWithPath:directory+"/legacy.png"),metadata=URL(fileURLWithPath:directory+"/legacy.png.json")
    try bytes.write(to:external); try Data("{\"text\":\"keep-original\"}".utf8).write(to:metadata)
    storage.update(external,["text":"must-not-overwrite-legacy"]); storage.queue.sync {}
    let originalMetadata=try String(contentsOf:metadata,encoding:.utf8)
    try check(originalMetadata=="{\"text\":\"keep-original\"}","legacy history metadata is read-only")
    var saved: Result<URL,Error>?
    storage.store(stitched) {saved=$0}
    let deadline=Date(timeIntervalSinceNow:5)
    while saved==nil && Date()<deadline {_=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))}
    let savedURL=try saved?.get()
    try check(savedURL != nil && FileManager.default.fileExists(atPath:savedURL!.path+".thumb.png"),"background history write includes image and thumbnail")
    var entries: [[String:Any]]?
    storage.entries {entries=$0}
    while entries==nil && Date()<deadline {_=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))}
    let indexedURL=(entries?.first?["path"] as? String).map {URL(fileURLWithPath:$0).resolvingSymlinksInPath()}
    try check(entries?.count==1 && indexedURL==savedURL?.resolvingSymlinksInPath(),"history indexes only its own fixture directory")
    let report: [String:Any]=["ok":true,"assertions":assertions,"fineSelection":true,"centeredToolbar":true,"frozenSnapshot":true,"retinaAndNegativeDisplayCoordinates":true,"borderHysteresis":true,"cancelReleasesSurfaces":true,"cropMedianMs":times[times.count/2],"cropP95Ms":times[Int(Double(times.count)*0.95)],"captureSubprocesses":0,"idleSelectionPollingTimers":0,"idleLayerWrites":selection.paintCount-paints,"legacyHistoryReadOnly":true,"backgroundHistoryWrite":true]
    try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:directory+"/native-report.json"),options:.atomic)
    emit(report)
}

// No NSApplication or screen permissions required for the tuning/geometry checks.
func selectionSettingsSelfTest() throws {
    var count=0
    func check(_ value: @autoclosure ()->Bool,_ label: String) throws {
        guard value() else {throw ShotError.message("Selection settings test failed: "+label)}; count+=1
    }
    try check(abs(ShotSelectionTuning().dwell-0.076)<0.0001,"default hover dwell is responsive at 76 ms")
    try check(ShotSelectionTuning(-1).value==0 && ShotSelectionTuning(2).value==1,"out of range settings clamp safely")
    for value in [Double.nan,Double.infinity,-Double.infinity] {
        try check(ShotSelectionTuning(value).value==ShotSelectionTuning.defaultValue,"invalid persisted values restore the default")
    }
    let window=CGRect(x:0,y:0,width:1000,height:800)
    let image=ShotTarget(rect:CGRect(x:100,y:100,width:300,height:240),role:"AXImage")
    let small=ShotTarget(rect:CGRect(x:150,y:180,width:24,height:20),role:"AXButton")
    let candidates=ShotGeometry.normalize([image,small],in:window)
    var previous=ShotSelectionTuning(0)
    for step in 0...20 {
        let tuning=ShotSelectionTuning(Double(step)/20)
        try check(tuning.dwell<=previous.dwell && tuning.edgeMargin<=previous.edgeMargin,"sensitivity increases consistently")
        try check(ShotGeometry.choose(candidates,at:CGPoint(x:162,y:190),window:window,current:image,tuning:tuning)==small,"small controls stay individually selectable at every sensitivity")
        previous=tuning
    }
    let targets=ShotGeometry.normalize([image],in:window),edge=CGPoint(x:410,y:200)
    try check(ShotGeometry.choose(targets,at:edge,window:window,current:image,tuning:.init(0))==image,"steady setting tolerates border overshoot")
    try check(ShotGeometry.choose(targets,at:edge,window:window,current:image,tuning:.init(1))?.role=="AXWindow","sensitive setting exits borders sooner")
    let old=ShotWindow(id:1,pid:1,frame:CGRect(x:0,y:0,width:500,height:500)),new=ShotWindow(id:2,pid:2,frame:CGRect(x:500,y:0,width:500,height:500))
    try check(ShotGeometry.window([new,old],at:CGPoint(x:506,y:200),current:old,tuning:.init(0))?.id==1,"steady setting retains a window near its border")
    try check(ShotGeometry.window([new,old],at:CGPoint(x:506,y:200),current:old,tuning:.init(1))?.id==2,"sensitive setting switches windows sooner")
    let scroll=ShotScrollTuning(),slow=ShotScrollTuning(0),fast=ShotScrollTuning(1)
    try check(ShotScrollTuning(-1).value==0 && ShotScrollTuning(2).value==1 && ShotScrollTuning(.nan).value==ShotScrollTuning.defaultValue,"scroll setting clamps independently")
    try check(slow.wheelThreshold>fast.wheelThreshold && slow.preciseThreshold>fast.preciseThreshold && slow.repeatInterval>fast.repeatInterval,"lower scroll sensitivity requires more intent and spaces repeats")
    var wheel=ShotScrollIntent()
    try check(wheel.consume(delta:1,precise:false,at:1,tuning:scroll)==nil,"one wheel tick does not overshoot at the default")
    try check(wheel.consume(delta:1,precise:false,at:1.05,tuning:scroll)==nil,"default accumulates deliberate wheel ticks")
    try check(wheel.consume(delta:1,precise:false,at:1.1,tuning:scroll)==1,"third wheel tick advances exactly one level")
    for i in 1...10 {try check(wheel.consume(delta:100,precise:false,at:1.1+Double(i)*0.02,tuning:scroll)==nil,"accelerated burst cannot bank repeated jumps")}
    try check(wheel.consume(delta:100,precise:false,at:1.5,tuning:scroll)==nil,"a burst leaves no stored surplus after cooldown")
    wheel.reset()
    try check(wheel.consume(delta:100,precise:false,at:2,tuning:fast)==1,"fast wheel setting permits one tick per level")
    try check(wheel.consume(delta:100,precise:false,at:2.01,tuning:fast)==nil,"even fast setting caps a burst to one level")
    var trackpad=ShotScrollIntent()
    try check(trackpad.consume(delta:scroll.preciseThreshold/2,precise:true,began:true,at:3,tuning:scroll)==nil,"small trackpad movements accumulate without a jump")
    try check(trackpad.consume(delta:scroll.preciseThreshold/2,precise:true,at:3.02,tuning:scroll)==1,"trackpad advances after crossing its own distance threshold")
    try check(trackpad.consume(delta:999,precise:true,momentum:true,at:4,tuning:scroll)==nil,"momentum cannot change a range")
    try check(trackpad.consume(delta:999,precise:true,ended:true,at:4.1,tuning:scroll)==nil,"gesture end cannot change a range")
    var reverse=ShotScrollIntent()
    _=reverse.consume(delta:1,precise:false,at:5,tuning:scroll)
    _=reverse.consume(delta:1,precise:false,at:5.05,tuning:scroll)
    try check(reverse.consume(delta:-1,precise:false,at:5.1,tuning:scroll)==nil,"direction reversal discards old-direction accumulation")
    _=reverse.consume(delta:-1,precise:false,at:5.15,tuning:scroll)
    try check(reverse.consume(delta:-1,precise:false,at:5.2,tuning:scroll)==(-1),"deliberate reverse input still changes one level")
    reverse.reset()
    _=reverse.consume(delta:1,precise:false,at:6,tuning:scroll)
    _=reverse.consume(delta:1,precise:false,at:6.05,tuning:scroll)
    try check(reverse.consume(delta:1,precise:false,at:7,tuning:scroll)==nil,"separate gestures do not share wheel accumulation")
    try check(reverse.consume(delta:1,precise:true,at:7.01,tuning:scroll)==nil,"changing devices resets accumulation")
    try check(reverse.consume(delta:.nan,precise:true,at:7.1,tuning:scroll)==nil,"invalid event deltas are ignored")
    var dense=ShotScrollIntent(),split=ShotScrollIntent()
    try check(dense.consume(delta:scroll.preciseThreshold,precise:true,at:8,tuning:scroll)==1,"one precise packet can cross one threshold")
    var splitSteps=0
    for i in 0..<10 {if split.consume(delta:scroll.preciseThreshold/10,precise:true,at:8+Double(i)*0.002,tuning:scroll) != nil {splitSteps+=1}}
    try check(splitSteps==1,"trackpad event packet count does not alter distance sensitivity")
    var sustained=ShotScrollIntent(),countedSteps=0
    for i in 0..<120 {if sustained.consume(delta:100,precise:true,at:10+Double(i)/60,tuning:scroll) != nil {countedSteps+=1}}
    try check(countedSteps<=7 && countedSteps>=4,"sustained trackpad input advances deliberately without a rapid burst")
    emit(["ok":true,"assertions":count,"defaultDwellMs":76,"rangeDwellMs":[60,220]])
}
