import AppKit
import SwiftUI
import MixCore

/// → TIDAL im Kopf des Bereichs MISSING: fehlende Tracks als Playlist bei TIDAL, gesperrt ohne Client-ID
struct TidalMissingButton: View {
    @Environment(MixModel.self) private var decks
    @Environment(LibraryStore.self) private var store
    @Bindable private var sync = TidalSyncModel.shared

    var body: some View {
        let ui = decks.prefs.ui
        let hasID = !ui.tidalClientID.trimmingCharacters(in: .whitespaces).isEmpty
        let count = store.missingTracks.count
        HStack(spacing: 4.z) {
            DeckButton(title: sync.running ? "TIDAL …" : "→ TIDAL", active: sync.running) {
                TidalSyncModel.shared.start(tracks: store.missingTracks, clientID: ui.tidalClientID,
                                            pattern: ui.tidalPlaylistPattern)
            }
            .disabled(!hasID || sync.running || count == 0)
            .help(hasID
                  ? "Fehlende Tracks als Playlist \(TidalMatch.playlistName(pattern: ui.tidalPlaylistPattern)) bei TIDAL anlegen (Suche nach Artist und Titel), nicht gefundene in einer Liste"
                  : "Client-ID unter ⌘, → Browser eintragen")
            if !sync.unmatched.isEmpty {
                DeckButton(title: "NICHT GEFUNDEN \(sync.unmatched.count)") { sync.showUnmatched = true }
                    .help("Tracks ohne Treffer bei TIDAL: Artist – Titel, zum Kopieren")
            }
        }
        .sheet(isPresented: $sync.showUnmatched) { TidalUnmatchedSheet(tracks: sync.unmatched) }
    }
}

/// Blatt „Nicht gefunden“: Artist – Titel, Kopieren in die Zwischenablage
struct TidalUnmatchedSheet: View {
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        tracks.map { t in
            let a = t.artist.trimmingCharacters(in: .whitespaces), ti = t.title.trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? ti : ti.isEmpty ? a : "\(a) – \(ti)"
        }
        .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIDAL: ohne Treffer (\(tracks.count))").font(Theme.label(12, .bold))
            ScrollView {
                Text(text)
                    .font(Theme.mono(11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                DeckButton(title: "Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                DeckButton(title: "Schließen", active: true) { dismiss() }
            }
        }
        .padding(12)
        .frame(width: 460, height: 380)
        .background(Theme.chitin)
    }
}

/// ⌘, → BROWSER → TIDAL: Client-ID der eigenen App, Playlist-Muster, Abmelden
struct TidalSettingsSection: View {
    static let hint = "developer.tidal.com: app anlegen, redirect-uri http://localhost:7412/tidal/callback, scopes user.read playlists.read playlists.write search.read. client-id hier eintragen, ohne client-secret. ANMELDEN öffnet den browser (oder beim ersten → TIDAL im kopf von MISSING)."
    @Environment(MixModel.self) private var mix
    @State private var signedIn = TidalAuth.signedIn
    @State private var signing: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        @Bindable var mix = mix
        Section("TIDAL") {
            TextField("Client-ID", text: $mix.prefs.ui.tidalClientID)
                .settingsAnchor("browser.tidal.clientid")
            TextField("Playlist-Name", text: $mix.prefs.ui.tidalPlaylistPattern)
                .settingsAnchor("browser.tidal.pattern")
            HStack {
                Text(signing != nil ? "Anmeldung im Browser …" : signedIn ? "angemeldet" : "nicht angemeldet")
                    .font(Theme.mono(11)).foregroundStyle(signedIn ? Theme.bone : Theme.muted)
                Spacer()
                if signing != nil {
                    Button("Abbrechen") { signing?.cancel(); signing = nil }
                } else {
                    // Anmeldung ohne Playlist-Lauf: Browser öffnen, Rücksprung abwarten, Tokens in den Schlüsselbund
                    Button("Anmelden") {
                        error = nil
                        let id = mix.prefs.ui.tidalClientID
                        signing = Task { @MainActor in
                            do { _ = try await TidalAuth.signIn(clientID: id) } catch {
                                if !(error is CancellationError) { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
                            }
                            signedIn = TidalAuth.signedIn
                            signing = nil
                        }
                    }
                    .disabled(mix.prefs.ui.tidalClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    .settingsAnchor("browser.tidal.signin")
                }
                Button("Abmelden") {
                    TidalAuth.signOut()
                    signedIn = TidalAuth.signedIn
                }
                .disabled(!signedIn)
                .settingsAnchor("browser.tidal.signout")
            }
            if let error { Text(error).font(Theme.mono(10)).foregroundStyle(Theme.state) }
            Text(TidalSettingsSection.hint).settingsHint()
        }
    }
}
