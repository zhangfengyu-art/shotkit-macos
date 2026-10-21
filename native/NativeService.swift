import Cocoa
import ApplicationServices
import Vision

// One resident process owns the small AppKit panels and performs bounded AX work.
// Commands are acknowledged after reading, so the parent never overwrites stdin.
final class CapturePanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class CaptureButton: NSButton {
    var hover: ((Bool) -> Void)?
    var longPress: (() -> Void)?
    var motion = true
    private(set) var interaction = "idle"
    private var inside = false
    private var down = false
    private var holding = false
    private var tracking: NSTrackingArea?
    private let feedback = CALayer()
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setupFeedback() }
    required init?(coder: NSCoder) { super.init(coder: coder); setupFeedback() }
    private func setupFeedback() {
        wantsLayer = true; layer?.addSublayer(feedback); feedback.cornerRadius = 12
        feedback.zPosition = -1; feedback.opacity = 0
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        feedback.frame = bounds.insetBy(dx: 2, dy: 2)
        layer?.anchorPoint = CGPoint(x: 0.5,y: 0.5)
        layer?.position = CGPoint(x: frame.midX,y: frame.midY)
        CATransaction.commit()
    }
    private func render() {
        interaction = !isEnabled ? "disabled" : holding ? "holding" : down ? "pressed" : inside ? "hover" : "idle"
        let animated = motion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = down ? 0.92 : inside ? 1.035 : 1
        let opacity: Float = !isEnabled ? 0 : down ? 0.24 : holding ? 0.19 : inside ? 0.12 : 0
        let oldScale = layer?.presentation()?.value(forKeyPath:"transform.scale") as? CGFloat ?? 1
        let oldOpacity = feedback.presentation()?.opacity ?? feedback.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        feedback.backgroundColor = NSColor.labelColor.cgColor
        feedback.opacity = opacity; layer?.transform = CATransform3DMakeScale(animated ? scale : 1,animated ? scale : 1,1)
        CATransaction.commit()
        guard animated else { layer?.removeAnimation(forKey:"press"); feedback.removeAllAnimations(); return }
        let spring = CASpringAnimation(keyPath:"transform.scale"); spring.fromValue = oldScale; spring.toValue = scale
        spring.mass = 1; spring.stiffness = down ? 650 : 420; spring.damping = down ? 42 : 28
        spring.duration = down ? 0.10 : 0.28; layer?.add(spring,forKey:"press")
        let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = oldOpacity; fade.toValue = opacity; fade.duration = 0.10; feedback.add(fade,forKey:"feedback")
    }
    override var isEnabled: Bool { didSet { if !isEnabled { down = false; holding = false }; render() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetInteraction() }
    }
    func resetInteraction() { inside = false; down = false; holding = false; render(); hover?(false) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { inside = true; render(); hover?(true) }
    override func mouseExited(with event: NSEvent) { inside = false; render(); hover?(false) }
    override func rightMouseDown(with event: NSEvent) { if isEnabled, let longPress { longPress() } else { super.rightMouseDown(with:event) } }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        inside = true; down = true; render()
        let deadline = Date(timeIntervalSinceNow: 0.45)
        var longEligible = longPress != nil
        // AppKit's tracking run loop sleeps between events; no display-link or polling loop.
        while true {
            guard let next = window.nextEvent(matching:[.leftMouseUp,.leftMouseDragged],until:longEligible ? deadline : .distantFuture,inMode:.eventTracking,dequeue:true) else {
                guard window.isVisible else { resetInteraction(); return }
                guard inside, let longPress else { continue }
                holding = true; down = false; render()
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment,performanceTime:.now)
                longPress(); resetInteraction(); return
            }
            inside = bounds.contains(convert(next.locationInWindow,from:nil))
            if !inside { longEligible = false }
            down = inside; render(); hover?(inside)
            if next.type == .leftMouseUp {
                down = false; render()
                if inside && window.isVisible { _ = sendAction(action,to:target) }
                return
            }
        }
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }; down = true; render()
        _ = sendAction(action,to:target) // Actions are never held back by the animation.
        DispatchQueue.main.async { [weak self] in self?.down = false; self?.render() }
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; performClick(nil); return true }
    override func accessibilityPerformShowMenu() -> Bool { guard isEnabled, let longPress else { return false }; longPress(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    func compactContent(title: String, icon: String) {
        self.title = ""; image = nil
        let glyph = NSImageView(); glyph.image = symbol(icon,title,size: 16); glyph.imageScaling = .scaleProportionallyDown; glyph.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10.5); label.textColor = .labelColor; label.alignment = .center
        for v in [glyph,label] { v.translatesAutoresizingMaskIntoConstraints = false; v.setAccessibilityElement(false); addSubview(v) }
        NSLayoutConstraint.activate([
            glyph.topAnchor.constraint(equalTo: topAnchor,constant: 6),glyph.centerXAnchor.constraint(equalTo: centerXAnchor),glyph.widthAnchor.constraint(equalToConstant: 18),glyph.heightAnchor.constraint(equalToConstant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor,constant: -5),label.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 1),label.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -1),label.heightAnchor.constraint(equalToConstant: 13)
        ])
    }
}

func symbol(_ name: String, _ description: String, size: CGFloat = 17) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: description)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}

func glassSurface(_ content: NSView, radius: CGFloat, tint: NSColor? = nil) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = radius
        glass.tintColor = tint; glass.contentView = content
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        return glass
    }
    let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
    effect.wantsLayer = true; effect.layer?.cornerRadius = radius; effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(content)
    NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),content.topAnchor.constraint(equalTo: effect.topAnchor),content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
    return effect
}
func installServiceMenu() {
    let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
    appMenu.addItem(withTitle: "关闭窗口",action: #selector(NSWindow.performClose(_:)),keyEquivalent: "w"); appItem.submenu = appMenu; menu.addItem(appItem)
    let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
    for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle: title,action: action,keyEquivalent: key) }
    editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
}
func setGlassMotion(_ root: NSView?, enabled: Bool) {
    guard let root else { return }
    if #available(macOS 27.0, *), let glass = root as? NSGlassEffectView { glass.effectIsInteractive = enabled }
    root.subviews.forEach { setGlassMotion($0,enabled: enabled) }
}

final class NativeCaptureUI: NSObject, NSMenuDelegate {
    let panel: CapturePanel
    let content = NSView()
    let tip = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let kind: String
    var session = 0
    var send: (([String: Any]) -> Void)?
    var buttons = [String: CaptureButton]()
    var motion = true
    var defaultTip = "拖动选区可移动 · 长按工具查看更多 · Return 复制"

    init(kind: String) {
        self.kind = kind
        let size = kind == "toolbar" ? NSSize(width: 508, height: 94) : NSSize(width: 504, height: 118)
        panel = CapturePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false; panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = kind == "toolbar" ? "截图工具栏" : "滚动截图"
        if kind == "toolbar" {
            if #available(macOS 26.0, *) {
                let container = NSGlassEffectContainerView(frame: NSRect(origin: .zero,size: size))
                container.spacing = 6; container.contentView = content; panel.contentView = container
            } else { content.frame = NSRect(origin: .zero,size: size); panel.contentView = content }
        } else {
            let surface = glassSurface(content,radius: 24); surface.frame = NSRect(origin: .zero,size: size); panel.contentView = surface
        }
        tip.font = .systemFont(ofSize: 11); tip.textColor = .labelColor
        tip.alignment = .center; tip.lineBreakMode = .byTruncatingTail
        tip.translatesAutoresizingMaskIntoConstraints = false
        if kind != "toolbar" { content.addSubview(tip) }
        if kind == "toolbar" { buildToolbar() } else { buildLongHUD() }
    }

    func button(_ id: String, _ name: String, _ icon: String, _ hint: String, primary: Bool = false) -> CaptureButton {
        let b = CaptureButton(title: name, target: self, action: #selector(invokeCaptureAction(_:)))
        b.identifier = .init(id); b.image = symbol(icon, name, size: 16)
        b.toolTip = hint; b.setAccessibilityLabel(name); b.setAccessibilityHelp(hint)
        b.font = .systemFont(ofSize: 10.5, weight: .regular)
        if primary {
            b.bezelStyle = .rounded; b.imagePosition = .imageLeading
            b.keyEquivalent = "\r"; b.bezelColor = .controlAccentColor
            b.font = .systemFont(ofSize: 13, weight: .semibold)
        } else {
            b.bezelStyle = .recessed; b.isBordered = false; b.contentTintColor = .labelColor
            b.imagePosition = .imageAbove
        }
        b.hover = { [weak self] inside in guard let self else { return }; self.tip.stringValue = inside ? hint + (id == "translate" ? " · 长按选择语言" : id != "cancel" ? " · 长按更多" : "") : self.defaultTip }
        if ["translate","copy","save","ocr","pin","edit","long","more"].contains(id) {
            b.longPress = { [weak self, weak b] in guard let self, let b else { return }; self.showOptions(for:b) }
            b.setAccessibilityHelp(hint + "；长按或右键查看更多选项")
        }
        buttons[id] = b; return b
    }

    func buildToolbar() {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(row)
        let cancel = button("cancel", "取消", "xmark", "取消截图 · Esc")
        cancel.title = ""; cancel.imagePosition = .imageOnly
        let cancelGlass = glassSurface(cancel,radius: 20)
        row.addArrangedSubview(cancelGlass)
        cancelGlass.widthAnchor.constraint(equalToConstant: 40).isActive = true
        cancelGlass.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 0; actions.alignment = .centerY
        let definitions = [
            ("edit", "标注", "square.and.pencil", "标注 · E  箭头、文字、遮盖与裁剪"),
            ("ocr", "文字", "text.viewfinder", "提取文字 · O  识别后可修改、复制或翻译"),
            ("translate", "翻译", "character.bubble", "翻译 · T  自动识别选区文字并翻译"),
            ("pin", "贴图", "pin", "贴图 · P  置顶对照，滚轮缩放，右键关闭"),
            ("long", "长截图", "rectangle.portrait.and.arrow.right", "长截图 · L  逐段截取，保留三分之一重叠"),
            ("save", "保存", "square.and.arrow.down", "保存 · S  选择文件名和保存位置"),
            ("more", "更多", "ellipsis", "更多：读码、延时、AI、重新选择")
        ]
        for (id,name,icon,hint) in definitions {
            let b = button(id,name,icon,hint); b.compactContent(title: name,icon: icon); actions.addArrangedSubview(b)
            b.widthAnchor.constraint(equalToConstant: 47).isActive = true
            b.heightAnchor.constraint(equalToConstant: 46).isActive = true
        }
        let actionContent = NSView(); actions.translatesAutoresizingMaskIntoConstraints = false; actionContent.addSubview(actions)
        NSLayoutConstraint.activate([actions.leadingAnchor.constraint(equalTo: actionContent.leadingAnchor,constant: 9),actions.trailingAnchor.constraint(equalTo: actionContent.trailingAnchor,constant: -9),actions.topAnchor.constraint(equalTo: actionContent.topAnchor,constant: 6),actions.bottomAnchor.constraint(equalTo: actionContent.bottomAnchor,constant: -6)])
        let actionGlass = glassSurface(actionContent,radius: 29); row.addArrangedSubview(actionGlass)
        actionGlass.heightAnchor.constraint(equalToConstant: 58).isActive = true
        actionGlass.widthAnchor.constraint(equalToConstant: 347).isActive = true
        let copy = button("copy", "复制", "doc.on.doc", "复制图片 · Return  完成后直接粘贴",primary: true)
        copy.isBordered = false; copy.contentTintColor = .white
        copy.attributedTitle = NSAttributedString(string: "复制",attributes: [.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize: 13,weight: .semibold)])
        let copyContent = NSView(); copy.translatesAutoresizingMaskIntoConstraints = false; copyContent.addSubview(copy)
        NSLayoutConstraint.activate([copy.leadingAnchor.constraint(equalTo: copyContent.leadingAnchor,constant: 12),copy.trailingAnchor.constraint(equalTo: copyContent.trailingAnchor,constant: -12),copy.topAnchor.constraint(equalTo: copyContent.topAnchor,constant: 7),copy.bottomAnchor.constraint(equalTo: copyContent.bottomAnchor,constant: -7)])
        let copyGlass = glassSurface(copyContent,radius: 22,tint: .controlAccentColor); row.addArrangedSubview(copyGlass)
        copyGlass.widthAnchor.constraint(equalToConstant: 88).isActive = true
        copyGlass.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let tipContent = NSView(); tipContent.addSubview(tip)
        let tipGlass = glassSurface(tipContent,radius: 12); tipGlass.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(tipGlass)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor), row.topAnchor.constraint(equalTo: content.topAnchor,constant: 3),
            tipGlass.centerXAnchor.constraint(equalTo: content.centerXAnchor),tipGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -3),tipGlass.heightAnchor.constraint(equalToConstant: 23),
            tipGlass.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor,constant: -12),
            tip.leadingAnchor.constraint(equalTo: tipContent.leadingAnchor,constant: 12),tip.trailingAnchor.constraint(equalTo: tipContent.trailingAnchor,constant: -12),tip.centerYAnchor.constraint(equalTo: tipContent.centerYAnchor)
        ])
        tip.stringValue = defaultTip
    }

    func buildLongHUD() {
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)
        let close = button("cancel", "取消", "xmark", "取消长截图 · Esc")
        close.title = ""; close.imagePosition = .imageOnly; close.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(close)
        let next = button("next", "取下一段", "plus.rectangle.on.rectangle", "向下滚动一些，再取下一段 · ⌃⌘A", primary: true)
        let finish = button("finish", "完成并拼接", "checkmark", "至少两段后拼接，打开预览检查 · ⇧⌃⌘A")
        finish.bezelStyle = .rounded; finish.imagePosition = .imageLeading; finish.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [next, finish]); row.spacing = 10; row.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(row)
        defaultTip = "向下滚动，保留至少三分之一重叠，再取下一段"
        tip.stringValue = defaultTip
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), close.centerYAnchor.constraint(equalTo: title.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 26),
            tip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), tip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), tip.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor), row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13)
        ])
    }

    func update(_ data: [String: Any]) {
        if data["visible"] as? Bool == false { hide(); return }
        session = data["session"] as? Int ?? 0
        motion = data["motion"] as? Bool ?? true
        buttons.values.forEach { $0.motion = motion }
        setGlassMotion(panel.contentView,enabled: motion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if let rect = data["frame"] as? [String: Double], let x = rect["x"], let y = rect["y"] {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = NSRect(x: x, y: top - y - panel.frame.height, width: panel.frame.width, height: panel.frame.height)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
        }
        if kind == "long" {
            let count = data["count"] as? Int ?? 0
            title.stringValue = "滚动截图 · 已取 \(count) 段"
            buttons["finish"]?.isEnabled = count >= 2
        }
        if !panel.isVisible {
            panel.alphaValue = motion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
            panel.orderFrontRegardless(); panel.makeKey()
            if panel.alphaValue == 0 {
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel.animator().alphaValue = 1 }
                panel.contentView?.wantsLayer = true
                let arrival = CASpringAnimation(keyPath:"transform.scale"); arrival.fromValue = 0.97; arrival.toValue = 1
                arrival.stiffness = 420; arrival.damping = 30; arrival.duration = 0.28
                panel.contentView?.layer?.add(arrival,forKey:"arrival")
            }
        }
    }
    func hide() { buttons.values.forEach { $0.resetInteraction() }; panel.orderOut(nil); panel.alphaValue = 1 }

    func showOptions(for sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "more"
        let definitions: [(String,String,String)]
        switch id {
        case "translate": definitions = [("翻译为简体中文","translate:zh-Hans","character.bubble"),("翻译为英语","translate:en","character.bubble"),("翻译为日语","translate:ja","character.bubble"),("翻译为韩语","translate:ko","character.bubble")]
        case "save","copy": definitions = [("复制图片","copy","doc.on.doc"),("另存为…","save","square.and.arrow.down"),("保存到桌面","desktop","desktopcomputer"),("复制并打开 ChatGPT","ai","bubble.left.and.bubble.right")]
        case "ocr": definitions = [("提取并复制文字","ocr","text.viewfinder"),("识别并翻译","translate","character.bubble"),("读取二维码 / 条形码","qr","qrcode.viewfinder")]
        case "edit","pin","long": definitions = [("标注截图","edit","square.and.pencil"),("贴图置顶","pin","pin"),("开始长截图","long","rectangle.portrait.and.arrow.right"),("重新选择区域","reselect","viewfinder")]
        default: definitions = [("读取二维码 / 条形码","qr","qrcode.viewfinder"),("延时 3 秒截图","delay","timer"),("复制并打开 ChatGPT","ai","bubble.left.and.bubble.right"),("保存到桌面","desktop","desktopcomputer"),("重新选择区域","reselect","viewfinder")]
        }
        let menu = NSMenu(); menu.delegate = self
        for (name,action,icon) in definitions {
            let item = NSMenuItem(title:name,action:#selector(menuAction(_:)),keyEquivalent:""); item.identifier = .init(action); item.target = self; item.image = symbol(icon,name,size:15); menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:-5),in:sender)
    }

    @objc func invokeCaptureAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "more" {
            showOptions(for:sender)
        } else { send?(["event": "action", "kind": kind, "session": session, "action": id]) }
    }
    @objc func menuAction(_ item: NSMenuItem) {
        send?(["event": "action", "kind": kind, "session": session, "action": item.identifier?.rawValue ?? ""])
    }
    func menuWillOpen(_ menu: NSMenu) { send?(["event": "menu", "session": session, "open": true]) }
    func menuDidClose(_ menu: NSMenu) { send?(["event": "menu", "session": session, "open": false]) }
}

final class ShotService: NSObject {
    let axQueue = DispatchQueue(label: "local.shotkit.accessibility", qos: .userInteractive)
    let recognitionQueue = DispatchQueue(label:"local.shotkit.recognition",qos:.userInitiated)
    var panels = [String: NativeCaptureUI]()
    var toast: NativeStatusUI?
    var library: NativeLibraryController?
    var translation: NativeTranslationController?
    var environmentObserver: NSObjectProtocol?
    func start() {
        NSApp.setActivationPolicy(.accessory); installServiceMenu()
        environmentObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object: nil,queue: .main) { _ in
            emit(["event":"environment","reduceMotion":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
        }
        var ready: [String:Any] = ["event": "ready", "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
        if let tiff = symbol("viewfinder","截图",size: 18)?.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png,properties: [:]) {
            ready["menuIcon"] = "data:image/png;base64," + png.base64EncodedString()
        }
        emit(ready)
        RecognitionWarmup.shared.start()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard line.utf8.count < 262144, let bytes = line.data(using: .utf8),
                      let command = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.receive(command) }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        NSApp.run()
    }
    func receive(_ command: [String: Any]) {
        guard let id = command["id"] as? Int, let op = command["op"] as? String else { return }
        emit(["event": "ack", "id": id])
        let data = command["data"] as? [String: Any] ?? [:]
        func reply(_ result: Any) { emit(["event": "reply", "id": id, "data": result]) }
        switch op {
        case "ax":
            let pid = data["pid"] as? Int ?? 0, x = data["x"] as? Double ?? 0, y = data["y"] as? Double ?? 0
            axQueue.async {
                let start = ProcessInfo.processInfo.systemUptime
                let frames = (try? accessibilityChain(["ax", String(pid), String(x), String(y)])) ?? []
                DispatchQueue.main.async { reply(["frames": frames, "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000]) }
            }
        case "panel":
            let kind = data["kind"] as? String ?? "toolbar"
            guard ["toolbar", "long"].contains(kind) else { reply([:]); return }
            if data["visible"] as? Bool != false || panels[kind] != nil {
                if panels[kind] == nil { let panel = NativeCaptureUI(kind: kind); panel.send = emit; panels[kind] = panel }
                panels[kind]?.update(data)
            }
            reply(["ok": true])
        case "appearance":
            let style = data["style"] as? String
            NSApp.appearance = style == "light" ? NSAppearance(named: .aqua) : style == "dark" ? NSAppearance(named: .darkAqua) : nil
            reply(["ok":true])
        case "toast":
            if toast == nil { toast = NativeStatusUI() }
            toast?.show(data); reply(["ok":true])
        case "dismissToast": toast?.hide(); reply(["ok":true])
        case "history":
            if library == nil { library = NativeLibraryController(); library?.send = emit }
            library?.window.level = data["floating"] as? Bool == true ? .floating : .normal
            library?.show(data["items"] as? [[String:Any]] ?? []); library?.window.orderFrontRegardless(); reply(["ok":true])
        case "hideHistory": library?.window.orderOut(nil); emit(["event":"historyVisibility","visible":false]); reply(["ok":true])
        case "translate":
            guard let path = data["path"] as? String, FileManager.default.fileExists(atPath:path) else { reply(["error":"截图不存在"]); return }
            let started = ProcessInfo.processInfo.systemUptime
            if translation == nil { translation = NativeTranslationController(); translation?.model.send = emit }
            translation?.show(path:path,target:data["target"] as? String,startedAt:started); reply(["ok":true,"windowID":translation!.window.windowNumber])
        case "recognize":
            guard let path = data["path"] as? String, FileManager.default.fileExists(atPath:path) else { reply(["error":"截图不存在"]); return }
            RecognitionWarmup.shared.yieldToUser()
            let codesOnly = data["codesOnly"] as? Bool == true
            let key = TranslationMemory.imageKey(path)
            if !codesOnly, let key, let cached = TranslationMemory.shared.text.object(forKey:key) { reply(["text":cached as String,"codes":[]]); return }
            recognitionQueue.async {
                let response = Result { try codesOnly ? recognizeCodes(path) : recognize(path,includeCodes:false) }
                DispatchQueue.main.async {
                    switch response {
                    case .success(let values):
                        if !codesOnly, let key, let text = values["text"] as? String { TranslationMemory.shared.text.setObject(text as NSString,forKey:key,cost:text.utf8.count) }
                        reply(values)
                    case .failure(let error): reply(["error":error.localizedDescription])
                    }
                }
            }
        case "translationStatus":
            var status = translation?.model.diagnostics ?? ["stage":"closed"]
            status["windowVisible"] = translation?.window.isVisible ?? false
            status["windowID"] = translation?.window.windowNumber ?? 0
            reply(status)
        case "translationCancel": translation?.model.cancel(); reply(["ok":true])
        case "interactionStatus":
            reply(panels.mapValues { ui in ui.buttons.mapValues { ["state":$0.interaction,"enabled":$0.isEnabled] as [String:Any] } })
        case "ping": reply(["ok": true])
        case "shutdown": reply(["ok": true]); NSApp.terminate(nil)
        default: reply(["error": "未知服务命令"])
        }
    }
}
