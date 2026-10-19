import AVFoundation
import CryptoKit
import Foundation
import MixCore
import ImageIO
import UniformTypeIdentifiers

/// Cover-Bilder der Tracks: eingebettet (ID3 APIC, MP4 covr, FLAC PICTURE) oder cover/folder/front.jpg|png im
/// Ordner des Tracks. Lesen und Verkleinern nie auf dem Main-Thread; Speicher-Cache (NSCache, nach Bytes begrenzt)
/// und Platten-Cache (JPEG je Größe), damit langsame Laufwerke nur einmal gelesen werden.
public final class ArtworkCache: @unchecked Sendable {
    /// Kantenlänge in Pixeln (quadratisch, mittig beschnitten): klein = Browser-Spalte, groß = Deck und Vorschau
    public enum Size: Int, CaseIterable, Sendable { case small = 64, large = 320 }
    public enum Source: String, Sendable { case embedded, folder }

    /// MIX741_ARTWORK_DIR: anderer Cache-Ordner (Selbsttest, Messung)
    public static let shared = ArtworkCache(directory: ProcessInfo.processInfo.environment["MIX741_ARTWORK_DIR"].map { URL(fileURLWithPath: $0) }
        ?? E2E.caches.appendingPathComponent("MINOS-741/artwork"))

    public let directory: URL
    /// Eintrag im Speicher-Cache; image == nil heißt: Track hat kein Cover
    private final class Entry {
        let image: CGImage?
        init(_ i: CGImage?) { image = i }
    }
    private let memory = NSCache<NSString, Entry>()
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    /// Ordner -> gefundenes Ordner-Cover (oder keins), damit große Ordner nicht je Track gelistet werden
    private var folderArt: [String: String?] = [:]
    private let gate = Gate(limit: 3)
    /// geschnittene Datei -> Original: ohne eigenes Cover nimmt sie das eingebettete des Originals
    private var aliases: [String: String] = [:]

    private final class Job {
        var task: Task<CGImage?, Never>?
        var waiters = 1
    }

    public init(directory: URL, memoryLimit: Int = 48 << 20) {
        self.directory = directory
        memory.totalCostLimit = memoryLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Cover einer geschnittenen Datei aus dem Original (die neue Datei trägt keine Tags)
    public func alias(_ path: String, to original: String) { lock.withLock { aliases[path] = original } }

    private func memKey(_ path: String, _ size: Size) -> NSString { "\(size.rawValue)|\(path)" as NSString }

    /// Nur Speicher-Cache, blockiert nie: nil = noch unbekannt, .some(nil) = Track hat kein Cover
    public func cached(_ path: String, _ size: Size) -> CGImage?? {
        memory.object(forKey: memKey(path, size)).map { $0.image }
    }

    /// Cover in der gewünschten Größe: Speicher -> Platte -> Datei. Gleiche Anfragen teilen sich eine Arbeit;
    /// wird jede Anfrage abgebrochen (Zeile aus dem Bild gescrollt), entfällt das Lesen.
    public func image(_ path: String, _ size: Size) async -> CGImage? {
        if let e = memory.object(forKey: memKey(path, size)) { return e.image }
        let key = memKey(path, size) as String
        let job: Job = lock.withLock {
            if let j = jobs[key] { j.waiters += 1; return j }
            let j = Job()
            jobs[key] = j
            j.task = Task.detached(priority: .utility) { [self] in
                let img = await work(path, size)
                lock.withLock { if jobs[key] === j { jobs[key] = nil } }
                return img
            }
            return j
        }
        // Ergebnis der Arbeit, nicht erneut aus dem Speicher-Cache (NSCache kann es inzwischen verworfen haben)
        return await withTaskCancellationHandler {
            await job.task?.value ?? nil
        } onCancel: {
            lock.withLock {
                job.waiters -= 1
                if job.waiters == 0 {
                    job.task?.cancel()
                    if jobs[key] === job { jobs[key] = nil }
                }
            }
        }
    }

    private func work(_ path: String, _ size: Size) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        return await load(path, size)
    }

    @discardableResult
    private func store(_ path: String, _ size: Size, _ img: CGImage?) -> CGImage? {
        memory.setObject(Entry(img), forKey: memKey(path, size), cost: img.map { $0.bytesPerRow * $0.height } ?? 64)
        return img
    }

    private func load(_ path: String, _ size: Size) async -> CGImage? {
        var st = stat()
        guard stat(path, &st) == 0 else { return store(path, size, nil) }
        // Datei liegt nur in der Cloud (nicht geladen): nicht anfassen, sonst lädt der Dateianbieter den ganzen Track
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
        let base = Self.diskKey(path: path, mtime: st.st_mtimespec.tv_sec, size: st.st_size)
        let none = directory.appendingPathComponent(base + ".none")
        let file = directory.appendingPathComponent("\(base)-\(size.rawValue).jpg")
        if FileManager.default.fileExists(atPath: none.path) { return store(path, size, nil) }
        if let img = Self.decode(url: file) { return store(path, size, img) }
        // noch nicht im Platten-Cache: aus der Datei lesen, nur die verlangte Größe ablegen
        // (groß nur für Decks und Vorschau, sonst wüchse der Cache beim Scrollen um ~35 KB je Track)
        guard !Task.isCancelled else { return nil }
        guard let (data, _) = await find(path), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = Self.thumbnail(src, pixels: size.rawValue) else {
            if !Task.isCancelled { FileManager.default.createFile(atPath: none.path, contents: nil); store(path, size, nil) }
            return nil
        }
        Self.writeJPEG(img, to: file)
        return store(path, size, img)
    }

    /// Rohbild eines Tracks: eingebettet, sonst Ordner-Cover
    public func find(_ path: String) async -> (Data, Source)? {
        if let d = await Self.embedded(url: URL(fileURLWithPath: path)) { return (d, .embedded) }
        if let o = lock.withLock({ aliases[path] }), let d = await Self.embedded(url: URL(fileURLWithPath: o)) { return (d, .embedded) }
        let dir = (path as NSString).deletingLastPathComponent
        let hit: String?? = lock.withLock { folderArt[dir] }
        let cover: String? = hit ?? {
            let c = Self.folderCover(in: dir)
            lock.withLock { folderArt[dir] = c }
            return c
        }()
        if let cover, let d = try? Data(contentsOf: URL(fileURLWithPath: cover)) { return (d, .folder) }
        return nil
    }

    /// cover / folder / front mit .jpg .jpeg .png, Groß-/Kleinschreibung egal
    public static func folderCover(in dir: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var byName: [String: String] = [:]
        for n in names { byName[n.lowercased()] = n }
        for stem in ["cover", "folder", "front"] {
            for ext in ["jpg", "jpeg", "png"] {
                if let n = byName["\(stem).\(ext)"] { return (dir as NSString).appendingPathComponent(n) }
            }
        }
        return nil
    }

    /// eingebettetes Bild: FLAC-Blöcke selbst lesen, sonst die Metadaten von AVFoundation (ID3, MP4)
    public static func embedded(url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac" { return flacPicture(url: url) }
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.commonMetadata)) ?? []
        var art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        if art.isEmpty {
            items = (try? await asset.load(.metadata)) ?? []
            art = items.filter { [.id3MetadataAttachedPicture, .iTunesMetadataCoverArt].contains($0.identifier) }
        }
        for item in art {
            if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
        }
        return nil
    }

    /// FLAC: METADATA_BLOCK_PICTURE (Typ 6) im Kopf der Datei; Vorderseite (Bildtyp 3) bevorzugt
    static func flacPicture(url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard h.readData(ofLength: 4) == Data("fLaC".utf8) else { return nil }
        var found: Data?
        for _ in 0..<64 {
            let hdr = [UInt8](h.readData(ofLength: 4))
            guard hdr.count == 4 else { break }
            let last = hdr[0] & 0x80 != 0, type = hdr[0] & 0x7f
            let len = Int(hdr[1]) << 16 | Int(hdr[2]) << 8 | Int(hdr[3])
            if type == 6 {
                let b = [UInt8](h.readData(ofLength: len))
                var p = 0
                func u32() -> Int? {
                    guard p + 4 <= b.count else { return nil }
                    defer { p += 4 }
                    return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
                }
                guard let kind = u32(), let ml = u32() else { break }
                p += ml
                guard let dl = u32() else { break }
                p += dl + 16
                guard let n = u32(), p + n <= b.count else { break }
                let d = Data(b[p..<p + n])
                if kind == 3 { return d }
                if found == nil { found = d }
            } else {
                try? h.seek(toOffset: h.offsetInFile + UInt64(len))
            }
            if last { break }
        }
        return found
    }

    static func diskKey(path: String, mtime: Int, size: Int64) -> String {
        let h = SHA256.hash(data: Data("\(path)|\(mtime)|\(size)".utf8))
        return h.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// verkleinert und mittig quadratisch beschnitten
    static func thumbnail(_ src: CGImageSource, pixels: Int) -> CGImage? {
        // lange Kante so wählen, dass die kurze nach dem Beschnitt noch `pixels` hat
        var scale = pixels
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, min(w, h) > 0 {
            scale = Int((Double(pixels) * Double(max(w, h)) / Double(min(w, h))).rounded(.up))
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: scale,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let side = min(img.width, img.height)
        guard img.width != img.height else { return img }
        return img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)) ?? img
    }

    static func decode(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func writeJPEG(_ img: CGImage, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Speicher-Cache leeren (Tests)
    public func purgeMemory() {
        memory.removeAllObjects()
        lock.withLock { folderArt.removeAll() }
    }
}

/// begrenzt gleichzeitiges Lesen; die neueste Anfrage kommt zuerst dran (beim Scrollen die gerade sichtbaren Zeilen)
private actor Gate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { free = limit }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if let next = waiting.popLast() { next.resume() } else { free += 1 }
    }
}
