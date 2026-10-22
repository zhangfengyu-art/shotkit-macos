import Cocoa
import ScreenCaptureKit
import Carbon

@MainActor final class NativeCaptureEngine {
    var content: SCShareableContent?
    var contentAt: TimeInterval = 0
    func invalidate() { content=nil }
    func snapshot() async throws -> [ShotFrame] {
        guard CGPreflightScreenCaptureAccess() else { throw ShotError.message("请先在系统设置中允许 ShotKit 录制屏幕") }
        if let content,!content.applications.contains(where:{$0.processID==getpid()}),!NSApp.windows.isEmpty {invalidate()}
        let share: SCShareableContent
        if let content,ProcessInfo.processInfo.systemUptime-contentAt<2 { share=content }
        else {
            // Include hidden own windows so even a just-dismissed HUD remains excluded.
            share=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            content=share; contentAt=ProcessInfo.processInfo.systemUptime
        }
        let own=share.windows.filter {$0.owningApplication?.processID==getpid()}
        let ownApps=share.applications.filter {$0.processID==getpid()}
        // The native overlay, HUD, pins and result windows are excluded by WindowServer.
        // No hide-and-wait delay and no screencapture subprocess are needed.
        let specs=share.displays.compactMap { display -> (SCContentFilter,SCStreamConfiguration,CGRect,CGDirectDisplayID)? in
            guard let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==display.displayID}) else { return nil }
            let rect=ShotCoordinates.frame(screen),config=SCStreamConfiguration()
            config.width=Int(rect.width*screen.backingScaleFactor); config.height=Int(rect.height*screen.backingScaleFactor)
            config.showsCursor=false; config.capturesAudio=false
            return ((ownApps.isEmpty ? SCContentFilter(display:display,excludingWindows:own) : SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])),config,rect,display.displayID)
        }
        guard !specs.isEmpty else { throw ShotError.message("没有可用的屏幕") }
        return try await withThrowingTaskGroup(of:ShotFrame.self) { group in
            for (filter,config,rect,id) in specs {
                group.addTask { let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config); return ShotFrame(id:id,rect:rect,image:try ShotPixels.freeze(image)) }
            }
            var frames=[ShotFrame](); for try await frame in group { frames.append(frame) }; return frames
        }
    }
    func windows() -> [ShotWindow] {
        guard let entries=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return [] }
        return entries.compactMap { e in
            guard (e[kCGWindowLayer as String] as? Int)==0,(e[kCGWindowAlpha as String] as? Double ?? 1)>0,
                  let pid=e[kCGWindowOwnerPID as String] as? Int32,pid != getpid(),let id=e[kCGWindowNumber as String] as? UInt32,
                  let bounds=e[kCGWindowBounds as String] as? NSDictionary,let r=CGRect(dictionaryRepresentation:bounds),r.width>=24,r.height>=24 else { return nil }
            return ShotWindow(id:id,pid:pid,frame:r)
        }
    }
}

// Carbon's global hotkey registration needs neither Input Monitoring nor an event tap.
final class NativeHotkeys {
    var refs=[EventHotKeyRef]()
    var handler: EventHandlerRef?
    var action: ((UInt32)->Void)?
    var error: OSStatus = noErr
    var cancellation: EventHotKeyRef?
    var cancellationError: OSStatus = noErr
    func start() {
        stop()
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let result=InstallEventHandler(GetApplicationEventTarget(),{ _,event,user in
            guard let event,let user else { return OSStatus(eventNotHandledErr) }
            var hotkey=EventHotKeyID()
            let status=GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&hotkey)
            if status==noErr { Unmanaged<NativeHotkeys>.fromOpaque(user).takeUnretainedValue().action?(hotkey.id) }; return status
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard result==noErr else { error=result; return }
        for (id,flags) in [(UInt32(1),UInt32(cmdKey|controlKey)),(UInt32(2),UInt32(cmdKey|controlKey|shiftKey))] {
            var ref: EventHotKeyRef?
            let status=RegisterEventHotKey(UInt32(kVK_ANSI_A),flags,EventHotKeyID(signature:0x53484F54,id:id),GetApplicationEventTarget(),0,&ref)
            if status==noErr,let ref { refs.append(ref) } else { error=status }
        }
    }
    func setCancellation(_ enabled: Bool) {
        if enabled,cancellation != nil {return}
        if let cancellation {UnregisterEventHotKey(cancellation)}; cancellation=nil
        cancellationError=noErr
        if enabled,handler != nil {
            var ref: EventHotKeyRef?
            cancellationError=RegisterEventHotKey(UInt32(kVK_Escape),0,EventHotKeyID(signature:0x53484F54,id:3),GetApplicationEventTarget(),0,&ref)
            if cancellationError==noErr {cancellation=ref}
        }
    }
    func stop() { setCancellation(false); refs.forEach {UnregisterEventHotKey($0)}; refs=[]; if let handler {RemoveEventHandler(handler)}; handler=nil; error=noErr }
    deinit { stop() }
}
