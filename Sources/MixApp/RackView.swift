import AppKit
import SwiftUI
import MixEngine

// Insert-Slots einer FX-Unit oder des Master-Busses (b = MixController.masterBus): kompakte Slot-Zeilen in der Leiste,
// das ganze Rack als Popover, Effekt-Auswahl mit Suche, Parameter eines eingebauten Effekts.

/// Titel einer Unit ("FX 1", "MASTER")
func busTitle(_ b: Int) -> String { b == MixController.masterBus ? "MASTER" : "FX \(b + 1)" }

/// Effekt-Auswahl: Suche, EINGEBAUT, PLUGINS nach Hersteller (Apple zuerst, VST3 mit kleinem `VST3`), gesperrte mit Grund.
/// `replacing` = Slot, der den Effekt wechselt; nil = neuer Slot hinten
struct EffectPicker: View {
    @Environment(MixModel.self) private var mix
    @Environment(\.openSettings) private var openSettings
    let b: Int
    var replacing: Int?
    /// Suchtext beim Öffnen (Bilder, Tests)
    var query = ""
    var done: () -> Void = {}
    @State private var search = ""
    @State private var choices: [PluginCatalog.Choice] = []

    var body: some View {
        let slots = mix.slots(b)
        let words = search.lowercased().split(separator: " ").map(String.init)
        let match = { (s: String) in words.allSatisfy { s.lowercased().contains($0) } }
        let builtins = FXUnitState.Effect.builtins.filter { match($0.name) }
        let plugins = choices.filter { match("\($0.info.name) \($0.info.manufacturer) \($0.info.isVST3 ? "vst3" : "")") }
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "◆ " + busTitle(b) + " · " + (replacing.map { "SLOT \($0 + 1)" } ?? "+ SLOT"))
                .font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
            TextField("SUCHEN", text: $search)
                .textFieldStyle(.plain).font(Theme.mono(11))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.void).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !builtins.isEmpty { header("EINGEBAUT") }
                    ForEach(builtins, id: \.self) { e in builtinRow(e, slots) }
                    ForEach(Self.byMaker(plugins), id: \.0) { maker, list in
                        header(LocalizedStringKey(maker))
                        ForEach(list) { c in pluginRow(c) }
                    }
                    if builtins.isEmpty && plugins.isEmpty {
                        Text("nichts gefunden").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                Text("je eingebautem effekt ein slot je unit").font(Theme.mono(9)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Neu einlesen") { choices = mix.pluginChoices(refresh: true) }
                    .buttonStyle(.plain).font(Theme.label(9, .bold)).foregroundStyle(Theme.bone)
                    .help("Plugin-Liste neu einlesen (neu installierte Plugins)")
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(Theme.chitin)
        .onAppear { choices = mix.pluginChoices(); if !query.isEmpty { search = query } }
    }

    private func header(_ t: LocalizedStringKey) -> some View {
        Text(t).font(Theme.label(9, .heavy)).foregroundStyle(Theme.muted).padding(.top, 5).padding(.bottom, 1)
    }

    /// Hersteller-Gruppen: Apple zuerst, dann nach Name
    static func byMaker(_ list: [PluginCatalog.Choice]) -> [(String, [PluginCatalog.Choice])] {
        var order: [String] = [], by: [String: [PluginCatalog.Choice]] = [:]
        for c in list {
            let m = c.info.manufacturer.isEmpty ? "—" : c.info.manufacturer
            if by[m] == nil { order.append(m) }
            by[m, default: []].append(c)
        }
        order.sort { a, b in
            let aa = by[a]?.first?.info.isApple == true, bb = by[b]?.first?.info.isApple == true
            return aa != bb ? aa : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return order.map { ($0, (by[$0] ?? []).sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }) }
    }

    private func pick(_ id: String) {
        if let k = replacing { mix.replaceSlot(b, slot: k, id) } else { mix.addSlot(b, id) }
        done()
    }

    @ViewBuilder private func builtinRow(_ e: FXUnitState.Effect, _ slots: [FXSlot]) -> some View {
        let at = slots.firstIndex { $0.effect == e }
        let blocked = replacing == nil && at != nil
        Button { pick(e.name) } label: {
            HStack(spacing: 6) {
                Text(verbatim: e.name).font(Theme.label(10, .bold))
                    .foregroundStyle(blocked ? Theme.muted : (at == replacing && at != nil ? Theme.secondary : Theme.bone))
                Spacer(minLength: 4)
                if let at {
                    Text(verbatim: "SLOT \(at + 1)").font(Theme.mono(9)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 2).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .background(UITestMark(name: "pick \(e.name)"))
        .help(at == nil ? Text(verbatim: e.name)
              : replacing == nil ? Text("schon in Slot \(at! + 1) – je Effekt ein Slot je Unit")
              : Text("tauscht mit Slot \(at! + 1)"))
    }

    @ViewBuilder private func pluginRow(_ c: PluginCatalog.Choice) -> some View {
        let locked = c.lock != nil
        HStack(spacing: 6) {
            Button { if !locked { pick(c.info.id) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(verbatim: c.info.name).font(Theme.mono(10, .medium)).foregroundStyle(locked ? Theme.muted : Theme.bone).lineLimit(1)
                        if c.info.isVST3 { Text(verbatim: "VST3").font(Theme.mono(7, .bold)).foregroundStyle(Theme.muted) }
                    }
                    if let why = c.lock ?? c.note {
                        Text(verbatim: why).font(Theme.mono(8)).foregroundStyle(locked ? Theme.state.opacity(0.8) : Theme.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .background(UITestMark(name: "pick \(c.info.id)"))
            if c.fixInSettings {
                Button("⌘, PLUGINS") {
                    mix.settingsRequest = "PLUGINS"
                    done()
                    openSettings()
                }
                .buttonStyle(.plain).font(Theme.label(8, .bold)).foregroundStyle(Theme.bone)
                .help("Einstellungen → PLUGINS: „Plugins im Prozess (riskant)“")
            }
        }
        .help(Text(verbatim: "\(c.info.name) · \(c.info.manufacturer) · \(c.info.format.rawValue)"))
    }
}

/// Parameter eines eingebauten Effekts im Slot: Anteil und seine Regler/Schalter, Wert mit Einheit
struct SlotParamsView: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    let k: Int

    var body: some View {
        let slots = mix.slots(b)
        if slots.indices.contains(k), let e = slots[k].effect {
            let s = slots[k]
            let params = FXCatalog.builtinParams(e).filter { $0.id != "on" }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "◆ " + busTitle(b) + " · \(k + 1) " + e.name).font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 4), alignment: .leading, spacing: 8) {
                    ForEach(params) { p in cell(p, s) }
                }
                if e == .filter || e == .delay {
                    Text("ohne eigenen wert: resonanz bzw. feedback aus ⌘, → mixer & fx").font(Theme.mono(8)).foregroundStyle(Theme.muted)
                }
            }
            .padding(10)
            .background(Theme.chitin)
        } else {
            Text("Slot leer").font(Theme.mono(10)).foregroundStyle(Theme.muted).padding(10).background(Theme.chitin)
        }
    }

    @ViewBuilder private func cell(_ p: FXParam, _ s: FXSlot) -> some View {
        let v = p.id == "mix" ? s.mix : FXCatalog.param(s, p.id, prefs: mix.prefs.engine)
        VStack(spacing: 2) {
            if p.isSwitch {
                DeckButton(title: p.short, active: v >= 0.5, color: Theme.state, width: 40, verbatim: true) {
                    mix.setSlotParam(b, slot: k, p.id, v >= 0.5 ? 0 : 1)
                }
            } else {
                Knob(value: Binding(get: { v }, set: { x in
                    if p.id == "mix" { mix.setSlotMix(b, slot: k, x) } else { mix.setSlotParam(b, slot: k, p.id, x) }
                }), range: 0...1, defaultValue: p.defaultValue, bipolar: p.bipolar, color: Theme.state, size: 24)
            }
            Text(verbatim: p.short).font(Theme.label(8, .semibold)).foregroundStyle(Theme.muted)
            Text(verbatim: p.text(v)).font(Theme.mono(8)).foregroundStyle(Theme.bone).lineLimit(1)
        }
        .help(fxParamName(p))
    }
}

/// EDIT eines Plugin-Slots: Plugin-Fenster öffnen (ein offenes wird nach vorn geholt, wie die übrigen Fenster).
/// Gesperrt, solange das Plugin lädt oder nicht geladen ist (dann mit Grund als Hilfe)
struct PluginEditButton: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    let k: Int
    var compact = false
    var width: CGFloat? = nil

    var body: some View {
        let ready = mix.slotReady(b, k)
        let err = mix.pluginError(b)   // liest den Fehlerstand mit, damit die Hilfe nach dem Laden neu kommt
        let loading = mix.core.slotLoading(b, slot: k).loading
        DeckButton(title: "EDIT", width: width, compact: compact) { PluginWindow.show(unit: b, slot: k, core: mix.core) }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.4)
            .help(Text(verbatim: ready ? String(localized: "Plugin-Fenster öffnen")
                       : loading ? String(localized: "Plugin lädt noch")
                       : err.map { String(localized: "Plugin nicht geladen · \($0)") } ?? String(localized: "Plugin nicht geladen")))
            .background(UITestMark(name: "fx edit \(b) \(k)"))
    }
}

/// das ganze Rack (Popover): je Slot an/aus, Effekt (Klick = anderer), D/W, ▲▼, EDIT, ✕; + SLOT, Vorlagen, gemerkte Racks
struct RackView: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    @State private var picker: Int?   // Slot, dessen Effekt gewählt wird; -1 = neuer Slot
    @State private var params: Int?

    private var isMaster: Bool { b == MixController.masterBus }

    var body: some View {
        let slots = mix.slots(b)
        let error = mix.pluginError(b)
        let latency = mix.core.rackLatency(b)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: "◆ " + busTitle(b) + " · ").font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
                    + Text("RACK").font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
                Spacer()
                if latency.total > 0 {
                    Text(verbatim: String(format: "%.1f ms", latency.total * 1000))
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .help("Latenz der Plugins (Summe, nicht ausgeglichen)")
                }
            }
            if slots.isEmpty {
                Text("leer – durchgereicht").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(slots.enumerated()), id: \.element.uid) { k, slot in
                row(k, slot, slots.count, latency.slots.indices.contains(k) ? latency.slots[k] : nil)
            }
            HStack(spacing: 8) {
                Button { picker = -1 } label: { Text("+ SLOT") }
                    .buttonStyle(.plain).font(Theme.label(10, .bold)).foregroundStyle(Theme.bone)
                    .disabled(slots.count >= MixEngine.slotCount)
                    .opacity(slots.count >= MixEngine.slotCount ? 0.4 : 1)
                    .help("Effekt hinten anhängen (höchstens \(MixEngine.slotCount))")
                    .popover(isPresented: Binding(get: { picker == -1 }, set: { if !$0 { picker = nil } }), arrowEdge: .bottom) {
                        EffectPicker(b: b, replacing: nil) { picker = nil }.environment(mix)
                    }
                if !isMaster {
                    Menu {
                        ForEach(FXTemplate.all, id: \.name) { t in Button(t.name) { mix.applyTemplate(b, t) } }
                    } label: { Text("VORLAGEN") }
                    .menuStyle(.borderlessButton).fixedSize().font(Theme.label(10, .bold)).tint(Theme.bone)
                    .help("Slots durch eine Vorlage ersetzen: Gruppe FLT·DLY·REV oder ein eingebauter Effekt")
                }
                Menu {
                    let names = mix.rackNames
                    ForEach(names, id: \.self) { n in Button(n) { mix.loadRack(b, name: n) } }
                    if !names.isEmpty { Divider() }
                    Button("Rack speichern …") { saveAsking() }.disabled(slots.isEmpty)
                    if !names.isEmpty {
                        Menu("Löschen") { ForEach(names, id: \.self) { n in Button(n) { mix.deleteRack(n) } } }
                    }
                } label: { Text("RACKS") }
                .menuStyle(.borderlessButton).fixedSize().font(Theme.label(10, .bold)).tint(Theme.bone)
                .help("Gemerkte Racks laden oder dieses merken (mit den Einstellungen der Effekte und Plugins)")
            }
            if let error {
                Text(verbatim: "⚠︎ " + error).font(Theme.mono(10)).foregroundStyle(Theme.state).lineLimit(3)
            }
            if isMaster && !mix.masterFXActive {
                Text("extern: kein Summenpunkt – Master-Bus aus").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(10)
        .frame(width: 360)
        .background(Theme.chitin)
    }

    @ViewBuilder private func row(_ k: Int, _ slot: FXSlot, _ count: Int, _ latency: Double?) -> some View {
        let ready = mix.slotReady(b, k)
        let bypassed = mix.liveBypassed(slot)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                DeckButton(title: "ON", active: slot.on, color: Theme.state, width: 22) { mix.setSlotOn(b, slot: k, !slot.on) }
                    .help("Slot an/aus (aus = durchgereicht, Fahne klingt aus)")
                Text(verbatim: "\(k + 1)").font(Theme.mono(10, .bold)).foregroundStyle(Theme.muted)
                Button { picker = k } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: mix.slotName(slot)).font(Theme.label(10, .bold)).lineLimit(1)
                            .foregroundStyle(ready ? Theme.bone : Theme.muted)
                        if slot.isPlugin && !ready { Text(verbatim: "…").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: slotHelp(slot, latency)) + Text(verbatim: " · ") + Text("Klick = anderer Effekt"))
                .popover(isPresented: Binding(get: { picker == k }, set: { if !$0 { picker = nil } }), arrowEdge: .bottom) {
                    EffectPicker(b: b, replacing: k) { picker = nil }.environment(mix)
                }
                Knob(value: Binding(get: { slot.mix }, set: { mix.setSlotMix(b, slot: k, $0) }), range: 0...1, defaultValue: 1,
                     color: Theme.state, size: 16)
                    .help("D/W des Slots")
                DeckButton(title: "▲", width: 12, verbatim: true) { mix.moveSlot(b, slot: k, by: -1) }
                    .opacity(k > 0 ? 1 : 0.3).disabled(k == 0)
                    .help("früher im Signalfluss")
                DeckButton(title: "▼", width: 12, verbatim: true) { mix.moveSlot(b, slot: k, by: 1) }
                    .opacity(k < count - 1 ? 1 : 0.3).disabled(k >= count - 1)
                    .help("später im Signalfluss")
                if slot.isPlugin {
                    PluginEditButton(b: b, k: k, width: 26)
                } else {
                    DeckButton(title: "EDIT", width: 26) { params = k }
                        .help("Parameter des Effekts")
                        .popover(isPresented: Binding(get: { params == k }, set: { if !$0 { params = nil } }), arrowEdge: .bottom) {
                            SlotParamsView(b: b, k: k).environment(mix)
                        }
                }
                DeckButton(title: "✕", width: 12, verbatim: true) { mix.removeSlot(b, slot: k) }
                    .help("Slot entfernen")
            }
            if bypassed {
                Text("VST3 bypassed in LIVE").font(Theme.mono(8)).foregroundStyle(Theme.state).padding(.leading, 22)
            }
        }
    }

    private func slotHelp(_ s: FXSlot, _ latency: Double?) -> String {
        guard s.isPlugin else { return s.id }
        let info = mix.core.pluginCatalog.knownInfo(s.id)
        return (info.map { "\($0.name) · \($0.manufacturer)" } ?? s.id) + (latency.map { String(format: " · %.1f ms", $0 * 1000) } ?? "")
    }

    private func saveAsking() {
        let a = NSAlert()
        a.messageText = String(localized: "Rack speichern")
        a.informativeText = String(localized: "Gibt es den Namen schon, wird dieses Rack überschrieben.")
        let field = NSTextField(string: mix.slots(b).map { mix.slotName($0) }.joined(separator: FXCatalog.rackSeparator))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Speichern"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mix.saveRack(b, name: name)
    }
}

/// Knopf mit der Kurzform des Racks ("AUDelay +1", "—"), öffnet das Rack als Popover
struct RackButton: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    var width: CGFloat = 70
    @State private var shown = false

    var body: some View {
        let slots = mix.slots(b)
        let error = mix.pluginError(b)
        let first = slots.first.map { mix.slotName($0) }
        let label = (error != nil ? "⚠︎ " : "") + (first.map { String($0.prefix(10)) } ?? "—") + (slots.count > 1 ? " +\(slots.count - 1)" : "")
        Button { shown.toggle() } label: {
            Text(verbatim: label)
                .font(Theme.label(10.z, .bold))
                .lineLimit(1)
                .foregroundStyle(Theme.bone)
                .frame(minWidth: width.z, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(error ?? String(localized: "Rack: bis zu \(MixEngine.slotCount) Effekte in Reihe (eingebaut, Audio Unit, VST3)"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            RackView(b: b).environment(mix)
        }
    }
}

/// kompakte Slot-Zeilen einer Unit in der Leiste: Nummer, Effekt (Klick = wählen), ON-Punkt, D/W-Balken.
/// Rechtsklick: EDIT, früher, später, entfernen. Ziehen einer Zeile auf eine andere = umordnen. Bis 4 Zeilen je Spalte
struct SlotRows: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    static let perColumn = 4

    var body: some View {
        let slots = mix.slots(b)
        let columns = max(1, (slots.count + Self.perColumn - 1) / Self.perColumn)
        HStack(alignment: .top, spacing: 6.z) {
            if slots.isEmpty {
                Text("leer").font(Theme.label(8.z, .bold)).foregroundStyle(Theme.muted).frame(height: 12.z)
            }
            ForEach(0..<columns, id: \.self) { c in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(c * Self.perColumn..<min(slots.count, (c + 1) * Self.perColumn), id: \.self) { k in
                        SlotRow(b: b, k: k, slot: slots[k])
                    }
                }
            }
        }
    }
}

private struct SlotRow: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    let k: Int
    let slot: FXSlot
    @State private var picking = false
    @State private var editing = false
    @State private var dropping = false

    var body: some View {
        let ready = mix.slotReady(b, k), count = mix.slots(b).count, bypassed = mix.liveBypassed(slot)
        HStack(spacing: 3.z) {
            Text(verbatim: "\(k + 1)").font(Theme.mono(8.z, .bold)).foregroundStyle(Theme.muted).frame(width: 7.z)
            Button { picking = true } label: {
                Text(verbatim: mix.slotName(slot) + (slot.isPlugin && !ready ? " …" : ""))
                    .font(Theme.label(9.z, .bold)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(bypassed ? Theme.state : ready ? Theme.bone : Theme.muted)
                    .frame(width: 56.z, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "\(k + 1) " + mix.slotName(slot) + " · ") + Text("Klick = Effekt wählen · Rechtsklick = EDIT, Reihenfolge, entfernen"))
            .popover(isPresented: $picking, arrowEdge: .bottom) { EffectPicker(b: b, replacing: k) { picking = false }.environment(mix) }
            Button { mix.setSlotOn(b, slot: k, !slot.on) } label: {
                Circle().fill(slot.on ? Theme.state : Theme.void)
                    .overlay(Circle().stroke(slot.on ? Theme.state : Theme.hairline, lineWidth: 1))
                    .frame(width: 8.z, height: 8.z)
                    .padding(1.z)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("an/aus (aus = durchgereicht, Fahne klingt aus)")
            MixBar(value: slot.mix) { mix.setSlotMix(b, slot: k, $0) }
            if slot.isPlugin {
                PluginEditButton(b: b, k: k, compact: true, width: 24)
            } else {
                Color.clear.frame(width: 24.z, height: 11.z)
            }
        }
        .frame(height: 11.z)
        .background(Rectangle().fill(dropping ? Theme.secondary.opacity(0.25) : .clear))
        .background(UITestMark(name: "fx slot \(b) \(k) \(slot.id)"))
        .popover(isPresented: $editing, arrowEdge: .bottom) { SlotParamsView(b: b, k: k).environment(mix) }
        .contextMenu {
            Button(slot.isPlugin ? "Plugin-Fenster öffnen" : "Parameter …") {
                if slot.isPlugin { PluginWindow.show(unit: b, slot: k, core: mix.core) } else { editing = true }
            }
            .disabled(slot.isPlugin && !ready)
            Button(slot.on ? "Aus" : "An") { mix.setSlotOn(b, slot: k, !slot.on) }
            Divider()
            Button("Früher im Signalfluss") { mix.moveSlot(b, slot: k, by: -1) }.disabled(k == 0)
            Button("Später im Signalfluss") { mix.moveSlot(b, slot: k, by: 1) }.disabled(k >= count - 1)
            Divider()
            Button("Slot entfernen") { mix.removeSlot(b, slot: k) }
        }
        .helpInfo("fx.slot")
        .draggable("minos-slot:\(b):\(k)")
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, s.hasPrefix("minos-slot:") else { return false }
            let p = s.split(separator: ":")
            guard p.count == 3, Int(p[1]) == b, let from = Int(p[2]), from != k else { return false }
            mix.moveSlot(b, from: from, to: k)
            return true
        } isTargeted: { dropping = $0 }
    }
}

/// + im Kopf der Unit: Effekt hinten anhängen (Effekt-Auswahl)
struct AddSlotButton: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    @State private var picking = false

    var body: some View {
        let full = mix.slots(b).count >= MixEngine.slotCount
        Button { picking = true } label: {
            Text(verbatim: "+").font(Theme.mono(10.z, .bold)).foregroundStyle(full ? Theme.hairline : Theme.bone)
                .frame(width: 12.z, height: 12.z)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(full)
        .help("+ SLOT: Effekt hinzufügen (eingebaut oder Plugin)")
        .popover(isPresented: $picking, arrowEdge: .bottom) { EffectPicker(b: b, replacing: nil) { picking = false }.environment(mix) }
        .background(UITestMark(name: "fx add \(b)"))
    }
}

/// kleiner D/W-Balken: Ziehen = Wert, Doppelklick = 100 %
private struct MixBar: View {
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        let w = 22.z, h = 5.z
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.void)
            Rectangle().fill(Theme.bone.opacity(0.7)).frame(width: w * max(0, min(1, value)))
        }
        .frame(width: w, height: h)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .padding(.vertical, 2.z)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in set(max(0, min(1, g.location.x / w))) })
        .onTapGesture(count: 2) { set(1) }
        .help(Text("D/W des Slots") + Text(verbatim: String(format: " · %.0f %%", value * 100)))
    }
}

/// Master-Bus im Mixer: FX an/aus, D/W, Rack. Extern (jedes Deck auf eigenem Paar) ohne Summenpunkt: aus, mit Hinweis
struct MasterFXStrip: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let m = mix.masterFX, active = mix.masterFXActive
        VStack(alignment: .leading, spacing: 3.z) {
            fx(m, active)
            // Aufnahme (Master oder Eingang vom Pult, ⌘, -> AUDIO); auch extern aktiv
            HStack(spacing: 4.z) {
                RecordButton(compact: true)
                RecordMeter(width: 40)
            }
        }
    }

    private func fx(_ m: MasterFXState, _ active: Bool) -> some View {
        HStack(spacing: 4.z) {
            Text("MASTER").font(Theme.label(9.z, .heavy)).foregroundStyle(m.on && active ? Theme.state : Theme.muted)
            DeckButton(title: "FX", active: m.on, color: Theme.state, width: 20) { mix.toggleMasterFX() }
                .help(active ? Text("Master-Bus an/aus: Insert-Slots nach der Summe der Decks, vor MAIN")
                             : Text("Extern: kein Summenpunkt – der Master-Bus wirkt nur im internen Mixer"))
            Knob(value: Binding(get: { mix.masterFX.dryWet }, set: { mix.setMasterFX(dryWet: $0) }),
                 range: 0...1, defaultValue: 1, label: "D/W", color: Theme.state, size: 18)
            RackButton(b: MixController.masterBus, width: 54)
            if !active { Text("EXTERN AUS").font(Theme.label(8.z, .bold)).foregroundStyle(Theme.muted) }
        }
        .opacity(active ? 1 : 0.55)
    }
}
