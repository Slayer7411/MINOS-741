import Foundation
import CryptoKit
import Network
import SystemConfiguration
import MixCore
import MixEngine
import Observation

/// Zwei-Mac und B2B: Macs bieten sich per Bonjour an (`_minos741._tcp`, jede Verbindung: Ethernet,
/// Thunderbolt-/USB-Bridge, WLAN) und suchen sich gegenseitig. Jeder gekoppelte Mac hat eine Verbindung (Modus je
/// Mac: Session = alles, B2B = nur Takt). Beide bauen ausgehend auf und nehmen eingehende an; bei einer doppelten
/// Verbindung zum selben Mac bleibt die des kleineren Namens. Jeder Mac spielt seine Decks über sein eigenes Interface,
/// den Takt hält Link; die Führung der B2B-Gruppe wechselt per Anspruch (PairLead). Gespielt-Markierungen und
/// Einstellungen laufen nur über Session-Verbindungen; in die Collection schreibt nur der schreibende Mac
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
    /// verbundene Macs (je gekoppeltem Mac höchstens eine Verbindung)
    private var links: [PairConn] = []
    /// übrige Verbindungen, noch nicht bereit oder noch nicht entschieden
    private var candidates: [PairConn] = []
    private var retryPending = false
    /// Kopplung dieses Macs (nil = keine läuft)
    private(set) var pairing: PairingState?
    /// gekoppelte Macs (Modus je Mac)
    private(set) var peers: [PairedPeer] = PairedPeerStore.load()
    /// gefundene andere Macs (Bonjour-Namen)
    private(set) var seen: [String] = []
    /// letzte Meldung zur Kopplung (auch für E2E)
    private(set) var note = ""
    /// Führung der B2B-Gruppe (Anspruch mit Zähler)
    private(set) var lead = PairLead()
    /// Anzeige der Leiste: dieser Mac und die verbundenen gekoppelten Macs
    private(set) var info: [PairPeerInfo] = []
    /// LIVE-Schalter (nicht gespeichert): kein Ruhezustand
    @ObservationIgnored var onLive: ((Bool) -> Void)?
    /// dieser Mac führt Link (sonst folgt er der Führung); zuletzt gesendetes Tempo
    private var leads = true
    private var lastTempo = 0.0

    /// Einstellung übernehmen. An/aus baut die Verbindungen auf oder ab; Schreiber und Decks gehen über die bestehenden
    /// Verbindungen an die anderen Macs (kein Neuaufbau)
    func configure(_ new: PairSetup, history: HistoryStore, mix: MixModel) {
        guard !Session.isSelfTest, new != setup else { return }
        if new.on, setup.on {
            setup = new
            send(.state(writes: new.writes, decks: new.decks))
            report()
            return
        }
        pairing = nil
        lead = PairLead()
        dropTakt()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let old = links
        links = []
        old.forEach { $0.nw.cancel() }
        candidates.forEach { $0.nw.cancel() }
        candidates = []
        setup = new
        self.history = history
        self.mix = mix
        refresh()
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

    /// bei zwei Verbindungen zum selben Mac bleibt die, die der kleinere Name aufgebaut hat
    nonisolated static func keeps(initiator: String, over other: String) -> Bool { initiator < other }

    /// ausgehend zu einem Treffer; höchstens ein Versuch je Gegenüber
    private func found(_ name: String, _ ep: NWEndpoint) {
        guard setup.on, !links.contains(where: { $0.name == name }), !candidates.contains(where: { $0.dialed == name }) else { return }
        // Kopplung läuft: nur der Mac mit dem kleineren Namen wählt (eine Verbindung je Paar); sonst gekoppelte Macs
        if let p = pairing {
            guard p.peer == nil || p.peer == name, !peers.contains(where: { $0.name == name }),
                  Self.keeps(initiator: Self.computerName, over: name) else { return }
        } else {
            guard let entry = peers.first(where: { $0.name == name }), entry.mode != .off else { return }
        }
        if E2E.isActive {
            // Ende-zu-Ende: Bonjour findet den Partner (echt), die Verbindung läuft über Loopback. macOS liefert eine
            // Verbindung an die eigene LAN-Adresse nicht an den eigenen Listener (geprüft), Loopback geht.
            guard let port = E2EPeers.port(of: name) else { retryIfIdle(); return }
            let p = Self.parameters()
            p.requiredInterfaceType = .loopback
            adopt(NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: p), dialed: name)
            return
        }
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
        if let c = links.first(where: { $0.nw === nw }) {
            switch s {
            case .failed, .waiting: nw.cancel()
            case .cancelled: dropLink(c)
            default: break
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

    /// Verbindung zu einem gekoppelten Mac ist weg: Takt neu bestimmen, neu suchen
    private func dropLink(_ c: PairConn) {
        guard links.contains(where: { $0 === c }) else { return }
        links.removeAll { $0 === c }
        if c.mode == .session { PairDebug.shared.connectionLost() }
        if c.name != nil { StatusCenter.post(.warning, String(localized: "Zwei-Mac: Verbindung getrennt"), key: "pair") }
        applyTakt()
        retryIfIdle()
    }

    /// Handshake abgeschlossen: der Mac muss gekoppelt und nicht „aus“ sein; Dubletten entscheiden
    private func established(_ c: PairConn) {
        drop(c)
        guard let id = c.hs.peerID, let entry = peers.first(where: { $0.id == id }), entry.mode != .off else {
            c.nw.cancel()
            return
        }
        c.id = id
        c.name = entry.name
        c.localMode = entry.mode
        if let a = links.first(where: { $0.id == id }) {
            // zweite Verbindung zu diesem Mac: nur eine bleibt, die andere geht still weg (kein Status)
            if keepsDuplicate(c, over: a, other: entry.name) {
                links.removeAll { $0 === a }
                a.nw.cancel()
                promote(c)
            } else {
                c.nw.cancel()
            }
        } else {
            promote(c)
        }
    }

    /// bereite Kandidat wird aktiv: eigener Modus vorab; Hello, Führung und Takt, sobald der andere Modus kennt
    private func promote(_ c: PairConn) {
        links.append(c)
        c.promoted = true
        if lead.lamport == 0, let id = c.id { _ = lead.accept(lamport: 1, holder: min(PairIdentity.id, id)) }
        writeRaw(.mode(c.localMode), to: c)
        if let mix, !mix.clock.linkEnabled { mix.toggleLink() }
        let early = c.pending
        c.pending = []
        early.forEach { handle($0, from: c) }
    }

    /// zweites Duplikat: bleibt es, wenn sein Initiator den kleineren Namen hat (ausgehend = man selbst, eingehend = der andere)
    private func keepsDuplicate(_ c: PairConn, over a: PairConn, other: String) -> Bool {
        guard (c.dialed != nil) != (a.dialed != nil) else { return false }
        let own = Self.computerName
        return c.dialed != nil ? Self.keeps(initiator: own, over: other) : Self.keeps(initiator: other, over: own)
    }

    private func drop(_ c: PairConn) {
        candidates.removeAll { $0 === c }
    }

    /// neu suchen, solange ein gekoppelter Mac fehlt oder eine Kopplung läuft; höchstens ein Timer
    private func retryIfIdle() {
        let missing = peers.contains { p in p.mode != .off && !links.contains { $0.id == p.id } }
        guard setup.on, missing || pairing != nil, !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let p = PairLink.shared
                p.retryPending = false
                if p.setup.on { p.browse() }
            }
        }
    }

    private func owns(_ c: PairConn) -> Bool {
        links.contains { $0 === c } || candidates.contains { $0 === c }
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

    /// an alle Verbindungen, die den Modus kennen; der Filter (Modus je Verbindung) entscheidet, was hinausgeht
    func send(_ m: PairMessage) {
        for c in links { sendTo(c, m) }
    }

    private func sendTo(_ c: PairConn, _ m: PairMessage) {
        guard let mode = c.mode, let out = PairFilter.filtered(m, mode: mode), c.nw.state == .ready,
              let frame = try? c.chan?.seal(out.json()) else { return }
        write(frame, to: c.nw)
    }

    /// Nachricht ohne Filter (nur `mode`, vor dem Austausch der Modi)
    private func writeRaw(_ m: PairMessage, to c: PairConn) {
        guard c.nw.state == .ready, let frame = try? c.chan?.seal(m.json()) else { return }
        write(frame, to: c.nw)
    }

    /// Kopplung starten (Taste „Als … koppeln“, E2E `pair-start`): Partner `name`, nil = der erste gefundene
    @discardableResult
    func startPairing(with name: String?, mode: PairMode = .session) -> Bool {
        guard setup.on, pairing == nil, mode != .off else { return false }
        if let r = PairPeers.refusal(for: mode, id: "", in: peers) {
            say(Self.refusalText(r))
            return false
        }
        pairing = PairingState(peer: name, code: nil, confirmed: false, mode: mode)
        candidates.filter { $0.chan == nil && $0.nw.state == .ready }.forEach { beginRun($0) }
        browse()
        return true
    }

    static func refusalText(_ r: PairPeers.Refusal) -> String {
        switch r {
        case .sessionTaken: String(localized: "Zwei-Mac: der Session-Partner ist schon gekoppelt (nur einer)")
        case .groupFull: String(localized: "Zwei-Mac: die B2B-Gruppe ist voll (höchstens 8 Macs)")
        }
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

    /// Kopplung aufheben (Modus „aus“ lässt die Kopplung stehen): Schlüssel weg, Verbindung ab
    func unpair(_ id: String? = nil) {
        guard let target = id ?? peers.first(where: { $0.mode == .session })?.id ?? peers.first?.id,
              let p = peers.first(where: { $0.id == target }) else { return }
        PairKeychain.remove(p.id)
        peers.removeAll { $0.id == p.id }
        PairedPeerStore.save(peers)
        links.first { $0.id == p.id }?.nw.cancel()
        say(String(localized: "Kopplung aufgehoben"), .info)
        refresh()
    }

    /// Modus eines gekoppelten Macs ändern (Session höchstens einmal, B2B höchstens 7). Eine bestehende Verbindung
    /// geht dafür kurz ab und baut sich mit dem neuen Modus wieder auf
    @discardableResult
    func setMode(_ mode: PairMode, for id: String) -> Bool {
        guard let list = PairPeers.setting(mode, id: id, in: peers) else {
            if let r = PairPeers.refusal(for: mode, id: id, in: peers) { say(Self.refusalText(r)) }
            return false
        }
        peers = list
        PairedPeerStore.save(list)
        if let c = links.first(where: { $0.id == id }) {
            c.nw.cancel()
        }
        refresh()
        retryIfIdle()
        return true
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

    /// beide Seiten haben bestätigt: Schlüssel speichern, Mac in die Liste (mit Modus); die Verbindung geht danach sauber zu
    private func finishIfConfirmed(_ c: PairConn) -> Bool {
        guard c.localConfirmed, c.peerConfirmed, let sas = c.sas, let id = c.peerID, let name = c.peerName else { return true }
        let mode = pairing?.mode ?? .session
        guard let list = PairPeers.adding(PairedPeer(id: id, name: name, mode: mode), to: peers) else {
            let text = Self.refusalText(PairPeers.refusal(for: mode, id: id, in: peers) ?? .groupFull)
            say(text)
            pairing = nil
            closeAfterSending(c.nw, .pairReject)
            return true
        }
        PairKeychain.set(sas.key, for: id)
        peers = list
        PairedPeerStore.save(list)
        pairing = nil
        say(String(localized: "Gekoppelt mit \(name)"), .info)
        closeAfterSending(c.nw, nil)
        refresh()
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
        if c.promoted { handle(m, from: c) } else { c.pending.append(m) }
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

    /// Nachricht von einem verbundenen Mac; der Modus der Verbindung lässt nur Zulässiges durch
    private func handle(_ m: PairMessage, from c: PairConn) {
        if case let .mode(theirs) = m { acceptMode(theirs, c); return }
        guard let mode = c.mode, PairFilter.allows(m, mode: mode), let history else { return }
        switch m {
        case .mode:
            break
        case let .hello(writes, decks, version, name, played):
            c.name = name
            c.writes = writes
            c.decks = decks
            if version != PairMessage.version {
                StatusCenter.post(.error, String(localized: "Zwei-Mac: \(name) hat eine andere Version – beide Macs auf denselben Stand bringen"), key: "pair")
            }
            guard mode == .session else { refresh(); return }
            // beide schreiben: der Mac mit dem größeren Namen gibt ab (danach Schalter oben)
            if writes, setup.writes, Self.computerName > name { mix?.prefs.ui.pair.writes = false }
            report()
            if setup.writes {
                let s = PairPlayed.merged(history.played, Set(played))
                history.applyPlayed(s)
                send(.playedSet(s.sorted()))
            }
            if let mix, mix.live { sendTo(c, .live(true)) }
            applyTakt()
        case let .debugRequest(id, command, args):
            if let mix {
                let r = PairDebugResponder.answer(command: command, args: args, mix: mix, allowed: setup.remoteDebug)
                sendTo(c, .debugReply(id: id, ok: r.ok, body: r.body))
            }
        case let .debugReply(id, ok, body):
            PairDebug.shared.received(id: id, ok: ok, body: body)
        case let .clock(playing, _):
            guard mode == .session else { return }
            c.playing = playing
            applyTakt()
        case let .tempo(bpm):
            c.bpm = bpm
            refresh()
        case let .lead(lamport, holder):
            guard lead.accept(lamport: lamport, holder: holder) else { return }
            // weitergeben: der Anspruch erreicht auch Macs, die nur über einen anderen Mac verbunden sind
            for o in links where o !== c { sendTo(o, .lead(lamport: lamport, holder: holder)) }
            applyTakt()
        case let .state(writes, decks):
            c.writes = writes
            c.decks = decks
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

    /// Modus des anderen Macs: wirksam ist der strengere; danach Hello, Führung und Takt
    private func acceptMode(_ theirs: PairMode, _ c: PairConn) {
        guard c.peerMode == nil else { return }
        c.peerMode = theirs
        guard let mode = c.mode, mode != .off else {
            closeAfterSending(c.nw, nil)
            return
        }
        sendTo(c, .hello(writes: setup.writes, decks: setup.decks, version: PairMessage.version,
                         name: Self.computerName, played: (history?.played ?? []).sorted()))
        sendTo(c, .lead(lamport: lead.lamport, holder: lead.holder ?? PairIdentity.id))
        c.sentClock = nil
        applyTakt()
        report()
    }

    /// Statusleiste: verbunden mit wem, wer schreibt, Probleme, Führung, ungekoppelte Link-Teilnehmer
    private func report() {
        let names = links.compactMap { $0.name }.sorted()
        var text = "", level = StatusMessage.Level.ok
        if let s = links.first(where: { $0.mode == .session }), let name = s.name {
            let problems = PairCheck.problems(ownWrites: setup.writes, ownDecks: setup.decks, peerWrites: s.writes, peerDecks: s.decks)
            let theirs = s.decks.map { deckLetters[$0] }.joined(separator: "/")
            text = String(localized: "Zwei-Mac: verbunden mit \(name) (Decks \(theirs))") + " · "
                + (setup.writes ? String(localized: "dieser Mac schreibt") : s.writes ? String(localized: "\(name) schreibt") : "")
            for q in problems {
                switch q {
                case .bothWrite: text += String(localized: "beide schreiben")
                case .noneWrites: text += String(localized: "kein Mac schreibt – Schalter SCHREIBT oben")
                case let .sharedDecks(d): text += " · " + String(localized: "Deck \(d.map { deckLetters[$0] }.joined(separator: "/")) auf beiden")
                }
            }
            if !problems.isEmpty { level = .warning }
        } else if !names.isEmpty {
            text = String(localized: "B2B-Gruppe: \(names.joined(separator: ", "))")
        } else {
            return
        }
        text += " · " + (leads ? String(localized: "TAKT: dieser Mac") : String(localized: "TAKT: \(holderName)"))
        StatusCenter.post(level, text, key: "pair")
    }

    var connected: Bool { links.contains { $0.mode == .session } }

    /// Stand des Session-Partners (Name, Schreiben, Decks); nil ohne Session-Verbindung
    var peer: (name: String, writes: Bool, decks: [Int])? {
        guard let s = links.first(where: { $0.mode == .session }), let name = s.name else { return nil }
        return (name, s.writes, s.decks)
    }

    /// LIVE an/aus an den anderen Mac (nur Session)
    func sendLive(_ on: Bool) { send(.live(on)) }

    /// Master-Deck spielt oder steht (Oberflächen-Takt, nur bei Änderung)
    func masterDeckChanged() { applyTakt() }

    /// Tempo dieses Macs hat sich geändert: an die Verbindungen (Leiste) und den Stand, nur bei spürbarer Änderung
    func tempoChanged(_ bpm: Double) {
        guard abs(bpm - lastTempo) > 0.005 else { return }
        lastTempo = bpm
        send(.tempo(bpm: bpm))
        refresh()
    }

    /// TAKT-Schalter: dieser Mac übernimmt die Führung der Gruppe (größerer Anspruch, alle Verbindungen erfahren es)
    func claimTakt() {
        guard setup.on, !links.isEmpty else { return }
        _ = lead.claim(by: PairIdentity.id)
        send(.lead(lamport: lead.lamport, holder: PairIdentity.id))
        applyTakt()
    }

    /// Takt: welche Rolle dieser Mac hat (PairLead), im Paar entscheidet PairTempo; Link folgt, solange ein anderer führt
    private func applyTakt() {
        guard setup.on, let mix else { dropTakt(); return }
        let was = leads
        let connected = Set(links.compactMap { $0.id })
        let session = links.first { $0.mode == .session }
        switch PairLead.role(own: PairIdentity.id, holder: lead.holder, partner: session?.id, connected: connected) {
        case .group:
            leads = true
        case .follow:
            leads = false
        case .pair:
            if let s = session {
                leads = PairTempo.leads(ownPlaying: mix.playingMaster, peerPlaying: s.playing,
                                        ownLeads: lead.holder == PairIdentity.id, peerLeads: lead.holder == s.id,
                                        ownName: Self.computerName, peerName: s.name ?? "")
            } else {
                leads = true
            }
        }
        // Folgen, solange ein anderer führt (Link trägt Tempo und Takt der Gruppe)
        mix.core.setLinkFollow(!leads && !links.isEmpty)
        mix.setTaktHere(leads)
        let clock = PairMessage.clock(playingMaster: mix.playingMaster, leader: leads)
        for c in links where c.mode == .session && c.sentClock != clock {
            c.sentClock = clock
            sendTo(c, clock)
        }
        refresh()
        if leads != was { report() }
    }

    /// Name des Führenden (Leiste, Statuszeile)
    var holderName: String {
        guard let h = lead.holder else { return Self.computerName }
        if h == PairIdentity.id { return Self.computerName }
        return links.first { $0.id == h }?.name ?? peers.first { $0.id == h }?.name ?? h
    }

    /// Leiste: dieser Mac, dann die verbundenen gekoppelten Macs (Name, Modus, Führung, Tempo)
    private func refresh() {
        var list = [PairPeerInfo(id: PairIdentity.id, name: Self.computerName, mode: nil, connected: true,
                                 leader: lead.holder == PairIdentity.id || (lead.holder == nil && leads),
                                 bpm: mix?.clockBPMShown)]
        for c in links {
            guard let id = c.id, let name = c.name, let mode = c.mode else { continue }
            list.append(PairPeerInfo(id: id, name: name, mode: mode, connected: true, leader: lead.holder == id,
                                     bpm: c.bpm))
        }
        if info != list { info = list }
    }

    /// ohne Verbindung (oder Zwei-Mac aus) führt dieser Mac Link wie bisher
    private func dropTakt() {
        leads = true
        mix?.core.setLinkFollow(false)
        mix?.setTaktHere(true)
        refresh()
    }
}

/// Anzeige eines Macs in der Leiste (dieser Mac: mode nil)
struct PairPeerInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let mode: PairMode?
    let connected: Bool
    let leader: Bool
    let bpm: Double?
}

/// Eine Verbindung zu einem gekoppelten Mac; `dialed` = Name des Treffers, wenn wir sie aufgebaut haben (nil: eingehend).
/// Modus: der eigene (aus den Kopplungen) und der des anderen; wirksam ist der strengere, erst nach dem Austausch
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
    var promoted = false
    /// Kennung und Name des Macs (ab Kopplung), eigener und des anderen Modus
    var id: String?
    var name: String?
    var localMode: PairMode = .session
    var peerMode: PairMode?
    /// Stand des anderen Macs (nach hello / state / clock / tempo)
    var writes = false
    var decks: [Int] = []
    var playing = false
    var bpm: Double?
    var sentClock: PairMessage?
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

    /// wirksamer Modus; nil bis der andere seinen Modus geschickt hat
    var mode: PairMode? { peerMode.map { PairMode.effective($0, localMode) } }
}

/// Kopplung in Arbeit: Partner (Name, nil = der erste gefundene), Vergleichszahl sobald festgelegt, Modus
struct PairingState: Equatable {
    var peer: String?
    var code: String?
    var confirmed: Bool
    var mode: PairMode = .session
}
