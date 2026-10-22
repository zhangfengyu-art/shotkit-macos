import Cocoa
import ApplicationServices
import Vision
import CoreImage
import SwiftUI
typealias StoredState<Value> = SwiftUI.State<Value>
import Translation
import ImageIO
import NaturalLanguage

// Shared native image tools. The default entry point is the independent menu bar app.
var standaloneRuntime = false
enum ShotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
func emit(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
func fail(_ message: String) -> Never { emit(["error": message]); exit(1) }
func loadShot(_ path: String) throws -> NSImage {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ShotError.message("图片读取失败")
    }
    let result = NSImage(size: NSSize(width: cg.width,height: cg.height))
    result.addRepresentation(NSBitmapImageRep(cgImage: cg))
    return result
}
func cgImage(_ image: NSImage) throws -> CGImage {
    if let rep = image.representations.first as? NSBitmapImageRep, rep.pixelsWide == Int(image.size.width), rep.pixelsHigh == Int(image.size.height), let cg = rep.cgImage { return cg }
    // NSImage drawing handlers otherwise adopt the current screen's Retina scale.
    // Use an explicit 1:1 bitmap context so pixel coordinates and exported size agree.
    let width = Int(image.size.width.rounded()), height = Int(image.size.height.rounded())
    guard width > 0, height > 0, width * height <= 100_000_000,
          let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ShotError.message("图片尺寸过大或无法建立像素缓冲区")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
    image.draw(in: NSRect(x: 0,y: 0,width: width,height: height),from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = context.makeImage() else { throw ShotError.message("图片解码失败") }
    return cg
}
func savePNG(_ image: NSImage, _ path: String) throws {
    let rep = NSBitmapImageRep(cgImage: try cgImage(image))
    guard let data = rep.representation(using: .png, properties: [:]) else { throw ShotError.message("PNG 编码失败") }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
func copyImage(_ image: NSImage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
}

func accessibilityChain(_ args: [String]) throws -> [[String: Any]] {
    guard args.count >= 4, let pid = Int32(args[1]), let x = Double(args[2]), let y = Double(args[3]) else { return [] }
    return accessibilityTargets(pid,at:CGPoint(x:x,y:y)).map { target in
        ["x":Double(target.rect.minX),"y":Double(target.rect.minY),"w":Double(target.rect.width),"h":Double(target.rect.height),"role":target.role]
    }
}

// Keep geometry typed inside the app. CGFloat held in Any does not cast to Double;
// the former JSON bridge used to hide that distinction.
func accessibilityTargets(_ pid: pid_t,at point: CGPoint) -> [ShotTarget] {
    let x=point.x,y=point.y
    guard x.isFinite,y.isFinite else {return []}
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.025)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit) == .success else { return [] }
    let start = ProcessInfo.processInfo.systemUptime
    var result = [ShotTarget]()
    var current = hit
    func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
    }
    for _ in 0..<14 {
        guard let e = current, ProcessInfo.processInfo.systemUptime - start < 0.12 else { break }
        AXUIElementSetMessagingTimeout(e, 0.02)
        var p = CGPoint.zero, s = CGSize.zero
        if let position = attribute(e, kAXPositionAttribute), let size = attribute(e, kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p),
           AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s),
           s.width >= 16, s.height >= 14, CGRect(origin: p, size: s).contains(CGPoint(x: x, y: y)) {
            let role = attribute(e, kAXRoleAttribute) as? String ?? ""
            let decorative = ["AXSplitter", "AXScrollBar", "AXRuler", "AXGrowArea", "AXHandle", "AXSeparator"].contains(role)
            if !decorative && (role != "AXStaticText" || (s.width >= 60 && s.height >= 20)) {
                result.append(ShotTarget(rect:CGRect(origin:p,size:s),role:role))
            }
        }
        guard let parent = attribute(e, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        let next = unsafeBitCast(parent, to: AXUIElement.self)
        if CFEqual(e, next) { break }
        current = next
    }
    return result
}

func configureRecognition(_ request: VNRecognizeTextRequest) throws {
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let supported = try request.supportedRecognitionLanguages()
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].filter { supported.contains($0) }
}
func recognize(_ path: String, includeCodes: Bool = true, request: VNRecognizeTextRequest = VNRecognizeTextRequest()) throws -> [String: Any] {
    try recognizeHandler(VNImageRequestHandler(url:URL(fileURLWithPath:path)),includeCodes:includeCodes,request:request)
}
func recognize(_ image: CGImage, includeCodes: Bool = true, request: VNRecognizeTextRequest = VNRecognizeTextRequest()) throws -> [String: Any] {
    try recognizeHandler(VNImageRequestHandler(cgImage:image),includeCodes:includeCodes,request:request)
}
private func recognizeHandler(_ handler: VNImageRequestHandler,includeCodes: Bool,request: VNRecognizeTextRequest) throws -> [String:Any] {
    try configureRecognition(request)
    let codes = VNDetectBarcodesRequest()
    try handler.perform(includeCodes ? [request, codes] : [request])
    // Preserve line ordering instead of joining distant columns into one sentence.
    let lines = (request.results ?? []).sorted {
        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 { return $0.boundingBox.midY > $1.boundingBox.midY }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }.compactMap { $0.topCandidates(1).first?.string }
    return ["text": lines.joined(separator: "\n"), "codes": (codes.results ?? []).compactMap { $0.payloadStringValue }]
}
func recognizeCodes(_ path: String) throws -> [String:Any] {
    let request = VNDetectBarcodesRequest()
    try VNImageRequestHandler(url:URL(fileURLWithPath:path)).perform([request])
    return ["text":"", "codes":(request.results ?? []).compactMap { $0.payloadStringValue }]
}

struct Gray {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    init(_ image: NSImage) throws {
        let cg = try cgImage(image)
        width = 112; height = cg.height
        guard height <= 12000, cg.width <= 16000 else { throw ShotError.message("单张图片过大") }
        let sampleWidth = width, sampleHeight = height
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let c = CGContext(data: ptr.baseAddress, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
                bytesPerRow: sampleWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.interpolationQuality = .medium
            c.draw(cg, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard ok else { throw ShotError.message("拼接采样失败") }
        // CG bitmap row zero corresponds to the source's top row for this draw.
        bytes = pixels
    }
}

func verticalShift(_ a: Gray, _ b: Gray) throws -> Int {
    guard a.height == b.height else { throw ShotError.message("选区大小发生变化，请重新开始长截图") }
    let h = a.height, w = a.width
    guard h >= 100 else { throw ShotError.message("长截图选区高度至少需要 100 像素") }
    func score(_ shift: Int) -> (Double, Double) {
        let overlap = h - shift
        let rowStep = max(2, overlap / 90)
        var difference = 0.0, texture = 0.0, n = 0.0
        for y in stride(from: 3, to: overlap - 3, by: rowStep) {
            let ai = (y + shift) * w, bi = y * w
            for x in stride(from: 8, to: w - 8, by: 2) {
                let av = Double(a.bytes[ai+x]), bv = Double(b.bytes[bi+x])
                let ae = av - Double(a.bytes[ai+x-1]), be = bv - Double(b.bytes[bi+x-1])
                difference += abs(av-bv) + 1.5 * abs(ae-be)
                texture += abs(ae) + abs(be)
                n += 1
            }
        }
        return (difference / max(1,n), texture / max(1,n))
    }
    if score(0).0 < 0.25 { return 0 }
    let maxShift = h - max(60, h / 6)
    guard maxShift >= 8 else { throw ShotError.message("选区过小") }
    var best = 8, bestScore = Double.infinity, bestTexture = 0.0
    for shift in stride(from: 8, through: maxShift, by: 4) {
        let (value, texture) = score(shift)
        if value < bestScore { best = shift; bestScore = value; bestTexture = texture }
    }
    let coarse = best
    for shift in max(1,coarse-5)...min(maxShift,coarse+5) {
        let (value, texture) = score(shift)
        if value < bestScore { best = shift; bestScore = value; bestTexture = texture }
    }
    guard bestScore < 9, bestTexture > 0.8 else {
        throw ShotError.message("无法可靠拼接：请只框选滚动内容，向下滚动少一点，保留至少三分之一重叠；当前分段原图已保留")
    }
    return best
}

func stitch(_ paths: [String], output: String) throws -> [String: Any] {
    guard paths.count >= 2, paths.count <= 20 else { throw ShotError.message("长截图需要 2–20 张分段图片") }
    var images = [NSImage](), offsets = [Int](), previous: Gray?
    var total = 0, width = 0
    for path in paths {
        let image = try loadShot(path), cg = try cgImage(image), gray = try Gray(image)
        if images.isEmpty { width = cg.width; total = cg.height; offsets.append(0); images.append(image) }
        else {
            guard cg.width == width, let prior = previous else { throw ShotError.message("分段宽度不一致") }
            let shift = try verticalShift(prior, gray)
            if shift == 0 { continue }
            total += shift
            guard total <= 30000, width * total <= 100_000_000 else { throw ShotError.message("长图已达到尺寸上限，请分批拼接") }
            offsets.append(total - cg.height); images.append(image)
        }
        previous = gray
    }
    guard images.count >= 2 else { throw ShotError.message("画面没有向下滚动，未生成重复长图") }
    let image = NSImage(size: NSSize(width: width, height: total), flipped: true) { rect in
        NSColor.white.setFill(); rect.fill()
        for (i, part) in images.enumerated() {
            part.draw(in: NSRect(x: 0, y: offsets[i], width: width, height: Int(part.size.height)),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        return true
    }
    try savePNG(image, output)
    return ["path": output, "width": width, "height": total, "segments": images.count]
}

enum Tool: String, CaseIterable { case arrow = "箭头", box = "方框", pen = "画笔", text = "文字", redact = "遮盖", mosaic = "马赛克", crop = "裁剪" }
struct Mark {
    var tool: Tool
    var points: [NSPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var rect: NSRect {
        let a = points.first ?? .zero, b = points.last ?? .zero
        return NSRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }
    func draw(base: NSImage) {
        guard let a = points.first, let b = points.last else { return }
        color.setStroke(); color.setFill()
        let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        switch tool {
        case .box: p.appendRect(rect); p.stroke()
        case .redact:
            // Opaque replacement, flattened into the exported bitmap.
            NSColor.black.setFill(); rect.fill()
        case .mosaic:
            guard rect.width >= 1, rect.height >= 1, let source = try? cgImage(base),
                  let cut = source.cropping(to: rect.intersection(NSRect(origin: .zero, size: base.size)).integral) else { return }
            let miniSize = NSSize(width: max(1,rect.width/18), height: max(1,rect.height/18))
            let cutImage = NSImage(cgImage: cut, size: rect.size)
            let mini = NSImage(size: miniSize, flipped: true) { r in
                cutImage.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil); return true
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
            mini.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            (text as NSString).draw(at: a, withAttributes: [.font: NSFont.systemFont(ofSize: max(18,width*5),weight: .semibold), .foregroundColor: color])
        case .pen:
            p.move(to: a); for point in points.dropFirst() { p.line(to: point) }; p.stroke()
        case .arrow:
            p.move(to: a); p.line(to: b); p.stroke()
            let theta = atan2(b.y-a.y,b.x-a.x), length = max(15,width*4)
            let head = NSBezierPath(); head.move(to: b)
            head.line(to: NSPoint(x: b.x-length*cos(theta-0.48),y: b.y-length*sin(theta-0.48)))
            head.line(to: NSPoint(x: b.x-length*cos(theta+0.48),y: b.y-length*sin(theta+0.48))); head.close(); head.fill()
        case .crop: break
        }
    }
}
func flattened(_ base: NSImage, _ marks: [Mark], crop: NSRect?) throws -> NSImage {
    let size = base.size
    let rendered = NSImage(size: size, flipped: true) { rect in
        base.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for mark in marks { mark.draw(base: base) }; return true
    }
    if let crop = crop {
        guard let cg = try cgImage(rendered).cropping(to: crop.intersection(NSRect(origin: .zero,size: size)).integral) else {
            throw ShotError.message("裁剪范围无效")
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width,height: cg.height))
    }
    return rendered
}

final class EditorView: NSView {
    let base: NSImage
    var tool: Tool = .arrow
    var ink = NSColor.systemRed
    var stroke: CGFloat = 4
    var marks = [Mark](), redoMarks = [Mark]()
    var current: Mark?
    var onChange: (() -> Void)?
    var crop: NSRect? { marks.last(where: { $0.tool == .crop })?.rect }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: NSRect {
        let scale = min((bounds.width-32)/base.size.width,(bounds.height-32)/base.size.height)
        let size = NSSize(width: base.size.width*scale,height: base.size.height*scale)
        return NSRect(x: (bounds.width-size.width)/2,y: (bounds.height-size.height)/2,width: size.width,height: size.height)
    }
    init(_ image: NSImage) { base = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        let r = imageRect, scale = r.width/base.size.width
        base.draw(in: r,from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: nil)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: r.minX,yBy: r.minY); transform.scale(by: scale); transform.concat()
        NSBezierPath(rect: NSRect(origin: .zero,size: base.size)).addClip()
        for mark in marks { mark.draw(base: base) }
        current?.draw(base: base)
        if let selected = (current?.tool == .crop ? current?.rect : crop) {
            NSColor.controlAccentColor.setStroke(); let p = NSBezierPath(rect: selected); p.lineWidth = 2/scale
            p.setLineDash([6/scale,4/scale],count: 2,phase: 0); p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    func pixelPoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow,from: nil), r = imageRect, scale = r.width/base.size.width
        return NSPoint(x: min(base.size.width,max(0,(p.x-r.minX)/scale)),y: min(base.size.height,max(0,(p.y-r.minY)/scale)))
    }
    override func mouseDown(with event: NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow,from: nil)) else { return }
        window?.makeFirstResponder(self)
        let point = pixelPoint(event)
        current = Mark(tool: tool,points: [point,point],color: ink,width: stroke)
        if tool == .text {
            let alert = NSAlert(); alert.messageText = "添加文字"
            let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 320,height: 26)); alert.accessoryView = field
            alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                current?.text = field.stringValue; marks.append(current!); redoMarks.removeAll()
            }
            current = nil; needsDisplay = true; onChange?()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        let point = pixelPoint(event)
        if tool == .pen { current?.points.append(point) } else { current?.points[1] = point }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if var mark = current {
            if mark.tool != .pen { mark.points[1] = pixelPoint(event) }
            if mark.tool == .pen || mark.rect.width > 1 || mark.rect.height > 1 {
                marks.append(mark); redoMarks.removeAll()
            }
        }
        current = nil; needsDisplay = true; onChange?()
    }
    func undoMark() { if let mark = marks.popLast() { redoMarks.append(mark) }; needsDisplay = true; onChange?() }
    func redoMark() { if let mark = redoMarks.popLast() { marks.append(mark) }; needsDisplay = true; onChange?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redoMark() } else { undoMark() }; return
        }
        if event.keyCode == 53 { window?.performClose(nil); return }
        super.keyDown(with: event)
    }
}

final class EditorController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let window: NSWindow, editor: EditorView
    let output: String
    var accepted = false
    var onFinish: ((String)->Void)?
    var onClose: (()->Void)?
    let help = NSTextField(labelWithString: "")
    let dimensions = NSTextField(labelWithString: "")
    let tools = NSSegmentedControl()
    let color = NSColorWell()
    let slider = NSSlider(value: 4, minValue: 2, maxValue: 14, target: nil, action: nil)
    var undoItem: NSToolbarItem?, redoItem: NSToolbarItem?
    let toolIcons = ["arrow.up.right", "rectangle", "pencil.tip", "textformat", "rectangle.fill", "square.grid.3x3.fill", "crop"]
    let hints: [Tool:String] = [.arrow:"拖动鼠标画箭头",.box:"拖动框出需要强调的位置",.pen:"按住鼠标自由绘画",.text:"点一下图片，输入要添加的文字",.redact:"拖动覆盖内容，导出为不透明的黑色像素",.mosaic:"拖动选择要加马赛克的区域",.crop:"拖出要保留的范围，完成时按最后一个框裁剪"]
    convenience init(path: String, output: String) throws { try self.init(image:loadShot(path),output:output) }
    init(image: NSImage, output: String) {
        self.output = output; editor = EditorView(image)
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1080,height: 740),styleMask: [.titled,.closable,.resizable,.miniaturizable],backing: .buffered,defer: false)
        super.init()
        window.title = "标注截图"; window.subtitle = "箭头、文字、遮盖与裁剪"
        window.minSize = NSSize(width: 850,height: 480); window.toolbarStyle = .unified
        window.delegate = self; window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "ShotKit.Markup"); toolbar.delegate = self
        toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false; window.toolbar = toolbar
        let root = NSView(); window.contentView = root
        editor.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(editor)
        let bar = NSVisualEffectView(); bar.material = .headerView; bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bar)
        color.colorWellStyle = .minimal; color.color = editor.ink; color.target = self; color.action = #selector(selectColor(_:))
        color.toolTip = "标注颜色"; color.setAccessibilityLabel("标注颜色")
        color.translatesAutoresizingMaskIntoConstraints = false
        color.widthAnchor.constraint(equalToConstant: 28).isActive = true; color.heightAnchor.constraint(equalToConstant: 26).isActive = true
        slider.target = self; slider.action = #selector(selectWidth(_:)); slider.toolTip = "线条粗细和文字大小"
        slider.setAccessibilityLabel("线条粗细"); slider.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let label = NSTextField(labelWithString: "粗细"); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        let settings = NSStackView(views: [color, label, slider]); settings.spacing = 10
        settings.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(settings)
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byTruncatingTail; help.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(help)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); dimensions.textColor = .tertiaryLabelColor
        dimensions.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(dimensions)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: root.topAnchor), editor.leadingAnchor.constraint(equalTo: root.leadingAnchor),editor.trailingAnchor.constraint(equalTo: root.trailingAnchor),editor.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),bar.heightAnchor.constraint(equalToConstant: 44),
            settings.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),settings.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            help.leadingAnchor.constraint(equalTo: settings.trailingAnchor,constant: 20),help.centerYAnchor.constraint(equalTo: bar.centerYAnchor),help.trailingAnchor.constraint(lessThanOrEqualTo: dimensions.leadingAnchor,constant: -16),
            dimensions.trailingAnchor.constraint(equalTo: bar.trailingAnchor,constant: -18),dimensions.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        editor.onChange = { [weak self] in self?.refreshTools() }
        refreshTools()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(editor)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("tools"),.flexibleSpace,.init("undo"),.init("redo"),.space,.init("save"),.init("finish")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier); item.target = self
        switch identifier.rawValue {
        case "tools":
            tools.segmentCount = Tool.allCases.count; tools.trackingMode = .selectOne; tools.segmentStyle = .separated
            tools.target = self; tools.action = #selector(selectTool(_:)); tools.selectedSegment = 0
            for (i, tool) in Tool.allCases.enumerated() {
                tools.setImage(symbol(toolIcons[i],tool.rawValue),forSegment: i)
                tools.setWidth(42,forSegment: i); tools.setToolTip(tool.rawValue + " · " + (hints[tool] ?? ""),forSegment: i)
            }
            tools.setAccessibilityLabel("标注工具：箭头、方框、画笔、文字、遮盖、马赛克、裁剪")
            item.label = "标注工具"; item.view = tools
        case "undo": item.autovalidates = false; item.label = "撤销"; item.image = symbol("arrow.uturn.backward","撤销"); item.action = #selector(undoAction); item.toolTip = "撤销 · ⌘Z"; undoItem = item
        case "redo": item.autovalidates = false; item.label = "重做"; item.image = symbol("arrow.uturn.forward","重做"); item.action = #selector(redoAction); item.toolTip = "重做 · ⇧⌘Z"; redoItem = item
        case "save": item.label = "另存为"; item.image = symbol("square.and.arrow.down","另存为"); item.action = #selector(saveAs); item.toolTip = "另存为 PNG…"
        case "finish":
            let button = NSButton(title: "完成并复制",target: self,action: #selector(finish))
            button.bezelStyle = .rounded; button.keyEquivalent = "\r"; button.image = symbol("checkmark","完成")
            button.imagePosition = .imageLeading; button.toolTip = "导出标注后的图片并复制 · Return"
            item.label = "完成并复制"; item.view = button
        default: return nil
        }
        return item
    }
    func refreshTools() {
        undoItem?.isEnabled = !editor.marks.isEmpty; redoItem?.isEnabled = !editor.redoMarks.isEmpty
        help.stringValue = editor.tool.rawValue + " · " + (hints[editor.tool] ?? "")
        let size = editor.crop?.size ?? editor.base.size
        dimensions.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        color.isEnabled = ![Tool.redact,.mosaic,.crop].contains(editor.tool)
        slider.isEnabled = ![Tool.redact,.mosaic,.crop].contains(editor.tool)
    }
    @objc func selectTool(_ sender: NSSegmentedControl) { editor.tool = Tool.allCases[sender.selectedSegment]; refreshTools(); window.makeFirstResponder(editor) }
    @objc func selectColor(_ sender: NSColorWell) { editor.ink = sender.color }
    @objc func selectWidth(_ sender: NSSlider) { editor.stroke = CGFloat(sender.doubleValue) }
    @objc func undoAction() { editor.undoMark() }
    @objc func redoAction() { editor.redoMark() }
    func result() throws -> NSImage { try flattened(editor.base,editor.marks,crop: editor.crop) }
    @objc func finish() {
        do { let image = try result(); try savePNG(image,output); accepted = true; if let onFinish { onFinish(output) } else { emit(["path": output]) }; window.close(); if !standaloneRuntime { NSApp.stop(nil) } }
        catch { showError(error.localizedDescription) }
    }
    @objc func saveAs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "截图-\(Int(Date().timeIntervalSince1970)).png"; panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                do { try savePNG(self.result(),url.path) } catch { showError(error.localizedDescription) }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { if !accepted && !standaloneRuntime { emit(["cancelled": true]) }; onClose?(); if !standaloneRuntime { NSApp.stop(nil) } }
}

func showError(_ message: String) { let a = NSAlert(); a.messageText = message; a.runModal() }

final class PinView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func scrollWheel(with event: NSEvent) {
        guard let window = window else { return }
        let old = window.frame, factor = event.scrollingDeltaY > 0 ? 1.06 : 0.94
        let width = min(2400,max(100,old.width*factor)), height = width * old.height / old.width
        window.setFrame(NSRect(x: old.midX-width/2,y: old.midY-height/2,width: width,height: height),display: true)
    }
    override func rightMouseDown(with event: NSEvent) {
        let m = NSMenu()
        for (title,action) in [("复制图片",#selector(copyPin)),("半透明 / 不透明",#selector(alphaPin)),("关闭贴图",#selector(closePin))] {
            let item = NSMenuItem(title: title,action: action,keyEquivalent: ""); item.target = self; m.addItem(item)
        }
        NSMenu.popUpContextMenu(m,with: event,for: self)
    }
    @objc func copyPin() { if let image = image { copyImage(image) } }
    @objc func alphaPin() { window?.alphaValue = window?.alphaValue == 1 ? 0.55 : 1 }
    @objc func closePin() { window?.close() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) } }
}
final class PinController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (()->Void)?
    convenience init(path: String) throws { self.init(image:try loadShot(path)) }
    init(image: NSImage) {
        let maxSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200,height: 800)
        let scale = min(1,min(maxSize.width*0.65/image.size.width,maxSize.height*0.7/image.size.height))
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: image.size.width*scale,height: image.size.height*scale),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        super.init(); window.title = "贴图"; window.delegate = self; window.isReleasedWhenClosed = false
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let view = PinView(); view.toolTip = "拖动移动 · 滚轮缩放 · 右键查看更多操作"; view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { onClose?(); if !standaloneRuntime { NSApp.stop(nil) } }
}

final class TextResultController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSTextViewDelegate {
    let window: NSWindow
    let textView = NSTextView()
    let status = NSTextField(labelWithString: "直接编辑文字 · ⌘C 复制所选内容")
    let count = NSTextField(labelWithString: "")
    var translationWindow: NSWindow?
    let isQR: Bool
    var onClose: (()->Void)?
    var onTranslate: ((String)->Void)?
    convenience init(path: String, qr: Bool) throws { self.init(text:try String(contentsOfFile:path,encoding:.utf8),qr:qr) }
    init(text: String, qr: Bool) {
        isQR = qr
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 760,height: 570),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        super.init()
        window.title = qr ? "二维码内容" : "提取文字"; window.subtitle = "本机识别 · 可直接编辑"
        window.minSize = NSSize(width: 600,height: 400); window.toolbarStyle = .unified
        window.delegate = self; window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "ShotKit.Text"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; window.toolbar = toolbar
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        textView.string = text; textView.font = .systemFont(ofSize: 16); textView.delegate = self
        textView.isRichText = false; textView.isEditable = true; textView.isSelectable = true; textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true; textView.textContainerInset = NSSize(width: 24,height: 20); scroll.documentView = textView
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular); count.textColor = .tertiaryLabelColor
        for view in [scroll,status,count] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),scroll.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -12),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 22),status.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12),
            count.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -22),count.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        updateCount(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { isQR ? [.flexibleSpace,.init("save"),.init("copy")] : [.flexibleSpace,.init("translate"),.init("save"),.init("copy")] }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier identifier: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier); item.target = self
        switch identifier.rawValue {
        case "translate": item.label = "翻译"; item.image = symbol("character.bubble","翻译"); item.action = #selector(translateText); item.toolTip = "翻译当前文字"
        case "save": item.label = "保存文本"; item.image = symbol("square.and.arrow.down","保存文本"); item.action = #selector(saveText); item.toolTip = "另存为文本文件…"
        case "copy":
            let button = NSButton(title: "复制文字",target: self,action: #selector(copyText)); button.bezelStyle = .rounded; button.keyEquivalent = "\r"
            button.image = symbol("doc.on.doc","复制文字"); button.imagePosition = .imageLeading; button.toolTip = "复制全部文字 · Return"
            item.label = "复制文字"; item.view = button
        default: return nil
        }
        return item
    }
    func updateCount() { count.stringValue = "\(textView.string.count) 字" }
    func textDidChange(_ notification: Notification) { updateCount() }
    @objc func copyText() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textView.string,forType: .string)
        status.stringValue = "已复制，可以直接粘贴"
    }
    @objc func saveText() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "识别文字.txt"
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { do { try self.textView.string.write(to: url,atomically: true,encoding: .utf8) } catch { showError(error.localizedDescription) } }
        }
    }
    @objc func translateText() {
        if let onTranslate { onTranslate(textView.string); return }
        if translationWindow == nil {
            translationWindow = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 860,height: 600),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
            translationWindow?.title = "截图翻译"; translationWindow?.isReleasedWhenClosed = false
        }
        translationWindow?.contentView = NSHostingView(rootView: TranslationPanel(source: textView.string))
        translationWindow?.center(); translationWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { translationWindow?.close(); onClose?(); if !standaloneRuntime { NSApp.stop(nil) } }
}

struct SystemGlassAction: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}
struct TranslationPanel: View {
    let source: String
    @StateObject private var model = TranslationModel()
    var body: some View { NativeTranslationView(model: model).onAppear { model.setText(source) } }
}
final class CloseDelegate: NSObject, NSWindowDelegate { func windowWillClose(_ notification: Notification) { NSApp.stop(nil) } }

func selfTest(_ directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory,withIntermediateDirectories: true)
    let translationFixture = NSImage(size:NSSize(width:800,height:160),flipped:true) { r in
        NSColor.white.setFill(); r.fill()
        ("Hello. This is a screenshot translation test." as NSString).draw(at:NSPoint(x:24,y:50),withAttributes:[.font:NSFont.systemFont(ofSize:28),.foregroundColor:NSColor.black]); return true
    }
    try savePNG(translationFixture,directory+"/translation.png")
    let base = NSImage(size: NSSize(width: 640,height: 1600),flipped: true) { r in
        NSColor.white.setFill(); r.fill()
        for i in 0..<40 {
            let y = CGFloat(i*40)
            NSColor(calibratedRed: CGFloat((i*13)%31)/40,green: CGFloat((i*7)%29)/40,blue: CGFloat((i*11)%27)/40,alpha: 1).setFill()
            NSRect(x: 12,y: y+5,width: CGFloat(100+(i*47)%500),height: 8).fill()
            ("SHOTKIT TEST line \(i) · 截图文字识别" as NSString).draw(at: NSPoint(x: 22,y: y+15),withAttributes: [.font: NSFont.systemFont(ofSize: 18),.foregroundColor: NSColor.black])
        }
        return true
    }
    let cg = try cgImage(base)
    var paths = [String]()
    for (i,y) in [0,400,800].enumerated() {
        let cut = cg.cropping(to: CGRect(x: 0,y: y,width: 640,height: 800))!
        let path = directory+"/part-\(i).png"; try savePNG(NSImage(cgImage: cut,size: NSSize(width: 640,height: 800)),path); paths.append(path)
    }
    let report = try stitch(paths,output: directory+"/stitched.png")
    guard report["height"] as? Int == 1600 else { throw ShotError.message("拼接高度测试失败：\(report)") }
    let mark = Mark(tool: .redact,points: [NSPoint(x: 50,y: 60),NSPoint(x: 300,y: 150)],color: .black,width: 4)
    let mosaic = Mark(tool: .mosaic,points: [NSPoint(x: 330,y: 180),NSPoint(x: 600,y: 290)],color: .black,width: 4)
    let rendered = try flattened(try loadShot(paths[0]),[mark,mosaic],crop: CGRect(x: 0,y: 0,width: 640,height: 300))
    try savePNG(rendered,directory+"/redacted.png")
    let bitmap = NSBitmapImageRep(cgImage: try cgImage(rendered))
    guard bitmap.pixelsHigh == 300, let color = bitmap.colorAt(x: 100,y: 100)?.usingColorSpace(.deviceRGB),color.redComponent < 0.02,color.alphaComponent > 0.99 else { throw ShotError.message("遮盖扁平化测试失败") }
    let qr = CIFilter(name: "CIQRCodeGenerator")!
    let payload = "https://example.com/shotkit-test"
    qr.setValue(Data(payload.utf8),forKey: "inputMessage")
    let qrImage = qr.outputImage!.transformed(by: CGAffineTransform(scaleX: 10,y: 10))
    let qrCG = CIContext().createCGImage(qrImage,from: qrImage.extent)!
    let qrPath = directory+"/qr.png"
    try savePNG(NSImage(cgImage: qrCG,size: NSSize(width: qrCG.width,height: qrCG.height)),qrPath)
    let qrResult = try recognize(qrPath)
    guard (qrResult["codes"] as? [String] ?? []).contains(payload) else { throw ShotError.message("二维码读取测试失败") }
    let ocr = try recognize(paths[0])
    guard (ocr["text"] as? String ?? "").contains("SHOTKIT") else { throw ShotError.message("文字识别测试失败") }
    var duplicateRejected = false
    do { _ = try stitch([paths[0],paths[0]],output: directory+"/duplicate.png") } catch { duplicateRejected = true }
    guard duplicateRejected else { throw ShotError.message("重复分段检测失败") }
    emit(["ok": true,"stitchHeight": 1600,"ocr": true,"opaqueRedaction": true,"crop": true,"duplicateRejected": true,"qr": true])
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first?.hasPrefix("-psn_")==true ? "app" : (args.first ?? "app")
do {
    switch mode {
    case "app", "--demo":
        _ = NSApplication.shared; standaloneRuntime=true
        MainActor.assumeIsolated { let delegate=StandaloneApp(demo:mode=="--demo"); NSApp.delegate=delegate; NSApp.run(); withExtendedLifetime(delegate) {} }
    case "selection-settings-selftest": try selectionSettingsSelfTest()
    case "native-selftest":
        guard args.count==2 else {fail("缺少测试输出目录")}
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); try MainActor.assumeIsolated {try nativeSelfTest(args[1])}
    case "save":
        guard args.count == 2 else { fail("缺少图片") }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "截图-\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url { try Data(contentsOf: URL(fileURLWithPath: args[1])).write(to: url,options: .atomic); emit(["path": url.path]) }
        else { emit(["cancelled": true]) }
    case "environment": emit(["reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
    case "ax": emit(try accessibilityChain(args))
    case "thumbnail":
        guard args.count == 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 192] as CFDictionary) else { fail("缩略图生成失败") }
        try savePNG(NSImage(cgImage: cg,size: NSSize(width: cg.width,height: cg.height)),args[2]); emit(["ok": true])
    case "ocr": guard args.count == 2 else { fail("缺少图片") }; emit(try recognize(args[1],includeCodes:false))
    case "qr": guard args.count == 2 else { fail("缺少图片") }; emit(try recognizeCodes(args[1]))
    case "stitch": guard args.count >= 4 else { fail("缺少拼接图片") }; emit(try stitch(Array(args.dropFirst(2)),output: args[1]))
    case "selftest": guard args.count==2 else {fail("缺少测试输出目录")}; _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); try selfTest(args[1])
    case "edit", "pin", "translate", "text":
        guard args.count >= 2 else { fail("缺少图片") }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭",action: #selector(NSWindow.performClose(_:)),keyEquivalent: "w"); appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle: title,action: action,keyEquivalent: key) }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        var retained: AnyObject?
        if mode == "edit" { guard args.count == 3 else { fail("缺少输出路径") }; retained = try EditorController(path: args[1],output: args[2]) }
        else if mode == "pin" { retained = try PinController(path: args[1]) }
        else if mode == "text" {
            retained = try TextResultController(path: args[1],qr: args.count > 2 && args[2] == "qr")
        } else {
            let text = try String(contentsOfFile: args[1],encoding: .utf8)
            let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 860,height: 600),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
            let delegate = CloseDelegate(); w.delegate = delegate; w.title = "截图翻译"; w.contentView = NSHostingView(rootView: TranslationPanel(source: text)); w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            retained = [w, delegate] as NSArray; w.isReleasedWhenClosed = false
        }
        NSApp.run(); withExtendedLifetime(retained) {}; exit(0)
    default: fail("未知命令")
    }
} catch { fail(error.localizedDescription) }
