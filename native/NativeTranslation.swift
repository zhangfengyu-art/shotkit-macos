import Cocoa
import SwiftUI
import Translation
import Vision
import NaturalLanguage

final class RecognitionWarmup {
    static let shared = RecognitionWarmup()
    private var request: VNRecognizeTextRequest?
    func start() {
        let image = NSImage(size:NSSize(width:440,height:100),flipped:true) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Screenshot 文字识别" as NSString).draw(at:NSPoint(x:12,y:30),withAttributes:[.font:NSFont.systemFont(ofSize:26),.foregroundColor:NSColor.black]); return true
        }
        guard let cg = try? cgImage(image) else { return }
        let r = VNRecognizeTextRequest(); request = r
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let ok: Bool
            do { try configureRecognition(r); try VNImageRequestHandler(cgImage:cg).perform([r]); ok = true } catch { ok = false }
            DispatchQueue.main.async {
                self?.request = nil
                emit(["event":"recognitionReady","ok":ok,"milliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000])
            }
        }
    }
    func yieldToUser() { request?.cancel(); request = nil }
}

// Only bounded, in-memory caches. Screenshot text is never written to a second file.
final class TranslationMemory {
    static let shared = TranslationMemory()
    let text = NSCache<NSString, NSString>()
    let translations = NSCache<NSString, NSString>()
    init() {
        text.countLimit = 24; text.totalCostLimit = 2 * 1024 * 1024
        translations.countLimit = 48; translations.totalCostLimit = 2 * 1024 * 1024
    }
    static func imageKey(_ path: String) -> NSString? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let date = a[.modificationDate] as? Date, let size = a[.size] as? NSNumber else { return nil }
        return "\(path)|\(date.timeIntervalSince1970)|\(size)" as NSString
    }
}

final class TranslationModel: ObservableObject {
    enum Stage: String { case recognizing, preparing, translating, complete, cancelled, failed, ready }
    @Published var source = ""
    @Published var target = "zh-Hans"
    @Published var precise = false
    @Published var result = ""
    @Published var stage: Stage = .ready
    @Published var detail = "选择文字后翻译"
    @Published var copied = false
    @Published var configuration: TranslationSession.Configuration?
    @Published var ticket = 0
    var generation = 0
    var configurationGeneration = 0
    var task: Task<Void, Never>?
    var request: VNRecognizeTextRequest?
    var session: TranslationSession?
    var path: String?
    var openedAt = 0.0, ocrMs = 0.0, translationMs = 0.0, visibleMs = 0.0
    var cacheHit = false
    private var requestedSource = "", requestedTarget = "", requestedPrecise = false
    var send: (([String: Any]) -> Void)?
    let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "local.shotkit.translation.ocr"; q.qualityOfService = .userInitiated; q.maxConcurrentOperationCount = 1; return q
    }()
    var busy: Bool { [.recognizing, .preparing, .translating].contains(stage) }
    var canCopy: Bool { stage == .complete && !result.isEmpty && source.trimmingCharacters(in:.whitespacesAndNewlines) == requestedSource && target == requestedTarget && precise == requestedPrecise }
    var statusIcon: String {
        switch stage { case .complete: return "checkmark.circle.fill"; case .failed: return "exclamationmark.circle.fill"; case .cancelled: return "pause.circle"; default: return "character.bubble" }
    }
    func cancelWork() {
        generation += 1; task?.cancel(); task = nil
        request?.cancel(); request = nil; queue.cancelAllOperations()
        if #available(macOS 26.0, *) { session?.cancel() }
        session = nil; configuration = nil
    }
    func cancel() { cancelWork(); stage = .cancelled; detail = "已停止 · 可以修改原文后重新翻译"; report() }
    func load(path: String, target: String?) {
        RecognitionWarmup.shared.yieldToUser()
        cancelWork(); self.path = path; openedAt = ProcessInfo.processInfo.systemUptime
        visibleMs = 0; ocrMs = 0; translationMs = 0; cacheHit = false; copied = false
        source = ""; result = ""; stage = .recognizing; detail = "正在识别选区文字…"
        if let target { self.target = target }
        let revision = generation
        let key = TranslationMemory.imageKey(path)
        if let key, let cached = TranslationMemory.shared.text.object(forKey: key) {
            acceptText(cached as String, target: target, revision: revision); return
        }
        let r = VNRecognizeTextRequest(); request = r
        queue.addOperation { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let response = Result { try recognize(path, includeCodes: false, request: r) }
            DispatchQueue.main.async {
                guard let self, self.generation == revision else { return }
                self.request = nil; self.ocrMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                switch response {
                case .success(let values):
                    let text = values["text"] as? String ?? ""
                    if let key, !text.isEmpty { TranslationMemory.shared.text.setObject(text as NSString, forKey: key, cost: text.utf8.count) }
                    self.send?(["event":"recognized", "path":path, "text":text])
                    self.acceptText(text, target: target, revision: revision)
                case .failure(let error): self.stage = .failed; self.detail = "识别失败：\(error.localizedDescription)"; self.report()
                }
            }
        }
    }
    func acceptText(_ text: String, target: String?, revision: Int) {
        guard generation == revision else { return }
        source = text
        if target == nil {
            let language = NLLanguageRecognizer.dominantLanguage(for: text)
            self.target = language == .simplifiedChinese || language == .traditionalChinese ? "en" : "zh-Hans"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stage = .failed; detail = "未识别到文字 · 可以在左侧输入或粘贴原文"; report()
        } else { begin() }
    }
    func setText(_ text: String) {
        cancelWork(); path = nil; openedAt = ProcessInfo.processInfo.systemUptime; ocrMs = 0
        acceptText(text, target: nil, revision: generation)
    }
    func sourceEdited() {
        if busy { cancelWork() }
        copied = false; stage = .ready; detail = "原文已修改 · 按 ⌘Return 翻译" // Never leave a stale result copyable.
    }
    func begin() {
        cancelWork(); copied = false; cacheHit = false
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { stage = .failed; detail = "请先输入需要翻译的文字"; return }
        let revision = generation, selected = target, quality = precise
        requestedSource = text; requestedTarget = target; requestedPrecise = precise
        let key = "\(selected)|\(quality)|\(text)" as NSString
        if let cached = TranslationMemory.shared.translations.object(forKey: key) {
            result = cached as String; stage = .complete; detail = "翻译完成 · 已复用本次运行中的结果"; cacheHit = true; translationMs = 0
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == revision else { return }; self.report() }; return
        }
        result = ""; stage = .preparing; detail = "正在准备本地翻译…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let availability: LanguageAvailability
                if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: quality ? .highFidelity : .lowLatency) }
                else { availability = LanguageAvailability() }
                let status = try await availability.status(for: text, to: Locale.Language(identifier: selected))
                guard self.generation == revision, !Task.isCancelled else { return }
                guard status != .unsupported else { throw ShotError.message("这组语言暂不受系统翻译支持，请更换目标语言") }
                if #available(macOS 26.0, *), status == .installed,
                   let language = NLLanguageRecognizer.dominantLanguage(for: text) {
                    let s: TranslationSession
                    if #available(macOS 26.4, *) { s = TranslationSession(installedSource: Locale.Language(identifier: language.rawValue), target: Locale.Language(identifier: selected), preferredStrategy: quality ? .highFidelity : .lowLatency) }
                    else { s = TranslationSession(installedSource: Locale.Language(identifier: language.rawValue), target: Locale.Language(identifier: selected)) }
                    await self.translate(using: s, text: text, key: key, revision: revision)
                } else {
                    self.detail = "需要系统准备语言 · 请在系统提示中允许下载"
                    self.configurationGeneration = revision
                    if #available(macOS 26.4, *) { self.configuration = .init(source: nil, target: Locale.Language(identifier: selected), preferredStrategy: quality ? .highFidelity : .lowLatency) }
                    else { self.configuration = .init(source: nil, target: Locale.Language(identifier: selected)) }
                    self.ticket += 1
                }
            } catch {
                guard self.generation == revision, !Task.isCancelled else { return }
                self.stage = .failed; self.detail = "\(error.localizedDescription) · 可更换语言或重试"; self.report()
            }
        }
    }
    func optionsChanged() {
        if !source.isEmpty && (target != requestedTarget || precise != requestedPrecise || source.trimmingCharacters(in:.whitespacesAndNewlines) != requestedSource) { begin() }
    }
    @MainActor func translate(using session: TranslationSession, text: String, key: NSString, revision: Int) async {
        guard generation == revision else { return }
        self.session = session; stage = .translating; detail = "正在本地翻译…"
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await session.translate(text)
            guard generation == revision, !Task.isCancelled else { return }
            translationMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            result = response.targetText; stage = .complete; detail = "翻译完成 · 可修改原文或切换语言"
            TranslationMemory.shared.translations.setObject(result as NSString, forKey: key, cost: result.utf8.count + text.utf8.count)
            self.session = nil; report()
            if let window = NSApp.keyWindow { NSAccessibility.post(element:window, notification:.announcementRequested, userInfo:[.announcement:"翻译完成", .priority:NSAccessibilityPriorityLevel.medium.rawValue]) }
        } catch {
            guard generation == revision, !Task.isCancelled else { return }
            stage = .failed; detail = "\(error.localizedDescription) · 点重试或切换目标语言"; self.session = nil; report()
        }
    }
    @MainActor func translateConfigured(_ s: TranslationSession, revision: Int, text: String, target: String, precise: Bool) async {
        await translate(using: s, text: text, key: "\(target)|\(precise)|\(text)" as NSString, revision: revision)
    }
    func copy() {
        guard canCopy else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string); copied = true
    }
    func report() {
        send?(["event":"translationStatus", "stage":stage.rawValue, "ocrMs":ocrMs, "translationMs":translationMs, "visibleMs":visibleMs, "cacheHit":cacheHit])
    }
    var diagnostics: [String:Any] { ["stage":stage.rawValue, "ocrMs":ocrMs, "translationMs":translationMs, "visibleMs":visibleMs, "cacheHit":cacheHit, "sourceCount":source.count, "resultCount":result.count] }
}

struct NativeTranslationView: View {
    @ObservedObject var model: TranslationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName:"character.bubble.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment:.leading, spacing:3) {
                    Text("截图翻译").font(.headline)
                    Text("识别 · 翻译 · 复制").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if #available(macOS 26.4, *) {
                    Picker("翻译方式", selection:$model.precise) { Text("快速").tag(false); Text("精细").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width:124).help("快速适合随手截图；精细使用系统高保真翻译")
                }
                Picker("译为",selection:$model.target) { Text("简体中文").tag("zh-Hans"); Text("英语").tag("en"); Text("日语").tag("ja"); Text("韩语").tag("ko") }.frame(width:160).disabled(model.stage == .recognizing)
            }
            HSplitView {
                VStack(alignment:.leading, spacing:10) {
                    HStack { Label("原文",systemImage:"text.alignleft").font(.subheadline.weight(.medium)); Spacer(); Text("可编辑").font(.caption).foregroundStyle(.secondary) }
                    TextEditor(text:Binding(get:{ model.source },set:{ model.source = $0; model.sourceEdited() })).font(.system(size:16)).scrollContentBackground(.hidden)
                        .disabled(model.stage == .recognizing).overlay { if model.stage == .recognizing { waiting("正在识别选区文字") } }
                }.padding(18).frame(minWidth:260,maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:18)).overlay { RoundedRectangle(cornerRadius:18).stroke(Color(nsColor:.separatorColor).opacity(0.35),lineWidth:0.5) }
                VStack(alignment:.leading, spacing:10) {
                    HStack { Label("译文",systemImage:"text.bubble").font(.subheadline.weight(.medium)); Spacer(); if model.canCopy { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).transition(.opacity) } }
                    ScrollView { Text(model.result).font(.system(size:16)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                        .frame(maxWidth:.infinity,maxHeight:.infinity).overlay { if model.busy { waiting(model.stage == .recognizing ? "识别完成后自动翻译" : model.detail) } else if model.result.isEmpty { ContentUnavailableView(model.stage == .failed ? "暂时未能完成" : "译文会显示在这里",systemImage:model.statusIcon,description:Text(model.detail)) } }
                }.padding(18).frame(minWidth:260,maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:18)).overlay { RoundedRectangle(cornerRadius:18).stroke(Color(nsColor:.separatorColor).opacity(0.35),lineWidth:0.5) }
            }
            HStack(spacing:10) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName:model.statusIcon).foregroundStyle(model.stage == .complete ? .green : model.stage == .failed ? .orange : .secondary) }
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength:4)
                if model.busy {
                    Button("停止",systemImage:"stop",action:model.cancel).modifier(SystemGlassAction()).keyboardShortcut(.cancelAction)
                } else {
                    Button(model.stage == .failed ? "重试" : "重新翻译",systemImage:"arrow.clockwise",action:model.begin).modifier(SystemGlassAction()).keyboardShortcut(.return,modifiers:.command)
                }
                Button(model.copied ? "已复制" : "复制译文",systemImage:model.copied ? "checkmark" : "doc.on.doc",action:model.copy).modifier(SystemGlassAction(prominent:true)).disabled(!model.canCopy).keyboardShortcut("c",modifiers:[.command,.shift])
            }.frame(minHeight:36)
        }.padding(22).frame(minWidth:740,minHeight:490).background(Color(nsColor:.windowBackgroundColor))
        .animation(reduceMotion ? nil : .spring(response:0.28,dampingFraction:0.88),value:model.stage)
        .animation(reduceMotion ? nil : .easeOut(duration:0.14),value:model.copied)
        .onChange(of:model.target) { _,_ in model.optionsChanged() }
        .onChange(of:model.precise) { _,_ in model.optionsChanged() }
        .background {
            // A fresh task host isolates download sessions from cancelled or superseded work.
            if let configuration = model.configuration {
                let revision = model.configurationGeneration, text = model.source.trimmingCharacters(in:.whitespacesAndNewlines), target = model.target, precise = model.precise
                Color.clear.id(model.ticket).translationTask(configuration) { session in
                    await model.translateConfigured(session,revision:revision,text:text,target:target,precise:precise)
                }
            }
        }
    }
    func waiting(_ text: String) -> some View {
        VStack(spacing:12) { ProgressView().controlSize(.regular); Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(24).allowsHitTesting(false)
    }
}

final class NativeTranslationController: NSObject, NSWindowDelegate {
    let model = TranslationModel()
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:610),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    override init() {
        super.init(); window.title = "截图翻译"; window.toolbarStyle = .unified; window.minSize = NSSize(width:780,height:560)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView:NativeTranslationView(model:model)); window.center()
    }
    func show(path: String, target: String?, startedAt: Double? = nil) {
        model.load(path:path,target:target)
        if let startedAt { model.openedAt = startedAt }
        showWindow()
    }
    func show(text: String) { model.setText(text); showWindow() }
    func showWindow() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        window.contentView?.layoutSubtreeIfNeeded()
        model.visibleMs = (ProcessInfo.processInfo.systemUptime - model.openedAt) * 1000
        if !model.busy { model.report() }
    }
    func windowWillClose(_ notification: Notification) { model.cancelWork() }
}
