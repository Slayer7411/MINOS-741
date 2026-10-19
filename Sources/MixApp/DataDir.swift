import AppKit
import Foundation
import MixCore

/// Daten einer Session im Ordner `MINOS-741` neben der Collection-Datei: Einstellungen (`settings.plist`), Analysen,
/// Edits, Cuts, Playlists, History, Preparation, Sitzung. Zieht mit der Collection um – dieselbe Collection samt Ordner
/// ergibt auf jedem Mac dieselbe Session. Zwischenspeicher und Rechner-Gebundenes bleiben in Application Support.
enum DataDir {
    static let local = E2E.applicationSupport.appendingPathComponent("MINOS-741")
    /// bleibt lokal: Wellenform-Cache, Vorschauen, Lasttests (Daten, keine Einstellungen; baut jeder Mac selbst)
    static let localOnly: Set<String> = ["cache", "overviews", "loadtest", ".DS_Store"]
    static let name = "MINOS-741"

    /// beim ersten Zugriff festgelegt (Start): Ordner neben der Collection, beim ersten Mal aus Application Support befüllt.
    /// Selbsttest und fehlende/schreibgeschützte Collection-Ordner: Application Support
    static let shared: URL = resolve(collection: LibraryStore.defaultNML, local: local, selfTest: Session.isSelfTest)

    static func resolve(collection: URL, local: URL, selfTest: Bool) -> URL {
        guard !selfTest else { return local }
        let fm = FileManager.default
        let parent = collection.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { return local }
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        let existed = fm.fileExists(atPath: dir.path)
        do {
            if !existed { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            // was im Ordner fehlt, aus Application Support (erster Start; später dazugekommene Dateien wie plugins.json)
            for item in (try? fm.contentsOfDirectory(atPath: local.path)) ?? [] where !localOnly.contains(item) {
                let to = dir.appendingPathComponent(item)
                if !fm.fileExists(atPath: to.path) { try fm.copyItem(at: local.appendingPathComponent(item), to: to) }
            }
            return dir
        } catch {
            if !existed { try? fm.removeItem(at: dir) }
            return existed ? dir : local
        }
    }
}

/// Einstellungen als Datei im Datenordner (`settings.plist`): alles – Fenster, Teiler, Spalten, Ansicht, FX, Controller,
/// Tasten. Geschrieben beim Start, nach jeder Änderung und beim Beenden; beim Start übernommen, wenn die Datei seit dem
/// letzten Mal geändert wurde (anderer Mac, zurückgespielt). Auf dem Mac bleiben nur die Audio-Geräte-Einstellungen
/// (Interface, Rate, Puffer, Kanalpaare, Mixer-Modus, Aufnahme-Eingang), der Zwei-Mac-Modus, die gewählte Collection
/// und der Ordner der Absturzberichte
enum SettingsFile {
    static var url: URL { DataDir.shared.appendingPathComponent("settings.plist") }
    static let stampKey = "settings.imported"
    /// Audio-Gerät: eigene Schlüssel (MixModel.saveSetup)
    static let localKeys: Set<String> = ["deviceUID", "sampleRate", "bufferSize", "internalPair", "deckPairs", "previewPair",
                                         "mixerMode", "parallelDecks", stampKey]
    /// in `prefs.v1`: Zwei-Mac-Modus, Aufnahme-Eingang
    static let localPrefs: [[String]] = [["ui", "pair"], ["record", "inputUID"], ["record", "inputFirstChannel"],
                                         ["ui", "collectionPath"], ["ui", "crashReportFolder"], ["ui", "crashLastCopied"],
                                         ["ui", "crashLastPrompted"]]

    /// wird beim Übernehmen geschrieben (alles außer dem Audio-Gerät)
    static func shared(_ key: String) -> Bool { !localKeys.contains(key) }

    /// `prefs.v1` aus der Datei, die eigenen Werte aus `localPrefs` bleiben
    static func keepingLocal(_ incoming: Data, local: Data?) -> Data {
        guard var inc = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any] else { return incoming }
        let own = local.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        for path in localPrefs where path.count == 2 {
            var group = inc[path[0]] as? [String: Any] ?? [:]
            if let v = (own?[path[0]] as? [String: Any])?[path[1]] { group[path[1]] = v } else { group.removeValue(forKey: path[1]) }
            inc[path[0]] = group
        }
        return (try? JSONSerialization.data(withJSONObject: inc)) ?? incoming
    }

    static func stamp(_ u: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let d = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        return "\(Int(d.timeIntervalSince1970 * 1000))-\(s)"
    }

    /// Start, vor dem ersten Lesen der Einstellungen
    static func importIfChanged(_ d: UserDefaults = E2E.defaults) {
        guard !Session.isSelfTest, let s = stamp(url), d.string(forKey: stampKey) != s,
              let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        for (k, v) in dict where shared(k) {
            if k == AppPrefs.key, let p = v as? Data { d.set(keepingLocal(p, local: d.data(forKey: k)), forKey: k) } else { d.set(v, forKey: k) }
        }
        d.set(s, forKey: stampKey)
    }

    /// Serielle Warteschlange für Serialisieren, Vergleich und Schreiben (lief bei jeder Änderung auf dem Hauptthread)
    private static let ioQueue = DispatchQueue(label: "minos741.settings-export", qos: .utility)

    /// alle geteilten Werte in die Datei (atomar). Auf dem Hauptthread nur die Kopie der Einstellungen; Serialisieren,
    /// Vergleich und Schreiben im Hintergrund. `sync`: beim Beenden, dann ist die Datei fertig, wenn es zurückkommt
    static func export(_ d: UserDefaults = E2E.defaults, sync: Bool = false) {
        guard !Session.isSelfTest, let id = E2E.isActive ? E2E.suite : Bundle.main.bundleIdentifier,
              let dict = d.persistentDomain(forName: id) else { return }
        // alles in die Datei (auch das Audio-Gerät, zum Nachsehen); beim Übernehmen bleibt es lokal
        let box = DomainBox(dict: dict.filter { $0.key != stampKey })
        let target = url
        let write: @Sendable () -> String? = {
            let out = box.dict
            guard !out.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: out, format: .binary, options: 0) else { return nil }
            // unverändert: nicht schreiben (Drive, Zeitstempel)
            if let old = try? Data(contentsOf: target), old == data { return nil }
            guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
            return stamp(target)
        }
        if sync {
            if let s = ioQueue.sync(execute: write) { d.set(s, forKey: stampKey) }
        } else {
            ioQueue.async {
                guard let s = write() else { return }
                DispatchQueue.main.async { d.set(s, forKey: stampKey) }
            }
        }
    }

    /// Kopie der Einstellungen für die Warteschlange (Wert nur dort gelesen, nie geändert)
    private struct DomainBox: @unchecked Sendable { let dict: [String: Any] }

    nonisolated(unsafe) private static var pending: DispatchWorkItem?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var quitObserver: NSObjectProtocol?

    /// nach einer Änderung: gesammelt nach 2 s
    static func scheduleExport() {
        DispatchQueue.main.async {
            pending?.cancel()
            let w = DispatchWorkItem { export() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        }
    }

    /// Start: gleich schreiben, danach jede Änderung (auch Fenster, Spalten, Audio) gesammelt
    static func watch() {
        guard !Session.isSelfTest, observer == nil else { return }
        scheduleExport()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            scheduleExport()
        }
        // Beenden: sofort schreiben (auch wenn der Weg über AppDelegate.onQuit nicht läuft)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { TrackTableController.flushAll() }   // offene Spaltenanordnung vor dem Export
            E2E.defaults.synchronize()
            export(sync: true)
        }
    }
}
