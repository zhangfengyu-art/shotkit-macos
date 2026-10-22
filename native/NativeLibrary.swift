import Cocoa
import ImageIO

final class NativeStatusUI {
    let panel = CapturePanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
    let message = NSTextField(wrappingLabelWithString: "")
    let image = NSImageView()
    let spinner = NSProgressIndicator()
    var timer: Timer?
    var revision = 0
    init() {
        panel.allowsKey = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        let root = NSView(); panel.contentView = glassSurface(root,radius: 23)
        setGlassMotion(panel.contentView,enabled: false)
        message.font = .systemFont(ofSize: 13,weight: .medium); message.maximumNumberOfLines = 3
        message.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for v in [image,message,spinner] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 18),image.centerYAnchor.constraint(equalTo: root.centerYAnchor),image.widthAnchor.constraint(equalToConstant: 22),image.heightAnchor.constraint(equalToConstant: 22),
            spinner.centerXAnchor.constraint(equalTo: image.centerXAnchor),spinner.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: image.trailingAnchor,constant: 12),message.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -20),message.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
    }
    func show(_ data: [String:Any]) {
        timer?.invalidate(); revision += 1
        let wasVisible = panel.isVisible
        let text = data["text"] as? String ?? ""; message.stringValue = text
        let progress = text.hasSuffix("…")
        image.isHidden = progress
        if progress { spinner.startAnimation(nil) } else {
            spinner.stopAnimation(nil)
            let warning = ["失败","超时","错误","缺失"].contains { text.contains($0) }
            let done = text.hasPrefix("已") || text.contains("复制")
            image.image = symbol(warning ? "exclamationmark.circle.fill" : done ? "checkmark.circle.fill" : "info.circle",text,size: 21)
            image.contentTintColor = warning ? .systemOrange : done ? .systemGreen : .secondaryLabelColor
        }
        let maxWidth = min(560,((data["screenWidth"] as? NSNumber)?.doubleValue ?? 800)-40)
        let measured = (text as NSString).size(withAttributes: [.font: message.font!]).width
        let width = min(maxWidth,max(210,measured+76))
        message.preferredMaxLayoutWidth = width-76
        let bounds = (text as NSString).boundingRect(with: NSSize(width: width-76,height: 100),options: [.usesLineFragmentOrigin],attributes: [.font: message.font!])
        let height = min(96,max(52,ceil(bounds.height)+30))
        let x = (data["centerX"] as? NSNumber)?.doubleValue ?? 500, y = (data["bottomY"] as? NSNumber)?.doubleValue ?? 700
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(NSRect(x: x-width/2,y: top-y,width: width,height: height),display: true)
        let animated = data["motion"] as? Bool != false && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animated && !wasVisible ? 0 : 1; panel.orderFrontRegardless()
        if animated && !wasVisible { NSAnimationContext.runAnimationGroup { $0.duration = 0.13; panel.animator().alphaValue = 1 } }
        if animated && !progress { image.addSymbolEffect(.bounce,options:.nonRepeating) }
        let current = revision
        timer = Timer.scheduledTimer(withTimeInterval: max(0.5,data["duration"] as? Double ?? 1.5),repeats: false) { [weak self] _ in
            guard let self, self.revision == current else { return }; self.hide(animated:animated)
        }
    }
    func hide(animated: Bool = false) {
        revision += 1; let current = revision; timer?.invalidate(); timer = nil; spinner.stopAnimation(nil)
        guard animated else { panel.orderOut(nil); panel.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; self.panel.animator().alphaValue = 0 },completionHandler:{ [weak self] in
            guard let self, self.revision == current else { return }; self.panel.orderOut(nil); self.panel.alphaValue = 1
        })
    }
}

final class LibraryTile: NSView {
    var press: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self); addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateLayer() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateLayer() }
    override func accessibilityPerformPress() -> Bool { guard let press else { return false }; press(); return true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    var selected = false { didSet { needsDisplay = true; needsLayout = true; updateLayer() } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        CATransaction.begin(); CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
        layer?.backgroundColor = (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.06) : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor; layer?.borderWidth = selected ? 2 : hovered ? 1 : 0
        CATransaction.commit()
    }
}
final class LibraryItem: NSCollectionViewItem {
    let preview = NSImageView(), heading = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    var path = ""
    override var isSelected: Bool { didSet { (view as? LibraryTile)?.selected = isSelected } }
    override func loadView() {
        let root = LibraryTile(); root.wantsLayer = true; root.layer?.cornerRadius = 14; root.layer?.masksToBounds = true; view = root
        preview.imageScaling = .scaleProportionallyUpOrDown
        heading.font = .systemFont(ofSize: 12,weight: .medium); detail.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular); detail.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail; detail.lineBreakMode = .byTruncatingTail
        for v in [preview,heading,detail] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 12),preview.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -12),preview.topAnchor.constraint(equalTo: root.topAnchor,constant: 12),preview.heightAnchor.constraint(equalToConstant: 126),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 14),heading.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -14),heading.topAnchor.constraint(equalTo: preview.bottomAnchor,constant: 10),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),detail.trailingAnchor.constraint(equalTo: heading.trailingAnchor),detail.topAnchor.constraint(equalTo: heading.bottomAnchor,constant: 5)
        ])
        root.setAccessibilityElement(true); root.setAccessibilityRole(.button)
    }
}
final class LibraryCollection: NSCollectionView {
    var activate: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    override var acceptsFirstResponder: Bool { true }
    @objc func copy(_ sender: Any?) { activate?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c") { activate?(); return }
        if event.keyCode == 53 { window?.performClose(nil); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let index = indexPathForItem(at: convert(event.locationInWindow,from: nil)) { selectionIndexPaths = [index] }
        return makeMenu?()
    }
}
final class NativeLibraryController: NSObject, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 940,height: 680),styleMask: [.titled,.closable,.resizable,.miniaturizable],backing: .buffered,defer: false)
    let collection = LibraryCollection(), search = NSSearchField()
    let empty = NSTextField(labelWithString: "")
    let footer = NSTextField(labelWithString: "双击或按 Return 复制 · 右键查看更多操作")
    let cache = NSCache<NSString,NSImage>()
    var items = [[String:Any]](), filtered = [[String:Any]]()
    var controls = [String:NSToolbarItem]()
    var send: (([String:Any]) -> Void)?
    override init() {
        super.init()
        window.title = "截图历史"; window.toolbarStyle = .unified; window.minSize = NSSize(width: 700,height: 460)
        window.delegate = self; window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "ShotKit.Library"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; window.toolbar = toolbar
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let flow = NSCollectionViewFlowLayout(); flow.itemSize = NSSize(width: 200,height: 192); flow.minimumInteritemSpacing = 16; flow.minimumLineSpacing = 16; flow.sectionInset = NSEdgeInsets(top: 20,left: 20,bottom: 20,right: 20)
        collection.frame = NSRect(x: 0,y: 0,width: 940,height: 600); collection.autoresizingMask = [.width]; collection.wantsLayer = true
        collection.collectionViewLayout = flow; collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.backgroundColors = [.windowBackgroundColor]; collection.dataSource = self; collection.delegate = self
        collection.register(LibraryItem.self,forItemWithIdentifier: .init("shot")); scroll.documentView = collection
        let doubleClick = NSClickGestureRecognizer(target: self,action: #selector(copySelection)); doubleClick.numberOfClicksRequired = 2; collection.addGestureRecognizer(doubleClick)
        collection.activate = { [weak self] in self?.copySelection() }
        collection.makeMenu = { [weak self] in self?.refreshControls(); return self?.actionMenu() ?? NSMenu() }
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 17,weight: .medium); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        for v in [scroll,footer,empty] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),scroll.topAnchor.constraint(equalTo: root.topAnchor),scroll.bottomAnchor.constraint(equalTo: footer.topAnchor,constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 22),footer.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        cache.totalCostLimit = 12*1024*1024
    }
    func show(_ entries: [[String:Any]]) {
        items = Array(entries.prefix(100)); search.stringValue = ""; applyFilter()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(collection); send?(["event":"historyVisibility","visible":true])
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace,.init("edit"),.init("pin"),.init("more"),.init("copy"),.init("search")] }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier identifier: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: identifier); search.placeholderString = "搜索时间或文字"; search.delegate = self; item.searchField = search; item.preferredWidthForSearchField = 220; return item
        }
        let item: NSToolbarItem
        if identifier.rawValue == "more" { let more = NSMenuToolbarItem(itemIdentifier: identifier); more.menu = actionMenu(); more.showsIndicator = true; item = more }
        else { item = NSToolbarItem(itemIdentifier: identifier) }
        let names = ["edit":("标注","square.and.pencil"),"pin":("贴图","pin"),"more":("更多","ellipsis.circle"),"copy":("复制","doc.on.doc")]
        if let (name,icon) = names[identifier.rawValue] { item.label = name; item.toolTip = name; item.image = symbol(icon,name); item.target = self; if identifier.rawValue != "more" { item.action = #selector(toolbarAction(_:)) } }
        item.autovalidates = false; controls[identifier.rawValue] = item; return item
    }
    var selected: [String:Any]? { guard let index = collection.selectionIndexPaths.first?.item, filtered.indices.contains(index) else { return nil }; return filtered[index] }
    func refreshControls() { controls.values.forEach { $0.isEnabled = selected != nil } }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = query.isEmpty ? items : items.filter { (($0["title"] as? String ?? "") + " " + ($0["text"] as? String ?? "")).localizedStandardContains(query) }
        collection.reloadData()
        if !filtered.isEmpty { collection.selectionIndexPaths = [IndexPath(item: 0,section: 0)] }
        empty.stringValue = items.isEmpty ? "还没有截图，按 ⌃⌘A 开始" : "没有找到匹配的截图"
        empty.isHidden = !filtered.isEmpty; window.subtitle = "\(filtered.count) 张截图"; refreshControls()
    }
    func collectionView(_ collectionView: NSCollectionView,numberOfItemsInSection section: Int) -> Int { filtered.count }
    func collectionView(_ collectionView: NSCollectionView,itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: .init("shot"),for: indexPath) as! LibraryItem
        let entry = filtered[indexPath.item], path = entry["path"] as? String ?? "", thumb = entry["thumb"] as? String ?? ""
        (cell.view as? LibraryTile)?.press = { [weak self] in
            guard let self else { return }; self.collection.selectionIndexPaths = [indexPath]; self.refreshControls(); self.window.makeFirstResponder(self.collection)
        }
        cell.path = path; cell.heading.stringValue = entry["title"] as? String ?? "截图"; cell.detail.stringValue = entry["detail"] as? String ?? ""
        cell.view.setAccessibilityLabel(cell.heading.stringValue + "，" + cell.detail.stringValue)
        if let image = cache.object(forKey: path as NSString) { cell.preview.image = image }
        else {
            cell.preview.image = symbol("photo","截图缩略图",size: 30)
            DispatchQueue.global(qos: .userInitiated).async { [weak self,weak cell] in
                let source = FileManager.default.fileExists(atPath: thumb) ? thumb : path
                guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL,nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(imageSource,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240] as CFDictionary) else { return }
                let image = NSImage(cgImage: cg,size: NSSize(width: cg.width,height: cg.height))
                DispatchQueue.main.async { self?.cache.setObject(image,forKey: path as NSString,cost: cg.width*cg.height*4); if cell?.path == path { cell?.preview.image = image } }
            }
        }
        return cell
    }
    func collectionView(_ collectionView: NSCollectionView,didSelectItemsAt indexPaths: Set<IndexPath>) { refreshControls() }
    func collectionView(_ collectionView: NSCollectionView,didDeselectItemsAt indexPaths: Set<IndexPath>) { refreshControls() }
    func actionMenu() -> NSMenu {
        let menu = NSMenu()
        for (name,id,icon) in [("复制图片","copy","doc.on.doc"),("标注截图","edit","square.and.pencil"),("贴图置顶","pin","pin"),("提取文字","ocr","text.viewfinder"),("翻译文字","translate","character.bubble"),("读取二维码","qr","qrcode"),("另存为…","save","square.and.arrow.down"),("复制并打开 ChatGPT","ai","bubble.left.and.bubble.right"),("在访达中显示","finder","folder")] {
            let item = NSMenuItem(title: name,action: #selector(menuAction(_:)),keyEquivalent: ""); item.identifier = .init(id); item.target = self; item.image = symbol(icon,name,size: 15); menu.addItem(item)
        }
        return menu
    }
    func activate(_ action: String) { if let path = selected?["path"] as? String { send?(["event":"historyAction","path":path,"action":action]) } }
    @objc func copySelection() { activate("copy") }
    @objc func toolbarAction(_ sender: NSToolbarItem) { activate(sender.itemIdentifier.rawValue) }
    @objc func menuAction(_ sender: NSMenuItem) { activate(sender.identifier?.rawValue ?? "copy") }
    func windowWillClose(_ notification: Notification) { send?(["event":"historyVisibility","visible":false]) }
}
