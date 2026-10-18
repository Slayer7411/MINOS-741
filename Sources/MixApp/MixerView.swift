import SwiftUI
import MixCore
import MixEngine

/// Interner Mixer: Kanäle in der Reihenfolge C A B D, Crossfader. Im Extern-Modus Gain/Filter/FX, EQ nur mit Schalter.
struct MixerView: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let order = mix.showFourDecks ? [2, 0, 1, 3] : [0, 1]
        VStack(spacing: 6.z) {
            HStack(alignment: .top, spacing: 4.z) {
                ForEach(order, id: \.self) { ChannelStrip(d: $0) }
            }
            if mix.mixerMode == .internalMixer {
                HStack(spacing: 4.z) {
                    Text("A").font(Theme.label(9.z, .bold)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { mix.crossfader }, set: { mix.setCrossfader($0) }), in: -1...1)
                        .controlSize(zoomed: .mini)
                    Text("B").font(Theme.label(9.z, .bold)).foregroundStyle(.secondary)
                }
                .onDoubleClick(name: "dbl XFADE") { mix.setCrossfader(0) }
            } else {
                Text("EXTERN").font(Theme.label(9.z, .heavy)).foregroundStyle(.secondary)
            }
            AutoMixBar()
            MasterFXStrip()
        }
        .padding(6.z)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

struct ChannelStrip: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let deck = mix.deck(d)
        VStack(spacing: 3.z) {
            Text(deckLetters[d]).font(Theme.label(12.z, .heavy))
                .foregroundStyle(mix.focusedDeck == d ? Theme.bone : Theme.muted)
            knob(\.gainDb, -12...12, "GAIN")
            if mix.eqVisible {
                eqKnob(mix, d, \.eqHigh, "HI")
                eqKnob(mix, d, \.eqMid, "MID")
                eqKnob(mix, d, \.eqLow, "LO")
            }
            knob(\.filter, -1...1, "FILTER", color: Theme.state)
            HStack(spacing: 2.z) {
                ForEach(0..<mix.prefs.ui.fxUnitCount, id: \.self) { u in
                    DeckButton(title: "\(u + 1)", active: deck.fxAssign[u], color: Theme.state) { mix.toggleFXAssign(d, u) }.helpInfo("mixer.fxassign")
                }
            }
            if mix.mixerMode == .internalMixer {
                LevelFader(value: Binding(get: { deck.fader }, set: { v in mix.updateDeck(d) { $0.fader = v } }))
                .helpInfo("mixer.fader")
                    .frame(width: 22.z, height: 84.z)
                Picker("", selection: Binding(get: { deck.xf }, set: { v in mix.updateDeck(d) { $0.xf = v } })) {
                    ForEach(XFAssign.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(zoomed: .mini)
                .labelsHidden()
                .frame(width: 54.z)
            } else {
                let p = mix.deckPairs[d]
                Text("USB\n\(p + 1)/\(p + 2)")
                    .font(Theme.mono(10.z, .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4.z)
            }
        }
        .frame(width: 58.z)
    }

    private func knob(_ kp: WritableKeyPath<DeckState, Double>, _ r: ClosedRange<Double>, _ label: String,
                      color: Color = Theme.accent) -> some View {
        Knob(value: Binding(get: { mix.deck(d)[keyPath: kp] }, set: { v in mix.updateDeck(d) { $0[keyPath: kp] = v } }),
             range: r, defaultValue: 0, bipolar: true, label: label, color: color, size: 26)
    }
}

/// EQ-Regler eines Kanals (-26 … +12 dB, -26 = Kill; Doppelklick = 0 dB). Im Mixerkanal und am Deck-Kopf
func eqKnob(_ mix: MixModel, _ d: Int, _ kp: WritableKeyPath<DeckState, Double>, _ label: String, size: CGFloat = 26) -> some View {
    Knob(value: Binding(get: { mix.deck(d)[keyPath: kp] }, set: { v in mix.updateDeck(d) { $0[keyPath: kp] = v } }),
         range: -26...12, defaultValue: 0, bipolar: true, label: label, size: size)
}

/// Senkrechter Kanalfader
struct LevelFader: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Theme.void).frame(width: 4.z).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                Rectangle().fill(Theme.bone.opacity(0.5)).frame(width: 4.z, height: h * value)
                Rectangle().fill(Theme.bone)
                    .frame(width: geo.size.width, height: 8.z)
                    .offset(y: -(h - 8.z) * value)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = max(0, min(1, 1 - g.location.y / h))
            })
            .onDoubleClick(name: "dbl FADER") { value = 1 }
        }
    }
}

/// FX-Unit: Insert-Slots (Zeilen: Effekt, an/aus, D/W; das ganze Rack im Popover), dazu D/W der Unit und die
/// Schnellregler 1–3 mit Tasten. Sie liegen auf zuweisbaren Parametern aller Slots (Rechtsklick, ⌘, -> MIXER & FX);
/// der Controller geht denselben Weg.
/// Stufe der FX-Units in der oberen Leiste, je nach Platz neben der Master-Clock: ganz (Slots, Namen),
/// kompakt (ohne Slot-Liste und Regler-Beschriftung, Wert beim Zeigen), Streifen (Regler und Schalter, RACK darüber)
enum FXLevel: Int, Comparable {
    case full, compact, strip
    static func < (a: FXLevel, b: FXLevel) -> Bool { a.rawValue < b.rawValue }
    /// Breite je Unit in Punkten ohne Zoom (gemessen, siehe TopBar)
    var width: CGFloat {
        switch self {
        case .full: 295
        case .compact: 184
        case .strip: 158
        }
    }
}

struct FXUnitView: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    var level: FXLevel = .full
    @State private var rack = false

    private var unit: FXMirror { mix.fxUnits[u] }

    /// RACK-Schalter (in jeder Stufe): Slots, Vorlagen, gemerkte Racks
    private var rackButton: some View {
        Button { rack.toggle() } label: {
            Text(verbatim: unit.pluginError != nil ? "⚠︎ RACK" : "RACK").font(Theme.label(8.z, .bold))
                .foregroundStyle(unit.pluginError != nil ? Theme.state : Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(unit.pluginError.map { Text(verbatim: $0) } ?? Text("Rack: Slots, Vorlagen, gemerkte Racks"))
        .popover(isPresented: $rack, arrowEdge: .bottom) { RackView(b: u).environment(mix) }
    }

    var body: some View {
        let fx = unit.state
        let name = Text("FX \(u + 1)").font(Theme.label(10.z, .heavy)).foregroundStyle(fx.anyOn ? Theme.state : Theme.muted)
        HStack(alignment: .center, spacing: (level == .full ? 6 : 4).z) {
            Group {
                switch level {
                case .full:
                    VStack(alignment: .leading, spacing: 1.z) {
                        HStack(spacing: 4.z) {
                            name
                            rackButton
                            AddSlotButton(b: u)
                        }
                        SlotRows(b: u)
                    }
                case .compact:
                    HStack(spacing: 4.z) { name; rackButton }
                case .strip:
                    VStack(alignment: .leading, spacing: 1.z) { name; rackButton }
                }
            }
            .background(UITestMark(name: "fx unit \(u)"))
            FXKnob(u: u, c: .dryWet, labels: level == .full)
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 1.z) {
                    FXKnob(u: u, c: .knob(i), labels: level == .full)
                    FXButton(u: u, i: i)
                }
            }
        }
        .padding(.horizontal, (level == .full ? 6 : 4).z)
        .padding(.vertical, 2.z)
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)   // nie stauchen: die Zählerleiste in der Mitte gibt Platz ab
    }
}

/// Regler eines FX-Bedienelements: Beschriftung = zugewiesener Parameter (hell = eigene Zuweisung),
/// beim Drehen und Zeigen der Wert mit Einheit. Rechtsklick = zuweisen
struct FXKnob: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let c: FXControl
    /// Beschriftung unter dem Regler (kompakte Stufen: aus, der Wert steht im Hilfetext)
    var labels = true
    @State private var hover = false
    @State private var flash = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        let info = mix.fxUnits[u].controls[c.slot]
        let showValue = info.param != nil && (hover || flash)
        VStack(spacing: 0) {
            Knob(value: Binding(get: { mix.fxUnits[u].controls[c.slot].value }, set: { mix.setFXControl(u, c, $0) }),
                 range: 0...1, defaultValue: info.param?.defaultValue ?? 0, bipolar: info.param?.bipolar ?? false,
                 color: Theme.state, size: 20)
                .opacity(info.param == nil ? 0.35 : 1)
            if labels {
                Text(verbatim: showValue ? mix.fxText(u, info) : info.label)
                    .font(showValue ? Theme.mono(7.z) : Theme.label(7.z, .semibold))
                    .foregroundStyle(showValue || !info.isDefault ? Theme.bone : Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 32.z)
            }
        }
        .onHover { hover = $0 }
        .onChange(of: info.value) {
            // Wert kurz zeigen (Controller, Plugin-Fenster, Ziehen)
            flash = true
            flashTask?.cancel()
            flashTask = Task { try? await Task.sleep(for: .seconds(1.2)); if !Task.isCancelled { flash = false } }
        }
        .contextMenu { FXAssignMenu(u: u, c: c) }
        .help(fxHelp(info))
    }

    private func fxHelp(_ info: FXControlInfo) -> Text {
        guard let p = info.param else { return Text("Nicht zugewiesen · Rechtsklick = Parameter wählen") }
        return fxParamName(p) + Text(verbatim: " · " + mix.fxText(u, info) + " · ") + Text("Rechtsklick = Parameter wählen")
    }
}

/// Taste eines FX-Bedienelements: Schalter, Liste (nächste Stufe) oder min/max. Rechtsklick = zuweisen
struct FXButton: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let i: Int

    var body: some View {
        let c = FXControl.button(i)
        let info = mix.fxUnits[u].controls[c.slot]
        DeckButton(title: info.label, active: info.active, color: Theme.state, width: 22, verbatim: true) { mix.pressFXButton(u, i) }
            .opacity(info.param == nil ? 0.5 : 1)
            .contextMenu { FXAssignMenu(u: u, c: c) }
            .help(info.param.map { fxParamName($0) + Text(verbatim: " · " + mix.fxText(u, info) + " · ") + Text("Rechtsklick = Parameter wählen") }
                  ?? Text("Nicht zugewiesen · Rechtsklick = Parameter wählen"))
    }
}

/// Name eines Parameters (eigene Effekte übersetzt, Plugins wie geliefert)
func fxParamName(_ p: FXParam) -> Text {
    p.pluginParam == nil ? Text(LocalizedStringKey(p.name)) : Text(verbatim: p.name)
}

extension FXControl {
    /// Beschriftung in Menüs und Einstellungen (Lokalisierungsschlüssel)
    var title: LocalizedStringKey {
        switch self {
        case .dryWet: "D/W"
        case .knob1: "Regler 1"
        case .knob2: "Regler 2"
        case .knob3: "Regler 3"
        case .button1: "Taste 1"
        case .button2: "Taste 2"
        case .button3: "Taste 3"
        }
    }
}

/// FX-Belegung eines Bedienelements: Standard, nicht zugewiesen, alle Parameter des geladenen Effekts.
/// Gruppen als Abschnitte, bei vielen Parametern als Untermenüs (je 20). Tasten: Schalter/Listen oben, stufenlose als min/max.
/// `filter` = Suche (Einstellungen)
struct FXAssignMenu: View {
    @Environment(MixModel.self) private var mix
    let u: Int
    let c: FXControl
    var filter = ""

    private static let flatLimit = 24, chunk = 20

    var body: some View {
        let unit = mix.fxUnits[u]
        let mapped = unit.state.mapping[c]
        let params = unit.params
        let def = FXCatalog.defaultTarget(c, fx: unit.state, params: params).flatMap { k in params.first { $0.id == k } }
        let list = filter.isEmpty ? params : params.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.group.localizedCaseInsensitiveContains(filter)
        }
        Toggle(isOn: Binding(get: { mapped == nil }, set: { _ in mix.setFXMapping(u, c, nil) })) {
            Text("Standard") + Text(verbatim: " · ") + (def.map(fxParamName) ?? Text(verbatim: "—"))
        }
        Toggle(isOn: Binding(get: { mapped == "" }, set: { _ in mix.setFXMapping(u, c, "") })) { Text("Nicht zugewiesen") }
        Divider()
        if list.isEmpty {
            params.isEmpty ? Text("Effekt lädt …") : Text("Kein Parameter gefunden")
        }
        if c == .dryWet {
            let wet = list.filter { p in p.pluginParam != nil && ["mix", "wet", "dry"].contains { p.name.lowercased().contains($0) } }
            if !wet.isEmpty { Section("Mix des Plugins") { items(wet, mapped) } }
        }
        if c.isButton {
            let switches = list.filter(\.isSwitch), rest = list.filter { !$0.isSwitch }
            if !switches.isEmpty { Section("Schalter und Listen") { tree(switches, mapped) } }
            if !rest.isEmpty { Menu("Stufenlos (min/max)") { tree(rest, mapped) } }
        } else {
            tree(list, mapped)
        }
    }

    /// nach Gruppen: wenige = Abschnitte, viele = Untermenüs
    @ViewBuilder private func tree(_ list: [FXParam], _ mapped: String?) -> some View {
        let groups = Self.groups(list)
        if list.count <= Self.flatLimit || groups.count == 1 {
            ForEach(groups, id: \.0) { g in
                if g.0.isEmpty || groups.count == 1 { chunked(g.1, mapped) } else { Section(g.0) { chunked(g.1, mapped) } }
            }
        } else {
            ForEach(groups, id: \.0) { g in
                if g.0.isEmpty { chunked(g.1, mapped) } else { Menu { chunked(g.1, mapped) } label: { Text(verbatim: g.0) } }
            }
        }
    }

    @ViewBuilder private func chunked(_ list: [FXParam], _ mapped: String?) -> some View {
        if list.count <= Self.flatLimit {
            items(list, mapped)
        } else {
            ForEach(Array(stride(from: 0, to: list.count, by: Self.chunk)), id: \.self) { i in
                let part = Array(list[i..<min(i + Self.chunk, list.count)])
                Menu { items(part, mapped) } label: { Text(verbatim: "\(part[0].name) … \(part[part.count - 1].name)") }
            }
        }
    }

    private func items(_ list: [FXParam], _ mapped: String?) -> some View {
        ForEach(list) { p in
            Toggle(isOn: Binding(get: { mapped == p.id }, set: { _ in mix.setFXMapping(u, c, p.id) })) {
                // Art bzw. Bereich hinter dem Namen (Plugins: Einheit, AU mit Bereich)
                let detail: Text? = p.steps == 1 ? Text("Schalter") : p.steps > 1 ? Text("\(p.steps + 1) Stufen")
                    : p.pluginParam == nil || p.rangeText.isEmpty ? nil : Text(verbatim: p.rangeText)
                detail.map { fxParamName(p) + Text(verbatim: " · ") + $0 } ?? fxParamName(p)
            }
        }
    }

    /// Gruppen in der Reihenfolge des ersten Auftretens
    private static func groups(_ list: [FXParam]) -> [(String, [FXParam])] {
        var order: [String] = [], by: [String: [FXParam]] = [:]
        for p in list {
            if by[p.group] == nil { order.append(p.group) }
            by[p.group, default: []].append(p)
        }
        return order.map { ($0, by[$0] ?? []) }
    }
}

/// Obere Leiste in einstellbarer Höhe: der Griff darunter skaliert sie (60…130 %, gespeichert); die Leiste bekommt
/// die Breite des Fensters geteilt durch den Maßstab, damit sie skaliert wieder die volle Breite füllt
struct TopBarHost: View {
    @Environment(MixModel.self) private var mix
    @State private var natural: CGFloat = 0
    @State private var start: Double?

    var body: some View {
        let s = CGFloat(mix.prefs.ui.topBarScale)
        VStack(spacing: 0) {
            GeometryReader { geo in
                TopBar()
                    .fixedSize(horizontal: false, vertical: true)   // ideale Höhe, unabhängig vom Vorschlag (sonst Rückkopplung)
                    .frame(width: geo.size.width / s)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
                    .scaleEffect(s, anchor: .topLeading)
            }
            .frame(height: natural > 0 ? (natural * s).rounded() : nil)
            .fixedSize(horizontal: false, vertical: true)   // Höhe nicht vom Deck-Bereich zusammendrücken lassen
            .clipped()
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.top, 2.z)
                .overlay {
                    Color.clear.frame(height: 9.z)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if start == nil { start = mix.prefs.ui.topBarScale }
                                guard natural > 0 else { return }
                                let v = (start ?? 1) + Double(g.translation.height / natural)
                                mix.prefs.ui.topBarScale = max(0.6, min(1.3, (v * 100).rounded() / 100))
                            }
                            .onEnded { _ in start = nil })
                }
                .help("Ziehen: obere Leiste größer / kleiner · Doppelklick = 100 %")
                .onTapGesture(count: 2) { mix.prefs.ui.topBarScale = 1 }
        }
    }
}

/// Drei Gruppen (links, Mitte, rechts): die Mitte sitzt exakt auf der Mitte der Breite, unabhängig von den Seiten.
/// Passt eine Seite nicht mehr neben die Mitte, rückt die Mitte in eine Zeile darüber, die Seiten darunter (kein Überlappen)
struct CentredBar: Layout {
    var gap: CGFloat

    /// Rahmen je Gruppe (Index 0 links, 1 Mitte, 2 rechts) und Gesamtgröße
    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        // Höhe bei der eigenen Breite messen: Zeilen, die umbrechen, sind sonst ohne Breite zu niedrig
        let s = subviews.map { v -> CGSize in
            let w = v.sizeThatFits(.unspecified).width
            return v.sizeThatFits(ProposedViewSize(width: w, height: nil))
        }
        let (l, c, r) = (s[0], s[1], s[2])
        let side = max(l.width, r.width)
        let w = width ?? c.width + 2 * (side > 0 ? side + gap : 0)
        var frames = [CGRect](repeating: .zero, count: 3)
        // nebeneinander: jede Seite in ihrer Hälfte neben der Mitte
        if c.width <= w, side == 0 || side + gap <= (w - c.width) / 2 {
            let h = max(l.height, c.height, r.height)
            frames[0] = CGRect(x: 0, y: (h - l.height) / 2, width: l.width, height: l.height)
            frames[1] = CGRect(x: (w - c.width) / 2, y: 0, width: c.width, height: h)
            frames[2] = CGRect(x: w - r.width, y: (h - r.height) / 2, width: r.width, height: r.height)
            return (CGSize(width: w, height: h), frames)
        }
        // zu schmal: Mitte allein oben, darunter Seiten (nebeneinander, wenn sie passen)
        frames[1] = CGRect(x: max(0, (w - c.width) / 2), y: 0, width: c.width, height: c.height)
        var y = c.height
        let rows: [[Int]] = l.width > 0 && r.width > 0 && l.width + gap + r.width <= w ? [[0, 2]] : [[0], [2]]
        for row in rows where row.contains(where: { s[$0].width > 0 }) {
            let h = row.map { s[$0].height }.max() ?? 0
            y += y > 0 ? gap : 0
            for i in row where s[i].width > 0 {
                let x = i == 0 ? 0 : w - s[i].width
                frames[i] = CGRect(x: x, y: y + (h - s[i].height) / 2, width: s[i].width, height: s[i].height)
            }
            y += h
        }
        return (CGSize(width: w, height: y), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        return plan(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let f = plan(bounds.width, subviews).frames
        for i in 0..<3 where f[i].width > 0 {
            subviews[i].place(at: CGPoint(x: bounds.minX + f[i].minX, y: bounds.minY + f[i].minY), anchor: .topLeading,
                              proposal: ProposedViewSize(f[i].size))
        }
    }
}

/// Obere Leiste: FX 1 links · Master-Clock und Bar-Zähler mittig (mit Uhr, Aufnahme, ?) · FX 2 rechts.
/// Die FX-Units nehmen die Stufe, die neben der Mitte Platz hat (ganz, kompakt, Streifen); erst wenn auch der
/// Streifen nicht passt, rücken die Seiten in eine Zeile unter die Mitte
struct TopBar: View {
    @Environment(MixModel.self) private var mix
    /// Breite der Leiste und der Mitte (Zeichnen beobachtet: nur bei Änderung neu)
    @State private var width: CGFloat = 0
    @State private var centre: CGFloat = 0

    /// Größte Stufe, die neben der Mitte passt (je Seite, alle Units der Seite); zu schmal: ganz, in Zeilen
    static func level(width: CGFloat, centre: CGFloat, units: Int) -> FXLevel {
        let share = (width - centre) / 2 - 6.z
        for l in [FXLevel.full, .compact, .strip] where share >= l.width.z * CGFloat(units) { return l }
        return .full
    }

    var body: some View {
        let units = mix.prefs.ui.fxUnitCount == 4 ? 2 : 1
        let level = Self.level(width: width, centre: centre, units: units)
        CentredBar(gap: 6.z) {
            HStack(spacing: 6.z) {
                if mix.prefs.ui.showFXUnits {
                    FXUnitView(u: 0, level: level)
                    if mix.prefs.ui.fxUnitCount == 4 { FXUnitView(u: 2, level: level) }
                }
            }
            HStack(spacing: 6.z) {
                MasterClockPanel()
                BarCounter()
                Button { mix.core.resetSession() } label: {
                    Text("↺").font(Theme.mono(14.z)).foregroundStyle(Theme.bone).frame(width: 22.z).frame(minHeight: 42.z, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .help("Takt-Zähler neu starten: der aktuelle Beat wird Takt 1")
                SessionClockView()
                RecordPanel()
                HelpModeButton()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { centre = $0 }
            HStack(spacing: 6.z) {
                if mix.prefs.ui.showFXUnits {
                    FXUnitView(u: 1, level: level)
                    if mix.prefs.ui.fxUnitCount == 4 { FXUnitView(u: 3, level: level) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Master-Clock: LINK, AUTO/MASTER, Tempo mit −/+ und Tap, Metronom, Snap/Quant, Hauptlautstärke
struct MasterClockPanel: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        HStack(spacing: 6.z) {
            // Tempo und Master-Anzeige ändern sich laufend (Tempo-Fader am Master-Deck): eigene Hosting-View, sonst rechnet
            // jede Änderung das Layout des ganzen Fensters neu. Das Zahnrad bleibt draußen (SettingsLink braucht die Szene)
            // Größe hängt nur an der LINK-Beschriftung (Teilnehmerzahl) und an MAIN (extern ausgeblendet)
            Isolated("clock", sizeKey: [mix.linkPeersShown, mix.masterVolumeActive ? 1 : 0]) {
                Controls().environment(mix).foregroundStyle(Theme.bone).tint(Theme.state)
            }
            SettingsLink { Text("⚙︎").font(Theme.mono(14.z)).foregroundStyle(Theme.bone) }
                .buttonStyle(.borderless)
                .help("Einstellungen (⌘,)")
        }
        .padding(.horizontal, 8.z)
        .frame(minHeight: 42.z, maxHeight: .infinity)   // Zeilenhöhe: füllt die Mitte bis zur Höhe der FX-Units
        .background(Rectangle().fill(Theme.deck))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    struct Controls: View {
    @Environment(MixModel.self) private var mix
    @State private var dragStart: Double?

    var body: some View {
        let s = mix.clock
        HStack(spacing: 6.z) {
            DeckButton(title: s.linkEnabled && s.linkPeers > 0 ? "LINK \(s.linkPeers)" : "LINK", active: s.linkEnabled,
                       color: Theme.secondary, width: 38) { mix.toggleLink() }
                .help(s.linkEnabled ? Text("Link: MINOS gibt das Tempo vor · Neusetzungen \(s.linkForces) · Rechtsklick: Diagnose")
                                    : Text("Link: MINOS gibt das Tempo vor"))
                .contextMenu { Button("Link-Diagnose") { mix.showLinkDiagnosis() } }
                .helpInfo("clock.link")
            VStack(spacing: 2.z) {
                DeckButton(title: "AUTO", active: !s.clockMaster, width: 40) { mix.setClockMaster(false) }.helpInfo("clock.auto")
                    .help("Ein Deck ist Master (automatisch oder per MASTER-Taste)")
                DeckButton(title: "MASTER", active: s.clockMaster, color: Theme.secondary, width: 40) { mix.setClockMaster(true) }.helpInfo("clock.master")
                    .help("Clock ist Master: MINOS gibt das Tempo vor, gesyncte Decks folgen")
            }
            VStack(spacing: 0) {
                Text(String(format: "%.2f", s.masterTempo))
                    .font(Theme.mono(17.z, .semibold))
                    .foregroundStyle(s.clockMaster ? Theme.secondary : Theme.bone)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            // ziehen: 1 BPM pro 20 pt; schaltet auf Clock-Master
                            if dragStart == nil { dragStart = mix.masterBPM; mix.setClockMaster(true) }
                            mix.setClockBPM((dragStart ?? 128) - Double(g.translation.height / 1.z) / 20)
                        }
                        .onEnded { _ in dragStart = nil })
                    .help("ziehen = Tempo ändern")
                Text(s.clockMaster ? "CLOCK" : (mix.effectiveMaster.map { "DECK " + deckLetters[$0] } ?? "KEIN MASTER"))
                    .font(Theme.label(8.z)).foregroundStyle(Theme.muted)
            }
            .frame(width: 66.z)
            VStack(spacing: 2.z) {
                HStack(spacing: 2.z) {
                    DeckButton(title: "−", width: 12) { mix.setClockMaster(true); mix.nudgeClock(-0.1) }
                    DeckButton(title: "+", width: 12) { mix.setClockMaster(true); mix.nudgeClock(0.1) }
                }
                DeckButton(title: "TAP", width: 34) { mix.tap() }.helpInfo("clock.tap")
            }
            DeckButton(title: "SEMI", active: s.semiSync, color: Theme.state, width: 38) { mix.setSemiSync(!s.semiSync) }
                .help("Semi-Sync: neue Tracks laden mit dem Tempo des Masters, ohne Phasen-Sync")
            Text("│").foregroundStyle(Theme.hairline)
            VStack(spacing: 2.z) {
                DeckButton(title: "TICK", active: s.metronome, width: 30) { mix.setMetronome(!s.metronome) }
                    .help("Metronom auf dem Beat der Clock")
            }
            Knob(value: Binding(get: { mix.clock.metronomeVolume }, set: { mix.setMetronome(mix.clock.metronome, volume: $0) }),
                 range: 0...1, defaultValue: 0.5, label: "TICK", size: 20)
            Text("│").foregroundStyle(Theme.hairline)
            VStack(spacing: 2.z) {
                DeckButton(title: "S", active: mix.prefs.engine.snap, width: 14) { mix.toggleSnap() }
                    .help("Snap: Cues und Loop-Punkte rasten auf den Beat")
                DeckButton(title: "Q", active: mix.prefs.engine.quantize, width: 14) { mix.toggleQuantize() }
                    .help("Quant: Sprünge halten die Beat-Phase")
            }
            // externer Mixer: Lautstärke regelt das Pult, MAIN wirkt nicht -> ausgeblendet
            if mix.masterVolumeActive {
                Knob(value: Binding(get: { mix.clock.masterVolume }, set: { mix.setMasterVolume($0) }), range: 0...1,
                     defaultValue: 0.85, label: "MAIN", size: 24)
            }
        }
    }
    }
}

/// Stoppuhr der Sitzung: läuft ab dem ersten Play (oder dem Neustart), neben der Uhrzeit
@MainActor @Observable
final class SessionStopwatch {
    static let shared = SessionStopwatch()
    var start: Date?
    func reset() { start = Date() }
}

/// Uhrzeit oben, Stoppuhr unten (mm:ss, ab 1 h h:mm:ss); Klick auf die Stoppuhr = neu ab 0
struct SessionClockView: View {
    @Environment(MixModel.self) private var mix
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var watch: SessionStopwatch { SessionStopwatch.shared }

    var body: some View {
        VStack(spacing: 1.z) {
            Text(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            Text(verbatim: elapsed)
                .font(Theme.mono(13.z, .semibold)).foregroundStyle(watch.start == nil ? Theme.muted : Theme.bone)
        }
        .frame(width: 58.z).frame(minHeight: 42.z, maxHeight: .infinity)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { watch.reset() }
        .help("Stoppuhr: läuft ab dem ersten Play · Klick = neu ab 0 · darüber die Uhrzeit")
        .onReceive(tick) { t in
            now = t
            if watch.start == nil, mix.core.sessionBeat != nil { watch.start = t }
        }
    }

    private var elapsed: String {
        guard let s = watch.start else { return "0:00" }
        let t = Int(max(0, now.timeIntervalSince(s)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Bar-Zähler neben der Master-Clock: läuft ab dem ersten Play, zeigt die Lage im 4/8/16-Takt-Raster; die große Zahl
/// zählt innerhalb der Phrase (⌘, -> Anzeige, Standard 16 Takte) und fängt danach wieder bei 1 an.
/// Doppelklick = neu auf Takt 1.
struct BarCounter: View {
    @Environment(MixModel.self) private var mix
    /// Farben einmal statt in jedem Frame umrechnen
    private static let played = CG.bone.copy(alpha: 0.55) ?? CG.bone
    private static let shade = CGColor(gray: 0, alpha: 0.5)

    var body: some View {
        LiveCanvas(fps: 30) { [mix] ctx, size in
            ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
            guard let sb = mix.core.sessionBeat else {
                CG.text(String(localized: "BARS · ab erstem Play"), size: 10, weight: "Regular", color: CG.mutedNS, rightAt: size.width - 6, y: 15)
                return
            }
            let beat = max(0, sb)
            let bar = Int(beat / 4), inBar = Int(beat) % 4
            let frac = beat - beat.rounded(.down)
            let pulse = CGFloat(max(0, 1 - frac * 2.5))
            let phraseBars = max(1, mix.prefs.ui.phraseBeats / 4)
            CG.text("\(bar % phraseBars + 1).\(inBar + 1)", size: 15, weight: "SemiBold", color: CG.boneNS, rightAt: 46, y: 5)
            let toNext16 = 16 - bar % 16
            CG.text("16 ▸ \(toNext16)", size: 9, weight: "Regular", color: toNext16 == 1 ? CG.stateNS : CG.mutedNS, rightAt: 46, y: 25)
            let x0: CGFloat = 66, w = size.width - x0 - 4
            // drei Reihen gleicher Höhe und Abstand, mittig im Feld; je Reihe gleich breite Zellen, Lücke 2 pt,
            // alle Reihen auf derselben linken und rechten Kante
            for (row, n) in [4, 8, 16].enumerated() {
                let y = 5.5 + CGFloat(row) * 11, h: CGFloat = 9
                let cw = (w - 2 * CGFloat(n - 1)) / CGFloat(n)
                let cur = bar % n
                for i in 0..<n {
                    let r = CGRect(x: x0 + CGFloat(i) * (cw + 2), y: y, width: cw, height: h)
                    let last = cur == n - 1
                    if i < cur {
                        ctx.setFillColor(Self.played)
                    } else if i == cur {
                        ctx.setFillColor((last ? CG.state : CG.bone).copy(alpha: 0.6 + 0.4 * pulse) ?? CG.bone)
                    } else {
                        ctx.setFillColor(CG.hairline)
                    }
                    ctx.fill(r)
                    if i == cur {   // Beats im aktuellen Takt
                        ctx.setFillColor(CG.void)
                        for b in 1..<4 { ctx.fill(CGRect(x: r.minX + r.width * CGFloat(b) / 4, y: r.minY, width: 1, height: r.height)) }
                        ctx.setFillColor(Self.shade)
                        ctx.fill(CGRect(x: r.minX + r.width * CGFloat(inBar + 1) / 4, y: r.minY, width: r.width * CGFloat(3 - inBar) / 4, height: r.height))
                    }
                }
                CG.text("\(n)", size: 8, weight: "Regular", color: CG.mutedNS, rightAt: x0 - 3, y: y - 1)
            }
        }
        .frame(width: 300.z).frame(minHeight: 42.z, maxHeight: .infinity)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .onTapGesture(count: 2) { mix.core.resetSession() }
        .help("Bar-Zähler: läuft ab dem ersten Play, die große Zahl zählt innerhalb der Phrase · Doppelklick = neu auf Takt 1")
    }
}
