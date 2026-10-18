import Foundation
import CryptoKit
import Network
import SystemConfiguration
import MixCore
import MixEngine
import Observation

/// Zwei Macs als eine Session: beide bieten sich per Bonjour an (`_minos741._tcp`, jede Verbindung: Ethernet,
/// Thunderbolt-/USB-Bridge, WLAN) und suchen sich gegenseitig. Beide bauen ausgehend auf und nehmen eingehende an;
/// blockt die Firewall eine Richtung, kommt die andere durch. Die erste fertige Verbindung wird aktiv; entsteht eine
/// zweite, bleibt die des kleineren Namens (beide Macs entscheiden gleich). Jeder Mac spielt seine Decks (⌘, -> DECKS)
/// über sein eigenes Interface, den Takt hält Link. Über die Verbindung laufen die Gespielt-Markierungen; in die
/// Collection schreibt nur der schreibende Mac. Umschalten wirkt sofort
@MainActor @Observable
final class PairLink {
    static let shared = PairLink()
    /// Bonjour-Art; Ende-zu-Ende: eigene Art (`MIX741_E2E_SERVICE`), nie die der echten Macs
    static let service = E2E.isActive ? E2E.service : "_minos741._tcp"

    private let queue = DispatchQueue(label: "minos741.pair", qos: .utility)
    private(set) var setup = PairSetup()
    private weak var history: HistoryStore?
    private weak var mix: MixModel?
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// aktive Verbindung (ab `.ready`)
    private var active: PairConn?
    /// übrige Verbindungen, noch nicht bereit oder noch nicht entschieden
    private var candidates: [PairConn] = []
    /// Name des anderen Macs (Treffer oder hello); Initiator eingehender Verbindungen
    private var partner: String?
    private var retryPending = false
    /// Kopplung dieses Macs (nil = keine läuft)
    private(set) var pairing: PairingState?
    /// gekoppelter Partner (nil = nicht gekoppelt)
    private(set) var paired: PairedPeer? = PairedPeer.load()
    /// gefundene andere Macs (Bonjour-Namen)
    private(set) var seen: [String] = []
    /// letzte Meldung zur Kopplung (auch für E2E)
    private(set) var note = ""
    /// Stand des anderen Macs (nach hello / state)
    private(set) var peer: (name: String, writes: Bool, decks: [Int])?
    /// LIVE-Schalter (nicht gespeichert): kein Ruhezustand
    @ObservationIgnored var onLive: ((Bool) -> Void)?
    /// Takt: dieser Mac führt Link (ohne Verbindung wie bisher); Stand des anderen und zuletzt gesendete Nachricht
    private var leads = true
    private var peerPlaying = false
    private var peerLeads = false
    private var sentClock: PairMessage?

    private var connection: NWConnection? { active?.nw }

    /// Einstellung übernehmen. An/aus baut die Verbindung auf oder ab; Schreiber und Decks gehen über die bestehende
    /// Verbindung an den anderen Mac (kein Neuaufbau)
    func configure(_ new: PairSetup, history: HistoryStore, mix: MixModel) {
        guard !Session.isSelfTest, new != setup else { return }
        if new.on, setup.on {
            setup = new
            send(.state(writes: new.writes, decks: new.decks))
            report()
            return
        }
        peer = nil
        partner = nil
        pairing = nil
        dropTakt()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let old = active
        active = nil
        old?.nw.cancel()
        candidates.forEach { $0.nw.cancel() }
        candidates = []
        setup = new
        self.history = history
        self.mix = mix
        guard new.on else {
            history.onPlayedChange = nil
            PairDebug.shared.stop()
            StatusCenter.post(.info, String(localized: "Zwei-Mac: aus"), key: "pair")
            return
        }
        history.onPlayedChange = { add, remove in
            PairLink.shared.send(.played(add: add.sorted(), remove: remove.sorted()))
        }
        listen()
        browse()
        PairDebug.shared.start()
    }

    static var computerName: String {
        E2E.isActive ? E2E.name : (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "MINOS-741"
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    nonisolated private static func main(_ f: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(f) }
    }

    // MARK: Verbinden

    private func listen() {
        do {
            let l = try NWListener(using: Self.parameters())
            l.service = NWListener.Service(name: Self.computerName, type: Self.service)
            l.newConnectionHandler = { c in Self.main { PairLink.shared.adopt(c) } }
            l.stateUpdateHandler = { s in
                if case .ready = s, E2E.isActive, let port = l.port?.rawValue { E2EPeers.publish(port) }
                if case .failed = s { Self.main { if PairLink.shared.listener === l { PairLink.shared.restartListener() } } }
            }
            l.start(queue: queue)
            listener = l
            StatusCenter.post(.info, String(localized: "Zwei-Mac: sucht den zweiten Mac"), key: "pair")
        } catch {
            StatusCenter.post(.error, String(localized: "Zwei-Mac: kein Netz-Dienst (\(error.localizedDescription))"), key: "pair")
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { let p = PairLink.shared; if p.setup.on, p.listener == nil { p.listen() } }
        }
    }

    private func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: Self.parameters())
        let own = Self.computerName
        b.browseResultsChangedHandler = { results, _ in
            // jeder andere Mac; ausgehend verbinden, beide Seiten tun das
            let names = results.compactMap { r -> String? in
                guard case let .service(name, _, _, _) = r.endpoint, name != own else { return nil }
                return name
            }
            Self.main { PairLink.shared.seen = Array(Set(names)).sorted() }
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, name != own else { continue }
                let ep = r.endpoint
                Self.main { PairLink.shared.found(name, ep) }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    /// bei zwei Verbindungen bleibt die, die der kleinere Name aufgebaut hat
    nonisolated static func keeps(initiator: String, over other: String) -> Bool { initiator < other }

    /// ausgehend zu einem Treffer; höchstens ein Versuch je Gegenüber
    private func found(_ name: String, _ ep: NWEndpoint) {
        guard setup.on, active?.dialed != name, !candidates.contains(where: { $0.dialed == name }) else { return }
        // Kopplung läuft: nur der Mac mit dem kleineren Namen wählt (eine Verbindung je Paar); sonst nur gekoppelte Partner
        if let p = pairing {
            guard p.peer == nil || p.peer == name, Self.keeps(initiator: Self.computerName, over: name) else { return }
        } else if paired == nil {
            return
        }
        if E2E.isActive {
            // Ende-zu-Ende: Bonjour findet den Partner (echt), die Verbindung läuft über Loopback. macOS liefert eine
            // Verbindung an die eigene LAN-Adresse nicht an den eigenen Listener (geprüft), Loopback geht.
            guard let port = E2EPeers.port(of: name) else { retryIfIdle(); return }
            partner = name
            let p = Self.parameters()
            p.requiredInterfaceType = .loopback
            adopt(NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: p), dialed: name)
            return
        }
        partner = name
        adopt(NWConnection(to: ep, using: Self.parameters()), dialed: name)
    }

    /// neue Verbindung als Kandidat (`dialed`: Name des Treffers bei ausgehend, nil bei eingehend)
    private func adopt(_ nw: NWConnection, dialed: String? = nil) {
        let c = PairConn(nw, dialed: dialed)
        candidates.append(c)
        nw.stateUpdateHandler = { s in Self.main { PairLink.shared.changed(s, of: nw) } }
        nw.start(queue: queue)
        receive(c)
    }

    private func changed(_ s: NWConnection.State, of nw: NWConnection) {
        if let a = active, a.nw === nw {
            switch s {
            case .failed, .waiting:
                nw.cancel()
            case .cancelled:
                active = nil
                peer = nil
                PairDebug.shared.connectionLost()
                dropTakt()
                StatusCenter.post(.warning, String(localized: "Zwei-Mac: Verbindung getrennt"), key: "pair")
                retryIfIdle()
            default:
                break
            }
            return
        }
        guard let c = candidates.first(where: { $0.nw === nw }) else { return }
        switch s {
        case .ready:
            if pairing != nil { beginRun(c) } else { write(c.hs.hello, to: nw) }
        case .failed, .waiting:
            drop(c)
            nw.cancel()
            retryIfIdle()
        case .cancelled:
            drop(c)
            retryIfIdle()
        default:
            break
        }
    }

    /// Handshake abgeschlossen: Dubletten entscheiden, der bereite Kandidat wird aktiv
    private func established(_ c: PairConn) {
        drop(c)
        if let a = active {
            // zweite Verbindung: nur eine bleibt, die andere geht still weg (kein Status, kein peer-Reset)
            if keepsDuplicate(c, over: a) {
                a.nw.cancel()
                promote(c)
            } else {
                c.nw.cancel()
            }
        } else {
            promote(c)
        }
    }

    /// bereite Kandidat wird aktiv: hello, Link, zurückgehaltene Nachrichten
    private func promote(_ c: PairConn) {
        active = c
        leads = setup.writes   // Anfangsführung: der schreibende Mac
        peerPlaying = false; peerLeads = false; sentClock = nil
        send(.hello(writes: setup.writes, decks: setup.decks, version: PairMessage.version, name: Self.computerName,
                    played: (history?.played ?? []).sorted()))
        applyTakt()
        if let mix, !mix.clock.linkEnabled { mix.toggleLink() }
        let early = c.pending
        c.pending = []
        early.forEach(handle)
    }

    /// zweites Duplikat: bleibt es, wenn sein Initiator den kleineren Namen hat (ausgehend = man selbst, eingehend = der andere)
    private func keepsDuplicate(_ c: PairConn, over a: PairConn) -> Bool {
        guard let other = partner, (c.dialed != nil) != (a.dialed != nil) else { return false }
        let own = Self.computerName
        return c.dialed != nil ? Self.keeps(initiator: own, over: other) : Self.keeps(initiator: other, over: own)
    }

    private func drop(_ c: PairConn) {
        candidates.removeAll { $0 === c }
    }

    /// neu suchen, solange keine Verbindung steht (die Trefferliste meldet nur Änderungen); höchstens ein Timer
    private func retryIfIdle() {
        guard setup.on, active == nil, !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let p = PairLink.shared
                p.retryPending = false
                if p.setup.on, p.active == nil { p.browse() }
            }
        }
    }

    private func owns(_ c: PairConn) -> Bool {
        active === c || candidates.contains { $0 === c }
    }

    /// eine Empfangsschleife je Verbindung; Kandidaten puffern, die aktive Verbindung wird zugestellt
    private func receive(_ c: PairConn) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            Self.main {
                let link = PairLink.shared
                guard link.owns(c) else { return }
                var ok = true
                if let data {
                    for f in c.reader.feed(data) where ok { ok = link.accept(f, on: c) }
                }
                if done || error != nil || !ok { c.nw.cancel() } else { link.receive(c) }
            }
        }
    }

    // MARK: Nachrichten

    func send(_ m: PairMessage) {
        guard let c = active, c.nw.state == .ready, let frame = try? c.chan?.seal(m.json()) else { return }
        write(frame, to: c.nw)
    }

    /// Kopplung starten (Taste „Mit … koppeln“, E2E `pair-start`): Partner `name`, nil = der erste gefundene
    @discardableResult
    func startPairing(with name: String?) -> Bool {
        guard setup.on, paired == nil, pairing == nil else { return false }
        pairing = PairingState(peer: name, code: nil, confirmed: false)
        candidates.filter { $0.chan == nil && $0.nw.state == .ready }.forEach { beginRun($0) }
        browse()
        return true
    }

    /// Vergleichszahl stimmt auf diesem Mac: bestätigen; gekoppelt ist erst, wenn der andere auch bestätigt hat
    func confirmPairing() {
        for c in candidates {
            guard let sas = c.sas, !c.localConfirmed else { continue }
            c.localConfirmed = true
            pairing?.confirmed = true
            write(.pairConfirm(sas.confirmation(from: PairIdentity.id)), to: c.nw)
            _ = finishIfConfirmed(c)
        }
    }

    /// Kopplung abbrechen: der andere Mac erfährt es über die Verbindung
    func cancelPairing() {
        guard pairing != nil else { return }
        pairing = nil
        for c in candidates where c.run != nil { closeAfterSending(c.nw, .pairReject) }
        say(String(localized: "Kopplung abgebrochen"), .info)
    }

    /// Kopplung aufheben: Schlüssel weg, bestehende Verbindung ab
    func unpair() {
        guard let p = paired else { return }
        PairKeychain.remove(p.id)
        paired = nil
        PairedPeer.save(nil)
        active?.nw.cancel()
        say(String(localized: "Kopplung aufgehoben"), .info)
    }

    /// Meldung zur Kopplung: Statuszeile und `note`
    private func say(_ text: String, _ level: StatusMessage.Level = .warning) {
        note = text
        StatusCenter.post(level, text, key: "pair")
    }

    /// Kopplung auf dieser Verbindung beginnt: zuerst die Festlegung (Commit) senden
    private func beginRun(_ c: PairConn) {
        guard c.run == nil else { return }
        let r = PairRendezvous(id: PairIdentity.id, name: Self.computerName)
        c.run = r
        write(.pairCommit(r.commitment), to: c.nw)
    }

    /// letzte Nachricht (optional), dann die Verbindung schließen
    private func closeAfterSending(_ nw: NWConnection, _ f: PairFrame?) {
        nw.send(content: f?.line(), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in nw.cancel() })
    }

    /// Kopplung gescheitert: Meldung, Sitzung zu, der andere Mac erfährt es
    private func failPairing(_ c: PairConn, _ text: String) -> Bool {
        say(text)
        pairing = nil
        closeAfterSending(c.nw, .pairReject)
        return true
    }

    /// beide Seiten haben bestätigt: Schlüssel speichern, gekoppelt; die Verbindung geht danach sauber zu
    private func finishIfConfirmed(_ c: PairConn) -> Bool {
        guard c.localConfirmed, c.peerConfirmed, let sas = c.sas, let id = c.peerID, let name = c.peerName else { return true }
        PairKeychain.set(sas.key, for: id)
        paired = PairedPeer(id: id, name: name)
        PairedPeer.save(paired)
        pairing = nil
        say(String(localized: "Gekoppelt mit \(name)"), .info)
        closeAfterSending(c.nw, nil)
        return true
    }

    private func write(_ f: PairFrame, to nw: NWConnection) {
        nw.send(content: f.line(), completion: .contentProcessed { _ in })
    }

    /// Frame eines Kandidaten: vor dem Kanal der Handshake, danach versiegelte Nachrichten. false = Verbindung schließen
    private func accept(_ f: PairFrame, on c: PairConn) -> Bool {
        guard c.chan != nil else { return shake(f, c) }
        guard let plain = try? c.chan?.open(f), let m = try? JSONDecoder().decode(PairMessage.self, from: plain) else {
            return false
        }
        if c === active { handle(m) } else { c.pending.append(m) }
        return true
    }

    private func shake(_ f: PairFrame, _ c: PairConn) -> Bool {
        switch f {
        case .pairCommit, .pairReveal, .pairConfirm, .pairReject:
            return pairStep(f, c)
        default:
            break
        }
        // auf dieser Verbindung läuft eine Kopplung: der normale Handshake ist hier nicht erlaubt
        if c.run != nil { return true }   // Kopplung läuft auf dieser Verbindung: Handshake-Frames ignorieren
        do {
            if let reply = try c.hs.receive(f, key: { PairKeychain.get($0) }) { write(reply, to: c.nw) }
            guard let ch = c.hs.channel() else { return true }
            c.chan = ch
            established(c)
            return owns(c)
        } catch {
            if error as? PairAuthError == .unpaired { return notPaired(f, c) }
            let who = c.hs.peerID ?? c.dialed ?? String(localized: "unbekannt")
            return failPairing(c, String(localized: "Pairing abgelehnt: \(who)"))
        }
    }

    private func notPaired(_ f: PairFrame, _ c: PairConn) -> Bool {
        var name = c.dialed ?? String(localized: "unbekannt")
        if case let .hello(_, n, _) = f { name = n }
        say(String(localized: "Nicht gekoppelt: \(name)"))
        return false
    }

    /// Kopplungsschritte auf dieser Verbindung: Festlegung, Aufdeckung, Bestätigung, Abbruch
    private func pairStep(_ f: PairFrame, _ c: PairConn) -> Bool {
        guard let run = c.run, pairing != nil else { return false }
        switch f {
        case let .pairCommit(h):
            guard c.peerCommit == nil else { return false }
            c.peerCommit = h
            write(run.reveal, to: c.nw)
            return true
        case let .pairReveal(id, name, _, _):
            guard let h = c.peerCommit, c.sas == nil else { return false }
            do {
                let sas = try run.finish(peerCommit: h, reveal: f)
                c.sas = sas
                c.peerID = id
                c.peerName = name
                pairing?.code = sas.code
                pairing?.peer = name
                return true
            } catch {
                return failPairing(c, String(localized: "Pairing abgelehnt: \(name)"))
            }
        case let .pairConfirm(mac):
            guard let sas = c.sas, let id = c.peerID, sas.verify(mac, from: id) else {
                let who = c.peerName ?? c.dialed ?? String(localized: "unbekannt")
                return failPairing(c, String(localized: "Pairing abgelehnt: \(who)"))
            }
            c.peerConfirmed = true
            return finishIfConfirmed(c)
        case .pairReject:
            let who = c.peerName ?? c.dialed ?? String(localized: "unbekannt")
            return failPairing(c, String(localized: "Pairing abgelehnt: \(who)"))
        default:
            return false
        }
    }

    private func handle(_ m: PairMessage) {
        guard let history else { return }
        switch m {
        case let .hello(writes, decks, version, name, played):
            peer = (name, writes, decks)
            partner = name
            if version != PairMessage.version {
                StatusCenter.post(.error, String(localized: "Zwei-Mac: \(name) hat eine andere Version – beide Macs auf denselben Stand bringen"), key: "pair")
            }
            // beide schreiben: der Mac mit dem größeren Namen gibt ab (danach Schalter oben)
            if writes, setup.writes, Self.computerName > name { mix?.prefs.ui.pair.writes = false }
            report()
            if setup.writes {
                let s = PairPlayed.merged(history.played, Set(played))
                history.applyPlayed(s)
                send(.playedSet(s.sorted()))
            }
            if let mix, mix.live { send(.live(true)) }
            applyTakt()
        case let .debugRequest(id, command, args):
            if let mix {
                let r = PairDebugResponder.answer(command: command, args: args, mix: mix, allowed: setup.remoteDebug)
                send(.debugReply(id: id, ok: r.ok, body: r.body))
            }
        case let .debugReply(id, ok, body):
            PairDebug.shared.received(id: id, ok: ok, body: body)
        case let .clock(playing, leader):
            guard peer != nil else { return }
            peerPlaying = playing; peerLeads = leader
            if leader, leads { leads = false }   // der Anspruch des anderen gewinnt
            applyTakt()
        case let .state(writes, decks):
            guard let p = peer else { return }
            peer = (p.name, writes, decks)
            // der andere hat das Schreiben übernommen -> abgeben
            if writes, setup.writes { mix?.prefs.ui.pair.writes = false }
            report()
        case let .live(on):
            if let mix, mix.live != on { mix.setLive(on, fromPeer: true) }
        case let .playedSet(s):
            if !setup.writes { history.applyPlayed(Set(s)) }
        case let .played(add, remove):
            history.applyPlayed(history.played.subtracting(remove).union(add))
        }
    }

    /// Statusleiste: verbunden mit wem, wer schreibt, Probleme
    private func report() {
        guard let p = peer else { return }
        let problems = PairCheck.problems(ownWrites: setup.writes, ownDecks: setup.decks, peerWrites: p.writes, peerDecks: p.decks)
        let theirs = p.decks.map { deckLetters[$0] }.joined(separator: "/")
        var text = String(localized: "Zwei-Mac: verbunden mit \(p.name) (Decks \(theirs))") + " · "
            + (setup.writes ? String(localized: "dieser Mac schreibt") : p.writes ? String(localized: "\(p.name) schreibt") : "")
        for q in problems {
            switch q {
            case .bothWrite: text += String(localized: "beide schreiben")
            case .noneWrites: text += String(localized: "kein Mac schreibt – Schalter SCHREIBT oben")
            case let .sharedDecks(d): text += " · " + String(localized: "Deck \(d.map { deckLetters[$0] }.joined(separator: "/")) auf beiden")
            }
        }
        text += " · " + (leads ? String(localized: "TAKT: dieser Mac") : String(localized: "TAKT: \(p.name)"))
        StatusCenter.post(problems.isEmpty ? .ok : .warning, text, key: "pair")
    }

    var connected: Bool { peer != nil }

    /// LIVE an/aus an den anderen Mac
    func sendLive(_ on: Bool) { send(.live(on)) }

    /// Master-Deck spielt oder steht (Oberflächen-Takt, nur bei Änderung)
    func masterDeckChanged() { applyTakt() }

    /// TAKT-Schalter: dieser Mac führt Link, der andere gibt ab (sein Stand kommt mit der nächsten Takt-Nachricht)
    func claimTakt() {
        guard setup.on, peer != nil, let mix, !leads else { return }
        leads = true
        peerLeads = false
        mix.core.setLinkFollow(false)
        mix.setTaktHere(true)
        let m = PairMessage.clock(playingMaster: mix.playingMaster, leader: true)
        if connection?.state == .ready { sentClock = m; send(m) }
        report()
    }

    /// Takt: wer führt (PairTempo), die Clock folgt Link, solange der andere führt; Stand nur bei Änderung senden
    private func applyTakt() {
        guard setup.on, let mix else { dropTakt(); return }
        let was = leads
        if let p = peer {
            leads = PairTempo.leads(ownPlaying: mix.playingMaster, peerPlaying: peerPlaying, ownLeads: leads,
                                    peerLeads: peerLeads, ownName: Self.computerName, peerName: p.name)
        }
        mix.core.setLinkFollow(peer != nil && !leads)
        mix.setTaktHere(leads)
        let m = PairMessage.clock(playingMaster: mix.playingMaster, leader: leads)
        if m != sentClock, connection?.state == .ready { sentClock = m; send(m) }
        if leads != was, peer != nil { report() }
    }

    /// ohne Verbindung (oder Zwei-Mac aus) führt dieser Mac Link wie bisher
    private func dropTakt() {
        leads = true; sentClock = nil; peerPlaying = false; peerLeads = false
        mix?.core.setLinkFollow(false)
        mix?.setTaktHere(true)
    }
}

/// Eine Verbindung zum anderen Mac; `dialed` = Name des Treffers, wenn wir sie aufgebaut haben (nil: eingehend)
@MainActor
fileprivate final class PairConn {
    let nw: NWConnection
    let dialed: String?
    var reader = PairLineReader<PairFrame>()
    /// Nachrichten vor der Aktivierung
    var pending: [PairMessage] = []
    /// Handshake; danach `chan` für die versiegelten Nachrichten
    var hs = PairHandshake(ownID: PairIdentity.id, ownName: PairLink.computerName)
    var chan: PairChannel?
    /// Kopplung auf dieser Verbindung: eigene Festlegung, Festlegung des Partners, Vergleich, Bestätigungen
    var run: PairRendezvous?
    var peerCommit: Data?
    var sas: PairSAS?
    var peerID: String?
    var peerName: String?
    var localConfirmed = false, peerConfirmed = false

    init(_ nw: NWConnection, dialed: String?) {
        self.nw = nw
        self.dialed = dialed
    }
}

/// Kopplung in Arbeit: Partner (Name, nil = der erste gefundene), Vergleichszahl sobald festgelegt
struct PairingState: Equatable {
    var peer: String?
    var code: String?
    var confirmed: Bool
}
