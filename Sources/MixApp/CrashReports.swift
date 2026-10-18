import AppKit
import Foundation
import MixCore
import SwiftUI

/// Absturzberichte von MINOS-741 (macOS-Berichte in `~/Library/Logs/DiagnosticReports`). Ablauf nach dem Start (im
/// Hintergrund, 20 s): neue Berichte suchen, dann
/// - beim nächsten Start nach einem Absturz fragen (Sheet mit dem bereinigten Bericht, `CrashRedact`), nichts wird gesendet,
/// - bei gewähltem Ordner und eingeschalteter Option den vollständigen Bericht dorthin schreiben (ohne Geräte-Kennungen).
/// Keine Netzverbindung. Das Statusprotokoll (`StatusLogFile`) liegt lokal im Datenordner.
enum CrashReports {
    /// Berichte, die gesammelt werden (Präfix des Dateinamens, Endung `.ips`)
    static let prefixes = ["MINOS-741", "minos741", "minos-files"]
    static let suffix = ".ips"
    /// nach dem Start: Verzögerung bis zur Suche
    static let scanDelay: TimeInterval = 20
    /// Statusmeldungen des letzten Laufs je Bericht
    static let statusLimit = 100
    /// erster Lauf (noch kein Zeitpunkt gemerkt): Berichte der letzten Tage, nicht die ganze Historie
    static let firstScanWindow: TimeInterval = 14 * 24 * 3600

    /// Ordner für die vollständigen Berichte; nil = aus (Option aus oder kein Ordner). Vom Hauptthread gesetzt
    nonisolated(unsafe) static var target: URL?

    /// nach jeder Änderung der Einstellungen (MixModel.prefs)
    static func configure(_ ui: UIPrefs) {
        target = !Session.isSelfTest && ui.crashReports && !ui.crashReportFolder.isEmpty
            ? URL(fileURLWithPath: ui.crashReportFolder, isDirectory: true) : nil
    }

    /// macOS-Ordner der Berichte; im Ende-zu-Ende-Lauf `<root>/diagnostic-reports`
    static var diagnosticsDir: URL {
        if let r = E2E.root { return r.appendingPathComponent("diagnostic-reports", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    // MARK: Auswahl

    /// Neue Berichte: Name passt (Präfix, `.ips`) und Zeitpunkt liegt nach `after`; älteste zuerst. Verglichen wird auf
    /// Millisekunden: `Date` rechnet intern ab 2001, der Umweg über Sekunden seit 1970 verschiebt die letzte Stelle
    static func newReports(_ files: [(name: String, date: Date)], after: Date) -> [(name: String, date: Date)] {
        let cut = millis(after)
        return files.filter { f in
            millis(f.date) > cut && f.name.hasSuffix(suffix) && prefixes.contains { f.name.hasPrefix($0) }
        }.sorted { $0.date < $1.date }
    }

    static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    static func listFiles(_ dir: URL, fm: FileManager = .default) -> [(name: String, date: Date)] {
        var files: [(name: String, date: Date)] = []
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path),
                  let d = a[.modificationDate] as? Date else { continue }
            files.append((n, d))
        }
        return files
    }

    // MARK: Dateiname

    /// `<jjjj-mm-tt_hhmmss>_<Rechner>_<Build>.txt`; Rechner und Build auf Buchstaben, Ziffern und Bindestrich gekürzt
    static func fileName(date: Date, computer: String, build: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(f.string(from: date))_\(sanitize(computer))_\(sanitize(build)).txt"
    }

    static func sanitize(_ s: String) -> String {
        var out = ""
        for c in s {
            if c.isASCII, c.isLetter || c.isNumber { out.append(c) } else if c == "-" || c == "." || c == " " { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "unbekannt" : out
    }

    // MARK: Einstellungen

    /// Einstellungs-Wörterbuch (Domäne der App) als JSON-Text, ohne Geräte-Kennungen; `prefs.v1` wird ausgepackt
    static func settingsJSON(_ domain: [String: Any]) -> String {
        var d = domain
        if let raw = d[AppPrefs.key] as? Data, let obj = try? JSONSerialization.jsonObject(with: raw) {
            d[AppPrefs.key] = obj
        }
        let clean = (CrashRedact.redactedSettings(d) as? [String: Any]) ?? [:]
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: Statusprotokoll

    /// Markierung am Start eines Laufs im Statusprotokoll
    static func runMarker(version: String, build: String, at date: Date = Date()) -> String {
        "=== Start \(version) (\(build)) \(StatusLogFile.stamp(date))"
    }

    /// Statusmeldungen vor dem letzten Start (= Lauf vor dem Absturz), ohne Markierungen
    static func previousRunTail(_ lines: [String], limit: Int = statusLimit) -> [String] {
        let isMarker: (String) -> Bool = { $0.hasPrefix("=== Start ") }
        guard let last = lines.lastIndex(where: isMarker) else { return Array(lines.suffix(limit)) }
        let before = lines[..<last].filter { !isMarker($0) }
        return Array(before.suffix(limit))
    }

    // MARK: Vollständiger Bericht (Ordner)

    struct Context {
        var appVersion: String
        var build: String
        var computer: String
        var macOS: String
        var copiedAt: Date
    }

    /// Textdatei eines vollständigen Berichts: Kopf, der .ips-Text unverändert, Statusmeldungen, Einstellungen
    static func report(ips: String, ipsName: String, reportDate: Date, status: [String], settings: String, context c: Context) -> String {
        let iso = ISO8601DateFormatter()
        var out = """
        MINOS-741 crash report
        app:       \(c.appVersion) (build \(c.build))
        computer:  \(c.computer)
        macOS:     \(c.macOS)
        report:    \(ipsName) (\(iso.string(from: reportDate)))
        copied:    \(iso.string(from: c.copiedAt))

        ===== ips =====

        """
        out += ips
        if !ips.hasSuffix("\n") { out += "\n" }
        out += "\n===== status (last \(status.count) messages of the previous run) =====\n"
        out += status.joined(separator: "\n")
        out += "\n\n===== settings (no device ids) =====\n"
        out += settings
        out += "\n"
        return out
    }

    /// Schreibt die Berichte in den Ordner: erst `.part`, dann umbenannt. Gibt die geschriebenen Dateien zurück
    /// (Namen, die schon existieren, bekommen `-2`, `-3` …)
    @discardableResult
    static func write(_ reports: [(url: URL, date: Date)], into folder: URL, status: [String], settings: String,
                      context: Context, fm: FileManager = .default) throws -> [URL] {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for r in reports {
            let ips = (try? String(contentsOf: r.url, encoding: .utf8)) ?? ""
            let text = report(ips: ips, ipsName: r.url.lastPathComponent, reportDate: r.date, status: status,
                              settings: settings, context: context)
            let base = String(fileName(date: r.date, computer: context.computer, build: context.build).dropLast(4))
            var dst = folder.appendingPathComponent(base + ".txt")
            var n = 2
            while fm.fileExists(atPath: dst.path) { dst = folder.appendingPathComponent("\(base)-\(n).txt"); n += 1 }
            let part = dst.appendingPathExtension("part")
            try Data(text.utf8).write(to: part, options: .atomic)
            try fm.moveItem(at: part, to: dst)
            written.append(dst)
        }
        return written
    }

    // MARK: Ablauf

    /// Ergebnis einer Suche: neuester kopierter Zeitpunkt, und ggf. die Anzeige für das Sheet
    struct ScanOutput {
        var copiedNewest: Date?
        var prompt: Prompt?
    }

    struct Prompt {
        var fileName: String
        var title: String
        var text: String
        var count: Int
        var newest: Date
    }

    /// Suche und Verarbeitung (Hintergrund). `copyAfter` / `promptAfter`: Zeitpunkte des zuletzt kopierten bzw. gezeigten Berichts
    static func scan(now: Date = Date(), reportsDir: URL, folder: URL?, copyAfter: Date?, promptAfter: Date?, askPrompt: Bool,
                     status: [String], settings: String, context: Context, names: CrashRedact.Names,
                     fm: FileManager = .default) -> ScanOutput {
        let files = listFiles(reportsDir, fm: fm)
        let window = now.addingTimeInterval(-firstScanWindow)
        var out = ScanOutput()
        if let folder {
            let fresh = newReports(files, after: copyAfter ?? window)
            if !fresh.isEmpty {
                let reports = fresh.map { (url: reportsDir.appendingPathComponent($0.name), date: $0.date) }
                do {
                    try write(reports, into: folder, status: status, settings: settings, context: context, fm: fm)
                    out.copiedNewest = fresh.last?.date
                } catch {
                    print("[absturz] Ordner nicht beschreibbar: \(folder.path) · \(error.localizedDescription)")
                }
            }
        }
        let fresh = newReports(files, after: promptAfter ?? window)
        if askPrompt, let last = fresh.last {
            let ips = (try? String(contentsOf: reportsDir.appendingPathComponent(last.name), encoding: .utf8)) ?? ""
            let text = CrashRedact.publicReport(ips: ips, status: status, names: names)
                ?? "MINOS-741 crash report (format not readable)\n"
            out.prompt = Prompt(fileName: last.name, title: CrashRedact.issueTitle(ips: ips, names: names),
                                text: text, count: fresh.count, newest: last.date)
        }
        return out
    }

    /// Start: nach `scanDelay` suchen. Ohne Ordner und mit ausgeschalteter Frage geschieht nichts.
    @MainActor
    static func scheduleScan(prefs ui: UIPrefs, mix: MixModel) {
        guard !Session.isSelfTest else { return }
        let folder = target
        let askPrompt = ui.askAfterCrash
        guard folder != nil || askPrompt else { return }
        let copyAfter = ui.crashLastCopied > 0 ? Date(timeIntervalSince1970: ui.crashLastCopied) : nil
        let promptAfter = ui.crashLastPrompted > 0 ? Date(timeIntervalSince1970: ui.crashLastPrompted) : nil
        let domainID = E2E.isActive ? E2E.suite : Bundle.main.bundleIdentifier
        let domain = domainID.flatMap { E2E.defaults.persistentDomain(forName: $0) } ?? [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + scanDelay) { [weak mix] in
            guard let mix else { return }
            DispatchQueue.global(qos: .utility).async {
                let status = (try? String(contentsOf: StatusLogFile.url, encoding: .utf8))
                    .map { previousRunTail($0.components(separatedBy: "\n")) } ?? []
                let context = Context(appVersion: appVersion, build: buildNumber, computer: CrashRedact.Names.current.computer,
                                      macOS: ProcessInfo.processInfo.operatingSystemVersionString, copiedAt: Date())
                let out = scan(reportsDir: diagnosticsDir, folder: folder, copyAfter: copyAfter, promptAfter: promptAfter,
                               askPrompt: askPrompt, status: status, settings: settingsJSON(domain), context: context,
                               names: .current)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let c = out.copiedNewest { mix.prefs.ui.crashLastCopied = c.timeIntervalSince1970 }
                        if let p = out.prompt { CrashPrompt.shared.present(p, mix: mix) }
                    }
                }
            }
        }
    }

    static var appVersion: String { bundleValue("CFBundleShortVersionString") }
    static var buildNumber: String { bundleValue("CFBundleVersion") }

    private static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "?"
    }
}

/// Statusprotokoll `DataDir.local/status-log.txt`: die letzten Zeilen, je Lauf eine Markierung. Lokal, nie gesendet;
/// schreibt im Hintergrund, verzögert gesammelt. Grundlage der Statuszeilen im Absturzbericht.
final class StatusLogFile: @unchecked Sendable {
    static let shared = StatusLogFile()
    static let limit = 500

    static var url: URL { DataDir.local.appendingPathComponent("status-log.txt") }

    private let queue = DispatchQueue(label: "minos741.status-log", qos: .utility)
    private var lines: [String]?   // nur auf `queue`
    private var flushPending = false

    /// Eine Meldung anhängen (von jedem Thread; im Selbsttest nichts)
    func append(_ line: String) {
        guard !Session.isSelfTest else { return }
        queue.async { [self] in
            ensureLoaded()
            lines?.append(line)
            scheduleFlush()
        }
    }

    /// Start eines Laufs: Markierung
    func beginRun(marker: String) {
        guard !Session.isSelfTest else { return }
        queue.async { [self] in
            ensureLoaded()
            lines?.append(marker)
            scheduleFlush()
        }
    }

    /// einmal angelegt: jede Statusmeldung läuft über den Hauptthread, ein neuer DateFormatter kostet dort merklich
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private func ensureLoaded() {
        guard lines == nil else { return }
        let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            flushPending = false
            flush()
        }
    }

    /// letzte `limit` Zeilen, atomar; Markierungen zählen mit
    private func flush() {
        guard var l = lines else { return }
        if l.count > Self.limit { l.removeFirst(l.count - Self.limit); lines = l }
        let text = l.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: Self.url, options: .atomic)
        } catch {
            print("[absturz] Statusprotokoll nicht schreibbar: \(error.localizedDescription)")
        }
    }
}

/// Das Sheet nach einem Absturz: bereinigter Bericht, Senden als GitHub-Issue (Browser, nichts automatisch), Kopieren,
/// Verwerfen, „Nicht mehr fragen“
@MainActor @Observable
final class CrashPrompt {
    static let shared = CrashPrompt()

    var shown = false
    private(set) var item: CrashReports.Prompt?
    @ObservationIgnored private weak var mix: MixModel?

    /// Sheet sichtbar? In Ende-zu-Ende-Läufen nie (die Zustände bleiben über die Steuerung lesbar)
    var sheetShown: Bool { shown && !E2E.isActive }

    func present(_ p: CrashReports.Prompt, mix: MixModel?) {
        self.mix = mix
        item = p
        shown = true
    }

    /// Schließen (auch Verwerfen): dieser Bericht gilt als gezeigt
    func close() {
        shown = false
        if let p = item { mix?.prefs.ui.crashLastPrompted = p.newest.timeIntervalSince1970 }
        item = nil
    }

    /// Bereinigten Bericht in die Zwischenablage
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Browser öffnet das neue Issue mit dem Text; ist er zu lang, steht der volle Text in der Zwischenablage
    func openIssue() {
        guard let p = item else { return }
        let intro = "What were you doing when it crashed?\n\n"
        let r = CrashRedact.issueURL(title: p.title, body: intro + p.text)
        if r.truncated { copy(p.text) }
        CrashLinks.open(r.url)
        close()
    }

    /// Schalter „Nicht mehr fragen“
    var dontAsk: Bool {
        get { !(mix?.prefs.ui.askAfterCrash ?? true) }
        set { mix?.prefs.ui.askAfterCrash = !newValue }
    }
}

/// Öffnen von Adressen aus dem Absturzfenster. Im Selbsttest und im Ende-zu-Ende-Lauf wird die Adresse nur gemerkt
/// (Steuerung: `crash-state`), nie im Browser geöffnet.
enum CrashLinks {
    nonisolated(unsafe) static var recorded: [String] = []
    nonisolated(unsafe) static var opener: (URL) -> Void = { url in
        if Session.isSelfTest || E2E.isActive { recorded.append(url.absoluteString) } else { NSWorkspace.shared.open(url) }
    }

    static func open(_ url: URL) { opener(url) }
}

struct CrashPromptView: View {
    private var prompt: CrashPrompt { CrashPrompt.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12.z) {
            Text("MINOS-741 ist abgestürzt. Bericht ansehen?").font(Theme.label(15.z)).textCase(.uppercase)
            if let p = prompt.item {
                Text(p.count > 1 ? "\(p.count) neue Berichte, gezeigt wird der neueste. Bereinigt: ohne Pfade, Nutzer, Rechner und Geräte. Nichts wird automatisch gesendet."
                     : "Bereinigt: ohne Pfade, Nutzer, Rechner und Geräte. Nichts wird automatisch gesendet.")
                    .font(Theme.mono(11.z)).foregroundStyle(Theme.bone.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(verbatim: p.text)
                        .font(Theme.mono(10.z))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8.z)
                }
                .frame(height: 260.z)
                .background(Theme.chitin)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            HStack(spacing: 8.z) {
                flatButton("Als GitHub-Issue senden", primary: true) { prompt.openIssue() }.keyboardShortcut(.defaultAction)
                flatButton("Kopieren") { if let t = prompt.item?.text { prompt.copy(t) } }
                Spacer()
                flatButton("Verwerfen") { prompt.close() }.keyboardShortcut(.cancelAction)
            }
            Toggle("Nicht mehr fragen", isOn: Binding(get: { prompt.dontAsk }, set: { prompt.dontAsk = $0 }))
                .toggleStyle(FlatToggleStyle())
        }
        .padding(18.z)
        .frame(width: 560.z)
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }

    /// Flacher 741-Schalter wie DeckButton (Versalien, Haarlinie); `primary` = rot gefüllt
    private func flatButton(_ title: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        DeckButton(title: title, active: primary, action: action).textCase(.uppercase)
    }
}

/// Kästchen mit Beschriftung daneben (Haarlinie, an = rot gefüllt), wie SettingsToggleStyle ohne feste Spalte
private struct FlatToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8.z) {
            ZStack {
                Rectangle().fill(Theme.void)
                Rectangle().stroke(configuration.isOn ? Theme.state : Theme.muted, lineWidth: 1)
                if configuration.isOn { Rectangle().fill(Theme.state).padding(3.z) }
            }
            .frame(width: 14.z, height: 14.z)
            configuration.label
                .font(Theme.mono(11.z)).foregroundStyle(Theme.bone)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
    }
}
