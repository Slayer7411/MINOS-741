// VST3-Host: ein Effekt aus einem .vst3-Bundle über das VST 3 SDK (Sources/VST3SDK, MIT).
// Ablauf beim Öffnen (UI-Thread): Modul laden (bleibt geladen) → Komponente anlegen + initialisieren → Controller
// (aus der Komponente oder eigene Klasse) → verbinden (ConnectionProxy) → Zustand der Komponente an den Controller →
// Busse (Haupt-Ein-/Ausgang stereo, Rest aus) → setupProcessing (Echtzeit, 32 Bit) → aktiv → processing.
// Audio-Thread: Eingang in vorab angelegte Puffer, Parameter aus einem sperrfreien Ring in vorab angelegte Queues,
// process(), Ausgang zurück. Steuer-Aufrufe, die den Prozessor umbauen (Reset, Zustand), nehmen ihm kurz den Block
// weg (busy-Flag): der Audio-Thread wartet nie, er lässt dann nur den Block trocken.
#include "MixDSPVST3Host.h"
#include "PluginBackend.h"

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstunits.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/connectionproxy.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/utility/stringconvert.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

void setErr(char *err, int len, const std::string &s) {
    if (err && len > 0) std::snprintf(err, size_t(len), "%s", s.c_str());
}

void copyStr(char *dst, size_t cap, const std::string &s) {
    if (cap == 0) return;
    std::snprintf(dst, cap, "%s", s.c_str());
}

/// Host-Kontext für alle Plugins: Name + IMessage/IAttributeList (für die Verbindung Komponente ↔ Controller)
class MinosHost : public HostApplication {
public:
    tresult PLUGIN_API getName(String128 name) override {
        return Steinberg::Vst::StringConvert::convert("MINOS-741", name) ? kResultTrue : kInternalError;
    }
};

FUnknown *hostContext() {
    static MinosHost *host = new MinosHost();   // lebt bis Prozessende (Plugins dürfen den Zeiger behalten)
    return static_cast<IHostApplication *>(host);
}

/// geladene Module je Bundle-Pfad. Bleiben geladen: viele Plugins vertragen kein Entladen + erneutes Laden.
std::mutex moduleLock;
std::map<std::string, VST3::Hosting::Module::Ptr> &modules() {
    static auto *m = new std::map<std::string, VST3::Hosting::Module::Ptr>();
    return *m;
}

VST3::Hosting::Module::Ptr loadModule(const std::string &path, std::string &error) {
    std::lock_guard<std::mutex> g(moduleLock);
    auto &m = modules();
    if (auto it = m.find(path); it != m.end()) return it->second;
    auto mod = VST3::Hosting::Module::create(path, error);
    if (!mod) {
        if (error.empty()) error = "module not loadable";
        return nullptr;
    }
    mod->getFactory().setHostContext(hostContext());
    m[path] = mod;
    return mod;
}

bool isEffect(const VST3::Hosting::ClassInfo &ci) {
    if (ci.category() != kVstAudioEffectClass) return false;
    const auto &subs = ci.subCategories();
    bool fx = std::find(subs.begin(), subs.end(), "Fx") != subs.end();
    bool inst = std::find(subs.begin(), subs.end(), "Instrument") != subs.end();
    return fx && !inst;
}

std::string lower(std::string s) {
    for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

/// Parameter-Änderungen Steuer-Threads → Audio-Thread: Ring, mehrere Schreiber (kurz gesperrt), ein Leser ohne Sperre
struct ParamRing {
    static constexpr uint32_t N = 1024;
    struct Entry { ParamID id; ParamValue value; };
    Entry buf[N];
    std::atomic<uint32_t> head{0}, tail{0};
    std::atomic_flag writing = ATOMIC_FLAG_INIT;

    bool push(ParamID id, ParamValue v) {
        while (writing.test_and_set(std::memory_order_acquire)) std::this_thread::yield();
        uint32_t h = head.load(std::memory_order_relaxed), t = tail.load(std::memory_order_acquire);
        bool ok = h - t < N;
        if (ok) { buf[h % N] = {id, v}; head.store(h + 1, std::memory_order_release); }
        writing.clear(std::memory_order_release);
        return ok;
    }
    bool peek(Entry &e) const {
        uint32_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire)) return false;
        e = buf[t % N];
        return true;
    }
    void pop() { tail.fetch_add(1, std::memory_order_release); }
};

/// Ereignis aus dem Audio-Thread (performEdit / restartComponent während process())
struct HostEvent {
    enum Kind : uint32_t { kEdit = 0, kRestart = 1 };
    Kind kind;
    uint32_t id;
    ParamValue value;
    int32 flags;
};

/// Ereignisse vom Audio-Thread zum Steuer-Thread: vorab angelegt, ein Schreiber (Audio-Thread), ein Leser
/// (mdvst3_drain_events). Voll: der Ereignis wird verworfen und gezählt, nie gewartet.
struct HostEventRing {
    static constexpr uint32_t N = 256;
    HostEvent buf[N];
    std::atomic<uint32_t> head{0}, tail{0};
    std::atomic<uint32_t> dropped{0};

    bool push(const HostEvent &e) {
        uint32_t h = head.load(std::memory_order_relaxed), t = tail.load(std::memory_order_acquire);
        if (h - t >= N) { dropped.fetch_add(1, std::memory_order_relaxed); return false; }
        buf[h % N] = e;
        head.store(h + 1, std::memory_order_release);
        return true;
    }
    bool pop(HostEvent &e) {
        uint32_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire)) return false;
        e = buf[t % N];
        tail.store(t + 1, std::memory_order_release);
        return true;
    }
};

/// > 0, solange der aktuelle Thread in process() eines Plugins rechnet (Host-Rückrufe dann nur in den Ring)
static thread_local int renderDepth = 0;
struct RenderScope {
    RenderScope() { ++renderDepth; }
    ~RenderScope() { --renderDepth; }
};

struct VST3Plugin;

/// IComponentHandler: Änderungen aus der Ansicht des Plugins → Prozessor + Zuhörer
class ComponentHandler : public U::Implements<U::Directly<IComponentHandler>> {
public:
    explicit ComponentHandler(VST3Plugin *p) : plug(p) {}
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue v) override;
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32 flags) override;
    VST3Plugin *plug;
};

/// IPlugFrame: das Plugin möchte eine andere Größe seiner Ansicht
class PlugFrame : public U::Implements<U::Directly<IPlugFrame>> {
public:
    explicit PlugFrame(VST3Plugin *p) : plug(p) {}
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *r) override;
    VST3Plugin *plug;
};

struct VST3Plugin final : MDPlugin {
    VST3Plugin() : MDPlugin(MDPLUG_KIND_VST3) {}
    ~VST3Plugin() override;
    void process(float *L, float *R, int n) override;
    void reset() override;

    // Teile des Plugins
    VST3::Hosting::Module::Ptr module;
    IPtr<IComponent> component;
    IPtr<IAudioProcessor> processor;
    IPtr<IEditController> controller;
    bool singleComponent = false;
    IPtr<ConnectionProxy> componentCP, controllerCP;
    IPtr<ComponentHandler> handler;
    bool active = false, processing = false;

    // Rechnen (vorab angelegt)
    uint32_t maxFrames = 0;
    double sampleRate = 44100;
    std::vector<AudioBusBuffers> inBus, outBus;
    std::vector<float *> chanPtrs;
    std::vector<float> chanStore;
    int inCh = 0, outCh = 0;
    IPtr<ParameterChanges> inChanges, outChanges;
    int queueCap = 0;
    IPtr<EventList> inEvents, outEvents;
    ProcessContext ctx{};
    ProcessData data{};
    int64_t position = 0;
    ParamRing ring;
    HostEventRing hostEvents;
    /// 0 frei, 1 Audio-Thread rechnet, 2 Steuer-Thread baut um
    std::atomic<int> busy{0};
    std::atomic<uint32_t> latency{0};

    // Zuhörer + Ansicht (UI-Thread)
    std::mutex listenerLock;
    MDVST3ParamListener listener = nullptr;
    void *listenerCtx = nullptr;
    IPtr<IPlugView> view;
    IPtr<PlugFrame> frame;
    MDVST3ResizeFn resizeFn = nullptr;
    void *resizeCtx = nullptr;

    void notify(ParamID id, ParamValue v) {
        std::lock_guard<std::mutex> g(listenerLock);
        if (listener) listener(listenerCtx, id, v);
    }

    /// Prozessor für einen Umbau holen (wartet auf das Ende eines laufenden Blocks, höchstens ~1 s)
    bool acquire() {
        for (int i = 0; i < 20000; i++) {
            int expected = 0;
            if (busy.compare_exchange_weak(expected, 2, std::memory_order_acquire)) return true;
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
        return false;
    }
    void release() { busy.store(0, std::memory_order_release); }

    void stopProcessing() {
        if (processing && processor) processor->setProcessing(false);
        processing = false;
        if (active && component) component->setActive(false);
        active = false;
    }
    void startProcessing() {
        if (component && component->setActive(true) == kResultOk) active = true;
        if (active && processor) { processor->setProcessing(true); processing = true; }   // kNotImplemented ist erlaubt
    }

    void closeEditor() {
        if (!view) return;
        view->removed();
        view->setFrame(nullptr);
        view = nullptr;
        frame = nullptr;
        resizeFn = nullptr; resizeCtx = nullptr;
    }
};

tresult PLUGIN_API ComponentHandler::performEdit(ParamID id, ParamValue v) {
    if (!plug) return kResultFalse;
    if (renderDepth > 0) { plug->hostEvents.push({HostEvent::kEdit, id, v, 0}); return kResultOk; }
    plug->ring.push(id, v);
    plug->notify(id, v);
    return kResultOk;
}

/// Umbau/Latenz/Werte neu lesen (Steuer-Thread: Plugin-Aufrufe und Umbau, der Block wartet kurz)
static tresult applyRestart(VST3Plugin *plug, int32 flags) {
    if (flags & kLatencyChanged) {
        if (plug->processor) plug->latency.store(plug->processor->getLatencySamples());
    }
    if (flags & (kParamValuesChanged | kParamTitlesChanged)) plug->notify(MDVST3_ALL_PARAMS, 0);
    if (flags & kReloadComponent) {
        if (plug->acquire()) {
            plug->stopProcessing();
            plug->startProcessing();
            plug->release();
        }
    }
    return kResultOk;   // kIoChanged: Busse bleiben, wie sie beim Öffnen eingerichtet wurden
}

tresult PLUGIN_API ComponentHandler::restartComponent(int32 flags) {
    if (!plug) return kResultFalse;
    if (renderDepth > 0) { plug->hostEvents.push({HostEvent::kRestart, 0, 0, flags}); return kResultOk; }
    return applyRestart(plug, flags);
}

tresult PLUGIN_API PlugFrame::resizeView(IPlugView *v, ViewRect *r) {
    if (!plug || !v || !r || v != plug->view.get()) return kInvalidArgument;
    if (plug->resizeFn) plug->resizeFn(plug->resizeCtx, r->getWidth(), r->getHeight());
    v->onSize(r);
    return kResultTrue;
}

VST3Plugin::~VST3Plugin() {
    closeEditor();
    stopProcessing();
    if (componentCP) componentCP->disconnect();
    if (controllerCP) controllerCP->disconnect();
    componentCP = nullptr; controllerCP = nullptr;
    if (controller) controller->setComponentHandler(nullptr);
    if (handler) handler->plug = nullptr;
    if (controller && !singleComponent) controller->terminate();
    if (component) component->terminate();
    controller = nullptr; processor = nullptr; component = nullptr;
}

void VST3Plugin::reset() {
    if (!acquire()) return;
    stopProcessing();
    startProcessing();
    position = 0;
    release();
}

void VST3Plugin::process(float *L, float *R, int n) {
    RenderScope renderScope;
    if (n <= 0 || uint32_t(n) > maxFrames) return;
    int expected = 0;
    if (!busy.compare_exchange_strong(expected, 1, std::memory_order_acquire)) return;   // wird gerade umgebaut: trocken
    if (!active) { busy.store(0, std::memory_order_release); return; }

    // Eingang: Hauptbus, mono = Mitte
    float **in = inBus[0].channelBuffers32;
    if (inCh == 1) {
        for (int i = 0; i < n; i++) in[0][i] = 0.5f * (L[i] + R[i]);
    } else {
        std::memcpy(in[0], L, sizeof(float) * size_t(n));
        std::memcpy(in[1], R, sizeof(float) * size_t(n));
    }
    for (auto &b : inBus) b.silenceFlags = 0;
    for (auto &b : outBus) b.silenceFlags = 0;

    // Parameter: jüngster Wert je Parameter am Blockanfang
    inChanges->clearQueue();
    outChanges->clearQueue();
    ParamRing::Entry e;
    while (ring.peek(e)) {
        int32 used = inChanges->getParameterCount(), idx = 0;
        bool present = false;
        for (int32 i = 0; i < used && !present; i++) present = inChanges->getParameterData(i)->getParameterId() == e.id;
        if (!present && used >= queueCap) break;   // voll: Rest im nächsten Block
        if (auto *q = inChanges->addParameterData(e.id, idx)) q->addPoint(0, e.value, idx);
        ring.pop();
    }
    inEvents->clear();
    outEvents->clear();

    ctx.projectTimeSamples = position;
    ctx.continousTimeSamples = position;
    ctx.state = ProcessContext::kPlaying | ProcessContext::kContTimeValid;
    if (tempo > 0) {
        ctx.tempo = tempo;
        ctx.projectTimeMusic = beat;
        ctx.timeSigNumerator = 4; ctx.timeSigDenominator = 4;
        ctx.barPositionMusic = std::floor(beat / 4) * 4;
        ctx.state |= ProcessContext::kTempoValid | ProcessContext::kProjectTimeMusicValid | ProcessContext::kTimeSigValid |
                     ProcessContext::kBarPositionValid;
    }
    data.numSamples = n;
    tresult r = processor->process(data);
    position += n;
    busy.store(0, std::memory_order_release);
    if (r != kResultOk) return;   // Signal bleibt trocken

    float **out = outBus[0].channelBuffers32;
    uint64 silent = outBus[0].silenceFlags;
    if (silent & 1) std::memset(L, 0, sizeof(float) * size_t(n)); else std::memcpy(L, out[0], sizeof(float) * size_t(n));
    int rc = outCh >= 2 ? 1 : 0;
    if (silent & (uint64(1) << rc)) std::memset(R, 0, sizeof(float) * size_t(n)); else std::memcpy(R, out[rc], sizeof(float) * size_t(n));
}

VST3Plugin *asVST3(MDPlugin *p) { return p && p->kind == MDPLUG_KIND_VST3 ? static_cast<VST3Plugin *>(p) : nullptr; }

/// Busse einrichten: Haupt-Ein-/Ausgang stereo (sonst, was das Plugin anbietet), Neben-Busse aus
bool setupBuses(VST3Plugin *p, std::string &why) {
    int32 nIn = p->component->getBusCount(kAudio, kInput), nOut = p->component->getBusCount(kAudio, kOutput);
    if (nIn < 1) { why = "no audio input (not an effect)"; return false; }
    if (nOut < 1) { why = "no audio output"; return false; }
    std::vector<SpeakerArrangement> ins(size_t(nIn), SpeakerArr::kStereo), outs(size_t(nOut), SpeakerArr::kStereo);
    for (int32 i = 1; i < nIn; i++) p->processor->getBusArrangement(kInput, i, ins[size_t(i)]);
    for (int32 i = 1; i < nOut; i++) p->processor->getBusArrangement(kOutput, i, outs[size_t(i)]);
    p->processor->setBusArrangements(ins.data(), nIn, outs.data(), nOut);   // abgelehnt: das Plugin behält seine
    for (int32 i = 0; i < nIn; i++) {
        p->processor->getBusArrangement(kInput, i, ins[size_t(i)]);
        p->component->activateBus(kAudio, kInput, i, i == 0);
    }
    for (int32 i = 0; i < nOut; i++) {
        p->processor->getBusArrangement(kOutput, i, outs[size_t(i)]);
        p->component->activateBus(kAudio, kOutput, i, i == 0);
    }
    for (int32 dir : {kInput, kOutput}) {
        for (int32 i = 0; i < p->component->getBusCount(kEvent, dir); i++) p->component->activateBus(kEvent, dir, i, false);
    }
    p->inCh = SpeakerArr::getChannelCount(ins[0]);
    p->outCh = SpeakerArr::getChannelCount(outs[0]);
    if (p->inCh < 1 || p->outCh < 1) { why = "main bus without channels"; return false; }

    // Puffer: jeder Kanal jedes Busses bekommt gültigen Speicher (auch inaktive)
    size_t total = 0;
    for (auto a : ins) total += size_t(SpeakerArr::getChannelCount(a));
    for (auto a : outs) total += size_t(SpeakerArr::getChannelCount(a));
    p->chanStore.assign(total * p->maxFrames, 0.f);
    p->chanPtrs.assign(total, nullptr);
    for (size_t c = 0; c < total; c++) p->chanPtrs[c] = p->chanStore.data() + c * p->maxFrames;
    size_t next = 0;
    auto fill = [&](std::vector<AudioBusBuffers> &bus, const std::vector<SpeakerArrangement> &arr) {
        bus.assign(arr.size(), AudioBusBuffers());
        for (size_t b = 0; b < arr.size(); b++) {
            bus[b].numChannels = SpeakerArr::getChannelCount(arr[b]);
            bus[b].channelBuffers32 = p->chanPtrs.data() + next;
            next += size_t(bus[b].numChannels);
        }
    };
    fill(p->inBus, ins);
    fill(p->outBus, outs);
    return true;
}

} // namespace

extern "C" {

int mdvst3_scan(const char *bundlePath, MDVST3Class *out, int maxOut, char *err, int errLen) {
    setErr(err, errLen, "");
    if (!bundlePath) { setErr(err, errLen, "no path"); return -1; }
    std::string why;
    auto mod = loadModule(bundlePath, why);
    if (!mod) { setErr(err, errLen, why); return -1; }
    const auto &factory = mod->getFactory();
    std::string factoryVendor = factory.info().vendor();
    int n = 0;
    for (auto &ci : factory.classInfos()) {
        if (!isEffect(ci)) continue;
        if (out && n < maxOut) {
            MDVST3Class &c = out[n];
            std::memset(&c, 0, sizeof c);
            copyStr(c.cid, sizeof c.cid, ci.ID().toString(false));
            copyStr(c.name, sizeof c.name, ci.name());
            copyStr(c.vendor, sizeof c.vendor, ci.vendor().empty() ? factoryVendor : ci.vendor());
            copyStr(c.version, sizeof c.version, ci.version());
            copyStr(c.subCategories, sizeof c.subCategories, ci.subCategoriesString());
        }
        n++;
    }
    return n;
}

MDPlugin *mdvst3_open(const char *bundlePath, const char *cid, double sampleRate, uint32_t maxFrames, char *err, int errLen) {
    setErr(err, errLen, "");
    if (!bundlePath || !cid) { setErr(err, errLen, "no path or class"); return nullptr; }
    std::string why;
    auto mod = loadModule(bundlePath, why);
    if (!mod) { setErr(err, errLen, why); return nullptr; }
    const auto &factory = mod->getFactory();
    const VST3::Hosting::ClassInfo *info = nullptr;
    auto infos = factory.classInfos();
    for (auto &ci : infos) {
        if (lower(ci.ID().toString(false)) == lower(cid)) { info = &ci; break; }
    }
    if (!info) { setErr(err, errLen, "class not found in bundle"); return nullptr; }
    if (!isEffect(*info)) { setErr(err, errLen, "not an audio effect class"); return nullptr; }

    auto *p = new VST3Plugin();
    p->module = mod;
    p->sampleRate = sampleRate;
    p->maxFrames = std::max(1u, maxFrames);
    auto fail = [&](const std::string &s) -> MDPlugin * { setErr(err, errLen, s); delete p; return nullptr; };

    // Komponente
    p->component = factory.createInstance<IComponent>(info->ID());
    if (!p->component) return fail("component not created");
    if (p->component->initialize(hostContext()) != kResultOk) {
        p->component = nullptr;   // nicht initialisiert: nicht terminieren
        return fail("component initialize failed");
    }
    p->processor = U::cast<IAudioProcessor>(p->component);
    if (!p->processor) return fail("no audio processor");

    // Controller: in der Komponente oder eigene Klasse
    if (auto c = U::cast<IEditController>(p->component)) {
        p->controller = c;
        p->singleComponent = true;
    } else {
        TUID ctrlID;
        if (p->component->getControllerClassId(ctrlID) == kResultTrue) {
            p->controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(ctrlID));
            if (p->controller && p->controller->initialize(hostContext()) != kResultOk) {
                p->controller = nullptr;
                return fail("controller initialize failed");
            }
        }
        if (p->controller) {
            auto compCP = U::cast<IConnectionPoint>(p->component), ctrlCP = U::cast<IConnectionPoint>(p->controller);
            if (compCP && ctrlCP) {
                p->componentCP = owned(new ConnectionProxy(compCP));
                p->controllerCP = owned(new ConnectionProxy(ctrlCP));
                p->componentCP->connect(ctrlCP);
                p->controllerCP->connect(compCP);
            }
        }
    }
    if (p->controller) {
        // Controller mit dem Zustand des Prozessors abgleichen
        MemoryStream s;
        if (p->component->getState(&s) == kResultOk) {
            s.seek(0, IBStream::kIBSeekSet, nullptr);
            p->controller->setComponentState(&s);
        }
        p->handler = owned(new ComponentHandler(p));
        p->controller->setComponentHandler(p->handler);
    }

    // Busse + Verarbeitung
    if (p->processor->canProcessSampleSize(kSample32) != kResultTrue) return fail("no 32-bit float processing");
    if (!setupBuses(p, why)) return fail(why);
    ProcessSetup setup{kRealtime, kSample32, int32(p->maxFrames), sampleRate};
    if (p->processor->setupProcessing(setup) != kResultOk) return fail("setupProcessing rejected");

    int32 params = p->controller ? p->controller->getParameterCount() : 0;
    p->queueCap = std::max<int32>(64, params);
    p->inChanges = owned(new ParameterChanges(p->queueCap));
    p->outChanges = owned(new ParameterChanges(p->queueCap));
    p->inEvents = owned(new EventList(64));
    p->outEvents = owned(new EventList(64));
    p->ctx.sampleRate = sampleRate;
    p->data.processMode = kRealtime;
    p->data.symbolicSampleSize = kSample32;
    p->data.numInputs = int32(p->inBus.size());
    p->data.numOutputs = int32(p->outBus.size());
    p->data.inputs = p->inBus.data();
    p->data.outputs = p->outBus.data();
    p->data.inputParameterChanges = p->inChanges;
    p->data.outputParameterChanges = p->outChanges;
    p->data.inputEvents = p->inEvents;
    p->data.outputEvents = p->outEvents;
    p->data.processContext = &p->ctx;

    p->startProcessing();
    if (!p->active) return fail("setActive failed");
    p->latency.store(p->processor->getLatencySamples());
    uint32 tail = p->processor->getTailSamples();
    p->tailFrames.store(tail == kInfiniteTail ? UINT32_MAX : tail);
    return p;
}

int mdvst3_param_count(MDPlugin *mp) {
    auto *p = asVST3(mp);
    return p && p->controller ? p->controller->getParameterCount() : 0;
}

bool mdvst3_param_info(MDPlugin *mp, int index, MDVST3Param *out) {
    auto *p = asVST3(mp);
    if (!p || !p->controller || !out) return false;
    ParameterInfo pi{};
    if (p->controller->getParameterInfo(index, pi) != kResultOk) return false;
    std::memset(out, 0, sizeof *out);
    out->id = pi.id;
    copyStr(out->title, sizeof out->title, Steinberg::Vst::StringConvert::convert(pi.title));
    if (out->title[0] == 0) copyStr(out->title, sizeof out->title, Steinberg::Vst::StringConvert::convert(pi.shortTitle));
    copyStr(out->units, sizeof out->units, Steinberg::Vst::StringConvert::convert(pi.units));
    out->stepCount = pi.stepCount;
    out->defaultValue = pi.defaultNormalizedValue;
    out->flags = pi.flags;
    out->unitId = pi.unitId;
    return true;
}

double mdvst3_param_get(MDPlugin *mp, uint32_t id) {
    auto *p = asVST3(mp);
    return p && p->controller ? p->controller->getParamNormalized(id) : 0;
}

void mdvst3_param_set(MDPlugin *mp, uint32_t id, double v) {
    auto *p = asVST3(mp);
    if (p && p->controller) p->controller->setParamNormalized(id, std::clamp(v, 0.0, 1.0));
}

void mdvst3_param_send(MDPlugin *mp, uint32_t id, double v) {
    if (auto *p = asVST3(mp)) p->ring.push(id, std::clamp(v, 0.0, 1.0));
}

bool mdvst3_param_text(MDPlugin *mp, uint32_t id, double v, char *out, int len) {
    auto *p = asVST3(mp);
    if (!p || !p->controller || !out || len <= 0) return false;
    String128 s{};
    if (p->controller->getParamStringByValue(id, v, s) != kResultOk) return false;
    copyStr(out, size_t(len), Steinberg::Vst::StringConvert::convert(s));
    return true;
}

bool mdvst3_unit_name(MDPlugin *mp, int32_t unitId, char *out, int len) {
    auto *p = asVST3(mp);
    if (!p || !p->controller || !out || len <= 0) return false;
    auto units = U::cast<IUnitInfo>(p->controller);
    if (!units) return false;
    for (int32 i = 0, n = units->getUnitCount(); i < n; i++) {
        UnitInfo ui{};
        if (units->getUnitInfo(i, ui) == kResultOk && ui.id == unitId) {
            copyStr(out, size_t(len), Steinberg::Vst::StringConvert::convert(ui.name));
            return true;
        }
    }
    return false;
}

// Zustand: "M7V3" · u32 Länge Komponente · Daten · u32 Länge Controller · Daten (little endian)
size_t mdvst3_get_state(MDPlugin *mp, uint8_t **out) {
    auto *p = asVST3(mp);
    if (!p || !out) return 0;
    *out = nullptr;
    MemoryStream comp, ctrl;
    if (p->component->getState(&comp) != kResultOk) return 0;
    if (p->controller && !p->singleComponent) p->controller->getState(&ctrl);
    size_t a = size_t(comp.getSize()), b = size_t(ctrl.getSize());
    size_t total = 4 + 4 + a + 4 + b;
    auto *buf = static_cast<uint8_t *>(std::malloc(total));
    if (!buf) return 0;
    auto put32 = [](uint8_t *d, uint32_t v) { for (int i = 0; i < 4; i++) d[i] = uint8_t(v >> (8 * i)); };
    std::memcpy(buf, "M7V3", 4);
    put32(buf + 4, uint32_t(a));
    if (a) std::memcpy(buf + 8, comp.getData(), a);
    put32(buf + 8 + a, uint32_t(b));
    if (b) std::memcpy(buf + 12 + a, ctrl.getData(), b);
    *out = buf;
    return total;
}

bool mdvst3_set_state(MDPlugin *mp, const uint8_t *d, size_t len) {
    auto *p = asVST3(mp);
    if (!p || !d || len < 12 || std::memcmp(d, "M7V3", 4) != 0) return false;
    auto get32 = [](const uint8_t *s) { uint32_t v = 0; for (int i = 0; i < 4; i++) v |= uint32_t(s[i]) << (8 * i); return v; };
    size_t a = get32(d + 4);
    if (8 + a + 4 > len) return false;
    size_t b = get32(d + 8 + a);
    if (12 + a + b > len) return false;
    // MemoryStream liest direkt aus fremdem Speicher (nicht const) → Kopien
    std::vector<uint8_t> compData(d + 8, d + 8 + a), ctrlData(d + 12 + a, d + 12 + a + b);
    IPtr<MemoryStream> comp = owned(new MemoryStream(compData.data(), TSize(a)));
    if (!p->acquire()) return false;
    tresult r = p->component->setState(comp);
    p->release();
    if (r != kResultOk) return false;
    if (p->controller) {
        comp->seek(0, IBStream::kIBSeekSet, nullptr);
        p->controller->setComponentState(comp);
        if (b && !p->singleComponent) {
            IPtr<MemoryStream> ctrl = owned(new MemoryStream(ctrlData.data(), TSize(b)));
            p->controller->setState(ctrl);
        }
        // Prozessor auf den Stand des Controllers bringen (manche Plugins übernehmen setState erst im nächsten Block)
        int32 n = p->controller->getParameterCount();
        for (int32 i = 0; i < n; i++) {
            ParameterInfo pi{};
            if (p->controller->getParameterInfo(i, pi) == kResultOk && !(pi.flags & ParameterInfo::kIsReadOnly))
                p->ring.push(pi.id, p->controller->getParamNormalized(pi.id));
        }
    }
    return true;
}

uint32_t mdvst3_latency(MDPlugin *mp) {
    auto *p = asVST3(mp);
    return p ? p->latency.load() : 0;
}

uint32_t mdvst3_tail(MDPlugin *mp) {
    auto *p = asVST3(mp);
    return p ? p->tailFrames.load() : 0;
}

void mdvst3_drain_events(MDPlugin *mp) {
    auto *p = asVST3(mp);
    if (!p) return;
    HostEvent e{};
    while (p->hostEvents.pop(e)) {
        if (e.kind == HostEvent::kEdit) {
            p->ring.push(e.id, e.value);
            p->notify(e.id, e.value);
        } else {
            applyRestart(p, e.flags);
        }
    }
}

int mdvst3_selftest_event_ring(int n) {
    HostEventRing ring;
    int dropped = 0;
    for (int i = 0; i < n; i++) {
        if (!ring.push({HostEvent::kEdit, uint32_t(i), 0, 0})) dropped++;
    }
    HostEvent e{};
    uint32_t next = 0;
    while (ring.pop(e)) {
        if (e.id != next) return -1;   // Reihenfolge verletzt
        next++;
    }
    return dropped == int(ring.dropped.load()) ? dropped : -1;
}

void mdvst3_set_listener(MDPlugin *mp, MDVST3ParamListener f, void *ctx) {
    auto *p = asVST3(mp);
    if (!p) return;
    std::lock_guard<std::mutex> g(p->listenerLock);
    p->listener = f;
    p->listenerCtx = ctx;
}

bool mdvst3_editor_open(MDPlugin *mp, void *nsView, int *width, int *height, MDVST3ResizeFn resize, void *ctx) {
    auto *p = asVST3(mp);
    if (!p || !p->controller || !nsView) return false;
    p->closeEditor();
    IPtr<IPlugView> v = owned(p->controller->createView(ViewType::kEditor));
    if (!v) return false;
    if (v->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) return false;
    p->view = v;
    p->frame = owned(new PlugFrame(p));
    p->resizeFn = resize; p->resizeCtx = ctx;
    v->setFrame(p->frame);
    if (v->attached(nsView, kPlatformTypeNSView) != kResultOk) {
        v->setFrame(nullptr);
        p->view = nullptr; p->frame = nullptr; p->resizeFn = nullptr; p->resizeCtx = nullptr;
        return false;
    }
    ViewRect r;
    if (v->getSize(&r) == kResultOk && r.getWidth() > 0 && r.getHeight() > 0) {
        if (width) *width = r.getWidth();
        if (height) *height = r.getHeight();
    }
    return true;
}

bool mdvst3_editor_resizable(MDPlugin *mp) {
    auto *p = asVST3(mp);
    return p && p->view && p->view->canResize() == kResultTrue;
}

bool mdvst3_editor_set_size(MDPlugin *mp, int *width, int *height) {
    auto *p = asVST3(mp);
    if (!p || !p->view || !width || !height) return false;
    ViewRect r(0, 0, *width, *height);
    if (p->view->canResize() == kResultTrue) p->view->checkSizeConstraint(&r);
    if (p->view->onSize(&r) != kResultOk) return false;
    *width = r.getWidth(); *height = r.getHeight();
    return true;
}

void mdvst3_editor_close(MDPlugin *mp) {
    if (auto *p = asVST3(mp)) p->closeEditor();
}

} // extern "C"
