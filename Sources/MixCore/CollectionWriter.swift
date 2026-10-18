import Foundation

/// Schreibt Metadaten-Änderungen in die collection.nml zurück.
/// Nur die betroffenen ENTRY-Blöcke werden ersetzt, und zwar textgenau: der Roh-Block aus `NMLEntryIndex`
/// wird in der aktuellen Datei gesucht und durch den geänderten Block ersetzt. Alles andere bleibt Byte für Byte
/// gleich (Kodierung, Zeilenenden, Attribut-Reihenfolge, Cues, AUDIO_ID …). Geänderte Attribute behalten ihren Platz,
/// neue kommen ans Ende des Start-Tags, fehlende Elemente (ALBUM, INFO, TEMPO) werden an der üblichen Stelle eingefügt.
public enum CollectionWriter {
    public struct Result: Sendable {
        /// neue Roh-Blöcke je Track-Schlüssel (für den Index im Speicher)
        public var blocks: [String: String] = [:]
        /// Felder, die jetzt so in der Datei stehen
        public var written: [String: [TrackField: String]] = [:]
        /// Analysen, die jetzt in der Datei stehen
        public var writtenAnalyses: [String] = []
        /// Tracks, deren Block in der Datei nicht (mehr) gefunden wurde – Datei inzwischen anders gespeichert
        public var missing: [String] = []
        /// angelegte Sicherung (nil = keine nötig, letzte ist jünger als eine Stunde)
        public var backup: URL?
        /// Datei tatsächlich neu geschrieben
        public var changed = false
        /// Hotcues / Grid, die jetzt so in der Datei stehen
        public var writtenCues: [String: TrackEdit] = [:]
        /// umbenannte Einträge: alter -> neuer Schlüssel
        public var moved: [String: String] = [:]
        /// neu angelegte Einträge
        public var added: [String] = []
        /// entfernte Einträge (Schlüssel)
        public var removed: [String] = []
        /// Verweise in den Playlists, die entfernt oder auf den Behalter umgebogen wurden
        public var removedRefs = 0
        /// eigene Playlists, wie sie jetzt in der Datei stehen (nil = nicht geschrieben)
        public var playlists: [NMLOwnNode]?
        /// eigener Playlist-Ordner hat sich geändert
        public var playlistsChanged = false
        /// UUIDs der Collection-Playlists, deren Einträge jetzt in der neuen Reihenfolge stehen
        public var playlistsEdited: [String] = []
        /// Größe + Änderungszeit der Datei nach dem Schreiben
        public var stamp: FileStamp?
    }

    public enum Failure: Error, CustomStringConvertible {
        case invalidResult(String)
        public var description: String {
            switch self { case let .invalidResult(s): "Ergebnis ungültig, Datei nicht geschrieben: \(s)" }
        }
    }

    /// Element und Attribut je Feld (wie der NML-Parser liest)
    static func place(_ f: TrackField) -> (element: String, attr: String) {
        switch f {
        case .title: ("ENTRY", "TITLE")
        case .artist: ("ENTRY", "ARTIST")
        case .album: ("ALBUM", "TITLE")
        case .trackNumber: ("ALBUM", "TRACK")
        case .genre: ("INFO", "GENRE")
        case .label: ("INFO", "LABEL")
        case .comment: ("INFO", "COMMENT")
        case .comment2: ("INFO", "RATING")
        case .keyText: ("INFO", "KEY")
        case .remixer: ("INFO", "REMIXER")
        case .producer: ("INFO", "PRODUCER")
        case .mix: ("INFO", "MIX")
        case .catalogNo: ("INFO", "CATALOG_NO")
        case .releaseDate: ("INFO", "RELEASE_DATE")
        case .rating: ("INFO", "RANKING")
        case .bpm: ("TEMPO", "BPM")
        }
    }

    /// kanonischer Wert -> Attributwert in der NML (unescaped); nil = Attribut entfernen
    static func nmlValue(_ f: TrackField, _ v: String) -> String? {
        switch f {
        case .trackNumber: return (Int(v) ?? 0) > 0 ? String(Int(v)!) : nil
        case .rating:
            let n = max(0, min(5, Int(v) ?? 0))
            return n > 0 ? String(n * 51) : nil
        case .releaseDate:
            let p = v.split(separator: "-").compactMap { Int($0) }
            return p.count == 3 ? "\(p[0])/\(p[1])/\(p[2])" : nil
        case .bpm:
            guard let b = Double(v), b > 0 else { return nil }
            return String(format: "%.6f", b)
        default:
            return v.isEmpty ? nil : v
        }
    }

    /// Attributwert aus der Datei (unescaped, nil = fehlt) -> kanonischer Wert, zum Vergleich
    static func canonical(_ f: TrackField, _ raw: String?) -> String {
        guard let raw else { return f == .rating ? "0" : "" }
        switch f {
        case .trackNumber: return (Int(raw) ?? 0) > 0 ? String(Int(raw)!) : ""
        case .rating: return String(max(0, min(5, (Int(raw) ?? 0) / 51)))
        case .releaseDate:
            let p = raw.split(separator: "/").compactMap { Int($0) }
            return p.count == 3 ? String(format: "%04d-%02d-%02d", p[0], p[1], p[2]) : ""
        case .bpm: return (Double(raw) ?? 0) > 0 ? String(format: "%.3f", Double(raw)!) : ""
        default: return raw
        }
    }

    // MARK: - ENTRY-Block

    /// geänderter ENTRY-Block; Felder, die schon so in der Datei stehen, bleiben unberührt
    public static func patch(entry block: String, changes: [TrackField: String]) -> String {
        var s = block
        let nl = block.unicodeScalars.contains("\r") ? "\r\n" : "\n"
        for el in ["ENTRY", "ALBUM", "INFO", "TEMPO"] {
            let fields = TrackField.allCases.filter { changes[$0] != nil && place($0).element == el }
            guard !fields.isEmpty else { continue }
            if let r = startTag(el, in: s) {
                var tag = String(s[r])
                for f in fields { tag = setAttr(f, changes[f]!, in: tag) }
                if tag != String(s[r]) { s.replaceSubrange(r, with: tag) }
            } else {
                let attrs = fields.compactMap { f in nmlValue(f, changes[f]!).map { " \(place(f).attr)=\"\(escape($0))\"" } }
                guard !attrs.isEmpty, let at = insertionPoint(el, in: s) else { continue }
                s.insert(contentsOf: nl + "<\(el)" + attrs.joined() + "></\(el)>", at: at)
            }
        }
        return s
    }

    /// Bereich des Start-Tags `<EL …>` im Block (ENTRY = der Block-Anfang, sonst erstes Vorkommen danach)
    static func startTag(_ el: String, in s: String) -> Range<String.Index>? {
        guard let entry = s.range(of: "<ENTRY", options: [.literal, .anchored]), let entryEnd = tagEnd(s, from: entry.lowerBound) else { return nil }
        if el == "ENTRY" { return entry.lowerBound..<entryEnd }
        guard let r = s.range(of: "<\(el) ", options: .literal, range: entryEnd..<s.endIndex)
                ?? s.range(of: "<\(el)>", options: .literal, range: entryEnd..<s.endIndex),
              let end = tagEnd(s, from: r.lowerBound) else { return nil }
        return r.lowerBound..<end
    }

    /// Index hinter dem `>` des Tags ab `from` (Anführungszeichen beachten)
    static func tagEnd(_ s: String, from: String.Index) -> String.Index? {
        var quoted = false
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { quoted.toggle() } else if c == ">", !quoted { return s.index(after: i) }
            i = s.index(after: i)
        }
        return nil
    }

    /// wohin ein fehlendes Element kommt: ALBUM hinter LOCATION, INFO hinter MODIFICATION_INFO/ALBUM/LOCATION, TEMPO hinter INFO
    static func insertionPoint(_ el: String, in s: String) -> String.Index? {
        let after: [String] = switch el {
        case "ALBUM": ["</LOCATION>"]
        case "INFO": ["</MODIFICATION_INFO>", "</ALBUM>", "</LOCATION>"]
        case "TEMPO": ["</INFO>", "</MODIFICATION_INFO>", "</ALBUM>", "</LOCATION>"]
        default: []
        }
        for a in after { if let r = s.range(of: a, options: .literal) { return r.upperBound } }
        return nil
    }

    /// Attribut im Start-Tag setzen, ändern oder entfernen – nur wenn sich der Wert wirklich ändert
    static func setAttr(_ f: TrackField, _ value: String, in tag: String) -> String {
        let name = place(f).attr
        let new = nmlValue(f, value)
        var t = tag
        if let r = t.range(of: " \(name)=\"", options: .literal),
           let q = t[r.upperBound...].firstIndex(of: "\"") {
            let current = unescape(String(t[r.upperBound..<q]))
            guard canonical(f, current) != value else { return tag }
            if let new { t.replaceSubrange(r.upperBound..<q, with: escape(new)) } else { t.removeSubrange(r.lowerBound...q) }
            return t
        }
        guard let new else { return tag }
        let end = t.hasSuffix("/>") ? t.index(t.endIndex, offsetBy: -2) : t.index(before: t.endIndex)
        t.insert(contentsOf: " \(name)=\"\(escape(new))\"", at: end)
        return t
    }

    /// Escaping wie in der Collection: & < > " (Apostroph bleibt roh)
    static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default: o.append(c)
            }
        }
        return o
    }

    /// benannte und numerische Entities auflösen
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var o = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let name = s[s.index(after: i)..<semi]
                var rep: String?
                switch name {
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                default:
                    if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(u) }
                    else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(u) }
                }
                if let rep { o += rep; i = s.index(after: semi); continue }
            }
            o.append(s[i])
            i = s.index(after: i)
        }
        return o
    }

    // MARK: - Analyse (TEMPO, LOUDNESS, MUSICAL_KEY, Grid-Marker)

    /// ENTRY-Block mit den analysierten Werten: BPM wie beim Bearbeiten, LOUDNESS und MUSICAL_KEY als Attribute ihrer
    /// Elemente (fehlende Elemente hinter TEMPO bzw. LOUDNESS), der Grid-Anker als CUE_V2 TYPE="4" (vorhandener Marker:
    /// START, sonst ein neuer vor </ENTRY>). Nur gesetzte Felder der Analyse ändern den Block.
    public static func patch(entry block: String, analysis a: TrackAnalysis) -> String {
        var s = block
        let nl = block.unicodeScalars.contains("\r") ? "\r\n" : "\n"
        let f6 = { (v: Double) in String(format: "%.6f", v) }
        // BPM mit 6 Stellen (0,0005 BPM Rundung = ~2 ms Drift über 8 Minuten)
        if let b = a.bpm, b > 0 {
            if let r = startTag("TEMPO", in: s) {
                let tag = setRawAttr("BPM", f6(b), in: String(s[r]))
                if tag != String(s[r]) { s.replaceSubrange(r, with: tag) }
            } else {
                s = patch(entry: s, changes: [.bpm: f6(b)])
            }
        }
        if let p = a.perceivedDb {
            var attrs = [(String, String)]()
            if let pk = a.peakDb { attrs.append(("PEAK_DB", f6(pk))) }
            attrs += [("PERCEIVED_DB", f6(p)), ("ANALYZED_DB", f6(p))]
            s = setElement("LOUDNESS", attrs, after: ["</TEMPO>", "</INFO>", "</MODIFICATION_INFO>", "</ALBUM>", "</LOCATION>"], in: s, nl: nl)
        }
        if let k = a.musicalKey {
            s = setElement("MUSICAL_KEY", [("VALUE", String(k))],
                           after: ["</LOUDNESS>", "</TEMPO>", "</INFO>", "</MODIFICATION_INFO>", "</ALBUM>", "</LOCATION>"], in: s, nl: nl)
        }
        if let g = a.gridAnchorMs {
            if let r = gridCueTag(in: s) {
                let tag = setRawAttr("START", f6(g), in: String(s[r]))
                if tag != String(s[r]) { s.replaceSubrange(r, with: tag) }
            } else if let end = s.range(of: "</ENTRY>", options: [.literal, .backwards]) {
                // eigene Zeile vor </ENTRY>, wie die Marker der Collection
                let tag = "<CUE_V2 NAME=\"AutoGrid\" DISPL_ORDER=\"0\" TYPE=\"4\" START=\"\(f6(g))\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"-1\"></CUE_V2>"
                let onLine = end.lowerBound > s.startIndex && s[s.index(before: end.lowerBound)] == "\n"
                s.insert(contentsOf: onLine ? tag + nl : nl + tag + nl, at: end.lowerBound)
            }
        }
        return s
    }

    /// Attribute eines Elements setzen; fehlt das Element, kommt es hinter die erste gefundene Marke
    static func setElement(_ el: String, _ attrs: [(String, String)], after: [String], in s: String, nl: String) -> String {
        var s = s
        if let r = startTag(el, in: s) {
            var tag = String(s[r])
            for (n, v) in attrs { tag = setRawAttr(n, v, in: tag) }
            if tag != String(s[r]) { s.replaceSubrange(r, with: tag) }
            return s
        }
        for a in after {
            if let r = s.range(of: a, options: .literal) {
                s.insert(contentsOf: nl + "<\(el)" + attrs.map { " \($0.0)=\"\(escape($0.1))\"" }.joined() + "></\(el)>", at: r.upperBound)
                return s
            }
        }
        return s
    }

    /// Attribut im Start-Tag setzen oder anhängen (nur wenn der Wert sich ändert)
    static func setRawAttr(_ name: String, _ value: String, in tag: String) -> String {
        var t = tag
        if let r = t.range(of: " \(name)=\"", options: .literal), let q = t[r.upperBound...].firstIndex(of: "\"") {
            guard String(t[r.upperBound..<q]) != escape(value) else { return tag }
            t.replaceSubrange(r.upperBound..<q, with: escape(value))
            return t
        }
        let end = t.hasSuffix("/>") ? t.index(t.endIndex, offsetBy: -2) : t.index(before: t.endIndex)
        t.insert(contentsOf: " \(name)=\"\(escape(value))\"", at: end)
        return t
    }

    /// Start-Tag des Grid-Markers (CUE_V2 mit TYPE="4")
    static func gridCueTag(in s: String) -> Range<String.Index>? {
        var from = s.startIndex
        while let r = s.range(of: "<CUE_V2 ", options: .literal, range: from..<s.endIndex), let end = tagEnd(s, from: r.lowerBound) {
            if s[r.lowerBound..<end].contains(" TYPE=\"4\"") { return r.lowerBound..<end }
            from = end
        }
        return nil
    }

    // MARK: - Datei

    /// Metadaten und Analysen in die Datei schreiben (Kurzform von `write(url:job:…)`)
    public static func write(url: URL, changes: [String: [TrackField: String]], analyses: [String: TrackAnalysis] = [:],
                             index: NMLEntryIndex, backupDir: URL?, now: Date = Date()) throws -> Result {
        try write(url: url, job: Job(changes: changes, analyses: analyses), index: index, backupDir: backupDir, now: now)
    }

    /// Temp-Datei im selben Ordner schreiben, dann per rename über das Original (atomar, nie halb geschrieben)
    static func replaceAtomically(_ url: URL, with data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).minos741-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: tmp)
            throw err
        }
    }

    /// so viele Sicherungen bleiben, ältere fallen weg
    public static let keepBackups = 30

    /// Sicherung `collection_JJJJ-MM-TT_HHMMSS.nml` in `dir`; nil, wenn die letzte jünger als `minInterval` ist.
    /// Danach nur die neuesten `keepBackups`
    public static func backup(_ url: URL, into dir: URL, now: Date, minInterval: TimeInterval = 3600) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = backupFormatter
        let newest = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("collection_") && $0.hasSuffix(".nml") }
            .compactMap { f.date(from: String($0.dropFirst("collection_".count).dropLast(4))) }
            .max()
        if let newest, now.timeIntervalSince(newest) < minInterval { return nil }
        let target = dir.appendingPathComponent("collection_\(f.string(from: now)).nml")
        guard !fm.fileExists(atPath: target.path) else { return nil }
        try fm.copyItem(at: url, to: target)
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("collection_") && $0.hasSuffix(".nml") && f.date(from: String($0.dropFirst("collection_".count).dropLast(4))) != nil }
            .sorted()
        for old in all.dropLast(keepBackups) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        return target
    }

    static var backupFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }

    /// Byte-Suche (memmem)
    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        return hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count).map { h.baseAddress!.distance(to: $0.assumingMemoryBound(to: UInt8.self)) }
            }
        }
    }
}
