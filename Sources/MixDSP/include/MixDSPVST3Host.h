// VST3-Host für MixDSP (macOS): ein Effekt aus einem .vst3-Bundle (VST 3 SDK, MIT) als MDPlugin.
// Laden, Zustand, Controller und Ansicht auf dem "UI-Thread" des SDK (in der App der Haupt-Thread, immer derselbe),
// mdplug_process() im Audio-Thread (keine Sperren, kein Speicher). Schließen/Zurücksetzen: MixDSPPlugin.h.
// Läuft im Prozess – ein Absturz des Plugins trifft MINOS-741 (Absturz-Markierung beim Öffnen).
#ifndef MIXDSP_VST3HOST_H
#define MIXDSP_VST3HOST_H
#include <stddef.h>
#include "MixDSPPlugin.h"
#ifdef __cplusplus
extern "C" {
#endif

/// eine Effekt-Klasse eines Bundles (Kategorie "Audio Module Class", Unterkategorie "Fx")
typedef struct {
    char cid[33];              ///< Klassen-ID, 32 Hex-Zeichen
    char name[128];
    char vendor[128];          ///< Klasse, sonst Fabrik
    char version[64];
    char subCategories[128];   ///< "Fx|Delay"
} MDVST3Class;

/// ein Parameter des Controllers (Werte normalisiert 0…1)
typedef struct {
    uint32_t id;
    char title[128];
    char units[32];
    int32_t stepCount;         ///< 0 = stufenlos
    double defaultValue;
    int32_t flags;             ///< ParameterInfo::ParameterFlags
    int32_t unitId;            ///< Unit (Gruppe), 0 = Wurzel
} MDVST3Param;

enum {
    MDVST3_PARAM_CAN_AUTOMATE = 1 << 0,
    MDVST3_PARAM_READ_ONLY = 1 << 1,
    MDVST3_PARAM_LIST = 1 << 3,
    MDVST3_PARAM_HIDDEN = 1 << 4,
    MDVST3_PARAM_PROGRAM_CHANGE = 1 << 15,
    MDVST3_PARAM_BYPASS = 1 << 16,
};

/// alle Parameter neu lesen (restartComponent mit kParamValuesChanged)
#define MDVST3_ALL_PARAMS 0xffffffffu

/// Effekt-Klassen eines .vst3-Bundles (lädt den Code; Modul bleibt geladen). Liefert die Anzahl (bis maxOut
/// geschrieben) oder -1, Grund in err.
int mdvst3_scan(const char *bundlePath, MDVST3Class *out, int maxOut, char *err, int errLen);

/// Klasse `cid` anlegen, verbinden, Stereo-Busse, 32 Bit, Echtzeit, `sampleRate`, bis `maxFrames` je Block, aktiv.
/// NULL bei Fehler, Grund in err.
MDPlugin *mdvst3_open(const char *bundlePath, const char *cid, double sampleRate, uint32_t maxFrames, char *err, int errLen);

int mdvst3_param_count(MDPlugin *p);
bool mdvst3_param_info(MDPlugin *p, int index, MDVST3Param *out);
/// Wert laut Controller
double mdvst3_param_get(MDPlugin *p, uint32_t id);
/// Controller setzen (UI-Thread)
void mdvst3_param_set(MDPlugin *p, uint32_t id, double normalized);
/// an den Prozessor schicken (jeder Thread außer dem Audio-Thread; übernimmt der nächste Block)
void mdvst3_param_send(MDPlugin *p, uint32_t id, double normalized);
/// Anzeige-Text eines Werts ("-6.0 dB")
bool mdvst3_param_text(MDPlugin *p, uint32_t id, double normalized, char *out, int len);
/// Name einer Unit (IUnitInfo des Controllers); false ohne Units
bool mdvst3_unit_name(MDPlugin *p, int32_t unitId, char *out, int len);

/// Zustand von Komponente + Controller (eigener Container); *out mit free() freigeben. 0 bei Fehler.
size_t mdvst3_get_state(MDPlugin *p, uint8_t **out);
bool mdvst3_set_state(MDPlugin *p, const uint8_t *data, size_t len);

/// gemeldete Latenz in Samples (wird nicht ausgeglichen)
uint32_t mdvst3_latency(MDPlugin *p);
/// Nachklingzeit in Samples (0 = keine, UINT32_MAX = endlos)
uint32_t mdvst3_tail(MDPlugin *p);

/// Änderungen aus dem Plugin (eigene Ansicht, performEdit): id + Wert; MDVST3_ALL_PARAMS = alle neu lesen.
/// Kommt auf dem UI-Thread.
typedef void (*MDVST3ParamListener)(void *ctx, uint32_t id, double normalized);
void mdvst3_set_listener(MDPlugin *p, MDVST3ParamListener f, void *ctx);
/// Ereignisse aus dem Audio-Thread (Edit, Umbau während process()) hier abarbeiten: Zuhörer und Umbau laufen dabei
/// auf dem aufrufenden (Steuer-)Thread. Nie aus dem Audio-Thread aufrufen.
void mdvst3_drain_events(MDPlugin *p);
/// Test: Ring mit n Ereignissen füllen und in Reihenfolge leeren. Liefert die Zahl verworfener Ereignisse, -1 bei Fehler.
int mdvst3_selftest_event_ring(int n);

/// eigene Ansicht (IPlugView, "editor") in `nsView` hängen; Größe in *width/*height. Wünscht das Plugin eine andere
/// Größe, kommt `resize` (UI-Thread). false = keine eigene Ansicht.
typedef void (*MDVST3ResizeFn)(void *ctx, int width, int height);
bool mdvst3_editor_open(MDPlugin *p, void *nsView, int *width, int *height, MDVST3ResizeFn resize, void *ctx);
/// neue Größe des Fensters an die Ansicht (nach Ziehen am Fensterrand); liefert die angenommene Größe
bool mdvst3_editor_set_size(MDPlugin *p, int *width, int *height);
bool mdvst3_editor_resizable(MDPlugin *p);
void mdvst3_editor_close(MDPlugin *p);

#ifdef __cplusplus
}
#endif
#endif
