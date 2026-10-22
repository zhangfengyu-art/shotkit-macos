import Cocoa
import SwiftUI
import ServiceManagement
import Darwin

@MainActor final class StandaloneApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let demo: Bool
    let engine=NativeCaptureEngine(),hotkeys=NativeHotkeys()
    let store: NativeShotStore
    var statusItem: NSStatusItem!
    var selection: NativeSelectionSession?
    var captureTask: Task<Void,Never>?,captureGeneration=0
    var delay: Timer?
    var library: NativeLibraryController?,translation: NativeTranslationController?,toast: NativeStatusUI?
    var preferences: NSWindow?
    var retained=[UUID:AnyObject]()
    var pins=[UUID]()
    var observers=[NSObjectProtocol]()
    var lastPath: URL?
    var longRect: CGRect?,longParts=[URL](),longDirectory: URL?,longBusy=false,longGeneration=0
    var longHUD: NativeCaptureUI?,longEscape: Any?
    var captureMs: Double=0,cropMs: Double=0,selectionPaints=0
    var permissionModel: PermissionModel?
    var shutterSound: NSSound?
    var instanceFD: Int32 = -1
    var screenLayout=[ShotDisplayLayout]()
    init(demo: Bool) {
        self.demo=demo
        store=NativeShotStore(root:demo ? FileManager.default.temporaryDirectory.appendingPathComponent("ShotKit-Demo-"+UUID().uuidString) : nil)
        super.init()
    }
    var motion: Bool {(UserDefaults.standard.object(forKey:"motion") as? Bool ?? true) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); installServiceMenu()
        if let menu=NSApp.mainMenu?.items.first?.submenu {
            menu.removeAllItems()
            let about=NSMenuItem(title:"关于 ShotKit",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:""); about.target=NSApp; menu.addItem(about)
            let settings=NSMenuItem(title:"设置…",action:#selector(openSettings(_:)),keyEquivalent:","); settings.target=self; menu.addItem(settings)
            menu.addItem(.separator())
            let quit=NSMenuItem(title:"退出 ShotKit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); quit.target=NSApp; menu.addItem(quit)
        }
        do {try store.prepare()} catch {showError("无法建立截图目录："+error.localizedDescription); NSApp.terminate(nil); return}
        if !demo {
            let lockURL=store.root.deletingLastPathComponent().appendingPathComponent("instance.lock")
            instanceFD=Darwin.open(lockURL.path,O_CREAT|O_RDWR,0o600)
            if instanceFD<0 || flock(instanceFD,LOCK_EX|LOCK_NB) != 0 {NSApp.terminate(nil); return}
        }
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image=symbol("viewfinder","ShotKit 截图",size:18); statusItem.button?.image?.isTemplate=true
        statusItem.button?.toolTip="ShotKit · ⌃⌘A 截图 · ⇧⌃⌘A 历史"
        let menu=NSMenu(); menu.delegate=self; statusItem.menu=menu
        hotkeys.action = { [weak self] id in self?.handleHotkey(id) }
        if !demo {hotkeys.start()}
        screenLayout=ShotCoordinates.layout
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.handleScreenChange(ShotCoordinates.layout)}
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else {return}; self.selection?.motion=self.motion; self.selection?.paint(false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.screensDidSleepNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelCapture(); self?.engine.invalidate() } })
        RecognitionWarmup.shared.start(); writeDiagnostics()
        if demo {beginCapture()}
        else if !CGPreflightScreenCaptureAccess() || !UserDefaults.standard.bool(forKey:"onboarded") || hotkeys.error != noErr {showPreferences()}
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        // Finder / Launch Services may reopen a running app while its capture panel
        // is active. Keep that in-progress selection instead of dismissing it.
        if selection != nil || captureTask != nil || delay != nil || longRect != nil {return true}
        if demo {beginCapture()} else {showPreferences()}; return true
    }
    @objc func openSettings(_ sender: Any?) {showPreferences()}
    func applicationWillTerminate(_ notification: Notification) {
        cancelCapture(); endLong(keep:true); hotkeys.stop(); translation?.model.cancelWork()
        observers.forEach {NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0)}
        if instanceFD>=0 {flock(instanceFD,LOCK_UN); Darwin.close(instanceFD)}
    }
    func enabled(_ key: String,_ fallback: Bool=true) -> Bool {UserDefaults.standard.object(forKey:key) as? Bool ?? fallback}
    func handleHotkey(_ id: UInt32) {
        if id==3 {cancelCapture(); endLong(keep:true)}
        else if id==1 {beginCapture()}
        else if longRect != nil {finishLong()}
        else {showHistory()}
    }
    func handleScreenChange(_ layout: [ShotDisplayLayout]) {
        // Menu bar / Dock / recording-indicator changes can notify without
        // changing capture coordinates. Keep the frozen selection in that case.
        guard layout != screenLayout else {return}
        screenLayout=layout;engine.invalidate();cancelCapture();endLong(keep:true)
    }
    func notify(_ message: String,_ seconds: Double=1.5) {
        if toast==nil {toast=NativeStatusUI()}
        let screen=NSScreen.screens.first {ShotGeometry.inside(ShotCoordinates.frame($0),ShotCoordinates.mouse)} ?? NSScreen.screens[0],f=ShotCoordinates.frame(screen)
        toast?.show(["text":message,"duration":seconds,"centerX":f.midX,"bottomY":f.maxY-36,"screenWidth":f.width,"motion":motion])
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String,_ action: String,_ key: String="",enabled: Bool=true,checked: Bool=false) {
            let i=NSMenuItem(title:title,action:#selector(menuAction(_:)),keyEquivalent:key); i.representedObject=action; i.target=self; i.isEnabled=enabled; i.state=checked ? .on : .off; menu.addItem(i)
        }
        if longRect != nil {item("取下一段  ⌃⌘A","next"); item("完成并拼接  ⇧⌃⌘A","finish"); item("取消长截图","cancelLong"); menu.addItem(.separator())}
        item(demo ? "演示截图" : "选区截图  ⌃⌘A","capture"); item("当前屏幕截图","screen")
        item("重复截取上次区域","repeat",enabled:UserDefaults.standard.dictionary(forKey:"lastRect") != nil)
        item("延时 3 秒截上次区域","delay",enabled:UserDefaults.standard.dictionary(forKey:"lastRect") != nil)
        item("截图历史  ⇧⌃⌘A","history"); item("最近截图操作","latest",enabled:lastPath != nil)
        menu.addItem(.separator()); item("设置与权限…","settings",","); item("功能与按键说明","help")
        item("打开截图历史目录","folder"); menu.addItem(.separator()); item("退出 ShotKit","quit","q")
    }
    @objc func menuAction(_ sender: NSMenuItem) {
        guard let action=sender.representedObject as? String else {return}
        switch action {
        case "capture": DispatchQueue.main.async {self.beginCapture()}
        case "screen": let screen=NSScreen.screens.first {ShotGeometry.inside(ShotCoordinates.frame($0),ShotCoordinates.mouse)} ?? NSScreen.screens[0]; captureFresh(ShotCoordinates.frame(screen),action:"copy")
        case "history": showHistory()
        case "repeat","delay": if let r=lastRect {if action=="delay" {scheduleDelay(r)} else {captureFresh(r,action:"copy")}}
        case "latest": if let lastPath {actionMenu(lastPath).popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)}
        case "settings": showPreferences()
        case "help": showHelp()
        case "folder": NSWorkspace.shared.open(store.root)
        case "quit": NSApp.terminate(nil)
        case "next": nextLong()
        case "finish": finishLong()
        case "cancelLong": endLong(keep:true); notify("已结束长截图，分段仍保留在本机")
        default: break
        }
    }
    var lastRect: CGRect? {
        guard let d=UserDefaults.standard.dictionary(forKey:"lastRect"),let x=d["x"] as? Double,let y=d["y"] as? Double,let w=d["w"] as? Double,let h=d["h"] as? Double,w>=2,h>=2 else {return nil}; return CGRect(x:x,y:y,width:w,height:h)
    }
    func remember(_ r: CGRect) {if !demo {UserDefaults.standard.set(["x":r.minX,"y":r.minY,"w":r.width,"h":r.height],forKey:"lastRect")}}
    func cancelCapture() {
        captureGeneration+=1; captureTask?.cancel(); captureTask=nil; delay?.invalidate(); delay=nil
        if let selection {selectionPaints=selection.paintCount; selection.close()}; selection=nil; toast?.hide(); writeDiagnostics()
    }
    func beginCapture() {
        if selection != nil || captureTask != nil || delay != nil {cancelCapture(); return}
        if longRect != nil {nextLong(); return}
        guard demo || CGPreflightScreenCaptureAccess() else {showPreferences(); return}
        library?.window.orderOut(nil)
        let started=ProcessInfo.processInfo.systemUptime; captureGeneration+=1; let generation=captureGeneration
        captureTask=Task { [weak self] in
            guard let self else {return}
            do {
                let frames=try await (self.demo ? self.demoFrames() : self.engine.snapshot())
                guard !Task.isCancelled,self.captureGeneration==generation else {return}
                self.captureTask=nil; self.captureMs=(ProcessInfo.processInfo.systemUptime-started)*1000
                self.toast?.hide()
                let windows=self.demo ? self.demoWindows(frames) : self.engine.windows()
                let session=NativeSelectionSession(frames:frames,windows:windows,motion:self.motion,quickCopy:self.enabled("quickCopy",false))
                session.allowsAX = !self.demo
                session.action = { [weak self,weak session] name,r,image in
                    guard let self else {return}; self.selectionPaints=session?.paintCount ?? self.selectionPaints; self.cropMs=session?.cropMilliseconds ?? self.cropMs; self.selection=nil
                    if name.hasPrefix("error:") {self.notify(String(name.dropFirst(6)),3)}
                    else if name=="long" {self.beginLong(r)}
                    else if name=="delay" {self.scheduleDelay(r)}
                    else if let image {self.remember(r); self.deliver(image,action:name)}
                    self.writeDiagnostics()
                }
                session.ended = { [weak self,weak session] in guard let self else {return}; self.selectionPaints=session?.paintCount ?? 0; self.selection=nil; self.writeDiagnostics() }
                self.selection=session; session.start(); self.writeDiagnostics()
            } catch {if self.captureGeneration==generation {self.captureTask=nil; self.notify(error.localizedDescription,4); self.writeDiagnostics()}}
        }
        writeDiagnostics()
    }
    func captureFresh(_ r: CGRect,action: String,completion: ((CGImage?)->Void)?=nil) {
        guard captureTask==nil else {return}
        guard demo || CGPreflightScreenCaptureAccess() else {showPreferences(); completion?(nil); return}
        captureGeneration+=1; let generation=captureGeneration; let started=ProcessInfo.processInfo.systemUptime
        captureTask=Task { [weak self] in
            guard let self else {return}
            do {
                let frames=try await (self.demo ? self.demoFrames() : self.engine.snapshot())
                guard !Task.isCancelled,self.captureGeneration==generation else {return}
                let cropStart=ProcessInfo.processInfo.systemUptime,image=try ShotPixels.crop(r,from:frames)
                self.cropMs=(ProcessInfo.processInfo.systemUptime-cropStart)*1000; self.captureMs=(ProcessInfo.processInfo.systemUptime-started)*1000; self.captureTask=nil
                if let completion {completion(image)} else {self.remember(r); self.deliver(image,action:action)}; self.writeDiagnostics()
            } catch {if self.captureGeneration==generation {self.captureTask=nil; self.notify(error.localizedDescription,4); completion?(nil); self.writeDiagnostics()}}
        }
        writeDiagnostics()
    }
    func scheduleDelay(_ r: CGRect) {
        remember(r); delay?.invalidate(); notify("3 秒后截图 · 再按 ⌃⌘A 取消",2)
        delay=Timer.scheduledTimer(withTimeInterval:3,repeats:false) { [weak self] _ in MainActor.assumeIsolated { self?.delay=nil; self?.captureFresh(r,action:"copy") } }
        writeDiagnostics()
    }
    func deliver(_ image: CGImage,action: String) {
        let native=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        let immediate = !["ocr","qr","translate","edit"].contains(action) && !action.hasPrefix("translate:")
        if immediate {copyImage(native); notify("已复制 \(image.width) × \(image.height)",0.9); if enabled("sound") {if shutterSound==nil {shutterSound=NSSound(contentsOfFile:"/System/Library/Sounds/Pop.aiff",byReference:true)}; shutterSound?.volume=0.15; shutterSound?.play()}}
        if action=="pin" {pin(native)}
        if action=="edit" {openEditor(native)}
        if action=="ai" {openAI()}
        let isTranslation=action=="translate" || action.hasPrefix("translate:")
        var translationToken: UUID?
        if isTranslation {let controller=translationController(); controller.show(image:image,target:action.hasPrefix("translate:") ? String(action.dropFirst(10)) : nil); translationToken=controller.model.inputToken}
        store.store(image) { [weak self] result in
            guard let self else {return}
            switch result {
            case .success(let url):
                self.lastPath=url; self.store.prune(keeping:url)
                if action=="save" {self.saveAs(url)} else if action=="desktop" {self.saveDesktop(url)}
                else if isTranslation {
                    if self.translation?.model.inputToken==translationToken {self.translation?.model.path=url.path; if let text=self.translation?.model.source,!text.isEmpty {self.store.update(url,["text":text])}}
                }
                else if ["ocr","qr"].contains(action) {self.recognize(url,action:action)}
            case .failure(let error): self.notify("保存历史失败："+error.localizedDescription,4)
            }
        }
    }
    func perform(_ name: String,url: URL) {
        guard FileManager.default.fileExists(atPath:url.path) else {notify("截图文件已不存在"); return}
        switch name {
        case "copy","ai": do {copyImage(try loadShot(url.path)); notify("已复制图片"); if name=="ai" {openAI()}} catch {notify(error.localizedDescription)}
        case "edit": do {openEditor(try loadShot(url.path))} catch {notify(error.localizedDescription)}
        case "pin": do {pin(try loadShot(url.path))} catch {notify(error.localizedDescription)}
        case "ocr","qr","translate": recognize(url,action:name)
        case "save": saveAs(url)
        case "desktop": saveDesktop(url)
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([url])
        default: break
        }
    }
    func retain(_ value: AnyObject) -> UUID {let id=UUID(); retained[id]=value; return id}
    func release(_ id: UUID) {DispatchQueue.main.async {self.retained.removeValue(forKey:id); self.pins.removeAll {$0==id}}}
    func openEditor(_ image: NSImage) {
        let controller=EditorController(image:image,output:store.newURL().path),id=UUID()
        retained[id]=controller
        controller.onClose = { [weak self] in self?.release(id) }
        controller.onFinish = { [weak self] path in
            guard let self else {return}; let url=URL(fileURLWithPath:path); self.lastPath=url
            if let image=try? loadShot(path) {copyImage(image); self.notify("已复制标注后的图片")}
            self.store.prune(keeping:url)
        }
    }
    func pin(_ image: NSImage) {
        if pins.count>=6,let first=pins.first,let old=retained[first] as? PinController {old.window.close()}
        let controller=PinController(image:image),id=retain(controller); pins.append(id); controller.onClose = { [weak self] in self?.release(id) }
    }
    func translationController() -> NativeTranslationController {
        if let translation {return translation}
        let controller=NativeTranslationController(); controller.model.send = { [weak self] e in
            if e["event"] as? String=="recognized",let path=e["path"] as? String,let text=e["text"] as? String {self?.store.update(URL(fileURLWithPath:path),["text":text])}
        }; translation=controller; return controller
    }
    func recognize(_ url: URL,action: String) {
        if action=="translate" || action.hasPrefix("translate:") {translationController().show(path:url.path,target:action.hasPrefix("translate:") ? String(action.dropFirst(10)) : nil); return}
        let qr=action=="qr",clipboard=NSPasteboard.general.changeCount; notify(qr ? "正在读取二维码…" : "正在本机识别文字…",20)
        RecognitionWarmup.shared.yieldToUser()
        store.queue.async { [weak self] in
            let result=Result {try qr ? recognizeCodes(url.path) : ShotRecognition.text(url.path)}
            DispatchQueue.main.async { [weak self] in
                guard let self else {return}
                switch result {
                case .success(let values):
                    let text=qr ? (values["codes"] as? [String] ?? []).joined(separator:"\n") : (values["text"] as? String ?? "")
                    self.store.update(url,["text":text,"codes":values["codes"] ?? []])
                    guard !text.isEmpty else {self.notify(qr ? "未发现二维码或条形码" : "未识别到文字",2); return}
                    if NSPasteboard.general.changeCount==clipboard {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)}
                    let controller=TextResultController(text:text,qr:qr),id=self.retain(controller)
                    controller.onClose = { [weak self] in self?.release(id) }; controller.onTranslate = { [weak self] text in self?.translationController().show(text:text) }
                    self.notify(qr ? "二维码内容已复制，未自动打开链接" : "识别完成，可在窗口中修改或复制",2)
                case .failure(let error): self.notify(error.localizedDescription,4)
                }
            }
        }
    }
    func openAI() {
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.chat") {NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration(),completionHandler:nil); notify("截图已复制，在 ChatGPT 按 ⌘V 后发送",3)}
        else {notify("截图已复制，可粘贴到你使用的 AI 应用",3)}
    }
    func saveAs(_ url: URL) {
        NSApp.activate(ignoringOtherApps:true); let panel=NSSavePanel(); panel.allowedContentTypes=[.png]; panel.nameFieldStringValue="截图-\(Int(Date().timeIntervalSince1970)).png"
        panel.begin { [weak self] response in guard response == .OK,let destination=panel.url else {return}; self?.copyFile(url,to:destination,message:"已保存图片") }
    }
    func saveDesktop(_ url: URL) {copyFile(url,to:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/截图-\(Int(Date().timeIntervalSince1970)).png"),message:"已保存到桌面")}
    func copyFile(_ source: URL,to destination: URL,message: String) {
        store.queue.async { [weak self] in let result=Result {try Data(contentsOf:source).write(to:destination,options:.atomic)}; DispatchQueue.main.async { [weak self] in switch result {case .success:self?.notify(message); case .failure(let error):self?.notify("保存失败："+error.localizedDescription,4)} }}
    }
    func showHistory() {
        cancelCapture()
        if library==nil {library=NativeLibraryController(); library?.send = { [weak self] e in if let name=e["action"] as? String,let path=e["path"] as? String {self?.perform(name,url:URL(fileURLWithPath:path))} }}
        store.entries { [weak self] items in self?.library?.show(items) }
    }
    func actionMenu(_ url: URL) -> NSMenu {
        let menu=NSMenu()
        for (title,name) in [("复制图片","copy"),("标注截图","edit"),("贴图置顶","pin"),("提取文字","ocr"),("翻译文字","translate"),("读取二维码","qr"),("另存为…","save"),("保存到桌面","desktop"),("复制并打开 ChatGPT","ai"),("在访达中显示","finder")] {
            let item=NSMenuItem(title:title,action:#selector(historyAction(_:)),keyEquivalent:""); item.target=self; item.representedObject=["action":name,"url":url] as [String:Any]; menu.addItem(item)
        }; return menu
    }
    @objc func historyAction(_ sender: NSMenuItem) {if let d=sender.representedObject as? [String:Any],let name=d["action"] as? String,let url=d["url"] as? URL {perform(name,url:url)}}
    func beginLong(_ r: CGRect) {
        guard r.height>=100 else {notify("长截图请框选高度至少 100 点的内容区"); return}
        remember(r); longGeneration+=1; longRect=r; longParts=[]
        let dir=store.root.appendingPathComponent("long-"+UUID().uuidString,isDirectory:true)
        do {try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); longDirectory=dir} catch {notify(error.localizedDescription); longRect=nil; return}
        if longHUD==nil {longHUD=NativeCaptureUI(kind:"long"); longHUD?.send = { [weak self] e in switch e["action"] as? String {case "next":self?.nextLong(); case "finish":self?.finishLong(); case "cancel":self?.endLong(keep:true); default:break} }}
        hotkeys.setCancellation(true)
        longEscape=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in if e.keyCode==53 {self?.endLong(keep:true); return nil}; return e }
        nextLong()
    }
    func nextLong() {
        guard let r=longRect,let directory=longDirectory,!longBusy,captureTask==nil else {return}
        if longParts.count>=20 {finishLong(); return}
        longBusy=true; let generation=longGeneration; longHUD?.hide()
        captureFresh(r,action:"long") { [weak self] image in
            guard let self,self.longGeneration==generation else {return}
            guard let image else {self.longBusy=false; self.showLongHUD(); return}
            let url=directory.appendingPathComponent(String(format:"part-%02d.png",self.longParts.count+1))
            self.store.queue.async {
                let result=Result {try ShotPixels.png(image).write(to:url,options:.atomic)}
                DispatchQueue.main.async {
                    guard self.longGeneration==generation else {return}; self.longBusy=false
                    if case .success=result {self.longParts.append(url)} else {self.notify("保存分段失败",3)}; self.showLongHUD()
                }
            }
        }
    }
    func showLongHUD() {
        guard let r=longRect else {return}
        let screen=NSScreen.screens.first {ShotGeometry.inside(ShotCoordinates.frame($0),CGPoint(x:r.midX,y:r.midY))} ?? NSScreen.screens[0],f=ShotCoordinates.frame(screen)
        let x=max(f.minX+10,min(f.maxX-514,r.midX-252)); let y=r.minY-f.minY>=142 ? r.minY-130 : r.maxY+142<f.maxY ? r.maxY+12 : f.minY+16
        longHUD?.show(at:CGPoint(x:x,y:y),session:longGeneration,motion:motion,count:longParts.count)
    }
    func finishLong() {
        guard longRect != nil,!longBusy,longParts.count>=2 else {notify("先向下滚动，保留三分之一重叠，再取下一段"); return}
        let paths=longParts.map(\.path),directory=longDirectory,output=store.newURL(); endLong(keep:true); notify("正在拼接，完成后打开标注预览…",20)
        store.queue.async { [weak self] in
            let result=Result {try stitch(paths,output:output.path)}
            DispatchQueue.main.async { [weak self] in
                guard let self else {return}
                switch result {
                case .success:
                    if let image=try? loadShot(output.path) {self.lastPath=output; self.openEditor(image); self.notify("拼接完成，请检查接缝后复制或保存",3)}
                    if let directory {try? FileManager.default.removeItem(at:directory)}
                case .failure(let error):self.notify(error.localizedDescription+"；原始分段仍保留在历史目录",5)
                }
            }
        }
    }
    func endLong(keep: Bool) {
        longGeneration+=1; longRect=nil; longBusy=false; longParts=[]; longDirectory=nil; longHUD?.hide()
        hotkeys.setCancellation(false)
        if let longEscape {NSEvent.removeMonitor(longEscape)}; longEscape=nil
        writeDiagnostics()
    }
    func showHelp() {
        let a=NSAlert(); a.messageText="ShotKit 使用说明"; a.informativeText="⌃⌘A 截图 · ⇧⌃⌘A 历史\n\n移动鼠标自动选择窗口或内容；拖动自由框选。单击确定后显示工具栏，拖动内部移动、八个方点调整大小。\n\nReturn / C 复制 · E 标注 · O 文字 · T 翻译 · P 贴图 · S 保存 · L 长截图 · Q 读码 · D 延时 · A 复制到 AI\n\nEsc 取消；右键重新选择。方向键微调位置，Shift 调整大小，Option 加速。长按或右键工具按钮查看更多选项。\n\n长截图：只选滚动内容区，手动向下滚动并保留至少三分之一重叠，再取下一段，最后拼接并检查。\n\n截图历史仅保存在本机。遮盖导出不会删除历史中的原图。"; NSApp.activate(ignoringOtherApps:true); a.runModal()
    }
    func showPreferences() {
        cancelCapture()
        if preferences==nil {
            let model=PermissionModel(app:self); permissionModel=model
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:StandaloneSettings.windowHeight),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title="ShotKit"; w.isReleasedWhenClosed=false; w.contentView=NSHostingView(rootView:StandaloneSettings(model:model)); w.center(); preferences=w
        }
        permissionModel?.refresh(); preferences?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func writeDiagnostics() {
        guard !demo else {return}
        hotkeys.setCancellation(selection != nil || captureTask != nil || delay != nil || longRect != nil)
        let report: [String:Any]=["version":"5.0.4","standalone":true,"pid":getpid(),"hotkeysRegistered":hotkeys.refs.count,"hotkeyError":hotkeys.error,"escapeRegistered":hotkeys.cancellation != nil,"escapeError":hotkeys.cancellationError,"screenRecording":CGPreflightScreenCaptureAccess(),"accessibility":AXIsProcessTrusted(),"selecting":selection != nil,"captureMs":captureMs,"cropMs":cropMs,"selectionPaints":selectionPaints,"pollingTimers":0,"longCapture":longRect != nil,"updated":Date().timeIntervalSince1970]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]) {try? data.write(to:store.root.deletingLastPathComponent().appendingPathComponent("status.json"),options:.atomic)}
    }
    func demoFrames() async throws -> [ShotFrame] {
        let screen=NSScreen.screens[0],r=ShotCoordinates.frame(screen),scale=screen.backingScaleFactor
        let img=NSImage(size:NSSize(width:r.width*scale,height:r.height*scale),flipped:true) { bounds in
            NSColor(calibratedRed:0.1,green:0.15,blue:0.24,alpha:1).setFill(); bounds.fill()
            let card=NSRect(x:180*scale,y:150*scale,width:800*scale,height:440*scale)
            NSColor.white.setFill(); NSBezierPath(roundedRect:card,xRadius:24*scale,yRadius:24*scale).fill()
            ("ShotKit · Native Capture" as NSString).draw(at:NSPoint(x:220*scale,y:200*scale),withAttributes:[.font:NSFont.systemFont(ofSize:32*scale,weight:.semibold),.foregroundColor:NSColor.black])
            ("Hello. Screenshot capture runs natively on macOS.\nSelect, annotate, translate, and keep your ideas.\n\n⌃⌘A Capture     ⇧⌃⌘A History\nNo Hammerspoon required." as NSString).draw(at:NSPoint(x:220*scale,y:285*scale),withAttributes:[.font:NSFont.systemFont(ofSize:22*scale),.foregroundColor:NSColor.darkGray])
            return true
        }
        return [ShotFrame(id:0,rect:r,image:try cgImage(img))]
    }
    func demoWindows(_ frames: [ShotFrame]) -> [ShotWindow] {[ShotWindow(id:1,pid:getpid(),frame:CGRect(x:180,y:150,width:800,height:440))]}
}
enum ShotRecognition {static func text(_ path: String) throws -> [String:Any] {try recognize(path,includeCodes:false)}}

@MainActor final class PermissionModel: ObservableObject {
    weak var app: StandaloneApp?
    @Published var screen=false
    @Published var accessibility=false
    @Published var login=false
    @Published var message=""
    init(app: StandaloneApp) {self.app=app; refresh()}
    func refresh() {if let app,!app.demo,app.hotkeys.error != noErr {app.hotkeys.start()}; screen=CGPreflightScreenCaptureAccess(); accessibility=AXIsProcessTrusted(); login=SMAppService.mainApp.status == .enabled; app?.writeDiagnostics()}
    func requestScreen() { _=CGRequestScreenCaptureAccess(); if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {NSWorkspace.shared.open(url)} }
    func requestAccessibility() {
        _=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {NSWorkspace.shared.open(url)}
    }
    func start() {refresh(); guard screen || app?.demo==true else {message="先允许屏幕录制，然后点“重新检查权限”。"; return}; if app?.demo != true {UserDefaults.standard.set(true,forKey:"onboarded")}; app?.preferences?.orderOut(nil); app?.beginCapture()}
    func setLogin(_ value: Bool) {
        do {if value {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()}; message=""} catch {message="登录启动设置未完成："+error.localizedDescription}; refresh()
    }
}
struct StandaloneSettings: View {
    @ObservedObject var model: PermissionModel
    @AppStorage("motion") var motion=true
    @AppStorage("sound") var sound=true
    @AppStorage("quickCopy") var quickCopy=false
    @AppStorage("historyCount") var historyCount=60
    @AppStorage("legacyHistory") var legacyHistory=true
    @AppStorage("hoverSelectionSensitivity") var selectionSensitivity=ShotSelectionTuning.defaultValue
    @AppStorage("scrollSelectionSensitivity") var scrollSelectionSensitivity=ShotScrollTuning.defaultValue
    static var windowHeight: CGFloat {min(760,max(540,(NSScreen.main?.visibleFrame.height ?? 830)-70))}
    var body: some View {
        VStack(spacing:0) {
          ScrollView {
           VStack(alignment:.leading,spacing:20) {
            HStack(spacing:16) {
                Image(nsImage:NSApp.applicationIconImage).resizable().scaledToFit().frame(width:76,height:76)
                VStack(alignment:.leading,spacing:4) {Text("ShotKit").font(.largeTitle.weight(.semibold)); Text("原生截图 · 独立运行").foregroundStyle(.secondary)}
                Spacer(); Text("5.0.4").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:14) {
                permission("屏幕录制",detail:"用于获取你选择的屏幕像素，截图只保存在本机。",ready:model.screen,required:true,action:model.requestScreen)
                Divider()
                permission("辅助功能",detail:"可选。允许识别窗口里的图片、按钮和内容块。",ready:model.accessibility,required:false,action:model.requestAccessibility)
            }.padding(18).background(.quaternary.opacity(0.55),in:RoundedRectangle(cornerRadius:16))
            HStack {Button("重新检查权限") {model.refresh()}; Spacer(); Text("⌃⌘A 截图 · ⇧⌃⌘A 历史").font(.callout).foregroundStyle(.secondary)}
            Divider()
            VStack(alignment:.leading,spacing:12) {
                Toggle("登录时启动 ShotKit",isOn:Binding(get:{model.login},set:model.setLogin))
                HStack {Toggle("轻量动效",isOn:$motion); Spacer(); Toggle("截图声音",isOn:$sound)}
                Toggle("松开鼠标直接复制",isOn:$quickCopy)
                HStack {Text("历史保留数量"); Spacer(); Picker("历史保留数量",selection:$historyCount) {Text("12 张").tag(12); Text("60 张").tag(60); Text("100 张").tag(100)}.labelsHidden().frame(width:110)}
                Toggle("同时显示旧版截图历史（原文件保持原位）",isOn:$legacyHistory).font(.callout)
            }
            sensitivity(title:"滚轮切换灵敏度",value:$scrollSelectionSensitivity,defaultValue:ShotScrollTuning.defaultValue,label:ShotScrollTuning(scrollSelectionSensitivity).label,detail:"调低后需要更多滚动才切换一级。触控板惯性不会连跳；Tab、上下键仍按一次切一级。下次截图生效。")
            sensitivity(title:"自动识别响应",value:$selectionSensitivity,defaultValue:ShotSelectionTuning.defaultValue,label:ShotSelectionTuning(selectionSensitivity).label,detail:"默认快速跟随鼠标识别目标，与滚轮切换独立。手动框选即时响应，轻量动效跟随系统设置。下次截图生效。")
            if let app=model.app,app.hotkeys.error != noErr {Text("快捷键被其他应用占用。旧版截图模块停用后，点“重新检查权限”。").font(.callout).foregroundStyle(.orange)}
            if !model.message.isEmpty {Text(model.message).font(.callout).foregroundStyle(.secondary)}
           }.padding(28)
          }
            Divider().padding(.horizontal,28)
            HStack {Button("查看使用说明") {model.app?.showHelp()}.buttonStyle(.link); Spacer(); Button("开始截图",action:model.start).modifier(SystemGlassAction(prominent:true)).keyboardShortcut(.defaultAction)}.padding(.horizontal,28).padding(.vertical,18)
        }.frame(width:560,height:Self.windowHeight)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in model.refresh()}
    }
    func sensitivity(title: String,value: Binding<Double>,defaultValue: Double,label: String,detail: String) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(title).font(.headline);Spacer();Text(label).foregroundStyle(.secondary)
                Button("恢复默认") {value.wrappedValue=defaultValue}.controlSize(.small).disabled(abs(value.wrappedValue-defaultValue)<0.001)
            }
            HStack(spacing:12) {
                Text("更稳").font(.caption).foregroundStyle(.secondary)
                SelectionSensitivitySlider(value:value,title:title).frame(height:22)
                Text("更灵敏").font(.caption).foregroundStyle(.secondary)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(16).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:14))
    }
    func permission(_ title: String,detail: String,ready: Bool,required: Bool,action: @escaping ()->Void) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:ready ? "checkmark.circle.fill" : required ? "rectangle.dashed" : "cursorarrow.rays").font(.title2).foregroundStyle(ready ? Color.green : Color.secondary).frame(width:28)
            VStack(alignment:.leading,spacing:5) {Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            Spacer(); Button(ready ? "已允许" : "去设置",action:action).disabled(ready).controlSize(.small)
        }
    }
}

struct SelectionSensitivitySlider: NSViewRepresentable {
    @Binding var value: Double
    let title: String
    func makeCoordinator() -> Coordinator {Coordinator(value:$value)}
    func makeNSView(context: Context) -> NSSlider {
        let slider=NSSlider(value:ShotSelectionTuning(value).value,minValue:0,maxValue:1,target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        slider.isContinuous=true; slider.altIncrementValue=0.05
        slider.setAccessibilityLabel(title)
        return slider
    }
    func updateNSView(_ slider: NSSlider,context: Context) {
        context.coordinator.value=$value
        slider.doubleValue=ShotSelectionTuning(value).value
    }
    class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) {self.value=value}
        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue=(ShotSelectionTuning(sender.doubleValue).value*20).rounded()/20
        }
    }
}
