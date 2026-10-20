// MixDSP – Echtzeitkern. Regeln für alles, was in render() läuft:
// keine Sperren, kein new/delete, keine Systemaufrufe, nur vorab angelegter Speicher.
#include "MixDSP.h"
#include "MixDSPPlugin.h"
#include "MixDSPRecord.h"
#include "PluginBackend.h"
#include "Preview.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <memory>
#include <chrono>
#include <mutex>
#include <thread>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <os/workgroup.h>
#include <pthread.h>
#endif


#include "signalsmith-stretch/signalsmith-stretch.h"

namespace {

constexpr int kMaxFrames = MDSP_MAX_FRAMES;
constexpr int kMaxIn = kMaxFrames * 5;   // Eingang je Block bei Tempo bis 4× (+Reserve)
constexpr double kPi = 3.14159265358979323846;
constexpr float kReverbRef = 0.42f;       // Hall-Eingangsgewicht bei Pegel 1 (Abgleich: siehe Reverb::run)
constexpr double kTrimFadeS = 0.003;      // Rampe an geschnittenen Rändern: kein Knacken, kein Gleichanteil am Rand
constexpr double kScratchTauS = 0.02;    // Wellenform greifen: Zeitkonstante, mit der der Lesekopf dem Ziel der Hand folgt

/// Gleitregler (Faktor 0,002 je Sample) springen ab diesem Abstand aufs Ziel: in float bliebe der Wert bei 1 sonst
/// ~3e-5 darunter stehen (Schritt kleiner als ein halbes ULP) -> Ausgang nie bit-genau. 5e-5 = −86 dB, unhörbar
constexpr float kSnap = 5e-5f;

inline float dbToLin(float db) { return db <= -95.f ? 0.f : std::pow(10.f, db / 20.f); }

/// Denormals im Render-Block auf 0 (ausklingende Filter/Hall: auf Intel sonst bis ×100 Rechenzeit je Sample).
/// Setzt die Einstellung des Threads am Ende zurück (Tests/Offline rufen aus fremden Threads).
struct DenormalGuard {
#if defined(__aarch64__)
    uint64_t old;
    DenormalGuard() { asm volatile("mrs %0, fpcr" : "=r"(old)); uint64_t v = old | (uint64_t(1) << 24); asm volatile("msr fpcr, %0" :: "r"(v)); }
    ~DenormalGuard() { asm volatile("msr fpcr, %0" :: "r"(old)); }
#elif defined(__x86_64__) || defined(__i386__)
    unsigned old;
    DenormalGuard() { old = _mm_getcsr(); _mm_setcsr(old | 0x8040); }   // FTZ | DAZ
    ~DenormalGuard() { _mm_setcsr(old); }
#endif
};

// ---------- Biquad (RBJ) ----------
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1[2] = {0, 0}, z2[2] = {0, 0};
    void setIdentity() { b0 = 1; b1 = b2 = a1 = a2 = 0; }
    void clearState() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
    /// Frequenz unter Nyquist halten: darüber wird der Filter instabil (Geräte mit 16–32 kHz)
    static double safeF(double f, double fs) { return std::clamp(f, 1.0, fs * 0.45); }
    void set(double c0, double c1, double c2, double d0, double d1, double d2) {
        b0 = float(c0 / d0); b1 = float(c1 / d0); b2 = float(c2 / d0); a1 = float(d1 / d0); a2 = float(d2 / d0);
    }
    void lowpass(double f, double q, double fs) {
        f = safeF(f, fs);
        double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a);
    }
    void highpass(double f, double q, double fs) {
        f = safeF(f, fs);
        double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a);
    }
    void peaking(double f, double q, double db, double fs) {
        f = safeF(f, fs);
        double A = std::pow(10, db / 40), w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
        set(1 + a * A, -2 * c, 1 - a * A, 1 + a / A, -2 * c, 1 - a / A);
    }
    void shelf(bool low, double f, double db, double fs) {
        f = safeF(f, fs);
        double A = std::pow(10, db / 40), w = 2 * kPi * f / fs, c = std::cos(w), s = std::sin(w);
        double a = s / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * a;
        if (low) set(A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq),
                     (A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq);
        else set(A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sq),
                 (A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sq);
    }
    inline float tick(int ch, float x) {
        float y = b0 * x + z1[ch];
        z1[ch] = b1 * x - a1 * y + z2[ch];
        z2[ch] = b2 * x - a2 * y;
        return y;
    }
    void run(float *L, float *R, int n) {
        for (int i = 0; i < n; i++) { L[i] = tick(0, L[i]); R[i] = tick(1, R[i]); }
    }
};

/// EQ je Deck: Tief-Regal 100 Hz, Mitte-Glocke 1 kHz, Höhen-Regal 10 kHz. Ziel je Band (dB, -40 … +12; Kill = -40)
/// wird je 32 Samples gegen einen Glättungswert (~15 ms) gefahren, die Koeffizienten folgen ihm; 0 dB = Identität
struct EQBands {
    Biquad bq[3];
    float sm[3] = {0, 0, 0}, db[3] = {0, 0, 0};   // Glättungswert, dB der aktuellen Koeffizienten
    static void setBand(Biquad &b, int band, double gain, double fs) {
        if (band == 0) b.shelf(true, 100, gain, fs);
        else if (band == 1) b.peaking(1000, 0.7, gain, fs);
        else b.shelf(false, 10000, gain, fs);
    }
    void clearState() { for (auto &b : bq) b.clearState(); }
    void run(const float (&tgt)[3], float *L, float *R, int n, double fs) {
        constexpr int kSub = 32;
        const float alpha = 1 - std::exp(-float(kSub) / float(0.015 * fs));
        for (int i0 = 0; i0 < n; i0 += kSub) {
            int m = std::min(kSub, n - i0);
            for (int b = 0; b < 3; b++) {
                float t = std::min(12.f, std::max(-40.f, tgt[b]));   // NaN -> Kill
                sm[b] += (t - sm[b]) * alpha;
                if (std::fabs(t - sm[b]) < 0.01f) sm[b] = t;
                if (sm[b] != db[b]) { setBand(bq[b], b, sm[b], fs); db[b] = sm[b]; }
                bq[b].run(L + i0, R + i0, m);
            }
        }
    }
};

/// Ein-Knopf-Filter: v < 0 Lowpass, v > 0 Highpass, |v| klein = aus
struct SweepFilter {
    Biquad bq;
    float lastV = 999, lastQ = -1;
    bool active = false;
    void update(float v, float res, double fs) {
        if (v == lastV && res == lastQ) return;
        lastV = v; lastQ = res;
        double q = 0.5 + res * 2.0;
        if (v < -0.02f) { bq.lowpass(20000.0 * std::pow(60.0 / 20000.0, -v), q, fs); active = true; }
        else if (v > 0.02f) { bq.highpass(25.0 * std::pow(9000.0 / 25.0, v), q, fs); active = true; }
        else active = false;
    }
    void run(float *L, float *R, int n) { if (active) bq.run(L, R, n); }
};

// ---------- Delay (stereo, beat-synchron gesteuert von außen) ----------
// Aus = Eingang zu, Echo läuft aus (Spillover); erst wenn es verklungen ist, wird nicht mehr gerechnet
struct Delay {
    std::vector<float> bufL, bufR;
    int w = 0;
    float send = 0, tail = 0;
    void init(double fs) { bufL.assign(size_t(fs * 2.1), 0); bufR.assign(size_t(fs * 2.1), 0); }
    void clear() { std::fill(bufL.begin(), bufL.end(), 0); std::fill(bufR.begin(), bufR.end(), 0); send = tail = 0; }
    bool active() const { return send > 0.0005f || tail > 1e-5f; }
    void run(float *L, float *R, int n, double seconds, float feedback, float wet, double fs, bool on) {
        int len = int(bufL.size());
        int d = std::clamp(int(seconds * fs), 1, len - 1);
        float target = on ? 1.f : 0.f, peak = 0;
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            int r = w - d; if (r < 0) r += len;
            float dl = bufL[r], dr = bufR[r];
            bufL[w] = L[i] * send + dl * feedback;
            bufR[w] = R[i] * send + dr * feedback;
            L[i] += dl * wet; R[i] += dr * wet;
            peak = std::max(peak, std::max(std::fabs(dl), std::fabs(dr)));
            if (++w >= len) w = 0;
        }
        tail = peak;
        if (!on && !active()) clear();
    }
};

// ---------- Reverb (Diffusor + FDN mit 16 Leitungen) ----------
// Eingang stereo -> Diffusor (4 Stufen × 8 Kanäle, Hadamard-Mischung, ohne Rückkopplung: dicht ab der ersten ms)
// -> Rückkopplungsnetz aus 16 Verzögerungsleitungen (Primzahl-Längen 30 … 110 ms, Hadamard-Matrix, je Leitung
// Hochregal-Dämpfung: Höhen klingen schneller ab, bleiben aber hörbar), Leselänge jeder Leitung schwankt langsam
// (Allpass-Interpolation, verlustfrei) -> keine stehenden Resonanzen. L/R aus orthogonalen Summen der Leitungen.
// Nachhall 0,4 s … 25 s (Größe 0,9) … 200 s (Größe 1, fast eingefroren).
constexpr int kRvLines = 16, kRvDiffCh = 8, kRvDiffSteps = 4;
constexpr int kRvTank[kRvLines] = {1721, 4447, 1871, 1571, 2887, 3739, 3137, 1447, 2039, 4861, 2221, 1321, 3433, 2647, 4079, 2423};   // Samples bei 44,1 kHz
constexpr int kRvDiff[kRvDiffSteps][kRvDiffCh] = {{1229, 499, 709, 449, 1117, 211, 1693, 1531}, {607, 863, 17, 359, 991, 199, 467, 683},
                                                   {19, 149, 61, 457, 251, 307, 409, 241}, {197, 7, 193, 89, 59, 127, 37, 157}};
constexpr float kRvRates[kRvLines] = {0.28f, 0.58f, 0.43f, 0.78f, 0.33f, 0.68f, 0.47f, 0.93f, 0.72f, 0.18f, 1.02f, 0.53f, 0.83f, 0.38f, 0.62f, 0.22f};   // Hz
constexpr double kRvModMs = 0.35;          // Schwankung der Leselänge ± ms
constexpr double kRvDampHz = 3000;         // Eckfrequenz der Höhen-Dämpfung in den Leitungen
constexpr double kRvBuildS = 2.5;          // Pegelabgleich: gleiche Lautheit nach so langem Einspielen, unabhängig von der Größe

/// Nachhallzeit (s) aus der Größe 0…1
inline double reverbT60(double size) {
    size = std::clamp(size, 0.0, 1.0);
    if (size <= 0.9) return 0.4 * std::pow(25.0 / 0.4, size / 0.9);
    return 25.0 * std::pow(8.0, (size - 0.9) / 0.1);
}

/// Hadamard-Mischung (ungewichtet, schnelle Walsh-Transformation)
template <int N> inline void hadamard(float *v) {
    for (int h = 1; h < N; h *= 2)
        for (int i = 0; i < N; i += 2 * h)
            for (int j = i; j < i + h; j++) { float a = v[j], b = v[j + h]; v[j] = a + b; v[j + h] = a - b; }
}

struct Reverb {
    // Verzögerungen hintereinander in einem Puffer, je Leitung die nächste Zweierpotenz (Maske), ein gemeinsamer
    // Schreibzähler. Zwischen den Leitungen kRvPad Abstand: sonst fallen alle Zugriffe in dieselben Cache-Sätze (Rechenzeit ×3)
    static constexpr int kRvPad = 160;
    std::vector<float> tank; int tOff[kRvLines] = {}, tMask[kRvLines] = {};
    std::vector<float> diff; int dOff[kRvDiffSteps][kRvDiffCh] = {}, dMask[kRvDiffSteps][kRvDiffCh] = {}, diffD[kRvDiffSteps][kRvDiffCh] = {};
    unsigned wpos = 0;                                    // Schreibzähler (läuft über, Masken schneiden zu)
    float base[kRvLines] = {}, depth = 0;                 // Leselänge in Samples, Schwankung ± Samples
    float phase[kRvLines] = {}, step[kRvLines] = {}, mod[kRvLines] = {};   // LFO je Leitung
    float apY[kRvLines] = {};                             // Zustand der Allpass-Interpolation
    float shX[kRvLines] = {}, shY[kRvLines] = {};         // Zustand der Dämpfung
    float b0[kRvLines] = {}, b1[kRvLines] = {}, a1 = 0;   // Dämpfung je Leitung (Gleichanteil-Verstärkung eingerechnet)
    float inGain = 0;                                     // Pegelabgleich über die Größe
    Biquad hp1, hp2, lp;     // nur dieser Frequenzbereich geht in den Hall
    Biquad lowCut;           // Hochpass vor dem Hall (150 … 400 Hz mit der Helligkeit): Bass/Kick machen die Fahne sonst mulmig
    Biquad tilt;             // Höhenregal am Ausgang (Luft): -4 … +6 dB ab 7 kHz mit der Helligkeit
    std::vector<float> preL, preR; int preW = 0;          // Vorverzögerung (stereo, vor dem Diffusor), Platz für 200 ms
    float preSm = -1;                                     // geglättete Vorverzögerung in Samples (Regler springt nicht hörbar)
    float lastHP = -1, lastLP = -1, lastBright = -1, lastSize = -1;
    bool hpOn = false, lpOn = false;
    float send = 0, tail = 0;
    double fs = 44100;
    bool active() const { return send > 0.0005f || tail > 1e-5f; }
    void init(double rate) {
        fs = rate;
        double k = fs / 44100.0;
        preL.assign(size_t(fs * 0.2) + 1, 0); preR.assign(preL.size(), 0); preW = 0;
        depth = float(kRvModMs * 0.001 * fs);
        auto pow2 = [](int n) { int p = 1; while (p < n) p *= 2; return p; };
        int total = 0;
        for (int i = 0; i < kRvLines; i++) {
            base[i] = float(std::round(kRvTank[i] * k));
            int len = pow2(int(base[i] + depth) + 4);
            tOff[i] = total; tMask[i] = len - 1; total += len + kRvPad;
            step[i] = float(2 * kPi * kRvRates[i] / fs); phase[i] = float(i) * 0.9f; mod[i] = std::sin(phase[i]);
        }
        tank.assign(size_t(total), 0);
        total = 0;
        for (int s = 0; s < kRvDiffSteps; s++)
            for (int c = 0; c < kRvDiffCh; c++) {
                diffD[s][c] = std::max(1, int(std::round(kRvDiff[s][c] * k)));
                int len = pow2(diffD[s][c] + 1);
                dOff[s][c] = total; dMask[s][c] = len - 1; total += len + kRvPad;
            }
        diff.assign(size_t(total), 0);
        wpos = 0;
        lastBright = lastSize = -1;
    }
    void clear() {
        std::fill(preL.begin(), preL.end(), 0); std::fill(preR.begin(), preR.end(), 0);
        std::fill(tank.begin(), tank.end(), 0); std::fill(diff.begin(), diff.end(), 0);
        for (int i = 0; i < kRvLines; i++) apY[i] = shX[i] = shY[i] = 0;
        send = tail = 0;
    }
    /// Dämpfung und Pegel aus Größe und Helligkeit (nur bei Änderung)
    void tune(float size, float bright) {
        double t60 = reverbT60(size);
        double hfRatio = 0.35 + 0.55 * bright;            // Nachhall der Höhen ÷ Nachhall gesamt: dunkel 0,35 … hell 0,9
        double K = std::tan(kPi * Biquad::safeF(kRvDampHz, fs) / fs);
        a1 = float((K - 1) / (K + 1));
        for (int i = 0; i < kRvLines; i++) {
            double sec = base[i] / fs;
            double gLo = std::pow(10.0, -3 * sec / t60), gHi = std::pow(10.0, -3 * sec / (t60 * hfRatio));
            double r = gHi / gLo;
            b0[i] = float(gLo * (K + r) / (K + 1)); b1[i] = float(gLo * (K - r) / (K + 1));
        }
        // Energie nach kRvBuildS Einspielen ∝ T60/13,8 · (1 − e^(−13,8 · t / T60)) -> Eingang mit 1/√ davon
        double tau = t60 / 13.8, eff = tau * (1 - std::exp(-kRvBuildS / tau));
        inGain = float(1 / std::sqrt(eff));
    }
    /// Send-Effekt: das trockene Signal bleibt unverändert, der Hall kommt dazu.
    /// `level` = wie viel hineingeht (aus = Eingang zu, Hall klingt aus), `wet` = Hall-Anteil am Ausgang.
    /// hpP/lpP 0…1: Hochpass 20 Hz…8 kHz (24 dB), Tiefpass 500 Hz…20 kHz – so entsteht z. B. ein heller Swipe aus den Höhen.
    /// `gain` = Hall-Pegel linear (Einstellung), `bright` 0…1 = Helligkeit, `preS` = Vorverzögerung in Sekunden.
    void run(float *L, float *R, int n, float size, float level, float wet, float hpP, float lpP,
             float gain, float bright, float preS, bool on, bool loud, bool freeze = false) {
        if (on && freeze) { size = 1; level = 0; }   // Freeze: Eingang zu, Nachhall fast unendlich
        if (hpP != lastHP) {
            lastHP = hpP;
            hpOn = hpP >= 0.01f;
            if (!hpOn) { hp1.setIdentity(); hp2.setIdentity(); hp1.clearState(); hp2.clearState(); }
            else { double f = std::min(20 * std::pow(400.0, double(hpP)), fs * 0.45); hp1.highpass(f, 0.54, fs); hp2.highpass(f, 1.31, fs); }
        }
        if (lpP != lastLP) {
            lastLP = lpP;
            lpOn = lpP <= 0.99f;
            if (!lpOn) { lp.setIdentity(); lp.clearState(); } else lp.lowpass(std::min(500 * std::pow(40.0, double(lpP)), fs * 0.45), 0.707, fs);
        }
        bright = std::clamp(bright, 0.f, 1.f); size = std::clamp(size, 0.f, 1.f);
        if (bright != lastBright) {
            lowCut.highpass(150 * std::pow(400.0 / 150, double(bright)), 0.707, fs);
            tilt.shelf(false, 7000, -4 + 10 * double(bright), fs);
        }
        if (bright != lastBright || std::fabs(size - lastSize) > 1e-4f) { lastBright = bright; lastSize = size; tune(size, bright); }
        // kReverbRef: gain 1 -> Hall allein ≈ 4 dB unter dem Track, mit Hall ≈ 1,2× so laut wie trocken (rosa Rauschen, volles D/W)
        float g = kReverbRef * inGain * gain;
        // Single-Modus: was der Hochpass wegnimmt, kommt als Pegel zurück (Swipe aus den Höhen), max. +30 dB.
        // Abgleich an zwei Techno-Tracks: volles D/W gesamt ÷ trocken 1,02 … 1,45 über HP 0 … 0,9 (vorher bis 2,33)
        if (loud) g *= std::pow(10.f, std::min(30.f, 16 * hpP + std::max(0.f, hpP - 0.5f) * 6) / 20);
        int preLen = int(preL.size());
        // ganze Samples als Ziel: ein gebrochener Lesepunkt mittelt zwei Samples (bei 15 ms: -8 dB bei 16 kHz)
        float preT = std::clamp(std::round(float(preS * fs)), 0.f, float(preLen - 2));
        if (preSm < 0) preSm = preT;
        // LFO: Wert am Blockende, dazwischen linear
        float dmod[kRvLines];
        for (int j = 0; j < kRvLines; j++) {
            phase[j] += step[j] * n; if (phase[j] > 2 * float(kPi)) phase[j] -= 2 * float(kPi);
            dmod[j] = (std::sin(phase[j]) - mod[j]) / float(n);
        }
        float target = on ? level : 0.f, peak = 0;
        const float hd = 0.25f, he = 0.35355339f;   // 1/√16, 1/√8
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            float xl = L[i], xr = R[i];
            if (hpOn) { xl = hp2.tick(0, hp1.tick(0, xl)); xr = hp2.tick(1, hp1.tick(1, xr)); }
            if (lpOn) { xl = lp.tick(0, xl); xr = lp.tick(1, xr); }
            xl = lowCut.tick(0, xl); xr = lowCut.tick(1, xr);
            preL[preW] = xl; preR[preW] = xr;               // Vorverzögerung: erst schreiben, dann preSm Samples zurück lesen (0 = direkt)
            preSm += (preT - preSm) * 0.0005f;
            int d0 = int(preSm); float f = preSm - float(d0);
            int r0 = preW - d0; if (r0 < 0) r0 += preLen;
            int r1 = r0 - 1; if (r1 < 0) r1 += preLen;
            xl = preL[r0] + (preL[r1] - preL[r0]) * f; xr = preR[r0] + (preR[r1] - preR[r0]) * f;
            if (++preW >= preLen) preW = 0;
            // Diffusor: je Stufe verzögern, Kanäle tauschen/umpolen, Hadamard
            float gs = g * send * 0.5f;
            float v[kRvDiffCh];
            for (int c = 0; c < kRvDiffCh; c++) v[c] = (c & 1 ? xr : xl) * gs;
            for (int s = 0; s < kRvDiffSteps; s++) {
                float u[kRvDiffCh];
                for (int c = 0; c < kRvDiffCh; c++) {
                    float *b = diff.data() + dOff[s][c];
                    b[wpos & unsigned(dMask[s][c])] = v[c];
                    u[c] = b[(wpos - unsigned(diffD[s][c])) & unsigned(dMask[s][c])];
                }
                for (int c = 0; c < kRvDiffCh; c++) v[c] = ((c + s) & 1 ? -u[(c + 3) & 7] : u[(c + 3) & 7]);
                hadamard<kRvDiffCh>(v);
                for (int c = 0; c < kRvDiffCh; c++) v[c] *= he;
            }
            // Leitungen lesen (Allpass-Interpolation, Bruchteil 0,5 … 1,5), dämpfen, mischen, zurückschreiben.
            // Getrennte Schleifen: Lesen/Schreiben einzeln, der Rest läuft vektorisiert über alle 16 Leitungen
            float y[kRvLines], m[kRvLines], u0[kRvLines], u1[kRvLines], eta[kRvLines];
            int M[kRvLines];
            for (int j = 0; j < kRvLines; j++) {
                mod[j] += dmod[j];
                float D = base[j] + depth * mod[j];
                M[j] = int(D - 0.5f);
                float fr = D - float(M[j]);
                eta[j] = (1 - fr) / (1 + fr);
            }
            for (int j = 0; j < kRvLines; j++) {
                const float *b = tank.data() + tOff[j];
                unsigned mk = unsigned(tMask[j]), r = wpos - unsigned(M[j]);
                u0[j] = b[r & mk]; u1[j] = b[(r - 1) & mk];
            }
            for (int j = 0; j < kRvLines; j++) {
                float out = eta[j] * (u0[j] - apY[j]) + u1[j];
                apY[j] = out; y[j] = out;
                float sh = b0[j] * out + b1[j] * shX[j] - a1 * shY[j];
                shX[j] = out; shY[j] = sh; m[j] = sh * hd;
            }
            hadamard<kRvLines>(m);
            for (int j = 0; j < 8; j++) m[j] += v[j];
            for (int j = 8; j < kRvLines; j++) m[j] += (j & 1) ? -v[(j + 3) & 7] : v[(j + 3) & 7];
            for (int j = 0; j < kRvLines; j++) tank[size_t(tOff[j]) + (wpos & unsigned(tMask[j]))] = m[j];
            wpos++;
            // Ausgang: orthogonale Summen (L/R unkorreliert) + Diffusor-Ausgang als frühe Dichte
            float ol = 0, orr = 0;
            for (int j = 0; j < kRvLines; j++) { ol += y[j]; orr += (j & 1) ? -y[j] : y[j]; }
            float el = 0, er = 0;
            for (int c = 0; c < kRvDiffCh; c++) { el += v[c]; er += (c & 2) ? -v[c] : v[c]; }
            ol = (ol * hd + el * he * 0.5f); orr = (orr * hd + er * he * 0.5f);
            ol = tilt.tick(0, ol); orr = tilt.tick(1, orr);
            L[i] += ol * wet; R[i] += orr * wet;
            peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
        }
        for (int j = 0; j < kRvLines; j++) mod[j] = std::sin(phase[j]);   // Rundungsfehler der Rampe nicht aufsummieren
        tail = peak;
        if (!on && !active()) clear();
    }
};

// ---------- Reverb (Allpass-Ring, Standardtyp) ----------
// Eingang stereo -> Filter (HP/LP-Regler, Tiefen-Schnitt und 1-Pol-Tiefpass nach Helligkeit) -> Vorverzögerung -> Diffusor
// (4 Allpässe je Kanal) -> Ring aus zwei Hälften (L, R) in Achter-Form: je Hälfte Allpass -> Leitung -> Dämpfung
// (Tiefen-/Höhenregal, 1-Pol) -> Allpass -> Leitung, deren Ausgang speist die andere Hälfte.
// Die 8 Leitungen schwanken langsam (je eigene Rate 0,5 … 1,1 Hz), Bruchteil per Allpass gelesen.
// Größe: Basislänge 12 … 50 ms (gleitet), Nachhall 0,35 … 7 s, Diffusion und Modulation steigen mit.
// Dämpfung als Regal: Höhen klingen schneller ab, verschwinden nicht. Freeze: Eingang zu, Ring verlustfrei – Fahne steht.
constexpr int kRcLines = 8;                                   // je Hälfte: Allpass, Leitung, Allpass, Leitung
constexpr float kRcRatio[4] = {0.43f, 1.0f, 0.71f, 1.37f};    // Länge ÷ Basislänge
constexpr float kRcRatioSum = 0.43f + 1.0f + 0.71f + 1.37f;
constexpr float kRcSpread = 1.13f;                            // rechte Hälfte länger: L/R unkorreliert
constexpr double kRcBaseMs[2] = {12.0, 50.0};                 // Basislänge bei Größe 0 / 1
constexpr int kRcDiffN = 4;
constexpr float kRcDiffMs[2][kRcDiffN] = {{2.3f, 3.7f, 5.9f, 8.9f}, {2.6f, 4.1f, 6.4f, 9.6f}};
constexpr float kRcDiffG[kRcDiffN] = {0.65f, 0.65f, 0.55f, 0.55f};
constexpr float kRcLfoHz[kRcLines] = {0.53f, 0.89f, 0.71f, 1.07f, 0.61f, 0.97f, 0.79f, 1.13f};   // je Leitung eigene Rate
constexpr float kRcDepthMs[2] = {0.25f, 1.0f};                 // Modulation (Spitze ½) bei Größe 0 / 1
constexpr double kRcGlideS = 0.12;                            // Leitungslängen folgen der Größe (Zeitkonstante)
constexpr float kRcTrim = 0.53f;                              // Pegelabgleich zum FDN (rosa Rauschen, Gruppe, volles D/W)

inline double reverbClassicT60(double size) { return 0.35 * std::pow(20.0, std::clamp(size, 0.0, 1.0)); }

struct ReverbClassic {
    static constexpr int kPad = 160;                          // Abstand der Leitungen im Puffer (Cache-Sätze)
    std::vector<float> buf; int off[kRcLines] = {}; unsigned mask[kRcLines] = {};
    std::vector<float> dbuf; int doff[2][kRcDiffN] = {}, dlen[2][kRcDiffN] = {}; unsigned dmask[2][kRcDiffN] = {};
    unsigned w = 0;                                           // Schreibzähler (läuft über, Masken schneiden zu)
    float base[2] = {}, baseT[2] = {};                        // Basislänge je Hälfte in Samples (aktuell, Ziel)
    float glide = 0, depth = 0, ph[kRcLines] = {}, phStep[kRcLines] = {};
    float g1 = 0, g2 = 0;                                     // Allpässe im Ring
    float loopG[2] = {}, hiA[2] = {}, loA[2] = {};            // je Hälfte: Ring-Gain, Regal-Verstärkung Höhen/Tiefen
    float hiK = 0, loK = 0;                                   // 1-Pol (TPT): g/(1+g)
    float hiS[2] = {}, loS[2] = {}, fb[2] = {}, apY[kRcLines] = {};
    float inGain = 0, frz = 0;
    Biquad hp, lp, lowCut;
    float airK = 0, airS[2] = {};                             // 1-Pol-Tiefpass am Eingang (Luft, mit der Helligkeit)
    std::vector<float> preL, preR; int preW = 0; float preSm = -1;
    float lastHP = -1, lastLP = -1, lastBright = -1, shelfKey[3] = {-1, -1, -1};
    bool hpOn = false, lpOn = false;
    float send = 0, tail = 0;
    double fs = 44100;
    bool active() const { return send > 0.0005f || tail > 1e-5f; }

    void init(double rate) {
        fs = rate;
        preL.assign(size_t(fs * 0.2) + 1, 0); preR.assign(preL.size(), 0); preW = 0;
        auto pow2 = [](int n) { unsigned p = 1; while (p < unsigned(n)) p *= 2; return p; };
        float maxDepth = 2 * kRcDepthMs[1] * float(1e-3 * fs), maxBase = float(kRcBaseMs[1] * 1e-3 * fs) * kRcSpread;
        int total = 0;
        for (int j = 0; j < kRcLines; j++) {
            unsigned len = pow2(int(kRcRatio[j & 3] * maxBase + maxDepth) + 8);
            off[j] = total; mask[j] = len - 1; total += int(len) + kPad;
        }
        buf.assign(size_t(total), 0);
        total = 0;
        for (int c = 0; c < 2; c++)
            for (int s = 0; s < kRcDiffN; s++) {
                dlen[c][s] = std::max(1, int(std::lround(kRcDiffMs[c][s] * 1e-3 * fs)));
                unsigned len = pow2(dlen[c][s] + 1);
                doff[c][s] = total; dmask[c][s] = len - 1; total += int(len) + kPad;
            }
        dbuf.assign(size_t(total), 0);
        glide = float(1 - std::exp(-1 / (kRcGlideS * fs)));
        for (int j = 0; j < kRcLines; j++) { phStep[j] = float(kRcLfoHz[j] / fs); ph[j] = 0.125f * float(j); }
        base[0] = baseT[0] = -1;   // erste Größe setzt direkt (kein Gleiten beim Start)
        w = 0; lastBright = shelfKey[0] = -1;
    }
    void clear() {
        std::fill(preL.begin(), preL.end(), 0); std::fill(preR.begin(), preR.end(), 0);
        std::fill(buf.begin(), buf.end(), 0); std::fill(dbuf.begin(), dbuf.end(), 0);
        for (int h = 0; h < 2; h++) hiS[h] = loS[h] = fb[h] = airS[h] = 0;
        for (float &v : apY) v = 0;
        send = tail = frz = 0;
    }
    /// D Samples zurück, Bruchteil per Allpass (Betrag 1 bei allen Frequenzen: Freeze verliert nichts, Höhen bleiben)
    inline float rd(int j, float D) {
        const float *b = buf.data() + off[j];
        int M = int(D - 0.5f); float fr = D - float(M), eta = (1 - fr) / (1 + fr);
        unsigned r = w - unsigned(M);
        float y = eta * (b[r & mask[j]] - apY[j]) + b[(r - 1) & mask[j]];
        apY[j] = y;
        return y;
    }
    /// Abgriff (linear), D Samples zurück
    inline float tap(int j, float D) const {
        const float *b = buf.data() + off[j];
        int di = int(D); float f = D - float(di);
        unsigned r = w - unsigned(di);
        float a = b[r & mask[j]], c = b[(r - 1) & mask[j]];
        return a + (c - a) * f;
    }
    inline void put(int j, float v) { buf[size_t(off[j]) + (w & mask[j])] = v; }
    static inline float lfo(float p) { float t = 2 * p - 1; return 4 * t * (1 - std::fabs(t)); }   // p 0…1, Parabel ≈ Sinus

    /// Gains je Block: Nachhall aus der Größe, Regale aus Helligkeit und HP/LP, Freeze blendet auf verlustfrei
    void tune(float size, float bright, float hpP, float lpP) {
        double t60 = reverbClassicT60(size);
        // Nachhall der Höhen: Anteil am Nachhall (Helligkeit, LP; Standard 0,54) und Luftdämpfung (große Räume dunkler)
        double hfT60 = 1 / (1 / (t60 * (0.3 + 0.4 * bright) * (0.2 + 0.8 * lpP)) + 0.12);
        double lfT60 = t60 * (1 - 0.85 * hpP);                          // Tiefen: HP-Regler
        for (int h = 0; h < 2; h++) {
            double sec = 3 * kRcRatioSum * base[h] / fs;               // Durchlauf einer Hälfte, × 3 (dB/20 je s Nachhall)
            double lg = std::pow(10.0, -sec / t60), ha = std::pow(10.0, -sec * (1 / hfT60 - 1 / t60)), la = std::pow(10.0, -sec * (1 / lfT60 - 1 / t60));
            loopG[h] = float(lg + (1 - lg) * frz);
            hiA[h] = float(ha + (1 - ha) * frz); loA[h] = float(la + (1 - la) * frz);
        }
        double tau = t60 / 13.8, eff = tau * (1 - std::exp(-kRvBuildS / tau));   // gleiche Lautheit über die Größe (wie FDN)
        inGain = float(1 / std::sqrt(eff));
        g1 = 0.55f + 0.15f * size; g2 = 0.45f + 0.1f * size;
        depth = float(kRcDepthMs[0] + (kRcDepthMs[1] - kRcDepthMs[0]) * size) * (1 - 0.8f * frz) * float(1e-3 * fs);   // Freeze: weniger Schwanken (stehende Fläche)
    }

    /// Schnittstelle wie Reverb::run (Send: trocken bleibt, Hall kommt dazu), dazu `freeze`
    void run(float *L, float *R, int n, float size, float level, float wet, float hpP, float lpP,
             float gain, float bright, float preS, bool on, bool loud, bool freeze) {
        if (hpP != lastHP) {
            lastHP = hpP;
            hpOn = hpP >= 0.01f;
            if (!hpOn) { hp.setIdentity(); hp.clearState(); } else hp.highpass(20 * std::pow(400.0, double(hpP)), 0.707, fs);
        }
        if (lpP != lastLP) {
            lastLP = lpP;
            lpOn = lpP <= 0.99f;
            if (!lpOn) { lp.setIdentity(); lp.clearState(); } else lp.lowpass(500 * std::pow(40.0, double(lpP)), 0.707, fs);
        }
        bright = std::clamp(bright, 0.f, 1.f); size = std::clamp(size, 0.f, 1.f);
        hpP = std::clamp(hpP, 0.f, 1.f); lpP = std::clamp(lpP, 0.f, 1.f);
        if (bright != lastBright) {
            lastBright = bright;
            lowCut.highpass(120 * std::pow(300.0 / 120, double(bright)), 0.707, fs);
            double ga = std::tan(kPi * Biquad::safeF(3000 * (1 + 1.5 * double(bright)), fs) / fs); airK = float(ga / (1 + ga));
        }
        if (bright != shelfKey[0] || hpP != shelfKey[1] || lpP != shelfKey[2]) {
            shelfKey[0] = bright; shelfKey[1] = hpP; shelfKey[2] = lpP;
            double fh = Biquad::safeF(600 * (0.75 + 0.5 * bright) * std::pow(5.0, double(lpP)), fs), fl = Biquad::safeF(150 + 850 * double(hpP), fs);
            double gh = std::tan(kPi * fh / fs), gl = std::tan(kPi * fl / fs);
            hiK = float(gh / (1 + gh)); loK = float(gl / (1 + gl));
        }
        float bt = float((kRcBaseMs[0] * std::pow(kRcBaseMs[1] / kRcBaseMs[0], double(size))) * 1e-3 * fs);
        baseT[0] = bt; baseT[1] = bt * kRcSpread;
        if (base[0] < 0) { base[0] = baseT[0]; base[1] = baseT[1]; }
        float frzT = on && freeze ? 1.f : 0.f;
        frz += std::clamp(frzT - frz, -float(n / (0.05 * fs)), float(n / (0.05 * fs)));
        tune(size, bright, hpP, lpP);
        // × (1 + 0,6 · Größe): großer Raum nicht leiser als der FDN (gemessen: Hall allein 0,80 / 0,62 / 0,51 bei 0,2 / 0,6 / 0,9)
        float g = kReverbRef * kRcTrim * inGain * (1 + 0.6f * size) * gain;
        if (loud) g *= std::pow(10.f, std::min(30.f, 16 * hpP + std::max(0.f, hpP - 0.5f) * 6) / 20);
        int preLen = int(preL.size());
        float preT = std::clamp(std::round(float(preS * fs)), 0.f, float(preLen - 2));
        if (preSm < 0) preSm = preT;
        float target = on && !freeze ? level : 0.f, peak = 0;
        const float dl = 0.6f;   // Modulation der Leitungen ÷ Allpässe
        for (int i = 0; i < n; i++) {
            send += (target - send) * 0.002f;
            float xl = L[i], xr = R[i];
            if (hpOn) { xl = hp.tick(0, xl); xr = hp.tick(1, xr); }
            if (lpOn) { xl = lp.tick(0, xl); xr = lp.tick(1, xr); }
            xl = lowCut.tick(0, xl); xr = lowCut.tick(1, xr);
            float t0 = (xl - airS[0]) * airK, t1 = (xr - airS[1]) * airK;
            xl = t0 + airS[0]; airS[0] = xl + t0; xr = t1 + airS[1]; airS[1] = xr + t1;
            preL[preW] = xl; preR[preW] = xr;
            preSm += (preT - preSm) * 0.0005f;
            int d0 = int(preSm); float f = preSm - float(d0);
            int r0 = preW - d0; if (r0 < 0) r0 += preLen;
            int r1 = r0 - 1; if (r1 < 0) r1 += preLen;
            float in[2] = {(preL[r0] + (preL[r1] - preL[r0]) * f) * g * send, (preR[r0] + (preR[r1] - preR[r0]) * f) * g * send};
            if (++preW >= preLen) preW = 0;
            // Diffusor (Allpässe, ganze Samples)
            for (int c = 0; c < 2; c++) {
                float x = in[c];
                for (int s = 0; s < kRcDiffN; s++) {
                    float *b = dbuf.data() + doff[c][s];
                    float vM = b[(w - unsigned(dlen[c][s])) & dmask[c][s]], v = x + kRcDiffG[s] * vM;
                    b[w & dmask[c][s]] = v; x = vM - kRcDiffG[s] * v;
                }
                in[c] = x;
            }
            base[0] += (baseT[0] - base[0]) * glide; base[1] += (baseT[1] - base[1]) * glide;
            for (int j = 0; j < kRcLines; j++) { ph[j] += phStep[j]; if (ph[j] >= 1) ph[j] -= 1; }
            float nfb[2], len[kRcLines];
            for (int h = 0; h < 2; h++) {
                int j = h * 4;
                for (int k = 0; k < 4; k++) len[j + k] = base[h] * kRcRatio[k] + depth * (k & 1 ? dl : 1.f) * (1 + lfo(ph[j + k]));
                float u = in[h] + fb[1 - h];
                float vM = rd(j, len[j]), v = u - g1 * vM;   // Allpass 1
                put(j, v); u = vM + g1 * v;
                float y = rd(j + 1, len[j + 1]);              // Leitung 1
                put(j + 1, u); u = y;
                float s = loS[h], t = (u - s) * loK, lo = t + s; loS[h] = lo + t; u += (loA[h] - 1) * lo;   // Tiefenregal
                s = hiS[h]; t = (u - s) * hiK; lo = t + s; hiS[h] = lo + t; u = lo + hiA[h] * (u - lo);      // Höhenregal
                vM = rd(j + 2, len[j + 2]); v = u + g2 * vM;  // Allpass 2
                put(j + 2, v); u = vM - g2 * v;
                y = rd(j + 3, len[j + 3]);                    // Leitung 2
                put(j + 3, u);
                nfb[h] = y * loopG[h];
            }
            fb[0] = nfb[0]; fb[1] = nfb[1];
            // Ausgang: Abgriffe beider Hälften (Leitungen 1/2), Vorzeichen gemischt -> L/R unkorreliert
            float ol = tap(1, len[1] * 0.31f) + tap(1, len[1] * 0.83f) - tap(3, len[3] * 0.47f) - tap(5, len[5] * 0.57f) + tap(7, len[7] * 0.19f);
            float orr = tap(5, len[5] * 0.29f) + tap(5, len[5] * 0.79f) - tap(7, len[7] * 0.52f) - tap(1, len[1] * 0.61f) + tap(3, len[3] * 0.23f);
            ol = (ol + in[0] * 0.5f) * 0.4f; orr = (orr + in[1] * 0.5f) * 0.4f;
            w++;
            L[i] += ol * wet; R[i] += orr * wet;
            peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
        }
        tail = peak;
        if (!on && !active()) clear();
    }
};

// ---------- Beat-FX: Gater, Roll, Flanger, Phaser ----------
// Raster aus der Master-Clock: Beat am Anfang des Teilblocks + Beats je Sample (MDEngine::fxBeat/fxBps).
// Anteil (AMOUNT × D/W) mit Rampe 5 ms, auch Ein/Aus. Anteil 0 = Ausgang wird nicht angefasst (bitgleich trocken).
constexpr double kFxRampS = 0.005;
constexpr int kLfoSeg = 64;               // LFO/Koeffizienten alle 64 Samples (≤ 1,5 ms), dazwischen linear

inline float onePole(double tauS, double fs) { return float(1 - std::exp(-1 / (tauS * fs))); }
inline double frac(double x) { return x - std::floor(x); }
/// Rampe am Ziel: einrasten (dann ohne Rechnen je Sample), sonst true
inline bool settle(float &v, float target) { if (std::fabs(target - v) < 1e-6f) { v = target; return false; } return true; }

/// Gater: Tor je Periode (1/16 … 1/2 Beat) offen ab dem Teiler für `width` der Periode; Form 0 = Rechteck,
/// 1 = Abklingen (quadratisch auf 0 am Ende der offenen Zeit). Flanken 0,25 ms (1-Pol) – Pegelwechsel < 1 ms nach dem Raster.
/// Einschalten greift ab dem nächsten Teiler.
struct Gater {
    float mix = 0, env = 1, kMix = 0, kEdge = 0, lastPh = 0;
    bool armed = false, wasOn = false;
    void init(double fs) { kMix = onePole(kFxRampS, fs); kEdge = onePole(0.00025, fs); }
    void clear() { mix = 0; env = 1; armed = wasOn = false; }
    bool active() const { return mix > 0; }
    void run(float *L, float *R, int n, double beat, double bps, double beats, float shape, float width, bool mute,
             float amount, bool on) {
        beats = std::max(beats, 1.0 / 64);
        width = std::clamp(width, 0.05f, 0.95f); shape = std::clamp(shape, 0.f, 1.f);
        float inv = 1 / width;
        bool start = on && !wasOn;
        wasOn = on;
        double phd = frac(beat / beats), step = bps / beats;   // Phase je Sample weiterzählen (Block ab Clock-Beat)
        for (int i = 0; i < n; i++, phd += step) {
            if (phd >= 1) phd -= 1;
            float ph = float(phd);
            if (start) { start = false; armed = mix == 0; lastPh = ph < 1e-6f ? 1.f : ph; }   // klingt es noch aus: gleich weiter
            if (armed && ph < lastPh) { armed = false; mix = amount; }     // Teiler: Tor ist offen, Anteil springt ohne Knacken
            lastPh = ph;
            mix += ((on && !armed ? amount : 0.f) - mix) * kMix;
            float g = 0;
            if (!mute && ph < width) { float d = 1 - ph * inv; g = 1 - shape * (1 - d * d); }
            env = armed ? 1.f : env + (g - env) * kEdge;
            float a = 1 - mix * (1 - env);
            L[i] *= a; R[i] *= a;
        }
        if (!on && mix < 1e-5f) { mix = 0; env = 1; }
    }
};

/// Roll: Puffer-Wiederholer im Raster. Einschalten wartet auf den nächsten Teiler der Länge, nimmt eine Länge
/// (+ Überblendung) auf – dabei läuft das Live-Signal durch – und wiederholt sie. Das Deck läuft darunter weiter (wie Flux):
/// aus = zurück zum Live-Signal dort, wo der Track inzwischen ist. Kürzere Länge im Lauf: Anfang der Aufnahme im selben
/// Raster, längere: weiter wiederholen bis zum nächsten Teiler, dann neu aufnehmen. Jeder Sprung des Lesekopfs (Umlauf,
/// rückwärts, Länge) wird 2 ms überblendet; der alte Lesekopf läuft weiter und wird an den Rändern der Aufnahme gespiegelt.
struct Roll {
    std::vector<float> bufL, bufR;   // 4 s: 1 Takt bei 60 BPM (bei 20 BPM noch 1 Beat)
    bool play = false, wait = false;
    double lenBeats = 0, waitBeats = 0;
    int len = 0, take = 0, rec = 0, xfMax = 0, xf = 1;   // Länge, Frames der laufenden Aufnahme, gültige Frames im Puffer
    int64_t t = 0;                   // Frames seit Beginn der Aufnahme
    int p = 0, dir = 1;              // Lesekopf (zuletzt gelesen)
    int op = 0, od = 1, ox = 0;      // alter Lesekopf, Rest der Überblendung
    float gain = 1, gainSm = 1, mix = 0, kMix = 0, kGain = 0, lastPh = 0;
    void init(double fs) {
        bufL.assign(size_t(fs * 4) + 8, 0); bufR.assign(bufL.size(), 0);
        xfMax = std::max(8, int(0.002 * fs)); kMix = onePole(kFxRampS, fs); kGain = onePole(0.001, fs);
    }
    void clear() { play = wait = false; mix = 0; ox = 0; take = rec = 0; gain = gainSm = 1; }   // Puffer bleibt, gelesen wird nur Aufgenommenes
    bool active() const { return mix > 0; }
    inline void bounce(int &q, int &d) const {
        if (q >= rec) { q = std::max(0, 2 * rec - 2 - q); d = -1; }
        if (q < 0) { q = std::min(rec - 1, -q); d = 1; }
    }
    inline void fadeFrom(int q, int d) { op = q; od = d; bounce(op, od); ox = xf; }
    void arm(double beats) { wait = true; waitBeats = beats; lastPh = -1; }
    void run(float *L, float *R, int n, double beat, double bps, double beats, bool reverse, float decayDbPerBeat,
             float amount, bool on) {
        beats = std::clamp(beats, 1.0 / 64, 4.0);
        int cap = int(bufL.size()) - xfMax - 1;
        auto frames = [&](double b) { return std::clamp(int(std::lround(b / bps)), 16, cap); };
        auto repGain = [&] { return float(std::pow(10.0, -std::max(0.f, decayDbPerBeat) * lenBeats / 20)); };
        if (on && !play && !wait) arm(beats);
        if (on && play && beats != lenBeats) {
            int nl = frames(beats);
            if (nl <= take) { len = nl; lenBeats = beats; xf = std::min(xfMax, len / 4); wait = false; }   // steckt in der Aufnahme
            else if (!wait || waitBeats != beats) arm(beats);
        }
        float rep = repGain();
        for (int i = 0; i < n; i++) {
            float xl = L[i], xr = R[i];
            if (wait && on) {
                float ph = float(frac((beat + i * bps) / waitBeats));
                bool hit = lastPh < 0 ? ph < 1e-6f : ph < lastPh;
                lastPh = ph;
                if (hit) {   // Teiler erreicht: neu aufnehmen (läuft schon eine Wiederholung: von ihr überblenden)
                    if (play) fadeFrom(p + dir, dir); else { rec = 0; gainSm = 1; }
                    wait = false; play = true; lenBeats = waitBeats; len = frames(waitBeats);
                    xf = std::min(xfMax, len / 4); t = 0; take = 0; gain = 1; rep = repGain(); p = -1; dir = 1;
                }
            }
            mix += ((on ? amount : 0.f) - mix) * kMix;
            if (!play) continue;   // wartet: Live-Signal unverändert
            if (t < len + xf) { bufL[size_t(t)] = xl; bufR[size_t(t)] = xr; take = int(t) + 1; rec = std::max(rec, take); }
            int ph = int(t % len);
            if (t >= len && ph == 0) gain *= rep;
            int q = t < len ? ph : (reverse ? len - 1 - ph : ph), qd = t < len || !reverse ? 1 : -1;
            if (t > 0 && q != p + dir) fadeFrom(p + dir, dir);
            p = q; dir = qd; t++;
            gainSm += (gain - gainSm) * kGain;
            float wl = bufL[size_t(q)], wr = bufR[size_t(q)];
            if (ox > 0) {
                float a = float(ox) / float(xf + 1);
                wl += (bufL[size_t(op)] - wl) * a; wr += (bufR[size_t(op)] - wr) * a;
                op += od; bounce(op, od); ox--;
            }
            if (mix > 0) { L[i] = xl + mix * (wl * gainSm - xl); R[i] = xr + mix * (wr * gainSm - xr); }
        }
        if (!on && mix < 1e-5f) clear();
    }
};

/// LFO für Flanger/Phaser: beat-synchron (Phase = Beat ÷ Periode, 0 auf dem Teiler) oder frei (Hz); Freeze hält die Phase.
/// Wert 0…1 (½ − ½·cos), je Kanal mit Versatz (Spread), am Ende jedes 64er-Abschnitts gerechnet, 10 ms geglättet
/// (Freeze aus / Sync an springen nicht hörbar).
struct BeatLFO {
    double ph = 0; float sm[2] = {-1, -1}, k = 0;
    void init(double fs) { k = onePole(0.01, fs / kLfoSeg); }
    void reset() { sm[0] = sm[1] = -1; }
    void step(float *v, double beatEnd, double periodBeats, double hz, int m, double fs, bool freeze, float spread) {
        if (!freeze) ph = periodBeats > 0 ? frac(beatEnd / periodBeats) : frac(ph + hz * m / fs);
        for (int c = 0; c < 2; c++) {
            float x = float(0.5 - 0.5 * std::cos(2 * kPi * (ph + (c ? 0.5 * spread : 0.0))));
            sm[c] = sm[c] < 0 ? x : sm[c] + (x - sm[c]) * k;
            v[c] = sm[c];
        }
    }
};

/// Flanger: Verzögerung 0,3 … 8 ms (exponentiell um 1,55 ms, Tiefe = Anteil des Bereichs), linear gelesen, Rückkopplung
/// bis 0,85; Ausgang ½·(x + verzögert), Rückkopplung im Pegel ausgeglichen. Eingang mit dem Anteil eingeblendet.
struct Flanger {
    std::vector<float> bufL, bufR; unsigned w = 0, mask = 0;
    BeatLFO lfo; float d[2] = {0, 0}, depthSm = -1, fbSm = 0, mix = 0, kMix = 0; double fs = 44100;
    void init(double rate) {
        fs = rate; unsigned len = 1; while (len < unsigned(0.012 * fs) + 4) len *= 2;
        bufL.assign(len, 0); bufR.assign(len, 0); mask = len - 1;
        lfo.init(fs); kMix = onePole(kFxRampS, fs);
    }
    void clear() { std::fill(bufL.begin(), bufL.end(), 0); std::fill(bufR.begin(), bufR.end(), 0); mix = 0; d[0] = d[1] = 0; depthSm = -1; lfo.reset(); }
    bool active() const { return mix > 0; }
    void run(float *L, float *R, int n, double beat, double bps, double periodBeats, double hz, bool freeze, float spread,
             float depth, float feedback, float amount, bool on) {
        depth = std::clamp(depth, 0.f, 1.f); spread = std::clamp(spread, 0.f, 1.f);
        float fb = std::clamp(feedback, 0.f, 1.f) * 0.85f, target = on ? amount : 0.f;
        double dc = 0.00155 * fs, span = std::log(8.0 / 0.3) * 0.5;
        float wf = float(w + mask + 1);   // Schreibstelle + Pufferlänge: Lesestelle bleibt positiv
        for (int i0 = 0; i0 < n; i0 += kLfoSeg) {
            int m = std::min(kLfoSeg, n - i0);
            float v[2], de[2], inc[2];
            lfo.step(v, beat + (i0 + m) * bps, periodBeats, hz, m, fs, freeze, spread);
            depthSm = depthSm < 0 ? depth : depthSm + (depth - depthSm) * lfo.k;
            for (int c = 0; c < 2; c++) {
                de[c] = float(dc * std::exp(span * depthSm * (2 * v[c] - 1)));
                if (d[c] <= 0) d[c] = de[c];
                inc[c] = (de[c] - d[c]) / float(m);
            }
            bool ramp = settle(mix, target) | settle(fbSm, fb);
            for (int i = i0; i < i0 + m; i++) {
                if (ramp) { mix += (target - mix) * kMix; fbSm += (fb - fbSm) * kMix; }
                float y[2];
                const float *bs[2] = {bufL.data(), bufR.data()};
                for (int c = 0; c < 2; c++) {
                    d[c] += inc[c];
                    float r = wf - d[c];
                    unsigned r0 = unsigned(r); float f = r - float(r0);
                    float a = bs[c][r0 & mask], bb = bs[c][(r0 + 1) & mask];
                    y[c] = a + (bb - a) * f;
                }
                float xl = L[i], xr = R[i];
                bufL[w] = xl * mix + y[0] * fbSm; bufR[w] = xr * mix + y[1] * fbSm;
                w = (w + 1) & mask; wf = float(w + mask + 1);
                float g = 0.5f * (1 - 0.5f * fbSm);
                if (mix > 0) { L[i] = xl + mix * ((xl + y[0]) * g - xl); R[i] = xr + mix * ((xr + y[1]) * g - xr); }
            }
        }
        if (!on && mix < 1e-5f) clear();
    }
};

/// Phaser: 4 oder 8 Allpässe 1. Ordnung je Kanal, Eckfrequenz 130 Hz … 6,2 kHz (exponentiell um 900 Hz, Tiefe = Anteil),
/// Rückkopplung bis 0,8; Ausgang ½·(x + Kette) -> 2 bzw. 4 Kerben. Koeffizienten alle 64 Samples, dazwischen linear.
struct Phaser {
    typedef float f2 __attribute__((ext_vector_type(2)));   // L/R in einem Register
    static constexpr int kMaxStages = 8;
    f2 st[kMaxStages] = {}, fb1 = 0, fb2 = 0;
    float a[2] = {0, 0};
    BeatLFO lfo; float depthSm = 0, fbSm = 0, mix = 0, kMix = 0; bool fresh = true; double fs = 44100;
    void init(double rate) { fs = rate; lfo.init(fs); kMix = onePole(kFxRampS, fs); }
    void clear() { for (auto &x : st) x = 0; fb1 = fb2 = 0; mix = 0; fresh = true; lfo.reset(); }
    bool active() const { return mix > 0; }
    /// Rückkopplung aus dem vorletzten Sample: zwei Samples laufen gleichzeitig durch die Kette
    template <int NS> void segment(float *L, float *R, int i0, int m, const float *inc, float target, float fb) {
        f2 ac = {a[0], a[1]}, ai = {inc[0], inc[1]};
        bool ramp = settle(mix, target) | settle(fbSm, fb);
        for (int i = i0; i < i0 + m; i++) {
            if (ramp) { mix += (target - mix) * kMix; fbSm += (fb - fbSm) * kMix; }
            ac += ai;
            f2 x = {L[i], R[i]}, u = x + fb2 * fbSm;
            for (int k = 0; k < NS; k++) { f2 y = ac * u + st[k]; st[k] = u - ac * y; u = y; }
            fb2 = fb1; fb1 = u;
            if (mix > 0) {
                f2 o = x + mix * ((x + u) * (0.5f * (1 - 0.4f * fbSm)) - x);
                L[i] = o.x; R[i] = o.y;
            }
        }
        a[0] = ac.x; a[1] = ac.y;
    }
    void run(float *L, float *R, int n, double beat, double bps, double periodBeats, double hz, bool freeze, int stages,
             float depth, float feedback, float amount, bool on) {
        depth = std::clamp(depth, 0.f, 1.f);
        float fb = std::clamp(feedback, 0.f, 1.f) * 0.8f, target = on ? amount : 0.f;
        double span = std::log(6200.0 / 130.0) * 0.5;
        for (int i0 = 0; i0 < n; i0 += kLfoSeg) {
            int m = std::min(kLfoSeg, n - i0);
            float v[2], inc[2];
            lfo.step(v, beat + (i0 + m) * bps, periodBeats, hz, m, fs, freeze, 0.5f);   // L/R 90°
            depthSm = fresh ? depth : depthSm + (depth - depthSm) * lfo.k;
            for (int c = 0; c < 2; c++) {
                double f = Biquad::safeF(900 * std::exp(span * depthSm * (2 * v[c] - 1)), fs), tn = std::tan(kPi * f / fs);
                float ae = float((tn - 1) / (tn + 1));
                if (fresh) a[c] = ae;
                inc[c] = (ae - a[c]) / float(m);
            }
            fresh = false;
            if (stages > 4) segment<8>(L, R, i0, m, inc, target, fb); else segment<4>(L, R, i0, m, inc, target, fb);
        }
        if (!on && mix < 1e-5f) clear();
    }
};

// ---------- Insert-Slots (eingebaute Effekte, Audio Unit, VST3 – MixDSPPlugin.h) ----------
// Je FX-Unit × Deck (und im Master-Bus) bis zu kSlots Slots in Reihe, je Slot ein Effekt. Die eingebauten Effekte haben je
// Unit eine Instanz (FXChain), ein Slot sagt nur, wo im Signalfluss sie rechnen. Plugins: je Slot und Deck eine Instanz.
// Slot-Belegung (Effekt + Plugin je Slot) wird als Ganzes getauscht (Sequenzzähler), der Audio-Thread übernimmt sie am
// Blockanfang. Plugin aus = Eingang zu, Ausgang klingt aus; gerechnet wird, bis es 1 s (oder die vom Plugin gemeldete
// Nachklingzeit, höchstens 30 s) unter -100 dB war. Anteil (D/W) je Plugin-Slot: trocken = Eingang des Slots
constexpr int kSlots = MDSP_FX_SLOTS;
constexpr int kDeclick = 256;   // Samples, über die ein Sprung beim Umordnen ausgeglichen wird (~5 ms)

struct RackSlot {
    std::atomic<MDPlugin *> plugin{nullptr};
    std::atomic<int> kind{MDFX_KIND_NONE};
    /// NaN (im Deck oder aus dem Plugin): nicht rechnen, bis der Steuer-Thread es zurückgesetzt hat
    std::atomic<bool> resetPending{false};
    // nur Audio-Thread
    int k = MDFX_KIND_NONE;   // übernommener Effekt
    MDPlugin *last = nullptr;
    float mix = 0;            // Eingang des Plugins (an = 1, aus = 0, Rampe dazwischen)
    int quiet = 0x7fffffff;   // Samples in Folge unter der Schwelle
    int quietLimit(double fs) const {
        double t = last ? double(last->tailFrames.load(std::memory_order_relaxed)) : 0;
        return int(std::clamp(t, fs, 30 * fs));
    }
    bool tail(double fs) const { return last && quiet < quietLimit(fs); }
};

struct Rack {
    RackSlot slot[kSlots];
    /// Slots werden zusammen getauscht: Steuer-Thread zählt vor und nach dem Schreiben hoch (ungerade = wird geschrieben)
    std::atomic<uint32_t> seq{0};
    std::atomic<uint64_t> releaseAt{0};   // Render-Zähler, ab dem herausgenommene Plugins frei sind
    // nur Audio-Thread
    uint32_t seen = 0;
    unsigned present = 0;   // Bit je MDFXKind, das in einem Slot steht
    // Umordnen/Herausnehmen im Betrieb: der Ausgang springt (andere Reihenfolge = andere Funktion). Der Sprung zum letzten
    // Sample des vorigen Teilblocks wird über kDeclick Samples linear ausgeglichen
    bool reordered = false;
    uint64_t lastRun = ~uint64_t(0);    // Teilblock, in dem die Slots zuletzt rechneten
    float lastL = 0, lastR = 0, dcL = 0, dcR = 0;
    int dcLeft = 0;
    std::vector<float> xL, xR;
    void init() { xL.assign(kMaxFrames, 0); xR.assign(kMaxFrames, 0); }
    /// Audio-Thread: vollständig geschriebenen Stand übernehmen. Ein verschobenes Plugin behält Rampe und Fahne, ein neues
    /// beginnt mit geschlossenem Eingang
    void sync() {
        uint32_t s = seq.load(std::memory_order_acquire);
        if (s == seen || (s & 1)) return;
        MDPlugin *p[kSlots]; int kd[kSlots];
        for (int k = 0; k < kSlots; k++) {
            p[k] = slot[k].plugin.load(std::memory_order_acquire);
            kd[k] = slot[k].kind.load(std::memory_order_acquire);
        }
        if (seq.load(std::memory_order_acquire) != s) return;
        seen = s;
        MDPlugin *oldP[kSlots]; float oldMix[kSlots]; int oldQuiet[kSlots];
        for (int k = 0; k < kSlots; k++) { oldP[k] = slot[k].last; oldMix[k] = slot[k].mix; oldQuiet[k] = slot[k].quiet; }
        for (int k = 0; k < kSlots; k++) if (slot[k].k != kd[k] || p[k] != oldP[k]) reordered = true;
        present = 0;
        for (int k = 0; k < kSlots; k++) {
            RackSlot &c = slot[k];
            c.k = kd[k] >= 0 && kd[k] < MDFX_KIND_COUNT ? kd[k] : MDFX_KIND_NONE;
            if (c.k != MDFX_KIND_PLUGIN) p[k] = nullptr;
            present |= 1u << c.k;
            if (p[k] != oldP[k]) {
                c.last = p[k]; c.mix = 0; c.quiet = 0x7fffffff;
                for (int j = 0; j < kSlots; j++) if (p[k] && oldP[j] == p[k]) { c.mix = oldMix[j]; c.quiet = oldQuiet[j]; }
            }
        }
    }
    bool has(int kind) const { return present & (1u << kind); }
    /// ein Plugin rechnet noch (Eingang offen oder Fahne)
    bool pluginActive(double fs) const {
        for (auto &c : slot) if (c.last && (c.mix > 0.0005f || c.tail(fs))) return true;
        return false;
    }
    /// nach den Slots: Sprung durch eine neue Belegung ausgleichen (nur wenn der vorige Teilblock auch gerechnet wurde)
    void declick(float *L, float *R, int n, uint64_t block) {
        if (reordered) {
            reordered = false;
            if (lastRun + 1 == block && n > 0) { dcL = lastL - L[0]; dcR = lastR - R[0]; dcLeft = kDeclick; }
        }
        for (int i = 0; i < n && dcLeft > 0; i++, dcLeft--) {
            float w = float(dcLeft) / float(kDeclick);
            L[i] += dcL * w; R[i] += dcR * w;
        }
        if (n > 0) { lastL = L[n - 1]; lastR = R[n - 1]; }
        lastRun = block;
    }
    /// NaN/Inf aus einem Plugin auf 0 (sonst vergiftet es die folgenden Slots), Slot zurücksetzen lassen; Spitzenwert
    static float clean(RackSlot &c, float *L, float *R, int n) {
        float peak = 0; bool bad = false;
        for (int i = 0; i < n; i++) {
            if (!std::isfinite(L[i])) { L[i] = 0; bad = true; }
            if (!std::isfinite(R[i])) { R[i] = 0; bad = true; }
            peak = std::max(peak, std::max(std::fabs(L[i]), std::fabs(R[i])));
        }
        if (bad) c.resetPending.store(true, std::memory_order_release);
        return peak;
    }
    /// Plugin-Slot: out = x·(1 − w·m) + P(x·m)·w, m = Eingang (Rampe an/aus), w = Anteil. Aus und verklungen: durchreichen
    void runPlugin(RackSlot &c, float *L, float *R, int n, float w, bool on, double tempo, double beat, double fs) {
        MDPlugin *p = c.last;
        if (!p || c.resetPending.load(std::memory_order_acquire)) return;
        float target = on ? 1.f : 0.f;
        if (!on && c.mix <= 0.0005f && !c.tail(fs)) return;
        p->tempo = tempo; p->beat = beat;
        std::memcpy(xL.data(), L, sizeof(float) * n); std::memcpy(xR.data(), R, sizeof(float) * n);
        float m = c.mix;
        for (int i = 0; i < n; i++) { m += (target - m) * 0.002f; L[i] *= m; R[i] *= m; }
        mdplug_process(p, L, R, n);
        float peak = clean(c, L, R, n);
        for (int i = 0; i < n; i++) {
            c.mix += (target - c.mix) * 0.002f;
            float k = 1 - w * c.mix;
            L[i] = xL[i] * k + L[i] * w; R[i] = xR[i] * k + R[i] * w;
        }
        if (on || peak >= 1e-5f) c.quiet = 0; else if (c.quiet < 0x7fff0000) c.quiet += n;
    }
    /// Steuer-Thread: alle Slots in einem Schritt
    void set(const int *kinds, MDPlugin *const *p, int count, uint64_t renders) {
        seq.fetch_add(1, std::memory_order_acq_rel);
        for (int k = 0; k < kSlots; k++) {
            int kd = k < count && kinds ? kinds[k] : MDFX_KIND_NONE;
            slot[k].kind.store(kd, std::memory_order_release);
            slot[k].plugin.store(k < count && p && kd == MDFX_KIND_PLUGIN ? p[k] : nullptr, std::memory_order_release);
        }
        seq.fetch_add(1, std::memory_order_release);
        // ein Block, der vor dem Tausch begann, kann die alten noch rechnen – frei erst nach dem nächsten fertigen Block
        releaseAt.store(renders + 1);
    }
    bool contains(MDPlugin *p) const {
        for (auto &c : slot) if (c.plugin.load() == p) return true;
        return false;
    }
};

struct FXChain {   // eingebaute Effekte einer FX-Unit für ein Deck (bzw. den Master-Bus), dazu ihre Slots
    SweepFilter filter, delayFilter, rollFilter; Delay delay; Reverb reverb; ReverbClassic classic;
    Gater gater; Roll roll; Flanger flanger; Phaser phaser;
    Rack rack;
    void init(double fs) {
        delay.init(fs); reverb.init(fs); classic.init(fs);
        gater.init(fs); roll.init(fs); flanger.init(fs); phaser.init(fs);
        rack.init();
    }
};

struct TrackSlot { const float *L = nullptr, *R = nullptr; int64_t frames = 0; double rate = 44100; double start = 0; };

struct Deck {
    // vom Steuer-Thread geschrieben
    std::atomic<float> p[MD_PARAM_COUNT];
    std::atomic<double> pendingSeek{NAN};
    std::atomic<int> pendingFollow{-1};   // Position dieses Decks übernehmen (Instant Double), -1 = nichts
    std::atomic<int> loopVersion{0};
    std::atomic<bool> loopActiveReq{false};
    std::atomic<double> loopStartReq{0}, loopEndReq{0};
    // Schnitt (Sekunden, Ende 0 = Track-Ende), als Paar per Sequenzzähler (ungerade = wird geschrieben)
    std::atomic<uint32_t> trimSeq{0};
    std::atomic<double> trimStartReq{0}, trimEndReq{0};
    // Wellenform greifen (Sekunden): 0 = aus, 1 = Hand auf der Platte, 2 = losgelassen (läuft aufs Ziel aus)
    std::atomic<int> scratchMode{0};
    std::atomic<double> scratchTarget{0};
    // Track-Übergabe: Steuer-Thread füllt Slot (gen & 1) und veröffentlicht gen, Audio-Thread übernimmt und bestätigt
    TrackSlot slots[2];
    std::atomic<uint32_t> pendingGen{0};    // 0 = nichts ausstehend
    std::atomic<uint32_t> consumedGen{0};   // zuletzt übernommene Generation
    uint32_t loadGen = 0;                   // nur Steuer-Thread

    // vom Audio-Thread gelesen/geschrieben, nach außen atomar gespiegelt
    std::atomic<double> posOut{0}, fluxOut{0};
    // Host-Zeit (mach-Ticks) am Ende des Blocks zu posOut (0 = unbekannt); Seqlock wie der Takt-Stempel
    std::atomic<uint32_t> posSeq{0};
    std::atomic<uint64_t> posHost{0};
    std::atomic<bool> playingOut{false}, loopActiveOut{false};
    std::atomic<double> loopStartOut{0}, loopEndOut{0};
    std::atomic<float> rms{0}, peak{0};

    // nur Audio-Thread
    TrackSlot cur;
    double pos = 0, flux = 0, inAcc = 0;
    bool loopActive = false; double loopStart = 0, loopEnd = 0; int seenLoop = 0;
    double trimS = 0, trimE = 0; uint32_t seenTrim = 0;   // übernommener Schnitt (Sekunden)
    // je Block aus Track, Schnitt und Loop (Frames): hörbarer Bereich [lo, hi), Rampen an geschnittenen Rändern,
    // wirksamer Loop (nur der Teil im Schnitt)
    double lo = 0, hi = 0, fadeIn = 0, fadeOut = 0;
    bool loopWrap = false; double loopLo = 0, loopHi = 0;
    bool wasStretching = false;
    double latSm = 0;   // geglättete Keylock-Latenz (sonst springt die Position bei Tempowechseln)
    int latDir = 1;     // Richtung, in die der Lesekopf der Latenz vorausläuft
    float gainSm = 1, volSm = 0;
    EQBands eq;
    SweepFilter chanFilter;
    FXChain fx[MDSP_FX_UNITS];
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    std::vector<float> inL, inR, outL, outR;
    // Übergabe Teilblock -> Summe (Worker schreibt, Audio-Thread liest nach dem Join)
    bool blockHas = false, blockOk = true;   // etwas gerechnet / ohne NaN

    Deck() {
        for (auto &x : p) x.store(0);
        p[MD_RATE].store(1); p[MD_VOLUME].store(1); p[MD_FILTER_RES].store(0.6f);
    }
};

} // namespace

struct Clock {
    std::atomic<double> bpm{128}, setBeat{NAN}, beatOut{0};
    std::atomic<double> trim{0};   // Phasen-Trim (Beats), vom Audio-Thread einmal addiert
    std::atomic<bool> metroOn{false};
    std::atomic<float> metroVol{0.5f};
    std::atomic<int> metroCh{0};
    double beat = 0;
    // Beat am Blockanfang + Host-Zeit des Blocks (für Link), per Sequenzzähler konsistent lesbar
    std::atomic<uint32_t> stampSeq{0};
    std::atomic<double> stampBeat{0};
    std::atomic<uint64_t> stampHost{0};
    // Klick-Synthese (kurzer Sinus mit Abklingen)
    double clickPhase = 0, clickFreq = 1000; float clickEnv = 0;
};

// Decks parallel: Worker-Threads rechnen Deck B–D, der Audio-Thread Deck A, die Summe danach seriell.
// Wecken je Block per Semaphore (kein Spin), Worker treten der Workgroup des Geräte-IO-Threads bei und laufen mit
// Echtzeit-Policy (Blockdauer als Periode). Threads entstehen beim ersten Einschalten (Steuer-Thread), nie im Audio-Thread.
struct Workers {
    static constexpr int N = MDSP_DECKS - 1;
    std::atomic<bool> enabled{false};      // Audio-Thread liest je Teilblock
    std::atomic<bool> quit{false};
    std::atomic<bool> started{false};      // setzt der Steuer-Thread, liest auch die Geräte-Queue (mdsp_set_workgroup)
    std::thread threads[N];
    int n = 0;                             // Frames des laufenden Teilblocks (vor dem Wecken gesetzt)
    /// Teilblock-Zähler je Worker, beim Auftrag kopiert (der Audio-Thread zählt weiter, während ein verspäteter Worker noch rechnet)
    std::atomic<uint64_t> subOf[N] {};
#if defined(__APPLE__)
    dispatch_semaphore_t go[N] = {}, done[N] = {};
    std::mutex wgLock;                     // Steuer-Thread beim Setzen, Worker per try_lock beim Beitritt
    os_workgroup_t wg = nullptr;           // retained; Worker halten beim Beitritt eine eigene Referenz
    double period = 0;                     // Blockdauer in Sekunden (Echtzeit-Policy der Worker)
    std::atomic<uint32_t> wgGen{0};        // jede Änderung von wg/period
#endif
    std::atomic<int> joined{0}, realtime{0};   // Worker in der Workgroup / mit Echtzeit-Policy (Diagnose)
    // Watchdog: je Worker ein Auftrag `job` = Ticket << 2 | Phase. Der Audio-Thread vergibt (POSTED) und zieht nach
    // der Frist zurück (POSTED -> CANCELLED, der Worker rechnet dann nicht); der Worker übernimmt (POSTED -> RENDERING)
    // und meldet fertig (-> IDLE, dann `done[w]`). Ein Deck, dessen Worker noch rechnet, bleibt still, bis er fertig ist
    enum : uint32_t { IDLE = 0, POSTED = 1, RENDERING = 2, CANCELLED = 3 };
    std::atomic<uint32_t> job[N] = {};
    uint32_t ticket[N] = {};               // nur Audio-Thread
    bool owed[N] = {};                     // nur Audio-Thread: ein `done[w]` steht nach Fristablauf noch aus
    uint64_t postedNs[N] = {};             // nur Audio-Thread: Vergabe des ausstehenden Auftrags
    std::atomic<int> stuck{0};             // Worker mit ausstehendem Auftrag nach Fristablauf (Freigaben warten)
    std::atomic<uint32_t> timeouts{0};     // Fristabläufe seit Start
    std::atomic<uint64_t> lastTimeoutNs{0};   // Zeitpunkt (nowNs) des letzten Fristablaufs
    std::atomic<uint64_t> lastHangNs{0};      // wie lange der Worker beim letzten Fristablauf brauchte (bis fertig oder bis jetzt)
    std::atomic<uint32_t> synced[N] = {};   // je Worker: übernommene wgGen (+1, 0 = noch nie)
    std::atomic<uint32_t> testStallUs[N] = {};   // nur Tests: Worker schläft vor (negativ: vor der Übernahme) dem Rechnen
    std::atomic<int32_t> testStallMode[N] = {};
};

/// Master-Bus: Plugin-Kette nach der Summe der Decks auf einem Kanalpaar (Audio-Thread, seriell nach den Decks)
struct MasterBus {
    FXChain fx;
    std::atomic<int> ch{-1};              // erster Kanal des Paars, -1 = aus (externer Mixer: kein Summenpunkt)
    std::atomic<float> rms{0}, peak{0};   // Pegel des Paars nach dem Master-Bus, vor der Master-Lautstärke
};

// Profil des Render-Blocks: Nanosekunden je Abschnitt im schwersten Block seit dem letzten Abholen (Diagnose, Lasttest).
// Abschnitte: Deck A–D (seriell; parallel nur A, B–D stehen in `wait`), Warten auf die Worker, Summe + Master-Bus,
// Master-Lautstärke/Begrenzung/Clock, Vorhören. Schreibt nur der Audio-Thread, liest der Steuer-Thread (Sequenzzähler)
struct RenderProfile {
    static constexpr int N = 8;
    enum { A = 0, B, C, D, WAIT, MIX, MASTER, PREVIEW };
    std::atomic<uint32_t> seq{0};
    uint64_t worst = 0;             // Gesamtzeit des schwersten Blocks (ns)
    uint64_t parts[N] = {};
    uint32_t frames = 0;
    uint64_t cur[N] = {};           // laufender Block
};

struct MDEngine {
    double fs;
    Clock clock;
    Workers workers;
    RenderProfile profile;
    Deck decks[MDSP_DECKS];
    // je FX-Unit, dahinter der Master-Bus (Index MDSP_FX_UNITS)
    std::atomic<float> fxp[MDSP_FX_UNITS + 1][MDFX_PARAM_COUNT];
    std::atomic<float> slotOn[MDSP_FX_UNITS + 1][MDSP_FX_SLOTS];    // Plugin-Slot an (gilt für alle Decks der Unit)
    std::atomic<float> slotWet[MDSP_FX_UNITS + 1][MDSP_FX_SLOTS];   // Anteil des Plugin-Slots
    MasterBus bus;
    std::atomic<float> master{0.85f};
    float masterSm = 0.85f;
    uint64_t renderHost = 0;   // setzt der CoreAudio-Callback vor jedem Block
    uint64_t subStampHost = 0; // Host-Zeit am Ende des laufenden Teilblocks (Stempel der Position, 0 = unbekannt)
    std::atomic<uint64_t> renders{0};   // fertig gerechnete Blöcke (Plugin-Übergabe)
    uint64_t subBlock = 0;              // laufender Teilblock (nur Audio-Thread; Worker bekommen eine Kopie je Auftrag)
    double blockPos[MDSP_DECKS] = {};   // hörbare Positionen am Anfang des laufenden Blocks (nur Audio-Thread)
    MDPreview preview;                  // Vorhören (Preview.cpp)
    double fxBeat = 0, fxBps = 0;       // Clock am Anfang des Teilblocks, Beats je Sample (Beat-FX, Plugins)
    // Aufnahme-Abgriff des Masters (MixDSPRecord.h): Ring, erstes Kanalpaar, Freigabe nach einem Block ohne ihn
    std::atomic<MDRing *> recTap{nullptr};
    std::atomic<int> recCh{-1};
    std::atomic<uint64_t> recReleaseAt{0};
    std::atomic<uint64_t> recCostNs{0}, recWorstNs{0};
    std::atomic<uint32_t> recBlocks{0};
};

MDPreview &mdsp_preview_of(MDEngine *e) { return e->preview; }

// ---------- Lesen aus dem Track ----------

/// Grenzen für diesen Block: Schnitt (falls gültig, sonst die ganze Datei) und der Loop innerhalb davon
static void updateBounds(Deck &d) {
    uint32_t q = d.trimSeq.load(std::memory_order_acquire);
    if (q != d.seenTrim && !(q & 1)) {
        double s = d.trimStartReq.load(std::memory_order_relaxed), en = d.trimEndReq.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (d.trimSeq.load(std::memory_order_relaxed) == q) { d.trimS = s; d.trimE = en; d.seenTrim = q; }
    }
    const TrackSlot &t = d.cur;
    double fr = double(t.frames), s = d.trimS * t.rate, en = d.trimE * t.rate;
    if (!(en > 0) || en > fr) en = fr;
    if (!(s > 0)) s = 0;
    if (!(en > s)) { s = 0; en = fr; }   // Schnitt hinter dem Track-Ende o. Ä.: ganze Datei
    d.lo = s; d.hi = en;
    double f = std::min(kTrimFadeS * t.rate, (en - s) / 2);
    d.fadeIn = s > 0 ? f : 0;
    d.fadeOut = en < fr ? f : 0;
    double ls = std::max(d.loopStart * t.rate, s), le = std::min(d.loopEnd * t.rate, en);
    d.loopWrap = d.loopActive && le > ls;
    d.loopLo = ls; d.loopHi = le;
}

/// Faktor eines Samples: 0 außerhalb des hörbaren Bereichs (Schnitt bzw. Datei), Rampe an geschnittenen Rändern
static inline float gate(const Deck &d, int64_t k) {
    double x = double(k);
    if (x < d.lo || x >= d.hi) return 0.f;
    double g = 1;
    if (x < d.lo + d.fadeIn) g = (x - d.lo) / d.fadeIn;
    if (x > d.hi - 1 - d.fadeOut) g = std::min(g, (d.hi - 1 - x) / d.fadeOut);
    return float(g);
}

/// Position nach einem Schritt: Loop (nur im Schnitt), rückwärts nicht vor den Start
static inline void wrap(Deck &d, double step) {
    if (d.loopWrap) {
        if (step > 0 && d.pos >= d.loopHi) d.pos -= (d.loopHi - d.loopLo);
        if (step < 0 && d.pos < d.loopLo) d.pos += (d.loopHi - d.loopLo);
    }
    if (d.pos < d.lo) d.pos = d.lo;
}

/// ganzzahlig lesen (für den Keylock-Weg), mit Richtung und Loop
static void readInput(Deck &d, float *L, float *R, int n, int dir) {
    const TrackSlot &t = d.cur;
    const double full0 = d.lo + d.fadeIn, full1 = d.hi - 1 - d.fadeOut;   // hier ohne Rampe
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(d.pos);
        double x = double(k);
        if (x >= full0 && x <= full1) { L[i] = t.L[k]; R[i] = t.R[k]; }
        else { float g = gate(d, k); if (g > 0) { L[i] = t.L[k] * g; R[i] = t.R[k] * g; } else { L[i] = R[i] = 0; } }
        d.pos += dir;
        wrap(d, dir);
    }
}

/// Stretch nach einem Sprung vorfüllen: Audio, das an der aktuellen Position endet (keine Lücke, kein Verschmieren)
static void primeStretch(Deck &d, int dir, double rateSrc) {
    const TrackSlot &t = d.cur;
    int n = std::min(kMaxIn, d.stretch.inputLatency() * 2 + 1024);
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(d.pos) - int64_t(dir) * (n - i);
        float g = gate(d, k);
        d.inL[i] = g > 0 ? t.L[k] * g : 0.f;
        d.inR[i] = g > 0 ? t.R[k] * g : 0.f;
    }
    float *ins[2] = {d.inL.data(), d.inR.data()};
    d.stretch.seek(ins, n, rateSrc);
}

/// gebrochen lesen mit 4-Punkt-Hermite (Varispeed, Tonhöhe folgt dem Tempo)
static void readResampled(Deck &d, float *L, float *R, int n, double step) {
    const TrackSlot &t = d.cur;
    // alle vier Stützstellen ohne Rampe im Bereich -> direkt lesen, sonst je Stützstelle mit Faktor
    const double full0 = d.lo + d.fadeIn + 1, full1 = d.hi - 1 - d.fadeOut - 2;
    auto at = [&](const float *b, int64_t k) -> float { float g = gate(d, k); return g > 0 ? b[k] * g : 0.f; };
    for (int i = 0; i < n; i++) {
        int64_t k = int64_t(std::floor(d.pos));
        float f = float(d.pos - double(k));
        bool direct = double(k) >= full0 && double(k) <= full1;
        for (int c = 0; c < 2; c++) {
            const float *b = c == 0 ? t.L : t.R;
            float xm1, x0, x1, x2;
            if (direct) { xm1 = b[k - 1]; x0 = b[k]; x1 = b[k + 1]; x2 = b[k + 2]; }
            else { xm1 = at(b, k - 1); x0 = at(b, k); x1 = at(b, k + 1); x2 = at(b, k + 2); }
            float c1 = 0.5f * (x1 - xm1), c2 = xm1 - 2.5f * x0 + 2 * x1 - 0.5f * x2, c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
            float y = ((c3 * f + c2) * f + c1) * f + x0;
            (c == 0 ? L : R)[i] = y;
        }
        d.pos += step;
        wrap(d, step);
    }
}

/// NaN/Inf im Deck (kaputte Samples, instabiler Zustand): alle rekursiven Zustände zurück, sonst bleibt das Deck
/// dauerhaft stumm. Läuft im Audio-Thread – nur Füllen vorhandener Puffer.
static void healDeck(Deck &d) {
    d.eq.clearState();
    d.chanFilter.bq.clearState();
    for (auto &c : d.fx) {
        c.filter.bq.clearState(); c.delayFilter.bq.clearState(); c.rollFilter.bq.clearState();
        c.delay.clear(); c.reverb.clear(); c.classic.clear();
        c.gater.clear(); c.roll.clear(); c.flanger.clear(); c.phaser.clear();
        for (Biquad *b : {&c.reverb.hp1, &c.reverb.hp2, &c.reverb.lp, &c.reverb.lowCut, &c.reverb.tilt,
                          &c.classic.hp, &c.classic.lp, &c.classic.lowCut}) b->clearState();   // clear() lässt die Filter stehen
        for (auto &k : c.rack.slot) if (k.last) k.resetPending.store(true);   // Plugins zurücksetzen lassen (Steuer-Thread), bis dahin durchreichen
        c.rack.dcLeft = 0; c.rack.lastRun = ~uint64_t(0);
    }
    d.stretch.reset();
    d.wasStretching = false; d.latSm = 0; d.inAcc = 0;
    if (!std::isfinite(d.pos)) d.pos = 0;
    if (!std::isfinite(d.flux)) d.flux = d.pos;
    d.gainSm = 0; d.volSm = 0;   // weich wieder einblenden
}

// ---------- ein Deck rendern und in die Ausgänge mischen ----------

static void mixDeck(MDEngine *e, Deck &d, float **out, int channels, int n);

/// eine FX-Unit (bzw. den Master-Bus, unit = MDSP_FX_UNITS) auf einen Teilblock: Slots in Reihenfolge, danach klingen
/// eingebaute Effekte aus, die nicht mehr im Rack stehen. Jeder Effekt rechnet nur, solange er an ist oder noch klingt
static void runFX(MDEngine *e, FXChain &c, int u, float *L, float *R, int n, uint64_t sub) {
    auto &fp = e->fxp[u];
    Rack &rack = c.rack;
    rack.sync();
    float dw = fp[MDFX_DRYWET].load();
    auto on = [&](MDFXParam p) { return fp[p].load() > 0.5f; };
    auto filter = [&](SweepFilter &f, MDFXParam pOn, MDFXParam pAmount, MDFXParam pRes) {
        if (fp[pOn].load() > 0.5f) {
            f.update((fp[pAmount].load() * 2 - 1) * dw, fp[pRes].load(), e->fs);
            f.run(L, R, n);
        }
    };
    auto roll = [&](bool inRack) {
        bool rollOn = inRack && on(MDFX_ROLL_ON);
        if (rollOn || c.roll.active())
            c.roll.run(L, R, n, e->fxBeat, e->fxBps, fp[MDFX_ROLL_BEATS].load(), on(MDFX_ROLL_REVERSE), fp[MDFX_ROLL_DECAY].load(),
                       fp[MDFX_ROLL_AMOUNT].load() * dw, rollOn);
    };
    auto gater = [&](bool inRack) {
        bool gaterOn = inRack && on(MDFX_GATER_ON);
        if (gaterOn || c.gater.active())
            c.gater.run(L, R, n, e->fxBeat, e->fxBps, fp[MDFX_GATER_BEATS].load(), fp[MDFX_GATER_SHAPE].load(), fp[MDFX_GATER_WIDTH].load(),
                        on(MDFX_GATER_MUTE), fp[MDFX_GATER_AMOUNT].load() * dw, gaterOn);
    };
    auto flanger = [&](bool inRack) {
        bool flangerOn = inRack && on(MDFX_FLANGER_ON);
        if (flangerOn || c.flanger.active())
            c.flanger.run(L, R, n, e->fxBeat, e->fxBps, fp[MDFX_FLANGER_BEATS].load(), fp[MDFX_FLANGER_HZ].load(), on(MDFX_FLANGER_FREEZE),
                          fp[MDFX_FLANGER_SPREAD].load(), fp[MDFX_FLANGER_DEPTH].load(), fp[MDFX_FLANGER_FEEDBACK].load(),
                          fp[MDFX_FLANGER_AMOUNT].load() * dw, flangerOn);
    };
    auto phaser = [&](bool inRack) {
        bool phaserOn = inRack && on(MDFX_PHASER_ON);
        if (phaserOn || c.phaser.active())
            c.phaser.run(L, R, n, e->fxBeat, e->fxBps, fp[MDFX_PHASER_BEATS].load(), fp[MDFX_PHASER_HZ].load(), on(MDFX_PHASER_FREEZE),
                         int(fp[MDFX_PHASER_STAGES].load()), fp[MDFX_PHASER_DEPTH].load(), fp[MDFX_PHASER_FEEDBACK].load(),
                         fp[MDFX_PHASER_AMOUNT].load() * dw, phaserOn);
    };
    auto delay = [&](bool inRack) {
        bool delayOn = inRack && fp[MDFX_DELAY_ON].load() > 0.5f;
        if (delayOn || c.delay.active()) {
            float a = fp[MDFX_DELAY_AMOUNT].load();
            c.delay.run(L, R, n, fp[MDFX_DELAY_SECONDS].load(), fp[MDFX_DELAY_FEEDBACK].load() * (0.4f + 0.6f * a), a * dw, e->fs, delayOn);
        }
    };
    // zwei Hall-Typen: der gewählte läuft, der andere klingt nach einem Wechsel aus
    auto reverb = [&](bool inRack) {
        bool reverbOn = inRack && fp[MDFX_REVERB_ON].load() > 0.5f;
        bool fdn = fp[MDFX_REVERB_TYPE].load() > 0.5f, onC = reverbOn && !fdn, onF = reverbOn && fdn;
        if (onC || onF || c.classic.active() || c.reverb.active()) {
            bool dwSend = fp[MDFX_REVERB_DWSEND].load() > 0.5f, frz = fp[MDFX_REVERB_FREEZE].load() > 0.5f;
            float amt = fp[MDFX_REVERB_AMOUNT].load(), size = fp[MDFX_REVERB_SIZE].load(), hpP = fp[MDFX_REVERB_HP].load(),
                  lpP = fp[MDFX_REVERB_LP].load(), lvl = fp[MDFX_REVERB_LEVEL].load(), br = fp[MDFX_REVERB_BRIGHT].load(),
                  pre = fp[MDFX_REVERB_PREDELAY].load();
            float level = dwSend ? dw : 1.f, wet = dwSend ? amt : amt * dw;
            if (onC || c.classic.active()) c.classic.run(L, R, n, size, level, wet, hpP, lpP, lvl, br, pre, onC, dwSend, frz);
            if (onF || c.reverb.active()) c.reverb.run(L, R, n, size, level, wet, hpP, lpP, lvl, br, pre, onF, dwSend, frz);
        }
    };
    double tempo = e->clock.bpm.load(std::memory_order_relaxed);
    for (int k = 0; k < kSlots; k++) {
        RackSlot &s = rack.slot[k];
        switch (s.k) {
        case MDFX_KIND_FILTER: filter(c.filter, MDFX_FILTER_ON, MDFX_FILTER_AMOUNT, MDFX_FILTER_RES); break;
        case MDFX_KIND_DELAY:
            filter(c.delayFilter, MDFX_DELAY_FILTER_ON, MDFX_DELAY_FILTER_AMOUNT, MDFX_DELAY_FILTER_RES);
            delay(true);
            break;
        case MDFX_KIND_REVERB: reverb(true); break;
        case MDFX_KIND_GATER: gater(true); break;
        case MDFX_KIND_ROLL:
            roll(true);   // Filter danach: formt auch die Wiederholung
            filter(c.rollFilter, MDFX_ROLL_FILTER_ON, MDFX_ROLL_FILTER_AMOUNT, MDFX_ROLL_FILTER_RES);
            break;
        case MDFX_KIND_FLANGER: flanger(true); break;
        case MDFX_KIND_PHASER: phaser(true); break;
        case MDFX_KIND_PLUGIN:
            rack.runPlugin(s, L, R, n, e->slotWet[u][k].load(std::memory_order_relaxed) * dw,
                           e->slotOn[u][k].load(std::memory_order_relaxed) > 0.5f, tempo, e->fxBeat, e->fs);
            break;
        default: break;
        }
    }
    // aus dem Rack genommen: Eingang zu, Fahne klingt hinter den Slots aus
    if (!rack.has(MDFX_KIND_ROLL)) roll(false);
    if (!rack.has(MDFX_KIND_GATER)) gater(false);
    if (!rack.has(MDFX_KIND_FLANGER)) flanger(false);
    if (!rack.has(MDFX_KIND_PHASER)) phaser(false);
    if (!rack.has(MDFX_KIND_DELAY)) delay(false);
    if (!rack.has(MDFX_KIND_REVERB)) reverb(false);
    rack.declick(L, R, n, sub);
}

/// ein Deck für einen Teilblock rechnen (Abspielen, Kanalzug, FX, Fader) -> d.outL/outR; die Summe macht mixDeck
// posOut und Stempel zusammen veröffentlichen (Seqlock: Steuer-Thread liest ohne Sperre, nie bei Schreibvorgang)
static inline void publishPos(Deck &d, double pos, uint64_t host) {
    d.posSeq.fetch_add(1, std::memory_order_acq_rel);
    d.posOut.store(pos, std::memory_order_relaxed);
    d.posHost.store(host, std::memory_order_relaxed);
    d.posSeq.fetch_add(1, std::memory_order_release);
}

static void renderDeckBlock(MDEngine *e, Deck &d, int n, uint64_t sub) {
    d.blockHas = false; d.blockOk = true;
    // ausstehende Änderungen übernehmen
    uint32_t pg = d.pendingGen.exchange(0);
    if (pg) {
        d.cur = d.slots[pg & 1];
        d.pos = d.cur.start * d.cur.rate; d.flux = d.pos;
        d.loopActive = false; d.inAcc = 0;
        d.stretch.reset();
        d.consumedGen.store(pg);
    }
    bool jumped = pg != 0;
    double seek = d.pendingSeek.exchange(NAN);
    if (!std::isnan(seek) && d.cur.frames > 0) {
        d.pos = std::max(0.0, seek) * d.cur.rate; d.flux = d.pos; d.inAcc = 0;
        jumped = true;
    }
    // Instant Double: hörbare Position des Quell-Decks am Blockanfang – beide Decks rechnen ab hier dieselben Samples
    int fsrc = d.pendingFollow.exchange(-1);
    if (fsrc >= 0 && fsrc < MDSP_DECKS && d.cur.frames > 0) {
        d.pos = std::max(0.0, e->blockPos[fsrc]) * d.cur.rate; d.flux = d.pos; d.inAcc = 0;
        jumped = true;
    }
    int lv = d.loopVersion.load();
    if (lv != d.seenLoop) {
        d.seenLoop = lv;
        d.loopActive = d.loopActiveReq.load(); d.loopStart = d.loopStartReq.load(); d.loopEnd = d.loopEndReq.load();
    }
    // Schnitt: hörbare Position außerhalb (Sprung, Ladeposition, Schnitt geändert) -> auf die Grenze, Stretch neu vorfüllen
    updateBounds(d);
    if (d.cur.frames > 0) {
        double heard = d.wasStretching && !jumped ? d.pos - d.latSm * d.latDir : d.pos;
        if (heard < d.lo || heard > d.hi) {
            d.pos = std::clamp(heard, d.lo, d.hi); d.inAcc = 0;
            jumped = true;
        }
    }

    // Wellenform greifen: die Hand auf der Platte rechnet auch im Stopp (ein Teller unter der Hand klingt)
    int sm = d.scratchMode.load();
    bool scratch = sm != 0 && d.cur.frames > 0;
    bool playing = (d.p[MD_PLAYING].load() > 0.5f || scratch) && d.cur.frames > 0;
    // Keylock aus oder Stopp: Lesekopf (läuft der Stretch-Latenz voraus) auf die hörbare Position zurück
    bool stretchNow = playing && !scratch && (d.p[MD_KEYLOCK].load() > 0.5f || d.p[MD_KEYSHIFT].load() != 0);
    if (d.wasStretching && !stretchNow) {
        if (!jumped) { d.pos = std::max(0.0, d.pos - d.latSm * d.latDir); d.flux = std::max(0.0, d.flux - d.latSm * d.latDir); }
        d.latSm = 0; d.wasStretching = false;
    }
    // Deck steht: weiterrechnen, solange Echo oder Hall noch klingen (gemessen, kein festes Zeitlimit).
    // Plugin-Zeiger zuerst abgleichen: eine nicht zugewiesene Unit kommt unten nicht vorbei, `last` zeigte sonst
    // auf ein längst geschlossenes Plugin, und active() liest dessen Nachklingzeit
    bool fxTail = false;
    for (int u = 0; u < MDSP_FX_UNITS; u++) {
        d.fx[u].rack.sync();
        if (d.p[MD_FX1_ASSIGN + u].load() > 0.5f &&
            (d.fx[u].delay.tail > 1e-5f || d.fx[u].reverb.tail > 1e-5f || d.fx[u].classic.tail > 1e-5f || d.fx[u].rack.pluginActive(e->fs))) fxTail = true;
    }
    if (!playing && !fxTail) {   // Deck steht, kein Hall/Echo-Rest → nichts rechnen
        d.rms.store(d.rms.load() * 0.8f); d.peak.store(d.peak.load() * 0.8f);
        d.playingOut.store(false);
        if (d.cur.frames > 0) d.pos = std::clamp(d.pos, d.lo, d.hi);   // am Ende ein Stück darüber hinaus gelaufen
        publishPos(d, d.pos / d.cur.rate, e->subStampHost); d.fluxOut.store(d.flux / d.cur.rate);
        return;
    }

    float *L = d.outL.data(), *R = d.outR.data();
    double rate = std::clamp(double(d.p[MD_RATE].load()), 0.03, 4.0);
    double srcRatio = d.cur.rate / e->fs;
    int dir = d.p[MD_REVERSE].load() > 0.5f ? -1 : 1;
    float keyShift = d.p[MD_KEYSHIFT].load();
    bool stretching = playing && !scratch && (d.p[MD_KEYLOCK].load() > 0.5f || keyShift != 0);
    bool fluxOn = d.p[MD_FLUX].load() > 0.5f;
    double latencySrc = 0;

    if (!playing) {
        std::memset(L, 0, sizeof(float) * n); std::memset(R, 0, sizeof(float) * n);
    } else if (stretching) {
        if (d.wasStretching && !jumped && dir != d.latDir) {   // Reverse umgeschaltet: von der hörbaren Position aus neu
            d.pos = std::max(0.0, d.pos - d.latSm * d.latDir); d.flux = std::max(0.0, d.flux - d.latSm * d.latDir);
            d.wasStretching = false;
        }
        if (!d.wasStretching || jumped) {
            // Eingang um die Latenz vorauslesen → hörbar exakt an der Zielposition
            d.latSm = d.stretch.inputLatency() + d.stretch.outputLatency() * rate * srcRatio;
            d.latDir = dir;
            d.pos += d.latSm * dir; d.flux += d.latSm * dir;
            primeStretch(d, dir, rate * srcRatio);
        }
        // Eingangslänge für dieses Ausgangsfenster (gebrochen aufsummiert)
        d.inAcc = std::min(d.inAcc + n * rate * srcRatio, double(kMaxIn));   // begrenzt: int-Überlauf bei extremen Raten
        int nIn = std::clamp(int(d.inAcc), 0, kMaxIn);
        d.inAcc -= nIn;
        readInput(d, d.inL.data(), d.inR.data(), nIn, dir);
        double transpose = std::pow(2.0, keyShift / 12.0);
        if (d.p[MD_KEYLOCK].load() <= 0.5f) transpose *= rate;   // ohne Keylock folgt die Tonhöhe dem Tempo
        d.stretch.setTransposeFactor(float(transpose));
        float *ins[2] = {d.inL.data(), d.inR.data()}, *outs[2] = {L, R};
        d.stretch.process(ins, nIn, outs, n);
        latencySrc = d.stretch.inputLatency() + d.stretch.outputLatency() * rate * srcRatio;
    } else if (scratch) {
        // Ziel der Hand (Quell-Frames, im hörbaren Bereich): je Block der Anteil des Abstands, der in kScratchTauS verschwindet
        double tgt = std::clamp(d.scratchTarget.load() * d.cur.rate, d.lo, d.hi);
        double h = std::min(1.0, n / (kScratchTauS * e->fs));
        double step = std::clamp((tgt - d.pos) * h / n, -4.0 * srcRatio, 4.0 * srcRatio);
        bool loopWas = d.loopWrap; d.loopWrap = false;   // ein Loop wirkt nicht gegen die Hand
        readResampled(d, L, R, n, step);
        d.loopWrap = loopWas;
        if (sm == 2 && std::fabs(tgt - d.pos) < 1.0) { int two = 2; d.scratchMode.compare_exchange_strong(two, 0); }   // angekommen
    } else {
        readResampled(d, L, R, n, rate * srcRatio * dir);
    }
    d.wasStretching = stretching;

    // Flux: Schattenposition läuft normal weiter, solange Loop/Reverse aktiv
    if (fluxOn && !scratch && (dir < 0 || d.loopActive)) d.flux += n * rate * srcRatio; else d.flux = d.pos;

    // Ende (Track oder Schnitt): stoppt, sobald die hörbare Position es erreicht (Keylock: der Lesekopf läuft voraus,
    // dahinter liest er Stille – das Ende bleibt hörbar, nichts dahinter)
    if (playing && dir > 0 && (stretching ? d.pos - d.latSm * d.latDir : d.pos) >= d.hi) { d.p[MD_PLAYING].store(0); }

    // Kanalzug: Gain, EQ, Filter
    float g = dbToLin(d.p[MD_GAIN_DB].load());
    const float eqT[3] = {d.p[MD_EQ_LOW].load(), d.p[MD_EQ_MID].load(), d.p[MD_EQ_HIGH].load()};
    for (int i = 0; i < n; i++) {
        d.gainSm += (g - d.gainSm) * 0.002f;
        if (std::fabs(g - d.gainSm) < kSnap) d.gainSm = g;   // float bleibt sonst 3e-5 vor dem Ziel stehen
        L[i] *= d.gainSm; R[i] *= d.gainSm;
    }
    d.eq.run(eqT, L, R, n, e->fs);
    d.chanFilter.update(d.p[MD_FILTER].load(), d.p[MD_FILTER_RES].load(), e->fs);
    d.chanFilter.run(L, R, n);

    // FX-Units
    for (int u = 0; u < MDSP_FX_UNITS; u++) {
        if (d.p[MD_FX1_ASSIGN + u].load() <= 0.5f) continue;
        runFX(e, d.fx[u], u, L, R, n, sub);
    }

    // Lautstärke; Ausgangspaar und Summe in mixDeck (Audio-Thread, nach dem Join)
    float vol = d.p[MD_VOLUME].load();
    float sum = 0, pk = 0;
    for (int i = 0; i < n; i++) {
        d.volSm += (vol - d.volSm) * 0.002f;
        if (std::fabs(vol - d.volSm) < kSnap) d.volSm = vol;
        float l = L[i] * d.volSm, r = R[i] * d.volSm;
        L[i] = l; R[i] = r;
        sum += (l * l + r * r) * 0.5f; pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
    }
    d.blockHas = true;
    if (!std::isfinite(sum)) { d.blockOk = false; sum = pk = 0; }   // Block verwerfen, mixDeck setzt das Deck zurück
    float rms = std::sqrt(sum / std::max(1, n));
    d.rms.store(d.rms.load() * 0.7f + rms * 0.3f);
    d.peak.store(std::max(pk, d.peak.load() * 0.85f));

    // Zustand nach außen: hörbare Position (Keylock-Latenz abgezogen)
    if (stretching) d.latSm += (latencySrc - d.latSm) * 0.02;   // Latenz hängt leicht vom Tempo ab → glätten
    double heard = std::clamp(d.pos - d.latSm * d.latDir, d.lo, std::max(d.lo, d.hi));
    publishPos(d, heard / d.cur.rate, e->subStampHost);
    d.fluxOut.store(std::max(0.0, d.flux - d.latSm * d.latDir) / d.cur.rate);
    d.playingOut.store(d.p[MD_PLAYING].load() > 0.5f);
    d.loopActiveOut.store(d.loopActive);
    d.loopStartOut.store(d.loopStart); d.loopEndOut.store(d.loopEnd);
}

/// Teilblock eines Decks auf sein Kanalpaar summieren (nur Audio-Thread). NaN im Block: andere Decks bleiben hörbar,
/// dieses wird zurückgesetzt
static void mixDeck(MDEngine *e, Deck &d, float **out, int channels, int n) {
    (void)e;
    if (!d.blockHas) return;
    if (!d.blockOk) { healDeck(d); return; }
    int ch = std::clamp(int(d.p[MD_OUT_CHANNEL].load()), 0, std::max(0, channels - 2));
    float *oL = out[ch], *oR = out[std::min(ch + 1, channels - 1)];
    const float *L = d.outL.data(), *R = d.outR.data();
    for (int i = 0; i < n; i++) { oL[i] += L[i]; oR[i] += R[i]; }
}

static inline uint64_t nowNs();

/// Beginn eines weiteren Teilblocks (Frist der Worker), Systemregister
static inline uint64_t subBlockTicks() {
#if defined(__APPLE__)
    return mach_absolute_time();
#else
    return 0;
#endif
}

// ---------- Worker-Threads (Decks parallel) ----------
#if defined(__APPLE__)
/// Echtzeit-Policy wie ein Audio-Thread: Periode = Blockdauer, halbe Periode Rechenzeit, Frist eine Periode
static bool setRealtime(double periodS) {
    if (!(periodS > 0)) periodS = 512.0 / 48000;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticksPerNs = double(tb.denom) / double(tb.numer);
    uint32_t period = uint32_t(std::clamp(periodS * 1e9 * ticksPerNs, 1e4, 4e9));
    thread_time_constraint_policy_data_t p;
    p.period = period; p.computation = period / 2; p.constraint = period; p.preemptible = 1;
    return thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                             reinterpret_cast<thread_policy_t>(&p), THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_SUCCESS;
}

/// Workgroup/Periode übernehmen, wenn sie sich geändert hat (Worker-Thread, außerhalb eines Auftrags: beim Start und
/// nach dem Wecken durch mdsp_set_workgroup). Die Sperre schützt nur das Kopieren; Beitritt und Policy laufen ohne sie
struct WorkerGroup {
    uint32_t gen = 0;
    os_workgroup_t joined = nullptr;
    os_workgroup_join_token_s token{};
    bool rt = false;

    void sync(Workers &W, int w) {
        uint32_t g = W.wgGen.load(std::memory_order_acquire);
        if (W.synced[w].load(std::memory_order_relaxed) && g == gen) return;
        if (!W.wgLock.try_lock()) return;   // Steuer-Thread setzt gerade: beim nächsten Wecken
        g = W.wgGen.load(std::memory_order_acquire);
        os_workgroup_t wg = W.wg;
        if (wg) os_retain(wg);
        double period = W.period;
        W.wgLock.unlock();
        leave(W);
        bool r = setRealtime(period);
        if (r != rt) { W.realtime.fetch_add(r ? 1 : -1); rt = r; }
        if (wg) {
            if (os_workgroup_join(wg, &token) == 0) { joined = wg; W.joined.fetch_add(1); } else os_release(wg);
        }
        gen = g;
        W.synced[w].store(g + 1, std::memory_order_release);
    }
    void leave(Workers &W) {
        if (!joined) return;
        os_workgroup_leave(joined, &token); os_release(joined); joined = nullptr; W.joined.fetch_sub(1);
    }
};

static void workerMain(MDEngine *e, int w) {
    Workers &W = e->workers;
    char name[32];
    snprintf(name, sizeof name, "minos741.deck%c", 'A' + w + 1);
    pthread_setname_np(name);
    DenormalGuard ftz;
    Deck &d = e->decks[w + 1];
    WorkerGroup grp;
    grp.sync(W, w);   // vor dem ersten Auftrag: der erste Beitritt dauert Millisekunden
    for (;;) {
        dispatch_semaphore_wait(W.go[w], DISPATCH_TIME_FOREVER);
        if (W.quit.load(std::memory_order_acquire)) break;
        uint32_t j = W.job[w].load(std::memory_order_acquire);
        if ((j & 3) != Workers::POSTED) { grp.sync(W, w); continue; }   // Wecken ohne Auftrag: neue Workgroup/Periode
        grp.sync(W, w);
        uint32_t stall = W.testStallUs[w].exchange(0, std::memory_order_relaxed);
        bool stallFirst = stall && W.testStallMode[w].load(std::memory_order_relaxed) < 0;
        if (stallFirst) usleep(stall);   // nur Tests: Worker kommt zu spät dran
        // Auftrag übernehmen; zurückgezogen (Frist vorbei) oder veraltetes Wecken: nichts tun, nichts melden
        if (!W.job[w].compare_exchange_strong(j, (j & ~3u) | Workers::RENDERING, std::memory_order_acq_rel)) continue;
        if (stall && !stallFirst) usleep(stall);   // nur Tests: Worker hängt beim Rechnen
        renderDeckBlock(e, d, W.n, W.subOf[w].load(std::memory_order_relaxed));
        W.job[w].store(j & ~3u, std::memory_order_release);   // IDLE, vor dem Signal: wer `done` sieht, sieht IDLE
        dispatch_semaphore_signal(W.done[w]);
    }
    grp.leave(W);
    if (grp.rt) W.realtime.fetch_sub(1);
}

/// Steuer-Thread: bis zu 200 ms warten, bis alle Worker die aktuelle Workgroup/Periode übernommen haben – Beitritt und
/// Echtzeit-Policy dauern beim ersten Mal Millisekunden und sollen nicht in die Frist des ersten Blocks fallen
static void awaitWorkersSynced(Workers &W) {
    uint32_t want = W.wgGen.load(std::memory_order_acquire) + 1;
    for (int i = 0; i < 200; i++) {
        bool all = true;
        for (int w = 0; w < Workers::N; w++) all = all && int32_t(W.synced[w].load(std::memory_order_acquire) - want) >= 0;
        if (all) return;
        usleep(1000);
    }
}

static void startWorkers(MDEngine *e) {
    Workers &W = e->workers;
    if (W.started) return;
    for (int w = 0; w < Workers::N; w++) { W.go[w] = dispatch_semaphore_create(0); W.done[w] = dispatch_semaphore_create(0); }
    for (int w = 0; w < Workers::N; w++) W.threads[w] = std::thread(workerMain, e, w);
    W.started.store(true, std::memory_order_release);
    awaitWorkersSynced(W);
}

static void stopWorkers(MDEngine *e) {
    Workers &W = e->workers;
    W.enabled.store(false);
    if (!W.started) return;
    W.quit.store(true, std::memory_order_release);
    for (int w = 0; w < Workers::N; w++) dispatch_semaphore_signal(W.go[w]);
    for (int w = 0; w < Workers::N; w++) if (W.threads[w].joinable()) W.threads[w].join();
    for (int w = 0; w < Workers::N; w++) {
        if (W.go[w]) { dispatch_release(W.go[w]); W.go[w] = nullptr; }
        if (W.done[w]) { dispatch_release(W.done[w]); W.done[w] = nullptr; }
    }
    if (W.wg) { os_release(W.wg); W.wg = nullptr; }
    W.started = false; W.quit.store(false);
}

/// Audio-Thread: steht nach einem Fristablauf noch ein `done` aus? Ohne Warten abholen (dann frei), sonst true.
/// Solange true, wird das Deck nicht gerechnet (der Worker rechnet es womöglich noch)
static bool workerBusy(MDEngine *e, int w) {
    Workers &W = e->workers;
    if (!W.owed[w]) return false;
    if (dispatch_semaphore_wait(W.done[w], DISPATCH_TIME_NOW) != 0) {
        W.lastHangNs.store(nowNs() - W.postedNs[w], std::memory_order_relaxed);
        return true;
    }
    W.owed[w] = false;
    W.lastHangNs.store(nowNs() - W.postedNs[w], std::memory_order_relaxed);
    W.stuck.fetch_sub(1, std::memory_order_release);
    return false;
}

/// Decks B–D eines Teilblocks an die Worker geben (Deck A rechnet danach der Audio-Thread)
static void postWorkers(MDEngine *e, int n) {
    Workers &W = e->workers;
    W.n = n;
    uint64_t now = nowNs();
    for (int w = 0; w < Workers::N; w++) {
        uint32_t t = (W.ticket[w] + 1) & 0x3fffffffu;
        W.ticket[w] = t;
        W.postedNs[w] = now;
        W.subOf[w].store(e->subBlock, std::memory_order_relaxed);   // vor dem Auftrag (release unten)
        W.job[w].store(t << 2 | Workers::POSTED, std::memory_order_release);
        dispatch_semaphore_signal(W.go[w]);
    }
}

/// auf die Worker warten, höchstens bis 2 × Teilblock ab Blockanfang. Wer die Frist reißt, wird zurückgezogen (noch nicht
/// angefangen) oder als hängend vermerkt (rechnet noch); sein Deck fehlt in diesem Block (`skip`), ab dem nächsten Block
/// rechnet der Kern seriell. Liefert false bei Fristablauf
static bool waitWorkers(MDEngine *e, int n, uint64_t blockStartTicks, bool *skip) {
    Workers &W = e->workers;
    int64_t budgetNs = int64_t(2.0 * double(n) / e->fs * 1e9);
    dispatch_time_t deadline = dispatch_time(blockStartTicks, budgetNs);
    bool ok = true;
    for (int w = 0; w < Workers::N; w++) {
        if (dispatch_semaphore_wait(W.done[w], deadline) == 0) continue;
        uint32_t posted = W.ticket[w] << 2 | Workers::POSTED, j = posted;
        skip[w + 1] = true;
        ok = false;
        if (!W.job[w].compare_exchange_strong(j, (posted & ~3u) | Workers::CANCELLED, std::memory_order_acq_rel)) {
            W.owed[w] = true;
            W.stuck.fetch_add(1, std::memory_order_release);
        }
    }
    if (!ok) {
        uint64_t t = nowNs();
        W.enabled.store(false, std::memory_order_release);
        W.lastHangNs.store(t - W.postedNs[0], std::memory_order_relaxed);
        W.lastTimeoutNs.store(t, std::memory_order_relaxed);
        W.timeouts.fetch_add(1, std::memory_order_release);
    }
    return ok;
}
#else
static void startWorkers(MDEngine *) {}
static void stopWorkers(MDEngine *e) { e->workers.enabled.store(false); }
static bool workerBusy(MDEngine *, int) { return false; }
static void postWorkers(MDEngine *, int) {}
static bool waitWorkers(MDEngine *, int, uint64_t, bool *) { return true; }
#endif

// ---------- C-Schnittstelle ----------

extern "C" {

MDEngine *mdsp_create(double sampleRate) {
    auto *e = new MDEngine();
    e->fs = sampleRate;
    for (auto &d : e->decks) {
        d.inL.assign(kMaxIn, 0); d.inR.assign(kMaxIn, 0);
        d.outL.assign(kMaxFrames, 0); d.outR.assign(kMaxFrames, 0);
        d.stretch.presetDefault(2, float(sampleRate));
        primeStretch(d, 1, 1.0);   // interne Puffer einmal anlegen (nicht erst im Audio-Thread)
        for (auto &c : d.fx) c.init(sampleRate);
    }
    e->bus.fx.init(sampleRate);
    for (auto &u : e->fxp) for (auto &x : u) x.store(0);
    for (auto &u : e->slotOn) for (auto &x : u) x.store(1);
    for (auto &u : e->slotWet) for (auto &x : u) x.store(1);
    for (int u = 0; u <= MDSP_FX_UNITS; u++) {
        e->fxp[u][MDFX_DRYWET].store(1); e->fxp[u][MDFX_DELAY_SECONDS].store(0.46f);
        e->fxp[u][MDFX_DELAY_FEEDBACK].store(0.45f); e->fxp[u][MDFX_REVERB_SIZE].store(0.6f);
        e->fxp[u][MDFX_FILTER_RES].store(0.4f);
        e->fxp[u][MDFX_REVERB_HP].store(0); e->fxp[u][MDFX_REVERB_LP].store(1); e->fxp[u][MDFX_REVERB_DWSEND].store(0);
        e->fxp[u][MDFX_REVERB_LEVEL].store(1); e->fxp[u][MDFX_REVERB_BRIGHT].store(0.6f); e->fxp[u][MDFX_REVERB_PREDELAY].store(0.015f);
        for (auto p : {MDFX_FILTER_AMOUNT, MDFX_DELAY_AMOUNT, MDFX_REVERB_AMOUNT}) e->fxp[u][p].store(0.5f);
        for (auto p : {MDFX_GATER_AMOUNT, MDFX_ROLL_AMOUNT, MDFX_FLANGER_AMOUNT, MDFX_PHASER_AMOUNT}) e->fxp[u][p].store(1);
        e->fxp[u][MDFX_GATER_BEATS].store(0.25f); e->fxp[u][MDFX_GATER_WIDTH].store(0.5f); e->fxp[u][MDFX_ROLL_BEATS].store(0.25f);
        e->fxp[u][MDFX_FLANGER_BEATS].store(4); e->fxp[u][MDFX_FLANGER_HZ].store(0.25f); e->fxp[u][MDFX_FLANGER_DEPTH].store(0.7f);
        e->fxp[u][MDFX_FLANGER_FEEDBACK].store(0.5f); e->fxp[u][MDFX_FLANGER_SPREAD].store(0.5f);
        e->fxp[u][MDFX_PHASER_BEATS].store(2); e->fxp[u][MDFX_PHASER_HZ].store(0.5f); e->fxp[u][MDFX_PHASER_DEPTH].store(0.7f);
        e->fxp[u][MDFX_PHASER_FEEDBACK].store(0.4f); e->fxp[u][MDFX_PHASER_STAGES].store(4);
        for (auto p : {MDFX_DELAY_FILTER_AMOUNT, MDFX_ROLL_FILTER_AMOUNT}) e->fxp[u][p].store(0.5f);
        for (auto p : {MDFX_DELAY_FILTER_RES, MDFX_ROLL_FILTER_RES}) e->fxp[u][p].store(0.4f);
    }
    return e;
}

void mdsp_destroy(MDEngine *e) { stopWorkers(e); delete e; }

void mdsp_set_parallel(MDEngine *e, bool on) {
    if (on) { startWorkers(e); e->workers.enabled.store(e->workers.started); }
    else e->workers.enabled.store(false);
}

bool mdsp_parallel(MDEngine *e) { return e->workers.enabled.load(); }

void mdsp_render_profile(MDEngine *e, uint64_t *parts, int count, uint32_t *frames) {
    RenderProfile &prof = e->profile;
    for (int tries = 0; tries < 8; tries++) {
        uint32_t s0 = prof.seq.load(std::memory_order_acquire);
        if (s0 & 1) continue;
        uint64_t tmp[RenderProfile::N]; uint32_t f = prof.frames;
        for (int i = 0; i < RenderProfile::N; i++) tmp[i] = prof.parts[i];
        if (prof.seq.load(std::memory_order_acquire) != s0) continue;
        for (int i = 0; i < count && i < RenderProfile::N; i++) parts[i] = tmp[i];
        if (frames) *frames = f;
        break;
    }
    prof.worst = 0;   // nächster Block beginnt neu (Audio-Thread schreibt nur bei total > worst; eine verlorene Aktualisierung ist egal)
}

void mdsp_parallel_info(MDEngine *e, int *workers, int *joined, int *realtime) {
    if (workers) *workers = e->workers.started ? Workers::N : 0;
    if (joined) *joined = e->workers.joined.load();
    if (realtime) *realtime = e->workers.realtime.load();
}

void mdsp_parallel_watchdog(MDEngine *e, MDParallelWatchdog *out) {
    if (!out) return;
    Workers &W = e->workers;
    out->timeouts = W.timeouts.load(std::memory_order_acquire);
    out->lastNs = W.lastTimeoutNs.load(std::memory_order_relaxed);
    out->lastHangNs = W.lastHangNs.load(std::memory_order_relaxed);
    out->stuck = W.stuck.load(std::memory_order_acquire);
    out->nowNs = nowNs();
}

void mdsp_debug_stall_worker(MDEngine *e, int worker, uint32_t micros, bool beforeTaking) {
    if (worker < 0 || worker >= Workers::N) return;
    e->workers.testStallMode[worker].store(beforeTaking ? -1 : 1, std::memory_order_relaxed);
    e->workers.testStallUs[worker].store(micros, std::memory_order_relaxed);
}

void mdsp_set_workgroup(MDEngine *e, void *workgroup, double periodSeconds) {
#if defined(__APPLE__)
    Workers &W = e->workers;
    {
        std::lock_guard<std::mutex> lk(W.wgLock);
        auto wg = static_cast<os_workgroup_t>(workgroup);
        if (wg) os_retain(wg);
        if (W.wg) os_release(W.wg);
        W.wg = wg; W.period = periodSeconds;
        W.wgGen.fetch_add(1, std::memory_order_release);
    }
    // Worker gleich übernehmen lassen (Wecken ohne Auftrag), nicht erst im nächsten Block innerhalb der Frist
    if (W.started.load(std::memory_order_acquire)) {
        for (int w = 0; w < Workers::N; w++) dispatch_semaphore_signal(W.go[w]);
        awaitWorkersSynced(W);
    }
#else
    (void)e; (void)workgroup; (void)periodSeconds;
#endif
}

uint32_t mdsp_set_track(MDEngine *e, int deck, const float *left, const float *right, int64_t frames, double trackRate, double startSeconds) {
    Deck &d = e->decks[deck];
    d.p[MD_PLAYING].store(0);
    uint32_t gen = ++d.loadGen;
    if (gen == 0) gen = ++d.loadGen;   // 0 heißt „nichts ausstehend“
    // Slot der vorletzten Übergabe: längst übernommen oder nie gelesen (von der letzten überholt)
    // Rate 0/NaN (kaputte Datei) → Engine-Rate, sonst Division durch 0 bei jeder Positionsmeldung
    if (!(trackRate > 0) || !std::isfinite(trackRate)) trackRate = e->fs;
    if (!left || !right || frames < 0) { left = right = nullptr; frames = 0; }
    d.slots[gen & 1] = TrackSlot{left, right, frames, trackRate, std::isfinite(startSeconds) ? std::max(0.0, startSeconds) : 0};
    d.pendingGen.store(gen);
    return gen;
}

bool mdsp_track_consumed(MDEngine *e, int deck, uint32_t gen) {
    return int32_t(e->decks[deck].consumedGen.load() - gen) >= 0;
}
// Steuerwerte: NaN/Inf (kaputte Rechnung, kaputte Datei) werden verworfen – der Kern käme sonst nicht mehr heraus
// (Position NaN liest nichts, healDeck greift nur bei NaN am Ausgang; Clock-Beat NaN zählt nie weiter)
void mdsp_set_param(MDEngine *e, int deck, MDParam p, float v) { if (std::isfinite(v)) e->decks[deck].p[p].store(v); }
/// Zeile der FX-Parameter: Unit 0…3, Master-Bus dahinter; -1 = ungültig
static int fxRow(int unit) { return unit == MDSP_MASTER_UNIT ? MDSP_FX_UNITS : (unit >= 0 && unit < MDSP_FX_UNITS ? unit : -1); }
void mdsp_set_fx(MDEngine *e, int unit, MDFXParam p, float v) {
    int r = fxRow(unit);
    if (r >= 0 && p >= 0 && p < MDFX_PARAM_COUNT && std::isfinite(v)) e->fxp[r][p].store(v);
}
void mdsp_set_master(MDEngine *e, float v) { if (std::isfinite(v)) e->master.store(v); }

static Rack *rackOf(MDEngine *e, int unit, int deck) {
    if (unit == MDSP_MASTER_UNIT) return &e->bus.fx.rack;
    if (unit < 0 || unit >= MDSP_FX_UNITS || deck < 0 || deck >= MDSP_DECKS) return nullptr;
    return &e->decks[deck].fx[unit].rack;
}

void mdsp_set_fx_rack(MDEngine *e, int unit, int deck, const int *kinds, MDPlugin *const *plugins, int count) {
    if (Rack *r = rackOf(e, unit, deck)) r->set(kinds, plugins, std::clamp(count, 0, kSlots), e->renders.load());
}

bool mdsp_fx_plugin_released(MDEngine *e, int unit, int deck, MDPlugin *old) {
    Rack *r = rackOf(e, unit, deck);
    if (!old || !r) return true;
    if (r->contains(old)) return false;
    if (e->workers.stuck.load(std::memory_order_acquire) > 0) return false;   // ein hängender Worker rechnet womöglich noch damit
    return e->renders.load() >= r->releaseAt.load();
}

void mdsp_set_fx_slot(MDEngine *e, int unit, int slot, bool on, float wet) {
    int r = fxRow(unit);
    if (r < 0 || slot < 0 || slot >= kSlots) return;
    e->slotOn[r][slot].store(on ? 1.f : 0.f);
    if (std::isfinite(wet)) e->slotWet[r][slot].store(std::clamp(wet, 0.f, 1.f));
}

bool mdsp_fx_slot_needs_reset(MDEngine *e, int unit, int deck, int slot) {
    Rack *r = rackOf(e, unit, deck);
    return r && slot >= 0 && slot < kSlots && r->slot[slot].resetPending.load(std::memory_order_acquire);
}

void mdsp_fx_slot_reset_done(MDEngine *e, int unit, int deck, int slot) {
    Rack *r = rackOf(e, unit, deck);
    if (r && slot >= 0 && slot < kSlots) r->slot[slot].resetPending.store(false, std::memory_order_release);
}

void mdsp_set_master_fx_channel(MDEngine *e, int firstChannel) {
    e->bus.ch.store(firstChannel < 0 ? -1 : firstChannel);
    if (firstChannel < 0) { e->bus.rms.store(0); e->bus.peak.store(0); }
}

void mdsp_master_levels(MDEngine *e, float *rms, float *peak) { *rms = e->bus.rms.load(); *peak = e->bus.peak.load(); }
void mdsp_seek(MDEngine *e, int deck, double s) {
    if (!std::isfinite(s)) return;
    Deck &d = e->decks[deck];
    // gleich im Schnitt (mdsp_position meldet das Ziel sofort); die Länge der Datei prüft der Audio-Thread
    double ts = d.trimStartReq.load(std::memory_order_relaxed), te = d.trimEndReq.load(std::memory_order_relaxed);
    s = std::max(s, std::max(0.0, ts));
    if (te > ts) s = std::min(s, te);
    // Sprung beendet das Nachlaufen nach einem Scratch (sonst zöge der Kern zurück aufs alte Ziel); gehalten: Ziel mitnehmen
    int two = 2;
    if (!d.scratchMode.compare_exchange_strong(two, 0) && two == 1) d.scratchTarget.store(s);   // Sekunden wie mdsp_scratch
    d.pendingSeek.store(s);
}

void mdsp_set_trim(MDEngine *e, int deck, double s, double en) {
    if (!std::isfinite(s) || !std::isfinite(en)) return;
    s = std::max(0.0, s);
    if (en <= 0) en = 0;                    // Track-Ende
    else if (en <= s) { s = 0; en = 0; }    // leer oder verkehrt: kein Schnitt
    Deck &d = e->decks[deck];
    d.trimSeq.fetch_add(1, std::memory_order_acq_rel);
    d.trimStartReq.store(s, std::memory_order_relaxed); d.trimEndReq.store(en, std::memory_order_relaxed);
    d.trimSeq.fetch_add(1, std::memory_order_release);
}

void mdsp_set_loop(MDEngine *e, int deck, bool active, double s, double en) {
    Deck &d = e->decks[deck];
    if (!std::isfinite(s) || !std::isfinite(en)) { active = false; s = en = 0; }
    if (active && !(en > s)) active = false;   // leerer oder verkehrter Loop: nicht springen (sonst ein Sample in Schleife)
    d.loopActiveReq.store(active); d.loopStartReq.store(s); d.loopEndReq.store(en);
    d.loopVersion.fetch_add(1);
    // sofort nach außen sichtbar (Kern fragt direkt danach ab)
    d.loopActiveOut.store(active); d.loopStartOut.store(s); d.loopEndOut.store(en);
}

void mdsp_scratch(MDEngine *e, int deck, double s, bool held) {
    if (deck < 0 || deck >= MDSP_DECKS || !std::isfinite(s)) return;
    Deck &d = e->decks[deck];
    d.scratchTarget.store(std::max(0.0, s));
    d.scratchMode.store(held ? 1 : 2);
}

void mdsp_follow(MDEngine *e, int deck, int source) {
    if (source < 0 || source >= MDSP_DECKS || source == deck) return;
    // bis zum nächsten Block meldet mdsp_position schon die Position der Quelle
    e->decks[deck].pendingSeek.store(mdsp_position(e, source));
    e->decks[deck].pendingFollow.store(source);
}

double mdsp_position(MDEngine *e, int deck) {
    Deck &d = e->decks[deck];
    double s = d.pendingSeek.load();
    return std::isnan(s) ? d.posOut.load() : s;
}
double mdsp_flux_position(MDEngine *e, int deck) { return e->decks[deck].fluxOut.load(); }
bool mdsp_position_stamp(MDEngine *e, int deck, double *pos, uint64_t *hostTime) {
    Deck &d = e->decks[deck];
    double s = d.pendingSeek.load();
    if (!std::isnan(s)) { *pos = s; *hostTime = 0; return false; }   // Sprung steht an: ohne Stempel
    for (int i = 0; i < 8; i++) {
        uint32_t q = d.posSeq.load(std::memory_order_acquire);
        if (q & 1) continue;
        double p = d.posOut.load(std::memory_order_relaxed);
        uint64_t h = d.posHost.load(std::memory_order_relaxed);
        if (d.posSeq.load(std::memory_order_acquire) == q) { *pos = p; *hostTime = h; return h != 0; }
    }
    *pos = d.posOut.load(); *hostTime = 0; return false;
}
bool mdsp_loop(MDEngine *e, int deck, double *s, double *en) {
    Deck &d = e->decks[deck];
    *s = d.loopStartOut.load(); *en = d.loopEndOut.load();
    return d.loopActiveOut.load();
}
bool mdsp_playing(MDEngine *e, int deck) { return e->decks[deck].p[MD_PLAYING].load() > 0.5f; }
void mdsp_levels(MDEngine *e, int deck, float *rms, float *peak) { *rms = e->decks[deck].rms.load(); *peak = e->decks[deck].peak.load(); }

/// monotone Nanosekunden (Audio-Thread: ein Systemregister, kein Aufruf ins System)
static inline uint64_t nowNs() {
#if defined(__APPLE__)
    static const double ratio = [] { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return double(tb.numer) / double(tb.denom); }();
    return uint64_t(double(mach_absolute_time()) * ratio);
#else
    return uint64_t(std::chrono::steady_clock::now().time_since_epoch().count());
#endif
}

/// Host-Zeit `seconds` nach `host` (mach-Ticks)
static inline uint64_t hostAfter(uint64_t host, double seconds) {
    static const double perSec = [] { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return 1e9 * double(tb.denom) / double(tb.numer); }();
    return host + uint64_t(seconds * perSec);
}

void mdsp_render(MDEngine *e, float **out, int channels, int frames) {
    if (!out || channels <= 0 || frames <= 0) return;
    DenormalGuard ftz;
    RenderProfile &prof = e->profile;
    for (auto &x : prof.cur) x = 0;
    uint64_t tStart = nowNs(), t = tStart;
#if defined(__APPLE__)
    uint64_t blockTicks = mach_absolute_time();   // Frist der Worker: ab Blockanfang
#else
    uint64_t blockTicks = 0;
#endif
    auto lap = [&](int part) { uint64_t n2 = nowNs(); prof.cur[part] += n2 - t; t = n2; };
    for (int c = 0; c < channels; c++) std::memset(out[c], 0, sizeof(float) * frames);
    Clock &k = e->clock;
    double sb = k.setBeat.exchange(NAN);
    if (!std::isnan(sb)) k.beat = sb;
    double tr = k.trim.exchange(0);
    if (tr != 0) k.beat += tr;
    double beatStart = k.beat;
    double perSample = k.bpm.load() / 60.0 / e->fs;
    int done = 0;
    while (done < frames) {
        int n = std::min(kMaxFrames, frames - done);
        float *o[64];
        for (int c = 0; c < channels && c < 64; c++) o[c] = out[c] + done;
        e->fxBeat = beatStart + done * perSample; e->fxBps = perSample;
        e->subBlock++;
        e->subStampHost = e->renderHost ? hostAfter(e->renderHost, double(done + n) / e->fs) : 0;   // Ende des Teilblocks
        for (int i = 0; i < MDSP_DECKS; i++) e->blockPos[i] = e->decks[i].posOut.load(std::memory_order_relaxed);
        // Decks, deren Worker nach einem Fristablauf noch rechnet, bleiben still (nicht gleichzeitig zweimal rechnen)
        bool skip[MDSP_DECKS] = {};
        bool busy = false;
        for (int w = 0; w < Workers::N; w++) if (workerBusy(e, w)) { skip[w + 1] = true; busy = true; }
        if (!busy && e->workers.enabled.load(std::memory_order_acquire)) {
            postWorkers(e, n);
            renderDeckBlock(e, e->decks[0], n, e->subBlock);
            lap(RenderProfile::A);
            waitWorkers(e, n, done == 0 ? blockTicks : subBlockTicks(), skip);
            lap(RenderProfile::WAIT);
        } else {
            for (int i = 0; i < MDSP_DECKS; i++) { if (!skip[i]) renderDeckBlock(e, e->decks[i], n, e->subBlock); lap(RenderProfile::A + i); }
        }
        for (int i = 0; i < MDSP_DECKS; i++) if (!skip[i]) mixDeck(e, e->decks[i], o, std::min(channels, 64), n);
        // Master-Bus: nach der Summe, vor Master-Lautstärke und Begrenzung (Vorhören bleibt auf seinem Paar unberührt)
        MasterBus &mb = e->bus;
        mb.fx.rack.sync();
        int mch = mb.ch.load(std::memory_order_relaxed);
        if (mch >= 0 && mch + 1 < std::min(channels, 64)) {
            FXChain &c = mb.fx;
            // leerer Bus ohne Fahnen kostet nichts
            if ((c.rack.present & ~1u) != 0 || c.delay.active() || c.reverb.active() || c.classic.active() || c.roll.active() ||
                c.gater.active() || c.flanger.active() || c.phaser.active() || c.rack.pluginActive(e->fs))
                runFX(e, c, MDSP_FX_UNITS, o[mch], o[mch + 1], n, e->subBlock);
        }
        if (mch >= 0 && mch + 1 < std::min(channels, 64)) {
            float sum = 0, pk = 0;
            for (int i = 0; i < n; i++) {
                float l = o[mch][i], r = o[mch + 1][i];
                sum += (l * l + r * r) * 0.5f; pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
            }
            if (!std::isfinite(sum)) sum = pk = 0;
            mb.rms.store(mb.rms.load(std::memory_order_relaxed) * 0.7f + std::sqrt(sum / n) * 0.3f, std::memory_order_relaxed);
            mb.peak.store(std::max(pk, mb.peak.load(std::memory_order_relaxed) * 0.85f), std::memory_order_relaxed);
        }
        lap(RenderProfile::MIX);
        done += n;
    }
    float m = e->master.load();
    bool metro = k.metroOn.load();
    float mv = k.metroVol.load();
    int mc = std::clamp(k.metroCh.load(), 0, std::max(0, channels - 2));
    for (int i = 0; i < frames; i++) {
        e->masterSm += (m - e->masterSm) * 0.002f;
        if (std::fabs(m - e->masterSm) < kSnap) e->masterSm = m;
        for (int c = 0; c < channels; c++) {
            float x = out[c][i] * e->masterSm;
            out[c][i] = x > 1.f ? 1.f : (x < -1.f ? -1.f : (x == x ? x : 0.f));   // harte Begrenzung als letzte Sicherung, NaN → 0
        }
    }
    // Aufnahme: Master-Paar nach Begrenzung, vor Metronom und Vorhören (nur Kopie in den Ring)
    if (MDRing *tap = e->recTap.load(std::memory_order_acquire)) {
        int tc = e->recCh.load(std::memory_order_relaxed);
        if (tc >= 0 && tc + 1 < channels) {
            uint64_t r0 = nowNs();
            mdsp_ring_write(tap, out[tc], out[tc + 1], frames);
            uint64_t dt = nowNs() - r0;
            e->recCostNs.fetch_add(dt, std::memory_order_relaxed);
            e->recBlocks.fetch_add(1, std::memory_order_relaxed);
            if (dt > e->recWorstNs.load(std::memory_order_relaxed)) e->recWorstNs.store(dt, std::memory_order_relaxed);
        }
    }
    for (int i = 0; i < frames; i++) {
        // Clock weiterzählen, bei jedem Beat klicken (Takt-Eins höher)
        double before = k.beat;
        k.beat += perSample;
        if (std::floor(k.beat) != std::floor(before)) {
            long b = long(std::floor(k.beat));
            k.clickFreq = (b % 4 == 0) ? 1600 : 1000;
            k.clickEnv = 1; k.clickPhase = 0;
        }
        if (metro && k.clickEnv > 0.001f) {
            float c = float(std::sin(k.clickPhase)) * k.clickEnv * mv * 0.5f;
            k.clickPhase += 2 * kPi * k.clickFreq / e->fs;
            k.clickEnv *= 0.9985f;
            out[mc][i] += c;
            if (mc + 1 < channels) out[mc + 1][i] += c;
        } else if (k.clickEnv > 0) {
            k.clickEnv *= 0.9985f;
        }
    }
    lap(RenderProfile::MASTER);
    mdpv_render(e->preview, out, channels, frames, e->fs);   // Vorhören: eigenes Paar, nach dem Master
    lap(RenderProfile::PREVIEW);
    k.beatOut.store(k.beat);
    k.stampSeq.fetch_add(1, std::memory_order_acq_rel);
    k.stampBeat.store(beatStart, std::memory_order_relaxed);
    k.stampHost.store(e->renderHost, std::memory_order_relaxed);
    k.stampSeq.fetch_add(1, std::memory_order_release);
    e->renders.fetch_add(1);
    // schwerster Block seit dem letzten Abholen (Steuer-Thread liest per Sequenzzähler)
    uint64_t total = nowNs() - tStart;
    if (total > prof.worst) {
        prof.seq.fetch_add(1, std::memory_order_acq_rel);
        prof.worst = total; prof.frames = uint32_t(frames);
        for (int i = 0; i < RenderProfile::N; i++) prof.parts[i] = prof.cur[i];
        prof.seq.fetch_add(1, std::memory_order_release);
    }
}

void mdsp_set_render_host(MDEngine *e, uint64_t hostTime) { e->renderHost = hostTime; }
uint64_t mdsp_render_count(MDEngine *e) { return e->renders.load(std::memory_order_relaxed); }

void mdsp_set_record_tap(MDEngine *e, MDRing *ring, int firstChannel) {
    e->recCh.store(firstChannel, std::memory_order_relaxed);
    MDRing *old = e->recTap.exchange(ring, std::memory_order_acq_rel);
    if (old && old != ring) e->recReleaseAt.store(e->renders.load() + 2);
}

bool mdsp_record_tap_released(MDEngine *e, MDRing *ring) {
    if (!ring) return true;
    if (e->recTap.load(std::memory_order_acquire) == ring) return false;
    return e->renders.load() >= e->recReleaseAt.load();
}

void mdsp_record_tap_cost(MDEngine *e, uint64_t *total, uint64_t *worst, uint32_t *blocks) {
    if (total) *total = e->recCostNs.exchange(0, std::memory_order_relaxed);
    if (worst) *worst = e->recWorstNs.exchange(0, std::memory_order_relaxed);
    if (blocks) *blocks = e->recBlocks.exchange(0, std::memory_order_relaxed);
}

bool mdsp_clock_stamp(MDEngine *e, double *beat, uint64_t *hostTime) {
    Clock &k = e->clock;
    for (int i = 0; i < 8; i++) {
        uint32_t s = k.stampSeq.load(std::memory_order_acquire);
        if (s & 1) continue;
        double b = k.stampBeat.load(std::memory_order_relaxed);
        uint64_t h = k.stampHost.load(std::memory_order_relaxed);
        if (k.stampSeq.load(std::memory_order_acquire) == s) { *beat = b; *hostTime = h; return h != 0; }
    }
    return false;
}

void mdsp_clock_set_bpm(MDEngine *e, double bpm) { if (std::isfinite(bpm)) e->clock.bpm.store(std::clamp(bpm, 20.0, 300.0)); }
void mdsp_clock_set_beat(MDEngine *e, double beat) { if (std::isfinite(beat)) { e->clock.setBeat.store(beat); e->clock.beatOut.store(beat); } }
double mdsp_clock_beat(MDEngine *e) { return e->clock.beatOut.load(); }
void mdsp_clock_trim(MDEngine *e, double delta) {
    if (!std::isfinite(delta)) return;
    auto &t = e->clock.trim;
    double cur = t.load();
    while (!t.compare_exchange_weak(cur, cur + delta)) {}
}
double mdsp_keylock_latency(MDEngine *e) { return e->decks[0].stretch.outputLatency() / e->fs; }
void mdsp_metronome(MDEngine *e, bool on, float volume, int ch) {
    e->clock.metroOn.store(on); e->clock.metroVol.store(volume); e->clock.metroCh.store(ch);
}

} // extern "C"
