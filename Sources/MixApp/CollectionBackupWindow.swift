import AppKit
import SwiftUI
import MixCore

/// Wiederherstellen einer Collection-Sicherung. Ablauf: Prüfen (laufende Collection-Software, Inhalt der Sicherung),
/// bisheriger Stand wird gesichert, dann atomar ersetzt, danach lädt die Bibliothek neu.
@MainActor
enum CollectionRestore {
    /// Ergebnis für die Statuszeile und die Ende-zu-Ende-Steuerung
    struct Outcome: Equatable {
        let ok: Bool
        let message: String
        let tracks: Int?
    }

    /// Sicherung `backup` über die geladene Collection setzen. Prüfen, sichern und ersetzen laufen außerhalb des
    /// Hauptthreads (mit der Sperre der Collection); Ergebnis und Neuladen auf dem Hauptthread.
    /// `running`: prüft, ob die Collection-Software läuft
    static func run(_ backup: URL, store: LibraryStore, running: () -> Bool = LibraryStore.collectionSoftwareRunning) async -> Outcome {
        let collection = store.sourceURL ?? LibraryStore.defaultNML
        if running() {
            let msg = String(localized: "Wiederherstellen abgebrochen: die Collection-Software läuft. Erst beenden, dann wiederherstellen.")
            StatusCenter.post(.warning, msg, key: "backup.restore")
            return Outcome(ok: false, message: msg, tracks: nil)
        }
        StatusCenter.post(.info, String(localized: "Collection wird aus Sicherung wiederhergestellt …"), key: "backup.restore")
        let result = await Task.detached(priority: .utility) {
            Result { try CollectionBackups.restore(backup, over: collection) }
        }.value
        switch result {
        case let .success(r):
            store.load(collection)
            let msg = String(localized: "Collection aus Sicherung wiederhergestellt: \(r.tracks) Tracks")
            StatusCenter.post(.ok, msg, detail: r.previous.map { String(localized: "bisheriger Stand: \($0.lastPathComponent)") },
                              key: "backup.restore")
            return Outcome(ok: true, message: msg, tracks: r.tracks)
        case let .failure(error):
            let msg: String
            switch error as? CollectionBackups.Failure {
            case let .invalid(why)?: msg = String(localized: "Sicherung nicht wiederhergestellt: \(why)")
            case .previousNotBacked?: msg = String(localized: "Nicht wiederhergestellt: der bisherige Stand konnte nicht gesichert werden")
            case nil: msg = String(localized: "Nicht wiederhergestellt: \(String(describing: error))")
            }
            StatusCenter.post(.error, msg, key: "backup.restore")
            return Outcome(ok: false, message: msg, tracks: nil)
        }
    }
}

@MainActor
enum CollectionBackupWindow {
    static func show(store: LibraryStore) {
        let collection = store.sourceURL ?? LibraryStore.defaultNML
        BasicWindows.show("backups", title: "MINOS-741 Collection-Backup", size: NSSize(width: 640, height: 460)) {
            AnyView(CollectionBackupView(collection: collection) { url in
                _ = await CollectionRestore.run(url, store: store)
            })
        }
    }
}

/// Liste der Sicherungen (neueste zuerst): Datum, Größe, Trackzahl (erst beim Anzeigen gelesen)
struct CollectionBackupView: View {
    let collection: URL
    let restore: (URL) async -> Void
    @State private var entries: [CollectionBackups.Entry] = []
    @State private var selected: String?
    @State private var tracks: [String: Int] = [:]
    /// Wiederherstellen läuft (Hintergrund): Knopf gesperrt, Fortschritt sichtbar
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Collection-Backup").font(Theme.label(16)).textCase(.uppercase)
            Text(verbatim: CollectionBackups.folder(for: collection).lastPathComponent + " · " + String(localized: "neben der Collection"))
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            if entries.isEmpty {
                Text("Keine Sicherungen da. Sie entstehen beim Schreiben in die Collection (höchstens stündlich).")
                    .font(Theme.mono(12)).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { e in
                            HStack(spacing: 12) {
                                Text(verbatim: Self.dateText(e.date)).font(Theme.mono(11)).frame(width: 170, alignment: .leading)
                                Text(verbatim: Self.sizeText(e.bytes)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    .frame(width: 80, alignment: .trailing)
                                Text(tracks[e.id].map { String(localized: "\($0) Tracks") } ?? "…")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selected == e.id ? Theme.chitinRaised : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = e.id }
                            .task(id: e.id) {
                                guard tracks[e.id] == nil else { return }
                                let url = e.url
                                let n = await Task.detached(priority: .utility) { CollectionBackups.trackCount(url) }.value
                                tracks[e.id] = n ?? 0
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                }
                .background(Theme.chitin)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                DeckButton(title: "Wiederherstellen", active: true) {
                    guard let e = entries.first(where: { $0.id == selected }) else { return }
                    confirmAndRestore(e)
                }
                .disabled(selected == nil || busy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
        .onAppear { entries = CollectionBackups.list(in: CollectionBackups.folder(for: collection)) }
    }

    /// Rückfrage (nur im Programm; Selbsttest und Ende-zu-Ende lösen direkt aus)
    private func confirmAndRestore(_ e: CollectionBackups.Entry) {
        let a = NSAlert()
        a.messageText = String(localized: "Collection aus dieser Sicherung wiederherstellen?")
        a.informativeText = String(localized: "Der jetzige Stand der Collection wird vorher als neue Sicherung gesichert. Die Collection-Software darf nicht laufen.")
        a.addButton(withTitle: String(localized: "Wiederherstellen"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task { @MainActor in
            await restore(e.url)
            entries = CollectionBackups.list(in: CollectionBackups.folder(for: collection))
            busy = false
        }
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f.string(from: d)
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
