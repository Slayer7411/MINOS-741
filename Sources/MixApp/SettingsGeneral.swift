import SwiftUI
import AppKit
import MixCore
import MixEngine

/// ALLGEMEIN (erster Bereich): Einrichtung, Sprache und Zoom, Datenordner, Updates, Absturzberichte, LIVE, Start
struct GeneralSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Form {
            Section("Einrichtung") {
                LabeledContent("Einrichtungs-Ablauf") {
                    Button("Einrichtung …") { NotificationCenter.default.post(name: .showSetup, object: nil) }
                }
                .settingsAnchor("general.setup")
                Text("Zeigt die Einrichtung noch einmal: Sammlung, Ausgabegerät, Controller. Nichts wird gelöscht.").settingsHint()
            }
            Section("Sprache") {
                Picker("Sprache (wirkt nach Neustart)", selection: $mix.prefs.ui.language) {
                    Text("Systemstandard").tag("system")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "English").tag("en")
                }
                .settingsAnchor("display.language")
            }
            Section("Zoom") {
                Picker("Hauptfenster (⌘+ / ⌘− / ⌘0)", selection: Binding(get: { mix.prefs.ui.zoom }, set: { ZoomControl.set($0, mix: mix) })) {
                    ForEach(Set(ZoomSteps.levels + [mix.prefs.ui.zoom]).sorted(), id: \.self) { Text(verbatim: ZoomSteps.percent($0)).tag($0) }
                }
                .settingsAnchor("display.zoom")
            }
            Section("Daten") {
                LabeledContent("Datenordner") {
                    HStack(spacing: 8) {
                        Text(verbatim: (DataDir.shared.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([DataDir.shared]) }
                    }
                }
                .settingsAnchor("general.datafolder")
                LabeledContent("Einstellungsdatei") {
                    Text(verbatim: SettingsFile.url.lastPathComponent).font(Theme.mono(10)).foregroundStyle(.secondary)
                }
                .settingsAnchor("general.settingsfile")
                Text("Ordner MINOS-741 neben der Collection-Datei; zieht mit der Collection um.").settingsHint().help("Ordner MINOS-741 neben der Collection-Datei: settings.plist, Analysen, Edits, Cuts, Playlists, History. Zieht mit der Collection um.")
            }
            Section("Updates") {
                UpdateSettingsSection()
            }
            Section("Absturzberichte") {
                Toggle("Nach Absturz fragen", isOn: $mix.prefs.ui.askAfterCrash)
                    .settingsAnchor("cloud.crash.ask")
                Text("Nach Absturz: beim nächsten Start bereinigter Bericht. Gesendet wird nur, was du auslöst.")
                    .settingsHint()
                    .help("Beim nächsten Start zeigt MINOS-741 den bereinigten Bericht (ohne Pfade, Nutzer, Rechner, Geräte). Gesendet wird nur, was du in dem Fenster auslöst: GitHub-Issue im Browser oder Kopieren.")
                Toggle("Vollständige Berichte in Ordner ablegen", isOn: $mix.prefs.ui.crashReports)
                    .settingsAnchor("cloud.crash.on")
                HStack {
                    Text("Ordner")
                    Spacer()
                    Text(verbatim: mix.prefs.ui.crashReportFolder.isEmpty ? "—" : (mix.prefs.ui.crashReportFolder as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Ordner wählen …") { pickCrashFolder() }
                }
                .settingsAnchor("cloud.crash.folder")
                Text("Mit Ordner: jeder Bericht wird zusätzlich vollständig dort abgelegt. Nichts geht ins Netz.")
                    .settingsHint()
                    .help("Mit Ordner und eingeschalteter Option wird jeder neue Absturzbericht zusätzlich vollständig dort abgelegt (Bericht, Statusmeldungen, Einstellungen ohne Geräte-Kennungen). Nichts wird ins Netz geschickt.")
            }
            Section("LIVE") {
                Toggle("Lesbarkeit bei LIVE automatisch", isOn: $mix.prefs.ui.liveListAuto)
                    .settingsAnchor("browser.live.auto")
                Toggle("VST3 bei LIVE überbrücken", isOn: $mix.prefs.ui.liveBypassVST3)
                    .settingsAnchor("general.live.vst3")
                Text("Bei LIVE rechnen VST3-Plugins nicht mehr (Slot trocken): laufen im Prozess, ein Absturz risse MINOS-741 mit. Audio Units und eingebaute Effekte bleiben aktiv.")
                    .settingsHint()
            }
            Section("Start") {
                Toggle("Played-Status beim Start zurücksetzen", isOn: $mix.prefs.ui.resetPlayedOnStart)
                    .settingsAnchor("browser.resetplayed")
                Toggle("Beim Start prüfen", isOn: $mix.prefs.ui.checkOnStart)
                    .settingsAnchor("browser.checkonstart")
            }
        }
    }

    private func pickCrashFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Ordner für Absturzberichte")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        mix.prefs.ui.crashReportFolder = u.path
    }
}
