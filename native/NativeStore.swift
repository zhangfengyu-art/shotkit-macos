import Cocoa
import ImageIO

final class NativeShotStore {
    let root: URL
    let allowsLegacy: Bool
    let queue=DispatchQueue(label:"local.shotkit.storage",qos:.utility)
    init(root: URL? = nil) {
        allowsLegacy = root == nil
        self.root=(root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ShotKit/Screenshots",isDirectory:true)).standardizedFileURL.resolvingSymlinksInPath()
    }
    func prepare() throws { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    func newURL() -> URL { root.appendingPathComponent("shot_"+String(Int(Date().timeIntervalSince1970*1000))+"_"+UUID().uuidString.prefix(8)+".png") }
    func store(_ image: CGImage, completion: @escaping (Result<URL,Error>)->Void) {
        let url=newURL()
        queue.async {
            let result=Result { () throws -> URL in
                try self.prepare(); try ShotPixels.png(image).write(to:url,options:.atomic)
                self.metadata(url,["width":image.width,"height":image.height,"created":Date().timeIntervalSince1970])
                if let source=CGImageSourceCreateWithURL(url as CFURL,nil),let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240] as CFDictionary),let bytes=try? ShotPixels.png(thumb) { try? bytes.write(to:URL(fileURLWithPath:url.path+".thumb.png"),options:.atomic) }
                return url
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func metadata(_ url: URL, _ update: [String:Any]) {
        let path=URL(fileURLWithPath:url.path+".json")
        var existing=(try? Data(contentsOf:path)).flatMap {try? JSONSerialization.jsonObject(with:$0) as? [String:Any]} ?? [:]
        update.forEach {existing[$0.key]=$0.value}
        if let data=try? JSONSerialization.data(withJSONObject:existing,options:.sortedKeys) { try? data.write(to:path,options:.atomic) }
    }
    func update(_ url: URL, _ update: [String:Any]) { guard url.deletingLastPathComponent().standardizedFileURL==root.standardizedFileURL else {return}; queue.async {self.metadata(url,update)} }
    func entries(completion: @escaping ([[String:Any]])->Void) {
        let includeLegacy=allowsLegacy && (UserDefaults.standard.object(forKey:"legacyHistory") as? Bool ?? true)
        queue.async {
            let legacy=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/screenshot-data",isDirectory:true)
            let roots=includeLegacy ? [self.root,legacy] : [self.root]
            var files=[(URL,Date)]()
            for root in roots {
                for url in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey],options:.skipsHiddenFiles)) ?? [] {
                    guard url.lastPathComponent.hasPrefix("shot_"),url.pathExtension=="png",!url.lastPathComponent.hasSuffix(".thumb.png"),let values=try? url.resourceValues(forKeys:[.contentModificationDateKey,.isRegularFileKey]),values.isRegularFile==true else { continue }
                    files.append((url,values.contentModificationDate ?? .distantPast))
                }
            }
            let formatter=DateFormatter(); formatter.dateFormat="MM月dd日 HH:mm:ss"
            let entries=files.sorted {$0.1>$1.1}.prefix(100).map { url,date -> [String:Any] in
                let info=(try? Data(contentsOf:URL(fileURLWithPath:url.path+".json"))).flatMap {try? JSONSerialization.jsonObject(with:$0) as? [String:Any]} ?? [:]
                var w=info["width"] as? Int ?? 0,h=info["height"] as? Int ?? 0
                if w==0,let source=CGImageSourceCreateWithURL(url as CFURL,nil),let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] { w=p[kCGImagePropertyPixelWidth as String] as? Int ?? 0; h=p[kCGImagePropertyPixelHeight as String] as? Int ?? 0 }
                return ["path":url.path,"thumb":url.path+".thumb.png","title":formatter.string(from:date),"detail":"\(w) × \(h)","text":String((info["text"] as? String ?? "").prefix(256))]
            }
            DispatchQueue.main.async { completion(entries) }
        }
    }
    func prune(keeping: URL) {
        let limit=UserDefaults.standard.object(forKey:"historyCount") as? Int ?? 60
        queue.async {
            let files=((try? FileManager.default.contentsOfDirectory(at:self.root,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey],options:.skipsHiddenFiles)) ?? []).filter {$0.lastPathComponent.hasPrefix("shot_") && $0.pathExtension=="png" && !$0.lastPathComponent.hasSuffix(".thumb.png")}.sorted {
                ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)>((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var size=0
            for (index,url) in files.enumerated() {
                let values=try? url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey]); size+=values?.fileSize ?? 0
                if url != keeping && (index>=limit || size>300*1024*1024 || Date().timeIntervalSince(values?.contentModificationDate ?? Date())>30*86400) {
                    // Recoverable cleanup. Legacy Hammerspoon files are strictly read-only.
                    if (try? FileManager.default.trashItem(at:url,resultingItemURL:nil)) != nil {
                        for suffix in [".json",".thumb.png"] { try? FileManager.default.trashItem(at:URL(fileURLWithPath:url.path+suffix),resultingItemURL:nil) }
                    }
                }
            }
        }
    }
}
