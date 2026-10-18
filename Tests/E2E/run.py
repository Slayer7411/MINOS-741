#!/usr/bin/env python3
"""Ende-zu-Ende-Läufer für MINOS-741 (Beschreibung: Tests/E2E/README.md).

Aufruf (über scripts/e2e.sh):  python3 -I Tests/E2E/run.py [--list] [szenario …]
Umgebung: E2E_BIN (App-Binary, Pflicht), E2E_OUT (Ausgabe bei Fehlern), E2E_KEEP=1 (Ordner nie löschen).
Jede Instanz bekommt einen eigenen Ordner (Collection, Datenordner, Cache, Steuerung), eine eigene UserDefaults-Suite
und eine eigene Bonjour-Art dieses Laufs. Die Steuerung läuft über Ordnerpost (Tests/E2E/README.md).
"""
import datetime
import glob
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "fixtures"))
import build_fixture  # noqa: E402  (Tests/E2E/fixtures/build_fixture.py)

SCEN_DIR = os.path.join(HERE, "scenarios")
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
# Update-Szenario: die „installierte“ App und die Version, die sie per Update ersetzt (Tests/E2E/README.md)
INSTALLED = ("0.0.1", "e2e-old", "2026-10-01T00:00:00Z")
UPDATED_VERSION = "0.0.2"
MISSING = object()
READ_ONLY = {"ping", "snapshot", "list", "prefs-get", "status", "wait-ready", "setup-state", "crash-state"}
DEFAULT_TIMEOUT = 20.0


class Fail(Exception):
    pass


class Adopted:
    """App, die der Update-Helfer gestartet hat (kein Kind dieses Läufers): Ende über die PID"""

    def __init__(self, pid):
        self.pid = pid
        self.returncode = None

    def poll(self):
        if self.returncode is None:
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                self.returncode = 0
            except PermissionError:
                pass
        return self.returncode

    def wait(self, timeout=None):
        end = time.time() + (timeout if timeout is not None else 1e9)
        while self.poll() is None:
            if time.time() >= end:
                raise subprocess.TimeoutExpired(str(self.pid), timeout)
            time.sleep(0.1)
        return self.returncode


def make_bundle(app, binary, version, build, date):
    """App-Paket wie scripts/make-app.sh (ohne Icon): Programm, Helfer, Ressourcen, Info.plist, ad hoc signiert"""
    shutil.rmtree(app, ignore_errors=True)
    macos = os.path.join(app, "Contents", "MacOS")
    os.makedirs(macos)
    shutil.copy2(binary, os.path.join(macos, "MINOS-741"))
    shutil.copy2(os.path.join(os.path.dirname(binary), "minos-files"), os.path.join(macos, "minos-files"))
    res = os.path.join(app, "Contents", "Resources")
    shutil.copytree(os.path.join(REPO, "Sources", "MixApp", "Resources"), os.path.join(res, "Resources"))
    shutil.copytree(os.path.join(REPO, "Localization"), res, dirs_exist_ok=True)
    info = {"CFBundleName": "MINOS-741", "CFBundleDisplayName": "MINOS-741",
            "CFBundleIdentifier": "com.github.slayer7411.minos741", "CFBundleDevelopmentRegion": "de",
            "CFBundleLocalizations": ["de", "en"], "CFBundleExecutable": "MINOS-741", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": build, "MINOSBuildDate": date,
            "LSMinimumSystemVersion": "15.0", "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True}
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    subprocess.run(["codesign", "--force", "--sign", "-", app], check=True, capture_output=True)


def make_update_package(root, binary, updates):
    """DMG + latest.json für die neue Version in `updates` (wie scripts/make-dmg.sh --publish); Rückgabe: Build"""
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build = "e2e-new-" + secrets.token_hex(2)
    stage = os.path.join(root, "build-new")
    make_bundle(os.path.join(stage, "MINOS-741.app"), binary, UPDATED_VERSION, build, now)
    os.makedirs(updates, exist_ok=True)
    pack = os.path.join(root, "pack.dmg")
    subprocess.run(["hdiutil", "create", "-volname", "MINOS-741 e2e", "-srcfolder", stage, "-ov", "-format", "UDZO", pack],
                   check=True, capture_output=True)
    name = f"MINOS-741-{UPDATED_VERSION}-{build}.dmg"
    h = hashlib.sha256()
    with open(pack, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    # erst .part, dann umbenennen; Manifest atomar (wie make-dmg.sh)
    shutil.copy2(pack, os.path.join(updates, name + ".part"))
    os.replace(os.path.join(updates, name + ".part"), os.path.join(updates, name))
    manifest = {"version": UPDATED_VERSION, "build": build, "file": name, "sha256": h.hexdigest(),
                "size": os.path.getsize(pack), "date": now, "minSystem": "15.0"}
    with open(os.path.join(updates, "latest.json.tmp"), "w", encoding="utf-8") as f:
        json.dump(manifest, f)
    os.replace(os.path.join(updates, "latest.json.tmp"), os.path.join(updates, "latest.json"))
    return build


# MARK: Pfade und Werte

def resolve(path, data):
    """`body.decks.0.path` in verschachtelten dict/list-Werten; MISSING wenn nicht da.
    Schlüssel mit Punkt (z. B. `prefs.v1` in der plist) gehen vor: längster passender Schlüssel zuerst."""
    return _resolve(path.split("."), data)


def _resolve(parts, cur):
    if not parts:
        return cur
    if isinstance(cur, dict):
        for i in range(len(parts), 0, -1):
            key = ".".join(parts[:i])
            if key in cur:
                found = _resolve(parts[i:], cur[key])
                if found is not MISSING:
                    return found
        return MISSING
    if isinstance(cur, list):
        try:
            return _resolve(parts[1:], cur[int(parts[0])])
        except (ValueError, IndexError):
            return MISSING
    return MISSING


def check(value, op, expected):
    """eine Erwartung; Rückgabe: (ok, Text)"""
    if op == "exists":
        ok = (value is not MISSING) == bool(expected)
    elif value is MISSING:
        return False, "fehlt"
    elif op == "equals":
        # Wahrheitswerte nur mit Wahrheitswerten vergleichen (True == 1 gilt hier nicht)
        ok = (isinstance(value, bool) == isinstance(expected, bool)) and value == expected
    elif op == "not_equals":
        ok = value != expected
    elif op == "contains":
        ok = (expected in value) if isinstance(value, (str, list, dict)) else False
    elif op == "not_contains":
        ok = not ((expected in value) if isinstance(value, (str, list, dict)) else False)
    elif op in ("gt", "ge", "lt", "le"):
        try:
            v, e = float(value), float(expected)
        except (TypeError, ValueError):
            return False, f"keine Zahl: {value!r}"
        ok = {"gt": v > e, "ge": v >= e, "lt": v < e, "le": v <= e}[op]
    elif op == "startswith":
        ok = isinstance(value, str) and value.startswith(expected)
    elif op == "endswith":
        ok = isinstance(value, str) and value.endswith(expected)
    elif op == "matches":
        ok = isinstance(value, str) and re.search(expected, value) is not None
    else:
        raise Fail(f"unbekannte Erwartung: {op}")
    return ok, repr(value)[:300]


def ops_of(e):
    ops = [k for k in e if k not in ("path",)]
    if len(ops) != 1:
        raise Fail(f"Erwartung braucht genau eine Bedingung: {e}")
    return ops[0]


# MARK: Instanz

class Instance:
    def __init__(self, who, run_id, binary, base_dir, scenario_tag, music, extra_env=None, absent=False, fake_crash=False,
                 installed=False):
        self.who = who
        self.shared = os.path.join(base_dir, "shared")   # Portmeldungen des Laufs (Zwei-Mac-Verbindung)
        os.makedirs(self.shared, exist_ok=True)
        self.name = f"E2E-{who}-{run_id}"
        self.service = f"_m741e-{run_id}._tcp"
        self.binary = binary
        self.scenario = scenario_tag
        self.root = tempfile.mkdtemp(prefix=f"m741e2e-{who}-", dir=base_dir)
        self.proc = None
        self.launches = 0
        self.counter = 0
        self.logs = []
        self.extra_env = dict(extra_env or {})
        self.app = None
        # Collection und Datenordner gehören dieser Instanz; der Audio-Ordner ist für alle Instanzen gleich (nur lesen).
        # absent: keine Collection am Standardort (Erststart); die Fixture liegt unter <root>/fixture (für setup-choose)
        if absent:
            build_fixture.build(os.path.join(self.root, "fixture"), music)
        else:
            build_fixture.build(self.root, music)
        if fake_crash:
            build_fixture.write_fake_crash(self.root)
        for sub in ("control/outbox", "control/inbox", "appsupport", "logs", "shots", "music"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        if installed:
            # „installierte“ App im Testordner: nur diese Kopie darf ein Update ersetzen (MIX741_E2E_APP)
            self.app = os.path.join(self.root, "apps", "installed", "MINOS-741.app")
            make_bundle(self.app, binary, *INSTALLED)
            self.binary = os.path.join(self.app, "Contents", "MacOS", "MINOS-741")

    @property
    def control(self):
        return os.path.join(self.root, "control")

    @property
    def suite(self):
        safe = "".join(c if c.isalnum() or c == "-" else "-" for c in self.name)
        return "com.github.slayer7411.minos741.e2e." + safe

    def env(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("MIX741_")}
        # Einrichtung (Sheet) aus, außer ein Szenario verlangt sie (MIX741_SETUP=on)
        env.update({"MIX741_E2E_ROOT": self.root, "MIX741_E2E_NAME": self.name, "MIX741_E2E_SERVICE": self.service,
                    "MIX741_E2E_SHARED": self.shared, "MIX741_SETUP": "off"})
        env.update(self.extra_env)
        if self.app:
            env["MIX741_E2E_APP"] = self.app
        return env

    def start(self):
        self.launches += 1
        logf = os.path.join(self.root, "logs", f"app-{self.launches}.log")
        out = open(logf, "wb")
        self.proc = subprocess.Popen([self.binary], env=self.env(), cwd=self.root, stdout=out, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        out.close()
        self.logs.append(logf)

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def kill(self):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            try:
                if isinstance(self.proc, Adopted):
                    os.kill(self.proc.pid, signal.SIGKILL)
                else:
                    os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    def request(self, command, args=None, timeout=DEFAULT_TIMEOUT):
        """eine Anfrage über die Ordnerpost; Rückgabe: Antwort-Dict {ok, command, body, ...}"""
        self.counter += 1
        token = f"{self.who}-{self.counter:04d}-{command}-{secrets.token_hex(3)}"
        outbox = os.path.join(self.control, "outbox")
        tmp = os.path.join(outbox, f".{token}.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"command": command, "args": args or {}, "token": token}, f)
        os.replace(tmp, os.path.join(outbox, f"{token}.json"))
        reply = os.path.join(self.control, "inbox", f"{token}.json")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(reply):
                with open(reply, encoding="utf-8") as f:
                    data = json.load(f)
                os.remove(reply)
                return data
            if self.proc is not None and self.proc.poll() is not None:
                return {"ok": False, "command": command, "body": f"App beendet (Code {self.proc.returncode})"}
            time.sleep(0.1)
        # Anfrage zurücknehmen, damit sie nicht später noch läuft
        try:
            os.remove(os.path.join(outbox, f"{token}.json"))
        except FileNotFoundError:
            pass
        return {"ok": False, "command": command, "body": f"keine Antwort innerhalb {timeout:.0f} s"}

    def relaunch(self, timeout=60.0):
        """Nach einem Update: die alte App ist beendet, der Helfer hat die neue gestartet. Die neue Instanz wird über
        ihre PID aus `ping` verfolgt (kein Kind dieses Läufers)."""
        old = self.proc
        if old is None:
            raise Fail(f"{self.who}: keine App zum Ersetzen")
        try:
            old.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Fail(f"{self.who}: alte App beendet nicht innerhalb {timeout:.0f} s")
        self.proc = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            reply = self.request("ping", timeout=3)
            if reply.get("ok") and isinstance(reply.get("body"), dict):
                self.proc = Adopted(int(reply["body"]["pid"]))
                return reply
            time.sleep(0.3)
        raise Fail(f"{self.who}: neue App antwortet nicht nach dem Neustart (Log: {os.path.join(self.root, 'logs', 'update.log')})")

    def wait_ready(self, timeout=60.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            if not self.alive():
                raise Fail(f"{self.who}: App beendet vor dem Start (Log: {self.logs[-1]})")
            last = self.request("ping", timeout=3)
            if last.get("ok"):
                return last
            time.sleep(0.3)
        raise Fail(f"{self.who}: Steuerung antwortet nicht ({last})")

    def stop_clean(self, timeout=25.0):
        """Beenden über die Steuerung (Sitzung, Einstellungen), sonst hart"""
        if not self.alive():
            return "beendet"
        self.request("quit", timeout=5)
        try:
            self.proc.wait(timeout=timeout)
            return "sauber"
        except subprocess.TimeoutExpired:
            self.kill()
            return "abgeschossen"


# MARK: Szenario

class Scenario:
    def __init__(self, path, base_dir, binary, run_id, out_dir, keep):
        with open(path, encoding="utf-8") as f:
            self.spec = json.load(f)
        self.path = path
        self.name = self.spec.get("name") or os.path.splitext(os.path.basename(path))[0]
        self.base_dir = base_dir
        self.binary = binary
        self.run_id = run_id
        self.out_dir = out_dir
        self.keep = keep
        self.instances = {}
        self.vars = {}
        self.music = os.path.join(base_dir, "fixture-music")
        self.detail = ""
        self.steps_done = 0
        self.steps_total = len(self.spec.get("steps", []))

    def expand(self, value, who=None):
        """${key:datei} (Schlüssel im Audio-Ordner des Laufs), ${root}, ${root:A}, ${name:A}, ${var}"""
        if isinstance(value, dict):
            return {k: self.expand(v, who) for k, v in value.items()}
        if isinstance(value, list):
            return [self.expand(v, who) for v in value]
        if not isinstance(value, str):
            return value

        def sub(m):
            k = m.group(1)
            if k.startswith("key:"):
                return build_fixture.track_key(self.music, k[4:])
            if k == "root" or k.startswith("root:"):
                inst = self.inst(k[5:] or who)
                return inst.root
            if k.startswith("name:"):
                return self.inst(k[5:]).name
            if k == "music":
                return os.path.join(self.inst(who).root, "music")
            if k in self.vars:
                return str(self.vars[k])
            raise Fail(f"unbekannte Variable: ${{{k}}}")
        return re.sub(r"\$\{([^}]+)\}", sub, value)

    def inst(self, who):
        who = who or "A"
        if who not in self.instances:
            raise Fail(f"Instanz {who} nicht gestartet (Szenario: instances)")
        return self.instances[who]

    def run(self):
        t0 = time.time()
        ok = True
        try:
            build_fixture.write_audio(self.music)
            # Szenario-Optionen: "env" (für alle Instanzen), "collection": "absent" (ohne Collection am Standardort)
            extra_env = self.spec.get("env", {})
            absent = self.spec.get("collection") == "absent"
            fake_crash = bool(self.spec.get("fake_crash"))
            update = bool(self.spec.get("update"))
            for who in self.spec.get("instances", ["A"]):
                self.instances[who] = Instance(who, self.run_id, self.binary, self.base_dir, self.name, self.music,
                                               extra_env=extra_env, absent=absent, fake_crash=fake_crash, installed=update)
            if update:
                inst = self.inst("A")
                self.vars["installed_version"], self.vars["installed_build"] = INSTALLED[0], INSTALLED[1]
                self.vars["update_version"] = UPDATED_VERSION
                self.vars["update_build"] = make_update_package(inst.root, self.binary, os.path.join(inst.root, "updates"))
            for inst in self.instances.values():
                inst.start()
            for inst in self.instances.values():
                inst.wait_ready()
            for i, step in enumerate(self.spec.get("steps", []), 1):
                self.step(i, step)
                self.steps_done += 1
        except Fail as e:
            ok = False
            self.detail = self.detail or str(e)
        except Exception as e:  # noqa: BLE001 – Fehler im Läufer sind Fehler des Szenarios
            ok = False
            self.detail = self.detail or f"Läufer: {type(e).__name__}: {e}"
        finally:
            if not ok:
                self.collect_failure()
            for inst in self.instances.values():
                inst.stop_clean()
                inst.kill()
            for inst in self.instances.values():
                suite_cleanup(inst.suite)
                if ok and not self.keep:
                    shutil.rmtree(inst.root, ignore_errors=True)
        return ok, time.time() - t0

    def collect_failure(self):
        dst = os.path.join(self.out_dir, self.name)
        os.makedirs(dst, exist_ok=True)
        for who, inst in self.instances.items():
            try:
                if inst.alive():
                    inst.request("shot", {"path": os.path.join(inst.root, "shots", f"fehler-{who}.png")}, timeout=10)
            except Exception:  # noqa: BLE001
                pass
            target = os.path.join(dst, who)
            shutil.copytree(inst.root, target, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("*.wav", "outbox", "inbox"))
        with open(os.path.join(dst, "szenario.txt"), "w", encoding="utf-8") as f:
            f.write(f"{self.name}\n{self.detail}\nschritte: {self.steps_done}/{self.steps_total}\n")

    def step(self, index, step):
        kind = step.get("do")
        who = step.get("who", "A")
        label = f"Schritt {index} [{who} {kind}]"
        if kind == "sleep":
            time.sleep(float(step.get("seconds", 1)))
            return
        if kind == "restart":
            inst = self.inst(who)
            how = inst.stop_clean()
            inst.start()
            inst.wait_ready()
            self.vars[f"restart_{who}"] = how
            return
        if kind == "plist":
            return self.plist_step(index, who, step)
        if kind == "relaunch":
            inst = self.inst(who)
            try:
                reply = inst.relaunch(float(step.get("timeout", 60)))
            except Fail as e:
                raise Fail(f"Schritt {index} [{who} relaunch]: {e}")
            self.last_reply = reply
            return
        if kind == "file-check":
            return self.file_step(index, who, step)
        if kind == "quit":
            # Beenden über die Steuerung; wie es endete, prüft der Schritt (Standard: sauber)
            how = self.inst(who).stop_clean()
            if how != step.get("exit", "sauber"):
                raise Fail(f"Schritt {index} [{who} quit]: Ende {how!r}, erwartet {step.get('exit', 'sauber')!r}")
            return
        if kind == "forget-settings":
            # Datenordner bleibt, Einstellungs-Domäne (Suite) wird gelöscht: nächster Start liest settings.plist
            suite_cleanup(self.inst(who).suite)
            return
        args = self.expand(step.get("args", {}), who)
        if kind == "store-var":
            self.vars[step["name"]] = self.expand(step["value"], who)
            return
        inst = self.inst(who)
        timeout = float(step.get("timeout", DEFAULT_TIMEOUT))
        expects = step.get("expect", [])
        expect_ok = step.get("expect_ok", True)
        retry = step.get("retry", kind in READ_ONLY)
        deadline = time.time() + timeout
        reply, why = None, ""
        while True:
            reply = inst.request(kind, args, timeout=min(timeout, 30))
            ok_text = ""
            passed = bool(reply.get("ok")) == bool(expect_ok)
            if not passed:
                ok_text = f"ok={reply.get('ok')} body={json.dumps(reply.get('body'), ensure_ascii=False)[:300]}"
            for e in expects:
                e = self.expand(e, who)
                op = ops_of(e)
                good, text = check(resolve(e["path"], reply), op, e[op])
                if not good:
                    passed = False
                    ok_text = f"{e['path']} {op} {e[op]!r}: erhalten {text}"
                    break
            if passed:
                break
            if not retry or time.time() >= deadline:
                why = ok_text or "unbekannter Fehler"
                break
            time.sleep(0.25)
        if why:
            self.detail = f"{label}: {why}"
            raise Fail(self.detail)
        for name, path in step.get("save", {}).items():
            value = resolve(path, reply)
            if value is MISSING:
                raise Fail(f"{label}: save {name}: {path} fehlt")
            self.vars[name] = value
        if step.get("log"):
            # Messung: die Antwort mit Zeitpunkt ausgeben (Ausgabe des Laufs, nicht des Szenarios)
            print(f"[log] {time.strftime('%H:%M:%S')} {label}: {json.dumps(reply.get('body'), ensure_ascii=False)}", flush=True)
        self.last_reply = reply

    def file_step(self, index, who, step):
        """Datei da (exists) oder nicht; `contains`: Text kommt in der Datei vor"""
        label = f"Schritt {index} [{who} file-check]"
        path = self.expand(step["path"], who)
        present = os.path.exists(path)
        if present != step.get("exists", True):
            self.detail = f"{label}: {path} {'fehlt' if step.get('exists', True) else 'ist vorhanden'}"
            raise Fail(self.detail)
        if "contains" in step and present:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            needle = self.expand(step["contains"], who)
            if needle not in text:
                self.detail = f"{label}: {needle!r} steht nicht in {path}"
                raise Fail(self.detail)

    def plist_step(self, index, who, step):
        label = f"Schritt {index} [{who} plist]"
        path = self.expand(step["file"], who)
        deadline = time.time() + float(step.get("timeout", DEFAULT_TIMEOUT))
        last = "Datei fehlt"
        while True:
            if os.path.exists(path):
                with open(path, "rb") as f:
                    data = plistlib.load(f)
                # Einstellungen liegen als JSON-Daten im Schlüssel prefs.v1
                if isinstance(data.get("prefs.v1"), bytes):
                    data["prefs.v1"] = json.loads(data["prefs.v1"].decode("utf-8"))
                bad = None
                for e in step.get("expect", []):
                    e = self.expand(e, who)
                    op = ops_of(e)
                    good, text = check(resolve(e["path"], data), op, e[op])
                    if not good:
                        bad = f"{e['path']} {op} {e[op]!r}: erhalten {text}"
                        break
                if bad is None:
                    return
                last = bad
            if time.time() >= deadline:
                break
            time.sleep(0.25)
        self.detail = f"{label}: {last}"
        raise Fail(self.detail)


def build_fixture_dir(music):
    """NML-Schreibweise des Musikordners: /:tmp/:x/:music/:"""
    return build_fixture.dir_string(music + "/")


def suite_cleanup(suite):
    """Einstellungs-Domäne dieses Laufs entfernen (nie die Domäne der Hauptapp)"""
    if not suite.startswith("com.github.slayer7411.minos741.e2e."):
        return
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    try:
        os.remove(os.path.expanduser(f"~/Library/Preferences/{suite}.plist"))
    except FileNotFoundError:
        pass


# MARK: Lauf

def main(argv):
    if "--list" in argv:
        for p in sorted(glob.glob(os.path.join(SCEN_DIR, "*.json"))):
            print(os.path.basename(p)[:-5])
        return 0
    binary = os.environ.get("E2E_BIN", "")
    if not os.access(binary, os.X_OK):
        print(f"E2E_BIN fehlt oder nicht ausführbar: {binary!r}", file=sys.stderr)
        return 2
    names = [a for a in argv if not a.startswith("--")]
    paths = []
    if names:
        for n in names:
            if os.path.exists(n):
                paths.append(n)
                continue
            # Dateiname mit oder ohne Nummer und .json: `start-collection` findet `01-start-collection.json`
            stem = n[:-5] if n.endswith(".json") else n
            found = [p for p in sorted(glob.glob(os.path.join(SCEN_DIR, "*.json")))
                     if os.path.basename(p)[:-5] in (stem, stem.lstrip("0123456789-")) or os.path.basename(p)[:-5].endswith("-" + stem)]
            if len(found) != 1:
                print(f"Szenario {'fehlt' if not found else 'mehrdeutig'}: {n}", file=sys.stderr)
                return 2
            paths.append(found[0])
    else:
        paths = sorted(glob.glob(os.path.join(SCEN_DIR, "*.json")))
    out_dir = os.environ.get("E2E_OUT") or os.path.join(tempfile.gettempdir(), "minos741-e2e")
    keep = os.environ.get("E2E_KEEP") == "1"
    os.makedirs(out_dir, exist_ok=True)
    run_id = secrets.token_hex(3)
    base = tempfile.mkdtemp(prefix=f"m741e2e-run-{run_id}-")
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    print(f"E2E {stamp} · Binary {binary} · Lauf {run_id} · Ausgabe {out_dir}")
    results = []
    try:
        for p in paths:
            sc = Scenario(p, base, binary, run_id, out_dir, keep)
            ok, secs = sc.run()
            results.append((sc.name, ok, f"{sc.steps_done}/{sc.steps_total}", secs, sc.detail))
    finally:
        if not keep:
            shutil.rmtree(base, ignore_errors=True)
    width = max(len(r[0]) for r in results) if results else 10
    print()
    print(f"{'SZENARIO':<{width}}  {'ERGEBNIS':<8}  {'SCHRITTE':<8}  {'DAUER':>7}  DETAIL")
    for name, ok, steps, secs, detail in results:
        print(f"{name:<{width}}  {'PASS' if ok else 'FAIL':<8}  {steps:<8}  {secs:6.1f}s  {'' if ok else detail}")
    failed = [r for r in results if not r[1]]
    print()
    print(f"{len(results) - len(failed)} PASS, {len(failed)} FAIL" + (f" · Fehlerdaten: {out_dir}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
