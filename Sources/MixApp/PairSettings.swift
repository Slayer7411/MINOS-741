import SwiftUI
import MixCore

/// Zwei Macs: Kopplung mit dem gefundenen Mac (Vergleichszahl, bestätigen) oder Trennen der Kopplung
struct PairingRows: View {
    private let link = PairLink.shared

    var body: some View {
        Group {
            if let p = link.paired {
                LabeledContent("Gekoppelt mit \(p.name)") {
                    Button("Trennen") { link.unpair() }
                }
            } else {
                ForEach(link.seen, id: \.self) { name in
                    Button("Mit \(name) koppeln") { link.startPairing(with: name) }
                        .disabled(link.pairing != nil)
                }
                if link.seen.isEmpty {
                    Text("Sucht den zweiten Mac …").foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: sheetBinding) { pairSheet }
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
