<p align="center"><img src="docs/assets/banner.svg" alt="MINOS-741" width="100%"></p>

<p align="center"><a href="https://github.com/Slayer7411/MINOS-741/releases"><img src="https://img.shields.io/github/v/release/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=%24MINOS" alt="release"></a> <img src="https://img.shields.io/badge/CODENAME-LIMBUS-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="codename"> <a href="https://github.com/Slayer7411/MINOS-741/blob/main/CHANGELOG.md"><img src="https://img.shields.io/badge/CHANGELOG-%E2%97%86-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="changelog"></a> <a href="docs/MANUAL.md"><img src="https://img.shields.io/badge/MANUAL-%E2%86%92-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="manual"></a> <a href="https://slayer7411.github.io/MINOS-741/guide/"><img src="https://img.shields.io/badge/USER%20GUIDE-%E2%86%92-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="user guide"></a> <a href="https://github.com/Slayer7411/MINOS-741/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/LICENSE-GPL--2.0+-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="license"></a> <img src="https://img.shields.io/badge/MACOS-15+-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="macos 15+"> <img src="https://img.shields.io/badge/SWIFT-6-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="swift 6"> <img src="https://img.shields.io/badge/C++-17-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="c++17"></p>
<p align="center"><a href="https://github.com/Slayer7411/MINOS-741/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/Slayer7411/MINOS-741/ci.yml?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=CI" alt="ci"></a> <a href="https://github.com/Slayer7411/MINOS-741/commits/main"><img src="https://img.shields.io/github/last-commit/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=LAST%20COMMIT" alt="last commit"></a> <a href="https://github.com/Slayer7411/MINOS-741/graphs/contributors"><img src="https://img.shields.io/github/contributors/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=CONTRIBUTORS" alt="contributors"></a> <a href="https://github.com/Slayer7411/MINOS-741/discussions"><img src="https://img.shields.io/github/discussions/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=DISCUSSIONS" alt="discussions"></a> <a href="https://github.com/sponsors/Slayer7411"><img src="https://img.shields.io/badge/SPONSOR-%E2%99%A5-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="sponsor"></a></p>
<p align="center"><a href="https://soundcloud.com/minos-741"><img src="https://img.shields.io/badge/SOUNDCLOUD-minos--741-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="soundcloud"></a> <a href="https://www.instagram.com/minos_741/"><img src="https://img.shields.io/badge/INSTAGRAM-@minos__741-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="instagram"></a> <a href="https://github.com/Slayer7411/MINOS-741/discussions/categories/show-and-tell"><img src="https://img.shields.io/badge/SUBMIT%20A%20SET-%E2%86%92-d21f26?style=flat-square&labelColor=0a0a0a" alt="submit a set"></a></p>

native dj software for macos. classic deck workflow, nml collection in and out, own browser, tag system and plugin host.
built for my own setup -> after two weeks it replaced my old dj software at home. ideas -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions), own needs -> fork it.

new here? -> [START](docs/START.md): from zero to your first recorded set. every control with pictures -> [USER GUIDE](https://slayer7411.github.io/MINOS-741/guide/). everything it does -> [FEATURES](docs/FEATURES.md).

<p align="center"><img src="docs/assets/screenshot.png" alt="MINOS-741 with 4 decks, external mixer mode and dual browser" width="100%"></p>

## ◆ WHY

**multi browser**
* two browser panes side by side or stacked, each with own source, search, sort, tag filter and columns
* prepare the next track in one pane while the other stays on the running set
* all library columns, two-line rows, detail bar, smartlists with a rule editor

**tag system**
* tags live in comment 2 of the collection -> they travel with the library
* groups: `K tief lang B sub schwer H off DRUMS` -> kick / bass / hats / role, each group in its waveform color
* tag picker with one column per group, click = filter, ⌥-click = exclude, save as smartlist
* matching by key, tempo and tag groups (similar or complementary) against the master or chosen decks

**external plugins**
* audio unit (v2 / v3) and VST3 effects in fx insert slots, up to 6 in series per unit
* master bus effects in internal mixer mode
* audio units can run isolated in a separate service: a crashing plugin does not take the audio down

## ◆ UNDER THE HOOD

* c++ realtime audio core, lock-free, decks rendered in parallel (one thread per deck)
* audio runs apart from gui and browser -> the gui can hang or restart, sound and sync keep running
* audio device gone -> decks keep their state, output reopens by itself when the same device is back (~10 ms)
* file decoding in its own process: a hanging cloud file only blocks its helper
* link tempo sync over the network, minos can lead
* two hid controllers in native mode

## ◆ BUILT IN

* audio editing on the grid: cut, remove, keep, join, split, a-b-a, amp / norm -> always a new file, the original stays
* own analysis: bpm, key, beatgrid, loudness
* waveform presets: 3-band blend or spectrum, every color and band adjustable
* set recording with tracklist, history and preparation as nml
* 4 decks with the classic deck set, internal mixer or one usb pair per deck
* every option has a setting (⌘,), ui in german or english

## ◆ STATUS

work in progress, `0.x` -> things still change. [releases](https://github.com/Slayer7411/MINOS-741/releases) · [changelog](CHANGELOG.md) · [roadmap](docs/roadmap.md).
keys and full reference -> [MANUAL](docs/MANUAL.md).

## ◆ VERSIONS

minos judges the souls at the gate of the second circle in dante's inferno; every major version is named after a circle.

| major | name | circle |
|---|---|---|
| 0 | LIMBUS | limbo · first circle |
| 1 | LUXURIA | lust · second circle |
| 2 | GULA | gluttony · third circle |
| 3 | AVARITIA | greed · fourth circle |
| 4 | IRA | wrath · fifth circle |
| 5 | HAERESIS | heresy · sixth circle |
| 6 | VIOLENTIA | violence · seventh circle |
| 7 | FRAUS | fraud · eighth circle |
| 8 | PRODITIO | treachery · ninth circle |
| 9 | PURGATORIUM | purgatory · no circle of hell |
| 10 | PARADISUS | paradise · also every major after 10 |

## ◆ SETS

recorded a set with minos? it gets reposted.

* [soundcloud.com/minos-741](https://soundcloud.com/minos-741) -> sets recorded with minos, reposted daily
* [@minos_741](https://www.instagram.com/minos_741/) -> one set a day as a post, every release as a story, bigger releases as a post
* submit -> [discussions / show and tell](https://github.com/Slayer7411/MINOS-741/discussions/new?category=show-and-tell): soundcloud link, optional instagram handle and genre, your ok to repost. credits to the artist in every post
* recording: ● REC in the top bar, tracklist comes along as `.txt` + `.cue`

the accounts are run by an agent: reposts, posts and release stories are generated automatically.

## ◆ INSTALL

needs macos 15+, apple silicon or intel.

```
brew install --cask slayer7411/tap/minos-741
```

or the dmg from [releases](https://github.com/Slayer7411/MINOS-741/releases/latest). not signed by apple -> first start: system settings -> privacy & security -> OPEN ANYWAY.

## ◆ UPDATES

the app looks for updates by itself. channel: ⌘, -> ANZEIGE -> Updates.

* **newest build** (default): every build of main, one rolling release [`latest-build`](https://github.com/Slayer7411/MINOS-741/releases/tag/latest-build)
* **stable releases**: only the named releases `vX.Y.Z`
* **own folder**: `latest.json` and the DMG in a folder (`scripts/make-dmg.sh --publish <folder>`)
* **off**

checks 30 s after start, then every 6 h (own folder: every 30 min). a new build shows in the status bar and the menu. with automatic installs (off by default) it installs once no deck plays, LIVE is off and there was no input for 2 min. install: download, size and sha-256 check, replace the app, quit, start the new version. the old app stays next to it as `.MINOS-741-previous.app` (menu: restore previous version). only https to github.com.

releases: `scripts/release.sh --rolling --yes` (`latest-build`) or `scripts/release.sh <version> --name <NAME> --yes`. both refuse without `--yes`; `--dry-run` only prints the commands.

## ◆ HARDWARE

tested, works with:

* controller: Kontrol X1 mk2, native hid mode, up to two units (left deck a / c, right deck b / d)
* mixer: Xone:96 in external mixer mode, every deck on its own usb pair
* mixer profiles, ungetestet – Kanalbelegung bitte prüfen: Pioneer DJM-V10 (6 channels) and DJM-A9 (4 channels). ⌘, -> AUDIO -> Mischpult shows the detected profile and sets external mode with deck A–D on CH1–CH4 (the offer lists the exact pairs). optional MIDI clock to a MIDI output, off by default; how the mixer reacts to it is not tested
* audio: any core audio interface. internal mixer -> one stereo pair. external mixer -> one pair per deck (8 outputs for 4 decks, 10 with preview)
* keyboard: every action mappable (⌘, -> keyboard)

not yet: midi controllers and midi learn -> planned for 1.0, plus mapping files you can build yourself.
your controller or mixer missing? -> [request it](https://github.com/Slayer7411/MINOS-741/discussions/3) or dm [@minos_741](https://www.instagram.com/minos_741/).

## ◆ RUN IT

from source, needs xcode / swift 6.

```
git clone https://github.com/Slayer7411/MINOS-741.git
cd MINOS-741
swift run minos741
```

app bundle into /Applications:

```
scripts/make-app.sh
```

collection: the newest `collection.nml` in your library folder is found on start, others via ⌘O.
tests: `swift test`. engine self test:

```
MIX741_SELFTEST=1 MIX741_NOEXT=1 swift run minos741
```

## ◆ DOCS

```
> minos --help
```

**[→ MANUAL](docs/MANUAL.md)** -> install, decks, sync, mixer, fx, browser, tags, keys, troubleshooting, faq

**[→ USER GUIDE](https://slayer7411.github.io/MINOS-741/guide/)** -> the same as a site: chapters, search, annotated screenshots

* [features](docs/FEATURES.md) · [settings](docs/settings.md) · [controllers](docs/controllers.md) · [library](docs/library.md)
* [architecture](docs/architecture.md) · [nml files](docs/nml-files.md) · [roadmap](docs/roadmap.md)
* [changelog](CHANGELOG.md) · [contributing](CONTRIBUTING.md) · [all docs](docs/README.md)

## ◆ DESIGN

ci-741:
* void / chitin black, bone white text
* red only as state (playing, sync, loop, fx on), purple for master, phrases and the selected loop size
* cinzel in caps for labels, ibm plex mono for data
* radius 0, 1px hairlines, unicode instead of icons

fonts bundled under the sil open font license.

## ◆ CREDITS

* fonts: [cinzel](https://fonts.google.com/specimen/Cinzel), [ibm plex mono](https://fonts.google.com/specimen/IBM+Plex+Mono)
* link library, time-stretch library, VST 3 SDK: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)

not affiliated with any dj software or hardware vendor, no vendor code inside.

## ◆ CONTRIBUTING

bugs -> [issues](https://github.com/Slayer7411/MINOS-741/issues) · ideas -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions) · rules, setup, release checklist -> [CONTRIBUTING.md](CONTRIBUTING.md)

## ◆ LICENSE

© 2026 Slayer7411. dual licensed:
* free: GPL-2.0-or-later ([LICENSE.md](LICENSE.md)). your version stays open
* commercial, closed or sold products: license from the author with a revenue share -> [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)
* name, ◆ mark and logo stay with the author, forks pick their own
* pull requests need the [CLA](CLA.md)

third party:
* link library 3.1.5: GPL-2.0-or-later, `Sources/LinkKit`
* time-stretch / fft libraries: MIT, `Sources/MixDSP/vendor`
* VST 3 SDK 3.8.1 (hosting part): MIT, `Sources/VST3SDK` · VST is a registered trademark of Steinberg Media Technologies GmbH
* fonts: SIL open font license
* all notices and license texts: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
