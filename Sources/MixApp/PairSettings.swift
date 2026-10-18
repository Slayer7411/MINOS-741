import SwiftUI
import MixCore

/// Zwei Macs und B2B: gekoppelte Macs mit Modus (Session, B2B, aus), Kopplung mit gefundenen Macs (Vergleichszahl)
struct PairingRows: View {
    private let link = PairLink.shared

    var body: some View {
        Group {
            ForEach(link.peers) { p in
                LabeledContent(p.name) {
                    HStack {
                        Picker("Modus", selection: modeBinding(p.id)) {
                            Text("Session").tag(PairMode.session)
                            Text("B2B").tag(PairMode.b2b)
                            Text("Aus").tag(PairMode.off)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                        Button("Trennen") { link.unpair(p.id) }
                    }
                }
            }
            ForEach(link.seen.filter { n in !link.peers.contains { $0.name == n } }, id: \.self) { name in
                LabeledContent(name) {
                    HStack {
                        Button("Als Session koppeln") { link.startPairing(with: name, mode: .session) }
                        Button("Als B2B koppeln") { link.startPairing(with: name, mode: .b2b) }
                    }
                    .disabled(link.pairing != nil)
                }
            }
            if link.seen.isEmpty, link.peers.isEmpty {
                Text("Sucht den zweiten Mac …").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: sheetBinding) { pairSheet }
    }

    private func modeBinding(_ id: String) -> Binding<PairMode> {
        Binding(get: { link.peers.first { $0.id == id }?.mode ?? .off }, set: { link.setMode($0, for: id) })
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { link.pairing != nil }, set: { if !$0 { link.cancelPairing() } })
    }

    private var pairSheet: some View {
        VStack(spacing: 18) {
            Text("Kopplung mit \(link.pairing?.peer ?? "…")")
                .font(.headline)
            Text("Gleiche Zahl auf beiden Macs?")
            Text(link.pairing?.code ?? "……")
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            if link.pairing?.confirmed == true {
                Text("Warte auf den anderen Mac …").foregroundStyle(.secondary)
            }
            HStack {
                Button("Abbrechen") { link.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Bestätigen") { link.confirmPairing() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.pairing?.code == nil || link.pairing?.confirmed == true)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
