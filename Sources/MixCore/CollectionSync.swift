import Foundation
import CryptoKit

/// Ort einer Datei in der Collection (Element LOCATION). Schlüssel = VOLUME + DIR + FILE.
public struct NMLLocation: Codable, Equatable, Hashable, Sendable {
    public var volume: String
    public var volumeID: String
    /// „/:Users/:x/:Music/:“
    public var dir: String
    public var file: String

    public init(volume: String, volumeID: String, dir: String, file: String) {
        self.volume = volume; self.volumeID = volumeID; self.dir = dir; self.file = file
    }

    /// aus einem Pfad (wie `MusicFolder.nmlKey`)
    public init(path: String, volume: String, mount: String, volumeID: String? = nil) {
        var rel = path
        if mount != "/", rel.hasPrefix(mount) { rel = String(rel.dropFirst(mount.count)) }
        let comps = rel.split(separator: "/").map(String.init)
        self.volume = volume
        self.volumeID = volumeID ?? volume
        file = comps.last ?? ""
        dir = "/:" + comps.dropLast().map { $0 + "/:" }.joined()
    }

    /// Volume des Pfads nachsehen (Dateisystem)
    public static func of(path: String, volumeID: String? = nil) -> NMLLocation {
        let v = MusicFolder.volumeInfo(path)
        return NMLLocation(path: path, volume: v.name, mount: v.mount, volumeID: volumeID)
    }

    public var key: String { volume + dir + file }

    var tag: String {
        "<LOCATION DIR=\"\(CollectionWriter.escape(dir))\" FILE=\"\(CollectionWriter.escape(file))\" VOLUME=\"\(CollectionWriter.escape(volume))\" VOLUMEID=\"\(CollectionWriter.escape(volumeID))\"></LOCATION>"
    }
}

/// eigener Playlist-Knoten unter `$ROOT/MINOS-741` in der Collection-Datei
public indirect enum NMLOwnNode: Equatable, Sendable {
    case folder(String, [NMLOwnNode])
    case playlist(String, [String])

    public var name: String {
        switch self { case let .folder(n, _), let .playlist(n, _): n }
    }
}

/// Größe + Änderungszeit einer Datei: hat sie sich seit dem letzten Lesen geändert?
public struct FileStamp: Equatable, Sendable {
    public var size: Int
    public var mtime: Double

    public init(size: Int, mtime: Double) { self.size = size; self.mtime = mtime }

    public init?(url: URL) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.intValue, let m = a[.modificationDate] as? Date else { return nil }
        self.size = size
        mtime = m.timeIntervalSinceReferenceDate
    }
}

extension CollectionWriter {
    /// Name des eigenen Ordners unter `$ROOT`
    public static let ownFolder = "MINOS-741"

    /// alles, was in einem Schreibvorgang in die Datei geht
    public struct Job: Sendable {
        /// Metadaten (Feld -> kanonischer Wert)
        public var changes: [String: [TrackField: String]] = [:]
        /// eigene Analysen
        public var analyses: [String: TrackAnalysis] = [:]
        /// Hotcues / Memory-Cues / Loops und von Hand gesetztes Grid (edits.json)
        public var cues: [String: TrackEdit] = [:]
        /// Datei umbenannt: alter Schlüssel -> neuer Ort
        public var moves: [String: NMLLocation] = [:]
        /// neue Einträge (Track-Schlüssel = NML-Schlüssel), z. B. Tool-Loop-Dateien
        public var newEntries: [Track] = []
        /// eigene Playlists unter `$ROOT/MINOS-741` (nil = Playlists nicht anfassen)
        public var playlists: [NMLOwnNode]?
        /// Playlists der Collection (außerhalb von MINOS-741): neue Reihenfolge je Knoten, per UUID
        public var playlistEdits: [PlaylistEdit] = []
        /// Einträge entfernen (ENTRY-Block weg); Verweise in allen Playlists fallen weg
        public var remove: Set<String> = []
        /// entfernte Einträge -> Behalter: Verweise in den Playlists zeigen auf den Behalter (ohne Dublette)
        public var redirects: [String: String] = [:]
        /// Attribute des INFO-Elements je Schlüssel (COLOR, PLAYCOUNT)
        public var info: [String: [String: String]] = [:]
        /// zusätzliche Memory-Cues (Hotcue -1) je Schlüssel
        public var cueAdds: [String: [Cue]] = [:]
        /// Datei muss noch so sein wie beim letzten Lesen (nil = nicht prüfen)
        public var expected: FileStamp?

        public init(changes: [String: [TrackField: String]] = [:], analyses: [String: TrackAnalysis] = [:]) {
            self.changes = changes; self.analyses = analyses
        }

        public var isEmpty: Bool {
            changes.isEmpty && analyses.isEmpty && cues.isEmpty && moves.isEmpty && newEntries.isEmpty && playlists == nil
                && remove.isEmpty && info.isEmpty && cueAdds.isEmpty && playlistEdits.isEmpty
        }
    }

    /// Neue Reihenfolge einer Playlist der Collection. Der Knoten wird über seine UUID gefunden (muss in der Datei
    /// genau einmal stehen); `keys` ist die komplette neue Liste der Track-Schlüssel
    public struct PlaylistEdit: Sendable, Equatable {
        public var uuid: String
        public var keys: [String]
        /// doppelte Schlüssel erlauben (sonst Fehler vor dem Schreiben)
        public var allowDuplicates: Bool

        public init(uuid: String, keys: [String], allowDuplicates: Bool = false) {
            self.uuid = uuid
            self.keys = keys
            self.allowDuplicates = allowDuplicates
        }
    }

    // MARK: - Cues (CUE_V2)

    /// CUE_V2-Element im Block: Bereich inklusive Zeilenende dahinter
    struct CueTag {
        var range: Range<String.Index>
        var cue: Cue
    }

    /// alle CUE_V2-Elemente des Blocks in Reihenfolge
    static func cueTags(in s: String) -> [CueTag] {
        var out: [CueTag] = []
        var from = s.startIndex
        while let r = s.range(of: "<CUE_V2 ", options: .literal, range: from..<s.endIndex), let end = tagEnd(s, from: r.lowerBound) {
            let a = attributes(s[r.lowerBound..<end])
            var stop = end
            if let close = s.range(of: "</CUE_V2>", options: [.literal, .anchored], range: end..<s.endIndex) { stop = close.upperBound }
            if s[stop...].hasPrefix("\r\n") { stop = s.index(stop, offsetBy: 2) } else if s[stop...].hasPrefix("\n") { stop = s.index(after: stop) }
            let cue = Cue(name: a["NAME"] ?? "", kind: Cue.Kind(rawValue: Int(a["TYPE"] ?? "") ?? 0) ?? .cue,
                          startMs: Double(a["START"] ?? "") ?? 0, lengthMs: Double(a["LEN"] ?? "") ?? 0,
                          hotcue: Int(a["HOTCUE"] ?? "") ?? -1)
            out.append(CueTag(range: r.lowerBound..<stop, cue: cue))
            from = stop
        }
        return out
    }

    /// Attribute eines Start-Tags (unescaped)
    static func attributes(_ tag: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = tag.startIndex
        while let eq = tag[i...].range(of: "=\"") {
            var n = eq.lowerBound
            while n > tag.startIndex, tag[tag.index(before: n)] != " " { n = tag.index(before: n) }
            guard let q = tag[eq.upperBound...].firstIndex(of: "\"") else { break }
            out[String(tag[n..<eq.lowerBound])] = unescape(String(tag[eq.upperBound..<q]))
            i = tag.index(after: q)
        }
        return out
    }

    /// CUE_V2-Element wie die Collection (6 Nachkommastellen, REPEATS -1, ein Element je Zeile)
    static func cueTag(_ c: Cue) -> String {
        let name = c.name.isEmpty ? "n.n." : c.name
        return "<CUE_V2 NAME=\"\(escape(name))\" DISPL_ORDER=\"0\" TYPE=\"\(c.kind.rawValue)\" START=\"\(String(format: "%.6f", c.startMs))\" LEN=\"\(String(format: "%.6f", c.lengthMs))\" REPEATS=\"-1\" HOTCUE=\"\(c.hotcue)\"></CUE_V2>"
    }

    /// gleicher Cue (Zeiten auf die 6 Nachkommastellen der Datei genau)
    static func sameCue(_ a: Cue, _ b: Cue) -> Bool {
        a.kind == b.kind && a.hotcue == b.hotcue && (a.name == b.name || (a.name.isEmpty && b.name == "n.n.") || (b.name.isEmpty && a.name == "n.n."))
            && abs(a.startMs - b.startMs) < 0.000_6 && abs(a.lengthMs - b.lengthMs) < 0.000_6
    }

    /// Hotcues, wie sie aus einer Änderung in die Datei gehen: Grid-Marker zählen nicht (die setzt das Grid),
    /// nach Nummer sortiert – genau das, was `TrackEdit.apply` über die Collection-Cues legt
    public static func writtenHotcues(_ e: TrackEdit) -> [Cue]? {
        e.hotcues.map { $0.filter { $0.kind != .grid && $0.hotcue >= 0 }.sorted { $0.hotcue < $1.hotcue } }
    }

    /// ENTRY-Block mit den eigenen Hotcues und dem von Hand gesetzten Grid. Hotcues (HOTCUE 0–7, außer Grid-Markern)
    /// werden ersetzt: gleiche bleiben Zeichen für Zeichen stehen, weggefallene verschwinden, neue kommen hinter das
    /// letzte CUE_V2. Memory-Cues (HOTCUE -1) und weitere Grid-Marker bleiben. Grid: BPM und START des ersten
    /// Grid-Markers wie beim Schreiben der Analyse, nicht bei gesperrten Einträgen (LOCK="1")
    public static func patch(entry block: String, edit e: TrackEdit) -> String {
        var s = block
        if e.hasGrid, !isLocked(block) {
            s = patch(entry: s, analysis: TrackAnalysis(bpm: e.bpm, gridAnchorMs: e.gridAnchorMs))
        }
        guard let want = writtenHotcues(e) else { return s }
        var missing = want
        var drop: [Range<String.Index>] = []
        for t in cueTags(in: s) where t.cue.hotcue >= 0 && t.cue.kind != .grid {
            if let i = missing.firstIndex(where: { sameCue($0, t.cue) }) { missing.remove(at: i) } else { drop.append(t.range) }
        }
        for r in drop.reversed() { s.removeSubrange(r) }
        return insertCues(missing, into: s)
    }

    /// Cues hinter das letzte CUE_V2 setzen (sonst vor `</ENTRY>`), je eine Zeile
    static func insertCues(_ list: [Cue], into block: String) -> String {
        guard !list.isEmpty else { return block }
        var s = block
        let nl = block.unicodeScalars.contains("\r") ? "\r\n" : "\n"
        let text = list.map { cueTag($0) + nl }.joined()
        if let last = cueTags(in: s).last {
            let at = last.range.upperBound
            let lineStart = at == s.startIndex || s[s.index(before: at)] == "\n"
            s.insert(contentsOf: lineStart ? text : nl + text, at: at)
        } else if let end = s.range(of: "</ENTRY>", options: [.literal, .backwards]) {
            let onLine = end.lowerBound > s.startIndex && s[s.index(before: end.lowerBound)] == "\n"
            s.insert(contentsOf: onLine ? text : nl + text, at: end.lowerBound)
        }
        return s
    }

    /// ENTRY-Block mit zusätzlichen Cues (Memory-Cues aus einer Zusammenführung)
    public static func patch(entry block: String, addCues list: [Cue]) -> String {
        insertCues(list, into: block)
    }

    /// ENTRY-Block mit INFO-Attributen (COLOR, PLAYCOUNT); fehlt INFO, kommt es an die übliche Stelle
    public static func patch(entry block: String, info attrs: [String: String]) -> String {
        let nl = block.unicodeScalars.contains("\r") ? "\r\n" : "\n"
        return setElement("INFO", attrs.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                          after: ["</MODIFICATION_INFO>", "</ALBUM>", "</LOCATION>"], in: block, nl: nl)
    }

    /// Eintrag gesperrt (LOCK="1" im ENTRY-Tag)
    static func isLocked(_ block: String) -> Bool {
        guard let r = startTag("ENTRY", in: block) else { return false }
        return block[r].contains(" LOCK=\"1\"")
    }

    // MARK: - LOCATION

    /// ENTRY-Block mit neuem Ort (DIR, FILE, VOLUME, VOLUMEID); der Rest bleibt
    public static func patch(entry block: String, location l: NMLLocation) -> String {
        guard let r = block.range(of: "<LOCATION ", options: .literal), let end = tagEnd(block, from: r.lowerBound) else { return block }
        var tag = String(block[r.lowerBound..<end])
        for (n, v) in [("DIR", l.dir), ("FILE", l.file), ("VOLUME", l.volume), ("VOLUMEID", l.volumeID)] { tag = setRawAttr(n, v, in: tag) }
        var s = block
        s.replaceSubrange(r.lowerBound..<end, with: tag)
        return s
    }

    /// neuer Ort einer Datei, deren Pfad sich ändert (z. B. andere Endung nach dem Schneiden): Volume wie bisher,
    /// wenn der Pfad auf demselben Volume bleibt (VOLUMEID aus dem alten Eintrag)
    public static func pathChanged(old: String, new: String, oldBlock: String?) -> NMLLocation {
        var loc = NMLLocation.of(path: new)
        if let b = oldBlock, let r = b.range(of: "<LOCATION ", options: .literal), let end = tagEnd(b, from: r.lowerBound) {
            let a = attributes(b[r.lowerBound..<end])
            if a["VOLUME"] == loc.volume, let id = a["VOLUMEID"], !id.isEmpty { loc.volumeID = id }
        }
        return loc
    }

    // MARK: - neue Einträge

    /// ENTRY-Block für eine Datei, die noch nicht in der Collection steht (ohne AUDIO_ID: die Bibliothekssoftware
    /// rechnet sie bei der nächsten Analyse). Aufbau und Attribut-Reihenfolge wie die Einträge der Collection
    public static func newEntry(_ t: Track, location l: NMLLocation, now: Date = Date()) -> String {
        let f6 = { (v: Double) in String(format: "%.6f", v) }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let date = "\(c.year!)/\(c.month!)/\(c.day!)", secs = c.hour! * 3600 + c.minute! * 60 + c.second!
        func attrs(_ list: [(String, String?)]) -> String {
            list.compactMap { n, v in v.flatMap { $0.isEmpty ? nil : " \(n)=\"\(escape($0))\"" } }.joined()
        }
        func day(_ d: Date?) -> String? {
            guard let d else { return nil }
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
            return "\(c.year!)/\(c.month!)/\(c.day!)"
        }
        var s = "<ENTRY MODIFIED_DATE=\"\(date)\" MODIFIED_TIME=\"\(secs)\"" + attrs([("TITLE", t.title), ("ARTIST", t.artist)]) + ">"
        s += l.tag + "\n"
        if !t.album.isEmpty || t.trackNumber > 0 {
            s += "<ALBUM" + attrs([("TRACK", t.trackNumber > 0 ? String(t.trackNumber) : nil), ("TITLE", t.album)]) + "></ALBUM>\n"
        }
        s += "<MODIFICATION_INFO AUTHOR_TYPE=\"user\"></MODIFICATION_INFO>\n"
        s += "<INFO" + attrs([
            ("BITRATE", t.bitrate > 0 ? String(t.bitrate * 1000) : nil), ("GENRE", t.genre), ("LABEL", t.label),
            ("COMMENT", t.comment), ("RATING", t.comment2), ("KEY", t.keyText), ("REMIXER", t.remixer), ("PRODUCER", t.producer),
            ("MIX", t.mix), ("CATALOG_NO", t.catalogNo),
            ("PLAYTIME", t.duration > 0 ? String(Int(t.duration.rounded())) : nil), ("PLAYTIME_FLOAT", t.duration > 0 ? f6(t.duration) : nil),
            ("RANKING", t.rating > 0 ? String(min(5, t.rating) * 51) : nil), ("IMPORT_DATE", day(t.importDate ?? now)),
            ("RELEASE_DATE", day(t.releaseDate)), ("COLOR", t.color > 0 ? String(t.color) : nil),
            ("FILESIZE", t.fileSizeKB > 0 ? String(t.fileSizeKB) : nil),
        ]) + "></INFO>\n"
        if t.bpm > 0, t.bpm.isFinite { s += "<TEMPO BPM=\"\(f6(t.bpm))\" BPM_QUALITY=\"100.000000\"></TEMPO>\n" }
        if let p = t.perceivedDb, p.isFinite {
            s += "<LOUDNESS" + (t.peakDb.map { " PEAK_DB=\"\(f6($0))\"" } ?? "") + " PERCEIVED_DB=\"\(f6(p))\" ANALYZED_DB=\"\(f6(p))\"></LOUDNESS>\n"
        }
        if (0...23).contains(t.musicalKey) { s += "<MUSICAL_KEY VALUE=\"\(t.musicalKey)\"></MUSICAL_KEY>\n" }
        // Grid zuerst (ein Marker), dann Hotcues nach Nummer, dann Memory-Cues nach Zeit; Lade-Hilfsmarker nicht
        let grid = t.cues.first { $0.kind == .grid }
        let hot = t.cues.filter { $0.hotcue >= 0 && $0.kind != .grid }.sorted { $0.hotcue < $1.hotcue }
        let memory = t.cues.filter { $0.hotcue < 0 && $0.kind != .grid && $0.kind != .load }.sorted { $0.startMs < $1.startMs }
        for cue in (grid.map { [$0] } ?? []) + hot + memory { s += cueTag(cue) + "\n" }
        s += "</ENTRY>"
        return s
    }

    // MARK: - Playlists

    /// Playlist-ID, gleich bei gleichem Pfad (wiederholtes Schreiben ändert nichts)
    static func uuid(_ path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Text eines eigenen Knotens im Format der Collection
    static func nodeText(_ n: NMLOwnNode, path: String) -> String {
        switch n {
        case let .folder(name, children):
            let p = path + "/" + name
            return "<NODE TYPE=\"FOLDER\" NAME=\"\(escape(name))\"><SUBNODES COUNT=\"\(children.count)\">"
                + children.map { nodeText($0, path: p) }.joined() + "</SUBNODES>\n</NODE>\n"
        case let .playlist(name, keys):
            let p = path + "/" + name
            return "<NODE TYPE=\"PLAYLIST\" NAME=\"\(escape(name))\"><PLAYLIST ENTRIES=\"\(keys.count)\" TYPE=\"LIST\" UUID=\"\(uuid(p))\">"
                + keys.map { "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(escape($0))\"></PRIMARYKEY>\n</ENTRY>\n" }.joined()
                + "</PLAYLIST>\n</NODE>\n"
        }
    }

    /// Kinder-Knoten eines SUBNODES-Inhalts ab `from` bis `</SUBNODES>`: Bereich je Knoten (inkl. Zeilenende) + Start-Tag
    static func childNodes(_ s: String, from: String.Index) -> (nodes: [(range: Range<String.Index>, tag: Substring)], end: String.Index)? {
        var out: [(Range<String.Index>, Substring)] = []
        var i = from
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            if s[i...].hasPrefix("</SUBNODES>") { return (out, i) }
            guard s[i...].hasPrefix("<NODE "), let tagEnd = tagEnd(s, from: i) else { return nil }
            // passendes </NODE> (verschachtelte Knoten zählen)
            var depth = 1, j = tagEnd
            while depth > 0 {
                let open = s.range(of: "<NODE ", options: .literal, range: j..<s.endIndex)?.lowerBound ?? s.endIndex
                guard let close = s.range(of: "</NODE>", options: .literal, range: j..<s.endIndex) else { return nil }
                if open < close.lowerBound { depth += 1; j = s.index(open, offsetBy: 6) } else { depth -= 1; j = close.upperBound }
            }
            if s[j...].hasPrefix("\r\n") { j = s.index(j, offsetBy: 2) } else if s[j...].hasPrefix("\n") { j = s.index(after: j) }
            out.append((i..<j, s[i..<tagEnd]))
            i = j
        }
        return nil
    }

    /// PLAYLISTS-Teil (ab `<PLAYLISTS>` bis Dateiende) mit dem eigenen Ordner `$ROOT/MINOS-741`: vorhandener eigener
    /// Ordner wird ersetzt, sonst kommt er als letzter Knoten unter `$ROOT` dazu (COUNT + 1). Fremde Knoten bleiben
    /// Zeichen für Zeichen. nil = kein `$ROOT` gefunden
    public static func patch(playlists s: String, own children: [NMLOwnNode]) -> String? {
        guard let root = s.range(of: "<NODE TYPE=\"FOLDER\" NAME=\"$ROOT\">", options: .literal),
              let sub = s.range(of: "<SUBNODES", options: [.literal, .anchored], range: root.upperBound..<s.endIndex),
              let subEnd = tagEnd(s, from: sub.lowerBound),
              let list = childNodes(s, from: subEnd) else { return nil }
        let text = nodeText(.folder(ownFolder, children), path: "$ROOT")
        let own = list.nodes.first { n in
            let a = attributes(n.tag)
            return a["TYPE"] == "FOLDER" && a["NAME"] == ownFolder
        }
        var out = s
        if let own {
            guard String(s[own.range]) != text else { return s }
            out.replaceSubrange(own.range, with: text)
        } else {
            out.insert(contentsOf: text, at: list.end)
            let tag = setRawAttr("COUNT", String(list.nodes.count + 1), in: String(s[sub.lowerBound..<subEnd]))
            out.replaceSubrange(sub.lowerBound..<subEnd, with: tag)
        }
        return out
    }

    // MARK: - Verweise in Playlists

    /// Einträge einer Playlist (`<ENTRY><PRIMARYKEY TYPE="TRACK" KEY="…">`): Bereich inkl. Zeilenende, Bereich des
    /// Schlüssels, Schlüssel (unescaped)
    static func playlistEntries(_ body: String) -> [(range: Range<String.Index>, keyRange: Range<String.Index>, key: String)] {
        var out: [(range: Range<String.Index>, keyRange: Range<String.Index>, key: String)] = []
        let open = "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\""
        var pos = body.startIndex
        while let at = body.range(of: open, options: .literal, range: pos..<body.endIndex),
              let q = body[at.upperBound...].firstIndex(of: "\""),
              let close = body.range(of: "</ENTRY>", options: .literal, range: q..<body.endIndex) {
            var stop = close.upperBound
            if body[stop...].hasPrefix("\r\n") { stop = body.index(stop, offsetBy: 2) } else if body[stop...].hasPrefix("\n") { stop = body.index(after: stop) }
            out.append((at.lowerBound..<stop, at.upperBound..<q, unescape(String(body[at.upperBound..<q]))))
            pos = stop
        }
        return out
    }

    /// Eine Playlist: Einträge entfernter Tracks weg; umgebogene zeigen auf den Behalter, außer der steht schon drin
    /// (dann fällt der Eintrag weg). Ergebnis, Zahl der weggefallenen Einträge, Zahl der geänderten
    static func patchEntries(_ body: String, remove: Set<String>, redirects: [String: String]) -> (text: String, dropped: Int, changed: Int) {
        let list = playlistEntries(body)
        var here = Set(list.filter { !remove.contains($0.key) && redirects[$0.key] == nil }.map(\.key))
        var edits: [(Range<String.Index>, String)] = []
        var dropped = 0, changed = 0
        for e in list {
            if let t = redirects[e.key], t != e.key {
                if here.contains(t) {
                    edits.append((e.range, "")); dropped += 1
                } else {
                    here.insert(t)
                    edits.append((e.keyRange, escape(t)))
                }
                changed += 1
            } else if remove.contains(e.key) {
                edits.append((e.range, "")); dropped += 1; changed += 1
            }
        }
        var text = body
        for (r, t) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { text.replaceSubrange(r, with: t) }
        return (text, dropped, changed)
    }

    /// PLAYLISTS-Teil: alle Playlists durchgehen (ENTRIES der Playlist wird um die weggefallenen Einträge kleiner).
    /// Ergebnis, Zahl der Änderungen
    static func patchRefs(_ s: String, remove: Set<String>, redirects: [String: String]) -> (String, Int) {
        var out = ""
        var pos = s.startIndex
        var total = 0
        while let open = s.range(of: "<PLAYLIST ", options: .literal, range: pos..<s.endIndex),
              let head = tagEnd(s, from: open.lowerBound),
              let close = s.range(of: "</PLAYLIST>", options: .literal, range: head..<s.endIndex) {
            var tag = String(s[open.lowerBound..<head])
            let (body, dropped, changed) = patchEntries(String(s[head..<close.lowerBound]), remove: remove, redirects: redirects)
            total += changed
            if dropped > 0, let n = Int(attributes(tag[...])["ENTRIES"] ?? "") {
                tag = setRawAttr("ENTRIES", String(max(0, n - dropped)), in: tag)
            }
            out += s[pos..<open.lowerBound] + tag + body + "</PLAYLIST>"
            pos = close.upperBound
        }
        out += s[pos...]
        return (out, total)
    }

    /// Playlist mit der UUID aus `edit` im PLAYLISTS-Teil (ab `<PLAYLISTS>`): die Einträge kommen in der neuen Reihenfolge.
    /// Vorhandene Einträge bleiben Zeichen für Zeichen (je Schlüssel der Reihe nach), neue wie die Collection; ENTRIES
    /// wird auf die neue Zahl gesetzt. Refusal bei: UUID nicht oder mehrfach in der Datei, fremder Inhalt im Knoten,
    /// doppelte Schlüssel ohne `allowDuplicates`, Schlüssel nicht in der Collection
    static func patchCollectionPlaylist(_ tail: String, edit: PlaylistEdit, index: NMLEntryIndex) throws -> String {
        let attr = "UUID=\"\(edit.uuid)\""
        var hits: [Range<String.Index>] = []
        var from = tail.startIndex
        while let r = tail.range(of: attr, options: .literal, range: from..<tail.endIndex) { hits.append(r); from = r.upperBound }
        guard let at = hits.first, hits.count == 1 else {
            throw Failure.invalidResult(hits.isEmpty ? "Playlist-ID nicht gefunden: \(edit.uuid)" : "Playlist-ID mehrfach in der Datei: \(edit.uuid)")
        }
        guard let start = tail.range(of: "<PLAYLIST ", options: [.literal, .backwards], range: tail.startIndex..<at.lowerBound)?.lowerBound,
              tail.range(of: "</PLAYLIST>", options: .literal, range: start..<at.lowerBound) == nil,
              let headEnd = tagEnd(tail, from: start), at.upperBound <= headEnd,   // UUID im Start-Tag von PLAYLIST (nicht SMARTLIST)
              let close = tail.range(of: "</PLAYLIST>", options: .literal, range: headEnd..<tail.endIndex) else {
            throw Failure.invalidResult("Playlist-Knoten nicht lesbar: \(edit.uuid)")
        }
        let body = String(tail[headEnd..<close.lowerBound])
        let entries = playlistEntries(body)
        // nur Einträge im Knoten: alles andere wäre beim Umbau verloren
        var rest = body
        for e in entries.reversed() { rest.removeSubrange(e.range) }
        guard rest.allSatisfy(\.isWhitespace) else { throw Failure.invalidResult("unbekannter Inhalt in der Playlist: \(edit.uuid)") }
        if !edit.allowDuplicates, Set(edit.keys).count != edit.keys.count {
            throw Failure.invalidResult("doppelte Einträge nicht erlaubt")
        }
        var pool: [String: [String]] = [:]
        for e in entries { pool[e.key, default: []].append(String(body[e.range])) }
        var out = ""
        for k in edit.keys {
            guard index.raw[k] != nil || pool[k] != nil else { throw Failure.invalidResult("Track nicht in der Collection: \(k)") }
            if var list = pool[k], !list.isEmpty {
                out += list.removeFirst()
                pool[k] = list
            } else {
                out += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(escape(k))\"></PRIMARYKEY>\n</ENTRY>\n"
            }
        }
        let head = setRawAttr("ENTRIES", String(edit.keys.count), in: String(tail[start..<headEnd]))
        return String(tail[..<start]) + head + out + "</PLAYLIST>" + String(tail[close.upperBound...])
    }

    /// Playlists der Collection nach dem Schreiben: gleiche Knoten in gleicher Reihenfolge, nur die geänderten Listen
    /// haben die neue Liste (Knoten per UUID). Sonst Refusal-artiger Fehler
    static func validatePlaylists(old: PlaylistNode, new: PlaylistNode, edits: [PlaylistEdit]) throws {
        func flat(_ n: PlaylistNode) -> [PlaylistNode] { n.children.flatMap { [$0] + flat($0) } }
        let a = flat(old), b = flat(new)
        guard a.count == b.count else { throw Failure.invalidResult("Anzahl Knoten geändert: \(a.count) -> \(b.count)") }
        for (x, y) in zip(a, b) {
            guard x.kind == y.kind, x.name == y.name, x.uuid == y.uuid, x.query == y.query else {
                throw Failure.invalidResult("Knoten verändert: \(x.name)")
            }
            if x.kind == .playlist, let e = edits.first(where: { $0.uuid == x.uuid }) {
                guard y.trackKeys == e.keys else { throw Failure.invalidResult("Playlist nicht wie geschrieben: \(x.name)") }
            } else {
                guard x.trackKeys == y.trackKeys else { throw Failure.invalidResult("fremde Playlist geändert: \(x.name)") }
            }
        }
    }

    // MARK: - Schreiben

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// Selbsttest: nur Dateien im Temp-Ordner
        case protected(String)
        /// Datei seit dem letzten Lesen geändert -> erst neu einlesen
        case changedOnDisk
        public var description: String {
            switch self {
            case let .protected(p): "Selbsttest schreibt nur Kopien im Temp-Ordner, nicht \(p)"
            case .changedOnDisk: "Datei seit dem letzten Lesen geändert"
            }
        }
    }

    /// Selbsttest (MIX741_SELFTEST=1): nur Dateien unter dem Temp-Ordner – die echte Collection nie
    public static func writeAllowed(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["MIX741_SELFTEST"] == "1" else { return true }
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let target = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return target == tmp || target.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/")
    }

    /// alle Teile eines Schreibvorgangs: ENTRY-Blöcke (Metadaten, Analyse, Cues, Ort) textgenau ersetzen, neue
    /// Einträge vor `</COLLECTION>` (ENTRIES mitgezählt), eigener Playlist-Ordner. Ergebnis prüfen (lesbar, Anzahl
    /// Tracks + neue, geschriebene Cues wieder lesbar), Sicherung, atomar ersetzen
    public static func write(url: URL, job: Job, index: NMLEntryIndex, backupDir: URL?, now: Date = Date()) throws -> Result {
        guard writeAllowed(url) else { throw Refusal.protected(url.path) }
        if let exp = job.expected, FileStamp(url: url) != exp { throw Refusal.changedOnDisk }
        let data = try Data(contentsOf: url)
        var bytes = [UInt8](data)
        var res = Result()
        var replacements: [(range: Range<Int>, new: [UInt8])] = []
        let keys = Set(job.changes.keys).union(job.analyses.keys).union(job.cues.keys).union(job.moves.keys)
            .union(job.remove).union(job.info.keys).union(job.cueAdds.keys)
        let positions = locate(keys.compactMap { k in index.raw[k].map { (k, $0) } }, in: bytes)
        for key in keys.sorted() {
            guard let old = index.raw[key] else { res.missing.append(key); continue }
            let ob = Array(old.utf8)
            guard let pos = positions[key] else { res.missing.append(key); continue }
            if job.remove.contains(key) {
                // Block samt Zeilenende weg
                var end = pos + ob.count
                if end < bytes.count, bytes[end] == 10 { end += 1 } else if end + 1 < bytes.count, bytes[end] == 13, bytes[end + 1] == 10 { end += 2 }
                replacements.append((pos..<end, []))
                res.removed.append(key)
                continue
            }
            var new = old
            if let fields = job.changes[key] { new = patch(entry: new, changes: fields); res.written[key] = fields }
            if let a = job.analyses[key] { new = patch(entry: new, analysis: a); res.writtenAnalyses.append(key) }
            if let e = job.cues[key] { new = patch(entry: new, edit: e); res.writtenCues[key] = e }
            if let i = job.info[key], !i.isEmpty { new = patch(entry: new, info: i) }
            if let c = job.cueAdds[key], !c.isEmpty { new = patch(entry: new, addCues: c) }
            var newKey = key
            if let l = job.moves[key] { new = patch(entry: new, location: l); newKey = l.key; res.moved[key] = newKey }
            res.blocks[newKey] = new
            if new != old { replacements.append((pos..<(pos + ob.count), Array(new.utf8))) }
        }
        for r in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(r.range, with: r.new)
        }
        // neue Einträge (nur Schlüssel, die noch nicht in der Datei stehen)
        let known = Set(index.raw.keys).subtracting(res.moved.keys).subtracting(res.removed).union(res.moved.values)
        var added: [String] = []
        var seen = Set<String>()
        var newBlocks: [String] = []
        for t in job.newEntries where !known.contains(t.key) && !seen.contains(t.key) {
            guard let l = location(forKey: t.key, index: index) else { res.missing.append(t.key); continue }
            seen.insert(t.key)
            let block = newEntry(t, location: l, now: now)
            newBlocks.append(block)
            res.blocks[t.key] = block
            added.append(t.key)
        }
        if !newBlocks.isEmpty {
            guard let close = find(Array("</COLLECTION>".utf8), in: bytes) else { throw Failure.invalidResult("kein </COLLECTION>") }
            let lineStart = close > 0 && bytes[close - 1] == UInt8(ascii: "\n")
            let text = (lineStart ? "" : "\n") + newBlocks.map { $0 + "\n" }.joined()
            bytes.insert(contentsOf: Array(text.utf8), at: close)
            res.added = added
        }
        if !added.isEmpty || !res.removed.isEmpty {
            // Zähler des COLLECTION-Elements (ENTRIES) nachführen, nach dem Einfügen/Entfernen
            let head = Array("<COLLECTION ENTRIES=\"".utf8)
            if let h = find(head, in: bytes), let q = bytes[(h + head.count)...].firstIndex(of: UInt8(ascii: "\"")),
               let n = Int(String(decoding: bytes[(h + head.count)..<q], as: UTF8.self)) {
                bytes.replaceSubrange((h + head.count)..<q, with: Array(String(n + added.count - res.removed.count).utf8))
            }
        }
        // Verweise auf entfernte Einträge in allen Playlists: weg, oder auf den Behalter umgebogen
        if !job.remove.isEmpty || !job.redirects.isEmpty, let p = find(Array("<PLAYLISTS>".utf8), in: bytes) {
            let tail = String(decoding: bytes[p...], as: UTF8.self)
            let (patched, changed) = patchRefs(tail, remove: job.remove, redirects: job.redirects)
            if changed > 0 {
                bytes.replaceSubrange(p..., with: Array(patched.utf8))
                res.removedRefs = changed
            }
        }
        // Playlists der Collection per UUID: neue Reihenfolge des einen Knotens
        for edit in job.playlistEdits {
            guard let p = find(Array("<PLAYLISTS>".utf8), in: bytes) else { throw Failure.invalidResult("kein <PLAYLISTS>") }
            let tail = String(decoding: bytes[p...], as: UTF8.self)
            let patched = try patchCollectionPlaylist(tail, edit: edit, index: index)
            if patched != tail { bytes.replaceSubrange(p..., with: Array(patched.utf8)) }
            res.playlistsEdited.append(edit.uuid)
        }
        // eigene Playlists (nur Tracks, die nach dem Schreiben in der Collection stehen)
        if let own = job.playlists {
            let inFile = known.union(added)
            func filtered(_ n: NMLOwnNode) -> NMLOwnNode {
                switch n {
                case let .folder(name, c): .folder(name, c.map(filtered))
                case let .playlist(name, keys): .playlist(name, keys.map { res.moved[$0] ?? job.redirects[$0] ?? $0 }.filter { inFile.contains($0) })
                }
            }
            let nodes = own.map(filtered)
            if let p = find(Array("<PLAYLISTS>".utf8), in: bytes) {
                let tail = String(decoding: bytes[p...], as: UTF8.self)
                if let patched = patch(playlists: tail, own: nodes) {
                    if patched != tail { bytes.replaceSubrange(p..., with: Array(patched.utf8)); res.playlistsChanged = true }
                    res.playlists = nodes
                }
            }
        }
        guard bytes != [UInt8](data) else { return res }
        let out = Data(bytes)
        try validate(before: data, after: out, job: job, result: res)
        if let backupDir { res.backup = try backup(url, into: backupDir, now: now, minInterval: 0) }
        try replaceAtomically(url, with: out)
        res.changed = true
        res.stamp = FileStamp(url: url)
        return res
    }

    /// Position der Roh-Blöcke in der Datei, ein Durchgang über alle ENTRY-Blöcke der COLLECTION (statt einer Suche
    /// über die ganze Datei je Block: 14k Blöcke × 21 MB). Nicht gefunden = Block in der Datei inzwischen anders
    static func locate(_ blocks: [(key: String, block: String)], in bytes: [UInt8]) -> [String: Int] {
        guard !blocks.isEmpty else { return [:] }
        var want: [Data: String] = [:]
        for (k, b) in blocks { want[Data(b.utf8)] = k }
        var out: [String: Int] = [:]
        let open = Array("<ENTRY ".utf8), close = Array("</ENTRY>".utf8)
        let limit = find(Array("</COLLECTION>".utf8), in: bytes) ?? bytes.count
        bytes.withUnsafeBufferPointer { h in
            var i = 0
            while i < limit, out.count < want.count {
                guard let a = memmem(h.baseAddress! + i, limit - i, open, open.count) else { break }
                let start = h.baseAddress!.distance(to: a.assumingMemoryBound(to: UInt8.self))
                guard let e = memmem(h.baseAddress! + start, limit - start, close, close.count) else { break }
                let end = h.baseAddress!.distance(to: e.assumingMemoryBound(to: UInt8.self)) + close.count
                if let k = want[Data(h[start..<end])] { out[k] = start }
                i = end
            }
        }
        return out
    }

    /// Ort eines neuen Eintrags aus seinem Schlüssel (VOLUME + DIR + FILE), VOLUMEID wie die übrigen Einträge
    /// desselben Volumes. nil = kein NML-Schlüssel
    static func location(forKey key: String, index: NMLEntryIndex) -> NMLLocation? {
        guard let first = key.range(of: "/:"), let last = key.range(of: "/:", options: .backwards), last.upperBound < key.endIndex else { return nil }
        let volume = String(key[..<first.lowerBound])
        let l = NMLLocation(volume: volume, volumeID: volumeID(for: volume, index: index) ?? volume,
                            dir: String(key[first.lowerBound..<last.upperBound]), file: String(key[last.upperBound...]))
        return l.key == key ? l : nil
    }

    static func volumeID(for volume: String, index: NMLEntryIndex) -> String? {
        for block in index.raw.values {
            guard let r = block.range(of: "<LOCATION ", options: .literal), let end = tagEnd(block, from: r.lowerBound) else { continue }
            let a = attributes(block[r.lowerBound..<end])
            if a["VOLUME"] == volume, let id = a["VOLUMEID"], !id.isEmpty { return id }
        }
        return nil
    }

    /// Ergebnis lesen und mit dem Auftrag vergleichen, bevor es die Datei ersetzt
    static func validate(before: Data, after: Data, job: Job, result r: Result) throws {
        let old = try NMLParser.parse(data: before)
        let new: Collection
        do { new = try NMLParser.parse(data: after) } catch { throw Failure.invalidResult("\(error)") }
        guard new.tracks.count == old.tracks.count + r.added.count - r.removed.count else {
            throw Failure.invalidResult("\(old.tracks.count) -> \(new.tracks.count) tracks (+\(r.added.count) neu, -\(r.removed.count) entfernt)")
        }
        let byKey = Dictionary(new.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for k in r.added where byKey[k] == nil { throw Failure.invalidResult("neuer Eintrag fehlt: \(k)") }
        for k in r.removed where byKey[k] != nil { throw Failure.invalidResult("entfernter Eintrag noch da: \(k)") }
        for (o, n) in r.moved where byKey[n] == nil || byKey[o] != nil { throw Failure.invalidResult("umbenannt, nicht gefunden: \(n)") }
        for (k, e) in r.writtenCues {
            guard let t = byKey[r.moved[k] ?? k] else { throw Failure.invalidResult("Track fehlt: \(k)") }
            if let want = writtenHotcues(e) {
                let got = t.cues.filter { $0.hotcue >= 0 && $0.kind != .grid }.sorted { $0.hotcue < $1.hotcue }
                guard got.count == want.count, zip(got, want).allSatisfy({ sameCue($0, $1) }) else {
                    throw Failure.invalidResult("Cues nicht wieder lesbar: \(k)")
                }
            }
            if e.hasGrid, !t.locked, let a = e.gridAnchorMs, let g = t.gridAnchorMs, abs(a - g) > 0.001 {
                throw Failure.invalidResult("Grid nicht wieder lesbar: \(k)")
            }
        }
        if let own = r.playlists {
            guard let f = new.root.children.first(where: { $0.kind == .folder && $0.name == ownFolder }), f.children.count == own.count else {
                throw Failure.invalidResult("eigene Playlists nicht wieder lesbar")
            }
        }
        // Playlists der Collection: nur die geänderten Listen anders, alles andere Knoten für Knoten gleich
        if !job.playlistEdits.isEmpty {
            try validatePlaylists(old: old.root, new: new.root, edits: job.playlistEdits)
        }
    }
}

/// Konflikt-Sicherung: eigene Änderungen, die beim Neu-Laden der Datei weichen mussten (`…-konflikt.json`).
/// Neuere Einträge ersetzen ältere mit demselben Schlüssel.
public enum ConflictBackup {
    public static func save<T: Codable>(_ items: [String: T], to url: URL) throws {
        guard !items.isEmpty else { return }
        var all: [String: T] = [:]
        if let d = try? Data(contentsOf: url), let old = try? JSONDecoder().decode([String: T].self, from: d) { all = old }
        all.merge(items) { _, new in new }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: url, options: .atomic)
    }
}
