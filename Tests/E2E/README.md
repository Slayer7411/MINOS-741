# End-to-end tests

Real app binary (`minos741`, debug build), real collection parsing, real file IO, real audio decoding, real
networking (Bonjour + TCP between instances). No mocks. The only deviation: the audio output is a **null output**
(no audio device is opened; the engine renders blocks in real time on a timer), so there is no sound.

Scenarios are JSON files. Each instance is driven through a command mailbox (folder based). Scenario authors
should only need this README.

## Run

```
scripts/e2e.sh                       # builds debug, runs all scenarios in Tests/E2E/scenarios
scripts/e2e.sh --no-build start-collection
scripts/e2e.sh --list                # scenario names
```

Environment:

| variable | meaning |
|---|---|
| `E2E_OUT` | where logs and screenshots of failed scenarios go (default `$TMPDIR/minos741-e2e`) |
| `E2E_KEEP=1` | keep the temporary instance folders (also for passing scenarios) |

The `self-update` scenario (`05-self-update.json`) builds its own app bundles and a DMG in the test root, so it needs no
network and never touches `/Applications` or the user's folders (see *Update* below).

Scenario names may be given as file stem, with or without the number prefix (`start-collection`, `01-start-collection`).
A scenario given as a path (`scripts/e2e.sh --no-build Tests/E2E/bench/soak-ui.json`) runs outside `scenarios/`. Measurements: `E2E_FIXTURE_SECONDS=60` makes the fixture tracks 60 s long; a step with `"log": true` prints its reply as `[log] HH:MM:SS …` on stdout.

Output: one row per scenario, `PASS` / `FAIL`, step count, duration, and on failure the first failing step with
the expected and the received value. Exit code 0 only if all pass.

On failure, `E2E_OUT/<scenario>/<instance>/` contains the whole instance folder (without audio files): collection,
`collection/MINOS-741/settings.plist`, `appsupport/`, `logs/app-N.log` (one per launch), `shots/fehler-<who>.png`
(main window, taken before the instance is stopped). `E2E_OUT/<scenario>/szenario.txt` holds the failing step.

## Isolation

Each instance runs with `MIX741_E2E_ROOT=<temp dir>`. Everything the app writes or reads for the collection goes
under that folder:

| what | where (per instance) |
|---|---|
| collection | `<root>/collection/collection.nml` (replaces `LibraryStore.defaultNML`, i.e. `~/Native Instruments/…`) |
| data folder (settings, History, Preparation, session, played, analysis) | `<root>/collection/MINOS-741/` (next to the collection, as in normal use) |
| Application Support (cache, overviews, pair-debug mailbox, plugin list) | `<root>/appsupport/` |
| caches (artwork, file service) | `<root>/caches/` |
| music folder (browser "folder" source default) | `<root>/music/` (empty; audio for the fixture is in a per-run folder shared read-only by all instances of one run) |
| UserDefaults | suite `com.github.slayer7411.minos741.e2e.<instance name>`, never the app's own domain |
| computer name (pairing) | `MIX741_E2E_NAME`, default `E2E-<who>-<run id>` |
| Bonjour type (pairing) | `MIX741_E2E_SERVICE`, `_m741e-<run id>._tcp`; never `_minos741._tcp`. Discovery is real Bonjour; the TCP leg goes to `127.0.0.1:<port>` (see *Pairing* below) |
| pairing port file | `<shared>/<name>.port` (`MIX741_E2E_SHARED`, one folder per run, shared by the instances of that run) |
| audio output | none opened: `CoreAudioOutput` renders to a timer; `outputDeviceID` is 0 |
| control mailbox | `<root>/control/` |
| macOS crash reports (`DiagnosticReports`) | `<root>/diagnostic-reports/` (never the user's `~/Library/Logs/DiagnosticReports`) |
| old settings of the user (migration from older app names) | not read (`AppResources.migrateDefaults` skips them in E2E) |

Two instances of one run share the audio folder and the pairing port folder only (same track keys, as two Macs with the
same collection). Nothing else is shared.

### Pairing

Two instances pair the way two Macs do: each advertises `_m741e-<run id>._tcp` with Bonjour and browses for the other.
Only the TCP leg differs. macOS does not deliver a connection to this Mac's own LAN address to its own listener (checked
with a standalone Network.framework program: outgoing reaches `ready`, the listener never fires). So in E2E mode the
dialing instance connects to `127.0.0.1:<port>` with a loopback-only parameter set, where `<port>` is the listener
port the partner wrote to `<shared>/<partner name>.port`. Protocol, hello, played marks, pair state and the
remote-debug channel are the unchanged app code.

Without `MIX741_E2E_ROOT` none of this applies: `E2E.defaults` is `.standard`, the service is `_minos741._tcp`, the
dial uses the Bonjour endpoint as before.

Not isolated (known, see *Limitations*):
- `~/Library/Preferences/com.github.slayer7411.minos741.e2e.*.plist`: the suite is a file in the user's Preferences
  folder. The runner deletes the suites it created (`defaults delete` + file removal) after each scenario. Only
  suites with this prefix are touched.
- Read-only lookups of the real machine: installed audio plug-ins (`~/Library/Audio/Plug-Ins`), Spotlight search
  for the explorer, the system's audio devices list (read for the output picker, never opened).
- The app process itself is a normal macOS GUI process; the window appears (it does not activate).
- The DAW bridge listens on its fixed port (7.411). A second instance logs `DAW-Brücke: Port 7.411 belegt` and runs
  without the bridge. A DAW bridge already running on the machine is not affected.

## Command reference

Commands are sent as `control/outbox/<token>.json`:

```json
{"command": "snapshot", "args": {}, "token": "…"}
```

Replies appear as `control/inbox/<token>.json` (written atomically, so a file that exists is complete):

```json
{"ok": true, "command": "snapshot", "token": "…", "body": { … }, "at": "2026-…"}
```

`ok` false means the command was refused or timed out. `body` is then a plain string (reason, e.g.
`"unbekannter Befehl: x"`, `"kein Hauptfenster"`), or `{"fehler": "…"}` for a wait that timed out (`wait-ready`,
`analyze`). A `set-prefs` refusal is a string too (`"unbekannte Schlüssel: …"`). Scenarios see the reply as the object
above, so expectation paths start with `ok` or `body.`. Read-only commands
(`ping`, `snapshot`, `list`, `prefs-get`, `status`, `wait-ready`) are re-sent until expectations pass; mutating
commands are sent once (see `retry` below).

Track keys are NML keys (`E2E/:…/:music/:t01.wav`). Scenarios write them as `${key:t01.wav}`.

| command | args | reply `body` |
|---|---|---|
| `ping` | – | `{name, root, build, pid, uptime}` |
| `wait-ready` | `timeout` (s, default 60) | `{tracks}` once the collection is loaded; `{fehler}` after the timeout |
| `snapshot` | – | see below |
| `select-source` | `pane` (0 = A, default 0), `source` | `{pane, source}`; sources: `collection`, `preparation`, `history`, `playlist:<name>`, `smartlist:<name>` (also smartlists inside folders), `folder:<abs path>`, `explorer:<abs path>` |
| `search` | `pane`, `text` | `{pane, search}` |
| `list` | `pane` | `{count, rows: [{index, key, artist, title, bpm, keyText, played}]}`: rows of the pane as shown (hide-played applied) |
| `load` | `deck` (0–3), `key` or `index` (into the pane's rows), `force` | `{deck, key, accepted}`; `accepted` false when the deck refuses (e.g. playing) |
| `play` / `pause` | `deck` | `{deck, playing}`; idempotent |
| `sync` | `deck`, `on` (default true) | `{deck, sync}` |
| `master` | `deck` | `{deck, master}`: makes the deck the master (no-op if it already is) |
| `set-prefs` | JSON object, deep-merged into the app's preferences (same as `scripts/pairdebug.sh prefs-set`) | the merged preferences |
| `prefs-get` | – | the preferences |
| `status` | – | recent status messages |
| `ui-stats` | optional `reset` (true: the count up to now is returned, then counting restarts) | `{ticks, over16, over50, maxMs, pid}`: main-thread gaps between two 120 Hz ticks (> 16 ms, > 50 ms), longest gap (ms). Every gap over 50 ms is also written to the status log (`status-log.txt`, info level, "Hänger Hauptthread N ms") |
| `link` | optional `on` (true/false; absent: toggle) | `{linkEnabled}` (state before the change is applied on the next tick) |
| `analyze` | `keys` (list), `timeout` (s, default 180) | `{results: [{key, bpm, musicalKey}]}` once all are analysed (`bpm`/`musicalKey` null if not stored); `{fehler}` after the timeout |
| `add-to-playlist` | `playlist` (name of an own playlist; created if missing), `keys` | `{playlist, keys}` |
| `collection-playlist-add` | `playlist` (name of a playlist of the collection file), `keys` | `{playlist, keys}`: the tracks go to the end of that playlist in `collection.nml` (backup first, needs `ui.writeCollection`, refused while the collection software runs); the write runs after the reply, so check the file with `file-check` after a `sleep` |
| `mark-played` | `keys` | `{played}` (count); propagates to the paired instance |
| `reset-played` | optional `keys` (all if absent) | `{played}` |
| `shot` | `path` (PNG) | `{path, width, height}` of the main window (pixels) |
| `quit` | – | `{quitting: true}`, then the normal quit path (session, settings export); the runner waits for exit (step `quit`) |
| `setup-state` | – | `{shown, step, checked, reasons, firstLaunch, suppressed, collectionFound, collection, chosen, loaded, tracks}`: Einrichtung (Sheet) und Gründe beim Start |
| `setup-step` | `step`: collection, music, audio, network, done | the same, after opening the sheet at that step (also when suppressed) |
| `setup-choose` | `path` (collection file) | the same; stores `ui.collectionPath`, loads the collection |
| `setup-close` | – | the same, after closing the sheet (saves the settings) |
| `crash-state` | – | `{shown, count, file, title, text, opened, askAfterCrash, folderSet}`: Absturz-Sheet (`text` is the public, redacted report) |
| `crash-open` | – | the same, after the GitHub issue action: the address goes to `opened`, never to the browser |
| `crash-close` | – | the same, after closing the sheet |
| `update-check` | – | `{build, available: {version, build, file}\|null}`; checks the channel now (folder channel in the test: `updateChannel` folder, `updateFolder` in the root). The network channels are off in the test run |
| `update-install` | – | `{relaunch, build, version, to}` once the helper is started; the app then quits (the runner follows the new process, step `relaunch`). Refused while a deck plays, LIVE is on or a recording runs |
| `update-rollback` | – | `{relaunch, rollback, to}`: back to `.MINOS-741-previous.app`, same restart |
| `window` | `id`: `about`, `manual`, `shortcuts`, `log`, `backups` | `{recorded}`: the windows asked for so far. Nothing is shown in E2E (`BasicWindows`) |
| `issue` | – | `{opened}`: the bug-report address (`Fehler melden`), recorded only (`CrashLinks`), never in the browser |
| `backup-list` | – | `{backups: [{name, tracks, bytes}]}` of the collection's `Backup MINOS-741` folder, newest first |
| `backup-now` | – | `{name}`: backup of the current collection now (no minimum interval) |
| `backup-restore` | `name` (of `backup-list`) | `{ok, message, tracks}`: same path as the menu (`CollectionRestore`), without the confirmation dialog |
| `drag` | – | **not wired**: drops arrive as window/AppKit drag events, not reachable from the mailbox. Use `load` and `add-to-playlist` |

`snapshot` body (keys used by the scenarios; the rest is the same as `scripts/pairdebug.sh snapshot`):

- `name`, `build`, `pair` (`{on, writes, decks, connected, peer: {name, writes, decks}|null, service}`)
- `library`: `{tracks, playlists, smartlists, folders (all levels), collection (path), loaded}`
- `browser`: array of two panes `{source, search, selection, rows}`
- `decks`: array of four `{letter, visible, artist, title, key, path, trackBPM, bpm, pitchPct, ratePct, playing, sync, master, position, duration, keylock}`
- `output`: `{e2e: true, deviceID: 0, running, rate}`
- `audio`: `{device, deviceUID, sampleRate, coreRate, bufferSize, mixerMode, running}` (device fields show the configured device, not the null output)
- `clock`, `focusedDeck`, `prefs`
- `played`: `{count, keys}`
- `paths`: `{root, settings, dataDir, suite}`

## Scenario format

File `Tests/E2E/scenarios/NN-name.json`:

```json
{
  "name": "load-play",
  "description": "one line, what it proves",
  "instances": ["A"],
  "steps": [
    {"do": "load", "args": {"deck": 0, "key": "${key:t01.wav}"}, "expect": [{"path": "body.accepted", "equals": true}]},
    {"do": "snapshot", "timeout": 20, "expect": [{"path": "body.decks.0.trackBPM", "equals": 120.0}]},
    {"do": "snapshot", "save": {"pos1": "body.decks.0.position"}},
    {"do": "sleep", "seconds": 1.0},
    {"do": "snapshot", "expect": [{"path": "body.decks.0.position", "gt": "${pos1}"}]}
  ]
}
```

- top-level `env`: environment variables for every instance of the scenario (on top of the defaults, e.g. `MIX741_SETUP`).
  The runner starts instances with `MIX741_SETUP=off` (no first-run sheet) unless the scenario says otherwise.
- top-level `collection`: `"absent"` = no collection at the default place (first start). The fixture then lies in
  `${root}/fixture/collection/collection.nml` (for `setup-choose`).
- top-level `fake_crash: true`: writes one fake `MINOS-741_…ips` into `${root}/diagnostic-reports` before the start
  (macOS report folder of the instance, see *Isolation*).
- `instances`: list of letters (`A`, `B`, …), default `["A"]`. All are started and wait for `ping` before the first
  step. Instance B's computer name is `${name:B}`.
- `do`: a command name from the table above, or a runner step:
  - `sleep` (`seconds`): wait in the runner.
  - `restart` (`who`): clean quit, start again with the same folder and suite, wait ready.
  - `quit` (`who`, `exit`: `sauber` default, or `abgeschossen`): quit through the mailbox, then check how it ended.
  - `forget-settings` (`who`): delete the instance's UserDefaults suite (the next start must read `settings.plist`).
  - `plist` (`file`, `expect`): read a plist; the `prefs.v1` key (JSON bytes) is decoded, so paths like
    `prefs.v1.ui.hidePlayedTracks` work. `file` may use `${root:A}`.
  - `store-var` (`name`, `value`): set a variable.
  - `relaunch` (`who`, `timeout`): after `update-install` / `update-rollback`: waits until the old process has exited, then follows the new one by its pid (from `ping`).
  - `file-check` (`path`, `exists` default true, `contains`): a file is there (or not), and optionally contains a text.
- `update: true` in a scenario: the instance runs as the "installed" app `<root>/apps/installed/MINOS-741.app` (`MIX741_E2E_APP`, an own bundle copy with its own build and date), and the runner writes a newer build as `updates/MINOS-741-<version>-<build>.dmg` plus `updates/latest.json` (sha-256, size, date). Variables `installed_build`, `update_build`, `update_version`.
- `who`: instance letter for the step, default `A`.
- `args`: the command arguments; strings may contain variables (below).
- `expect`: list of expectations, see below. A command step passes when `ok` equals `expect_ok` (default `true`)
  and every expectation holds. With `retry: true` (default for read-only commands) the command is re-sent until
  the step passes or `timeout` (s, default 20) expires. Otherwise it is sent once.
- `save`: `{"varname": "path"}` takes values from the reply after a passing step.
- `timeout`: seconds for the step (default 20).

Expectations: one operator per entry, with `path` (dotted, numbers index lists, the path starts at the reply:
`ok`, `body`, `command`):

| operator | meaning |
|---|---|
| `equals` | same value and same kind (bool vs number checked separately) |
| `not_equals` | |
| `contains` | string contains, or list/dict contains the value |
| `not_contains` | |
| `gt` `ge` `lt` `le` | numeric comparison |
| `startswith` `endswith` `matches` (regex) | strings |
| `exists` | true/false: the path is present |

Variables (in any string of `args` and `expect`):

- `${key:FILE}`: NML key of a fixture file, e.g. `${key:t01.wav}`
- `${root}` / `${root:A}`: folder of the instance
- `${name:A}`: computer name of an instance
- `${music}`: folder of the run's fixture audio (read-only)
- `${varname}`: saved value; numbers are inserted as text, so use them in `gt` and the like

Failures: the first failing step stops the scenario. Its message says which instance, which path, which operator
and the value received.

### Fixture

`Tests/E2E/fixtures/build_fixture.py` writes, per run, the audio files and per instance the collection (no binary
files in the repo). Contents:

- 10 tracks `t01.wav` … `t10.wav`: 8 s mono 22.05 kHz click tracks, click at each beat, first beat at `offset` s.
  Table in `TRACKS` of the script. `t01` Alpha "Kick One" 120 BPM (first click 0.25 s), grid cue at 250 ms, hot cue
  "Intro" at 2 s; `t06` two hot cues (1 s, 4 s); genre, comment and tags (RATING) set; musical keys set.
- playlists `Warmup` = t01, t04, t08; `Peak` = t03, t06, t10.
- smartlists `Techno Or Dark` (`$GENRE == "Techno" | $COMMENT % "dark"`, 5 tracks), `Fast 125` (`$BPM > 125`, 4 tracks)
  and `Not Ambient` (`!($GENRE == "Ambient")`, 9 tracks), the last two inside folder `Crates`.

Totals: 10 tracks, 2 playlists, 3 smartlists, 1 folder.

## Writing a scenario: checklist

- Start from the example scenarios in `Tests/E2E/scenarios/`.
- Get keys with `${key:…}`, not by hand.
- Add `retry` only for read-only commands, or for idempotent mutations (`play`, `pause`, `sync`, `master`).
- Never send `load` twice in a row; it reloads the deck.
- Use `snapshot` expectations after mutating commands: decks load and start asynchronously.
- Two instances: give each its own letter in `who`; shared state (played marks) must use keys from the same audio folder.

## Update (`self-update`)

`MIX741_E2E_APP` names the copy the update may replace; the app refuses any target outside the test root. The updater
only ever acts on that copy: it downloads/copies the DMG under `<root>/tmp`, checks size and sha-256, mounts it
(`hdiutil -nobrowse -readonly`), copies the app next to the old one, removes the quarantine flag, checks the bundle
version and `codesign --verify`, then a small bash helper waits for the old pid, swaps the bundles (the old one stays as
`.MINOS-741-previous.app`) and starts the new one directly with the test environment. Log: `<root>/logs/update.log`.

## Limitations

- **No sound.** The audio output is a null output on a timer (`CoreAudioOutput.startNull`). Decoding, rendering,
  position, sync and analysis run as with a device; there is no audio device, so no latency or device-change tests.
  Timing comes from the timer, not the hardware clock.
- **Pairing TCP over loopback** (see *Pairing*). Two instances on one Mac cannot use the LAN address. Bonjour
  discovery and the protocol are real; the network path to the LAN address is not exercised.
- **`drag` is not wired.** Drops are window/AppKit drag events. Use `load` (deck) and `add-to-playlist` (playlist).
- **UI is only read.** The mailbox reads the window (`shot`) and the models; it does not click or type. Layout
  regressions need the UI test (`scripts/uitest.sh`).
- **Shared audio folder.** Instances of one run read the same WAV files (read-only). Analysis and cue writes go to
  each instance's own collection.
- **Suites are files.** `com.github.slayer7411.minos741.e2e.<name>.plist` lives in `~/Library/Preferences`. The runner
  deletes its own suites after each scenario; a crashed run can leave some behind (only with this prefix).
- **Sheets are not shown.** The setup and crash sheets are not presented in E2E runs (`SetupFlow.sheetShown`,
  `CrashPrompt.sheetShown`); their state is read with `setup-state` / `crash-state`. No browser is opened: `crash-open`
  only records the address (`CrashLinks`).
- **Real machine, read-only:** installed audio plug-ins (`~/Library/Audio/Plug-Ins`, plug-in catalog scan), Spotlight
  for the explorer search, the system audio device list (read, never opened), the DAW bridge port (see above).
- **The user's app may run at the same time.** Its own folders change while a run is going. The runner never writes
  to them; a change in `~/Native Instruments/…` during a run is not from the test.
- **Cloud library** (File Provider) is not exercised: fixtures are local files.
- **Update: folder channel only.** The network channels (GitHub) are off in the test run (`networkAllowed`); the
  download, the redirect rule and the host list are unit tests (`UpdaterTests`). The `self-update` scenario relaunches
  its own bundle copy, not a `/Applications` install.
- **One scenario at a time per runner.** Two runners in parallel get separate run ids, roots and suites, but the
  DAW bridge port conflicts with each other.
