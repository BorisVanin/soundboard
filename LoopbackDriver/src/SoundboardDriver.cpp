//
//  SoundboardDriver.cpp
//  Soundboard virtual audio device (AudioServerPlugIn) — written from scratch, C++.
//
//  Publishes ONE loopback device:
//    * an OUTPUT stream apps/the engine play into, and
//    * an INPUT stream that returns the same audio (the loopback).
//
//  The plug-in is a C COM-style CFPlugIn, but the implementation is C++: a
//  single `Driver` object holds all state and logic, and a table of C-ABI
//  "trampoline" functions (one per AudioServerPlugInDriverInterface slot)
//  forwards into it. Only the factory symbol is exported, as extern "C".
//
//  CONTROL API (cross-process): clients read the device's output level meters
//  through a custom HAL property declared in SoundboardControlProtocol.h. The
//  device's display name is fixed ("Soundboard") and read-only.
//
//  Dynamic format (rate / channels / int|float / bits) goes through the
//  standard RequestDeviceConfigurationChange -> PerformDeviceConfigurationChange
//  handshake. Loopback IO is a format-agnostic byte copy.
//

#include "SoundboardDriver.h"
#include "SoundboardControlProtocol.h"
#include "RingOwner.h"          // driver-owned shared-memory mix ring (SHMEM.md)

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <mach/mach_time.h>
#include <os/log.h>

#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

os_log_t gLog;

// Verbose, per-property-access logging. coreaudiod calls get/setPropertyData
// extremely often (every metering/volume poll), so logging there serialises the
// plugin and stalls volume changes. Compiled out unless SOUNDBOARD_VERBOSE is
// defined; lifecycle events still use os_log directly.
#if defined(SOUNDBOARD_VERBOSE)
#define VLOG(...) os_log(gLog, __VA_ARGS__)
#else
#define VLOG(...) ((void)0)
#endif

[[maybe_unused]] const char* fourcc(UInt32 code, char* buf)
{
    buf[0] = static_cast<char>((code >> 24) & 0xFF);
    buf[1] = static_cast<char>((code >> 16) & 0xFF);
    buf[2] = static_cast<char>((code >>  8) & 0xFF);
    buf[3] = static_cast<char>( code        & 0xFF);
    buf[4] = 0;
    return buf;
}

// ---------------------------------------------------------------- Topology
enum : AudioObjectID {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
    kObjectID_Volume_Output = 5,   // output volume control
};

constexpr Float32 kVolumeMinDB = -64.0f;
constexpr Float32 kVolumeMaxDB =   0.0f;

inline Float32 volScalarToDB(Float32 scalar) {
    if (scalar <= 0.0f) return kVolumeMinDB;
    Float32 db = 20.0f * std::log10(scalar);
    return db < kVolumeMinDB ? kVolumeMinDB : (db > kVolumeMaxDB ? kVolumeMaxDB : db);
}
inline Float32 volDBToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0.0f;
    Float32 s = std::pow(10.0f, db / 20.0f);
    return s < 0.0f ? 0.0f : (s > 1.0f ? 1.0f : s);
}

constexpr const char* kDevice_UID      = kSoundboardDeviceUID;
constexpr const char* kDevice_ModelUID = "ca.borisvanin.soundboard.model";
constexpr const char* kDevice_NameDefault = "Soundboard";
constexpr const char* kManufacturer    = "Boris Vanin";

constexpr Float64 kDefaultSampleRate = 48000.0;
constexpr UInt32  kDefaultChannels   = 2;
constexpr UInt32  kRingFrames        = 48000; // 1 s at 48k
constexpr UInt32  kMaxChannels       = 8;
constexpr UInt32  kMaxBytesPerSample = 4;
[[maybe_unused]] constexpr UInt32 kMaxBytesPerFrame = kMaxChannels * kMaxBytesPerSample;

enum : UInt64 { kChangeAction_ApplyPendingFormat = 1 };

// ------------------------------------------------------- Supported formats
constexpr Float64 kSupportedRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
constexpr UInt32  kSupportedChannels[] = { 1, 2 };
struct SampleType { UInt32 bits; UInt32 bytesPerSample; bool isFloat; };
constexpr SampleType kSupportedSampleTypes[] = {
    { 16, 2, false }, { 24, 3, false }, { 32, 4, false }, { 32, 4, true },
};
constexpr UInt32 kNumRates    = sizeof(kSupportedRates) / sizeof(kSupportedRates[0]);
constexpr UInt32 kNumChannels = sizeof(kSupportedChannels) / sizeof(kSupportedChannels[0]);
constexpr UInt32 kNumTypes    = sizeof(kSupportedSampleTypes) / sizeof(kSupportedSampleTypes[0]);
constexpr UInt32 kNumFormats  = kNumChannels * kNumTypes;

AudioStreamBasicDescription makeASBD(Float64 rate, UInt32 channels, UInt32 bits, UInt32 bytesPerSample, bool isFloat)
{
    AudioStreamBasicDescription f{};
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
                        | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    f.mFramesPerPacket  = 1;
    f.mChannelsPerFrame = channels;
    f.mBitsPerChannel   = bits;
    f.mBytesPerFrame    = bytesPerSample * channels;
    f.mBytesPerPacket   = f.mBytesPerFrame;
    return f;
}

bool rateSupported(Float64 r)
{
    for (Float64 s : kSupportedRates) if (s == r) return true;
    return false;
}
bool channelsSupported(UInt32 c)
{
    for (UInt32 s : kSupportedChannels) if (s == c) return true;
    return false;
}
bool formatSupported(const AudioStreamBasicDescription& f, UInt32& outBytesPerSample)
{
    if (f.mFormatID != kAudioFormatLinearPCM)   return false;
    if (!rateSupported(f.mSampleRate))          return false;
    if (!channelsSupported(f.mChannelsPerFrame)) return false;
    bool isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    for (const SampleType& t : kSupportedSampleTypes) {
        if (t.isFloat == isFloat && t.bits == f.mBitsPerChannel) {
            outBytesPerSample = t.bytesPerSample;
            return true;
        }
    }
    return false;
}

// ============================================================= Driver class
class Driver {
public:
    static Driver& shared() { static Driver instance; return instance; }

    AudioServerPlugInDriverRef ref() { return &mInterfacePtr; }
    void buildInterface(); // fill mInterface with the C trampolines

    // Lifecycle
    HRESULT  queryInterface(REFIID iid, LPVOID* out);
    ULONG    addRef()  { return ++mRefCount; }
    ULONG    release() { UInt32 v = mRefCount.load(); if (v) v = --mRefCount; return v; }
    OSStatus initialize(AudioServerPlugInHostRef host);
    OSStatus performConfigChange(UInt64 action);
    OSStatus abortConfigChange();

    // Properties
    Boolean  hasProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a);
    OSStatus isSettable(AudioObjectID obj, const AudioObjectPropertyAddress* a, Boolean* outSettable);
    OSStatus getPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                             UInt32 qSize, const void* qData, UInt32 inSize, UInt32* outSize, void* outData);
    OSStatus setPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                             UInt32 qSize, const void* qData, UInt32 inSize, const void* inData);

    // IO
    OSStatus startIO();
    OSStatus stopIO();
    OSStatus getZeroTimeStamp(Float64* outSample, UInt64* outHost, UInt64* outSeed);
    OSStatus doIO(UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer);

private:
    Driver();

    // --- Device name (fixed, read-only) ---
    CFStringRef  copyNameCF();                 // +1 ref for the HAL to release

    // --- Format ---
    OSStatus requestFormatChange(const AudioStreamBasicDescription& f);
    void     notifyFormatChanged();
    void     recomputeTiming();

    AudioServerPlugInDriverInterface  mInterface{};
    AudioServerPlugInDriverInterface* mInterfacePtr{ &mInterface };

    std::atomic<UInt32>       mRefCount{ 1 };
    AudioServerPlugInHostRef  mHost{ nullptr };

    std::mutex                  mMutex;     // guards mFormat/mPending/IO bookkeeping
    AudioStreamBasicDescription mFormat{};
    AudioStreamBasicDescription mPending{};
    std::atomic<UInt32>         mBytesPerFrame{ 0 }; // lock-free read on the RT thread
    std::atomic<float>          mVolumeScalar{ 1.0f }; // output volume (0..1), RT-read
    std::atomic<float>          mLevelL{ 0 }, mLevelR{ 0 };  // decaying level meters
    std::atomic<float>          mPeakL{ 0 }, mPeakR{ 0 };    // peak-hold meters

    // --- Diagnostics (cleared when the first IO client starts) ---
    // Let us answer, from the logs, "is FaceTime reading our input, and is the
    // engine actually writing non-silent audio into our output while it does?"
    // (Commented out: FaceTime loopback debugging session.)
    // std::atomic<UInt64>         mWriteMixCycles{ 0 };   // doIO WriteMix calls (engine -> us)
    // std::atomic<UInt64>         mReadInputCycles{ 0 };  // doIO ReadInput calls (consumer <- us)
    // std::atomic<float>          mSessionPeak{ 0 };      // loudest output sample seen this session
    // UInt64                      mLastHbWrite{ 0 };      // heartbeat bookkeeping (HAL thread only)
    // UInt64                      mLastHbRead{ 0 };

    bool    mIORunning{ false };
    UInt64  mIOCount{ 0 };
    Float64 mHostTicksPerFrame{ 0 };
    UInt64  mAnchorHostTime{ 0 };

    // Driver-owned shared-memory mix ring (SHMEM.md): created at Initialize, the
    // device's input source. Granted via the RingSession property, consumed (RT)
    // in ReadInput. All the ring/protocol logic lives in RingOwner (unit-tested).
    RingOwner mShmRing;
};

UInt32 buildAvailableFormats(AudioStreamRangedDescription* out, UInt32 cap)
{
    UInt32 n = 0;
    for (UInt32 c = 0; c < kNumChannels; ++c)
        for (UInt32 t = 0; t < kNumTypes; ++t) {
            if (n >= cap) return n;
            const SampleType& st = kSupportedSampleTypes[t];
            out[n].mFormat = makeASBD(kDefaultSampleRate, kSupportedChannels[c], st.bits, st.bytesPerSample, st.isFloat);
            out[n].mSampleRateRange.mMinimum = kSupportedRates[0];
            out[n].mSampleRateRange.mMaximum = kSupportedRates[kNumRates - 1];
            ++n;
        }
    return n;
}

// Scale `frames` of audio in `fmt` by a linear `gain` in place (the device's
// output volume). Handles the formats we advertise (float32, int16/24/32).
void applyGain(void* buffer, UInt32 frames, float gain, const AudioStreamBasicDescription& fmt)
{
    if (gain >= 0.9999f) return;                 // unity — nothing to do
    const UInt32 n = frames * fmt.mChannelsPerFrame;
    const bool isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;

    if (isFloat && fmt.mBitsPerChannel == 32) {
        auto* p = static_cast<float*>(buffer);
        for (UInt32 i = 0; i < n; ++i) p[i] *= gain;
    } else if (!isFloat && fmt.mBitsPerChannel == 16) {
        auto* p = static_cast<int16_t*>(buffer);
        for (UInt32 i = 0; i < n; ++i) p[i] = static_cast<int16_t>(p[i] * gain);
    } else if (!isFloat && fmt.mBitsPerChannel == 32) {
        auto* p = static_cast<int32_t*>(buffer);
        for (UInt32 i = 0; i < n; ++i) p[i] = static_cast<int32_t>(p[i] * gain);
    } else if (!isFloat && fmt.mBitsPerChannel == 24) {
        auto* p = static_cast<uint8_t*>(buffer);   // packed 3-byte little-endian signed
        for (UInt32 i = 0; i < n; ++i) {
            int32_t s = p[i*3] | (p[i*3+1] << 8) | (p[i*3+2] << 16);
            if (s & 0x800000) s |= ~0xFFFFFF;       // sign-extend
            s = static_cast<int32_t>(s * gain);
            p[i*3] = s & 0xFF; p[i*3+1] = (s >> 8) & 0xFF; p[i*3+2] = (s >> 16) & 0xFF;
        }
    }
}

// Per-channel normalized peak magnitude (0..1) for the L and R channels.
void computePeaks(const void* buffer, UInt32 frames, const AudioStreamBasicDescription& fmt, float& outL, float& outR)
{
    const UInt32 ch = fmt.mChannelsPerFrame;
    const bool isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    float pL = 0, pR = 0;
    auto accumulate = [&](UInt32 channel, float mag) {
        if (channel == 0) pL = std::max(pL, mag);
        else if (channel == 1) pR = std::max(pR, mag);
    };
    for (UInt32 f = 0; f < frames; ++f) {
        for (UInt32 c = 0; c < ch && c < 2; ++c) {
            UInt32 i = f * ch + c;
            float mag = 0;
            if (isFloat && fmt.mBitsPerChannel == 32) {
                mag = std::fabs(static_cast<const float*>(buffer)[i]);
            } else if (!isFloat && fmt.mBitsPerChannel == 16) {
                mag = std::fabs(static_cast<const int16_t*>(buffer)[i]) / 32768.0f;
            } else if (!isFloat && fmt.mBitsPerChannel == 32) {
                mag = std::fabs(static_cast<float>(static_cast<const int32_t*>(buffer)[i])) / 2147483648.0f;
            } else if (!isFloat && fmt.mBitsPerChannel == 24) {
                auto* b = static_cast<const uint8_t*>(buffer);
                int32_t s = b[i*3] | (b[i*3+1] << 8) | (b[i*3+2] << 16);
                if (s & 0x800000) s |= ~0xFFFFFF;
                mag = std::fabs(static_cast<float>(s)) / 8388608.0f;
            }
            accumulate(c, mag);
        }
    }
    if (ch == 1) pR = pL;          // mono -> mirror to both meters
    outL = pL > 1 ? 1 : pL;
    outR = pR > 1 ? 1 : pR;
}

// =============================================================== Trampolines
// Each matches the C-ABI signature of its AudioServerPlugInDriverInterface slot
// and forwards into the singleton.
HRESULT  T_QueryInterface(void*, REFIID iid, LPVOID* out) { return Driver::shared().queryInterface(iid, out); }
ULONG    T_AddRef(void*)  { return Driver::shared().addRef(); }
ULONG    T_Release(void*) { return Driver::shared().release(); }
OSStatus T_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef host) { return Driver::shared().initialize(host); }
OSStatus T_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*) { return kAudioHardwareUnsupportedOperationError; }
OSStatus T_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus T_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo* info) {
    // Each app that opens the device (input OR output side) is registered here.
    // FaceTime's voice-processing path opens the device full-duplex, so you'll
    // typically see it add TWO clients (bundle com.apple.FaceTime). A plain mic
    // consumer (Teams/Zoom) adds one input client.
    // (Commented out: FaceTime loopback debugging session.)
    // if (info) os_log(gLog, "AddDeviceClient pid=%d bundle=%{public}@", info->mProcessID, info->mBundleID);
    (void)info;
    return kAudioHardwareNoError;
}
OSStatus T_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo* info) {
    // (Commented out: FaceTime loopback debugging session.)
    // if (info) os_log(gLog, "RemoveDeviceClient pid=%d bundle=%{public}@", info->mProcessID, info->mBundleID);
    (void)info;
    return kAudioHardwareNoError;
}
OSStatus T_PerformConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64 action, void*) { return Driver::shared().performConfigChange(action); }
OSStatus T_AbortConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return Driver::shared().abortConfigChange(); }
Boolean  T_HasProperty(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a) { return Driver::shared().hasProperty(obj, a); }
OSStatus T_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a, Boolean* s) { return Driver::shared().isSettable(obj, a, s); }
OSStatus T_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32* outSize) { return Driver::shared().getPropertyData(obj, a, qs, qd, 0, outSize, nullptr); }
OSStatus T_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32 inSize, UInt32* outSize, void* outData) { return Driver::shared().getPropertyData(obj, a, qs, qd, inSize, outSize, outData); }
OSStatus T_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32 inSize, const void* inData) { return Driver::shared().setPropertyData(obj, a, qs, qd, inSize, inData); }
OSStatus T_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) { return Driver::shared().startIO(); }
OSStatus T_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) { return Driver::shared().stopIO(); }
OSStatus T_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64* s, UInt64* h, UInt64* seed) { return Driver::shared().getZeroTimeStamp(s, h, seed); }
OSStatus T_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 op, Boolean* outWill, Boolean* outInPlace) {
    Boolean will = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    if (outWill) *outWill = will;
    if (outInPlace) *outInPlace = true;
    return kAudioHardwareNoError;
}
OSStatus T_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return kAudioHardwareNoError; }
OSStatus T_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer, void*) { return Driver::shared().doIO(op, frames, cycle, mainBuffer); }
OSStatus T_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return kAudioHardwareNoError; }

// ============================================================ Driver methods
Driver::Driver()
{
    mFormat        = makeASBD(kDefaultSampleRate, kDefaultChannels, 32, 4, true);
    mPending       = mFormat;
    mBytesPerFrame = mFormat.mBytesPerFrame;
}

void Driver::buildInterface()
{
    mInterface = AudioServerPlugInDriverInterface{
        nullptr,
        T_QueryInterface, T_AddRef, T_Release,
        T_Initialize, T_CreateDevice, T_DestroyDevice,
        T_AddDeviceClient, T_RemoveDeviceClient,
        T_PerformConfigChange, T_AbortConfigChange,
        T_HasProperty, T_IsPropertySettable, T_GetPropertyDataSize,
        T_GetPropertyData, T_SetPropertyData,
        T_StartIO, T_StopIO, T_GetZeroTimeStamp,
        T_WillDoIOOperation, T_BeginIOOperation, T_DoIOOperation, T_EndIOOperation,
    };
}

HRESULT Driver::queryInterface(REFIID iid, LPVOID* out)
{
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(nullptr, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        ++mRefCount;
        *out = &mInterfacePtr;
        r = S_OK;
    }
    CFRelease(req);
    os_log(gLog, "QueryInterface -> %{public}s", r == S_OK ? "S_OK" : "E_NOINTERFACE");
    return r;
}

OSStatus Driver::initialize(AudioServerPlugInHostRef host)
{
    if (!gLog) gLog = os_log_create("ca.borisvanin.soundboard", "driver");
    mHost = host;
    recomputeTiming();
    // Create + own the mix ring for the driver's lifetime (SHMEM.md §1).
    if (mShmRing.create(kSoundboardRingName))
        os_log(gLog, "MixRing: created '%{public}s'", kSoundboardRingName);
    else
        os_log_error(gLog, "MixRing: create failed errno=%d", mShmRing.lastErrno());
    os_log(gLog, "Initialize: name='%{public}s' %.0f Hz / %u ch", kDevice_NameDefault,
           mFormat.mSampleRate, mFormat.mChannelsPerFrame);
    return kAudioHardwareNoError;
}

void Driver::recomputeTiming()
{
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    mHostTicksPerFrame = (1.0e9 / mFormat.mSampleRate) * (static_cast<Float64>(tb.denom) / static_cast<Float64>(tb.numer));
}

// ----------------------------------------------------------- Device name API
// The display name is fixed and read-only.
CFStringRef Driver::copyNameCF()
{
    return CFStringCreateWithCString(nullptr, kDevice_NameDefault, kCFStringEncodingUTF8);
}

// --------------------------------------------------------------- Format API
OSStatus Driver::requestFormatChange(const AudioStreamBasicDescription& f)
{
    bool same;
    {
        std::lock_guard<std::mutex> lock(mMutex);
        same = std::memcmp(&mFormat, &f, sizeof(f)) == 0;
        if (!same) mPending = f;
    }
    if (same) return kAudioHardwareNoError;
    if (!mHost || !mHost->RequestDeviceConfigurationChange) return kAudioHardwareUnspecifiedError;
    return mHost->RequestDeviceConfigurationChange(mHost, kObjectID_Device, kChangeAction_ApplyPendingFormat, nullptr);
}

OSStatus Driver::performConfigChange(UInt64 action)
{
    if (action != kChangeAction_ApplyPendingFormat) return kAudioHardwareNoError;
    Float64 rate; UInt32 ch, bits; bool flt;
    {
        std::lock_guard<std::mutex> lock(mMutex);
        mFormat = mPending;
        mBytesPerFrame = mFormat.mBytesPerFrame;
        recomputeTiming();
        rate = mFormat.mSampleRate; ch = mFormat.mChannelsPerFrame;
        bits = mFormat.mBitsPerChannel; flt = (mFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    }
    os_log(gLog, "PerformConfigChange: %.0f Hz / %u ch / %u-bit %{public}s", rate, ch, bits, flt ? "float" : "int");
    notifyFormatChanged();
    return kAudioHardwareNoError;
}

OSStatus Driver::abortConfigChange()
{
    std::lock_guard<std::mutex> lock(mMutex);
    mPending = mFormat;
    return kAudioHardwareNoError;
}

void Driver::notifyFormatChanged()
{
    if (!mHost || !mHost->PropertiesChanged) return;
    AudioObjectPropertyAddress dev[] = {
        { kAudioDevicePropertyNominalSampleRate,      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyStreamConfiguration,    kAudioObjectPropertyScopeInput,  kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeInput,  kAudioObjectPropertyElementMain },
    };
    mHost->PropertiesChanged(mHost, kObjectID_Device, 3, dev);
    AudioObjectPropertyAddress strm[] = {
        { kAudioStreamPropertyVirtualFormat,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    mHost->PropertiesChanged(mHost, kObjectID_Stream_Input, 2, strm);
}

// -------------------------------------------------------- Property plumbing
namespace {
UInt32 deviceStreams(AudioObjectPropertyScope scope, AudioObjectID out[2])
{
    UInt32 n = 0;
    // Input-only device (a virtual microphone): the mix is delivered on the input
    // stream from the app's ring. There is no output stream, so the device never
    // appears in the system's Output list.
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput)
        out[n++] = kObjectID_Stream_Input;
    return n;
}
OSStatus putArray(const void* src, UInt32 elemSize, UInt32 count, UInt32 inSize, UInt32* outSize, void* outData)
{
    if (outData) {
        UInt32 fit  = elemSize ? inSize / elemSize : 0;
        UInt32 give = fit < count ? fit : count;
        std::memcpy(outData, src, static_cast<size_t>(give) * elemSize);
        if (outSize) *outSize = give * elemSize;
    } else if (outSize) {
        *outSize = count * elemSize;
    }
    return kAudioHardwareNoError;
}
} // namespace

#define PUT(T, VAL) do { \
    if (outData && inSize >= sizeof(T)) { *reinterpret_cast<T*>(outData) = (VAL); } \
    if (outSize) *outSize = sizeof(T); \
    return kAudioHardwareNoError; \
} while (0)

OSStatus Driver::getPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                                 UInt32 qSize, const void* qData, UInt32 inSize, UInt32* outSize, void* outData)
{
    (void)qSize;
    const AudioObjectPropertySelector sel = a->mSelector;
    const AudioObjectPropertyScope scope  = a->mScope;
    [[maybe_unused]] char b1[5], b2[5];   // only referenced by VLOG (Debug)
    VLOG("GetProp%{public}s obj=%u sel=%{public}s scope=%{public}s",
         outData ? "" : "(size)", obj, fourcc(sel, b1), fourcc(scope, b2));

    switch (obj) {
    case kObjectID_PlugIn:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFStringCreateWithCString(nullptr, kManufacturer, kCFStringEncodingUTF8));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: { AudioObjectID dev = kObjectID_Device; return putArray(&dev, sizeof(dev), 1, inSize, outSize, outData); }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID r = kAudioObjectUnknown;
            if (qData && CFEqual(*static_cast<const CFStringRef*>(qData), CFSTR(kSoundboardDeviceUID))) r = kObjectID_Device;
            PUT(AudioObjectID, r);
        }
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFStringCreateWithCString(nullptr, "", kCFStringEncodingUTF8));
        }
        break;

    case kObjectID_Device:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:         PUT(CFStringRef, copyNameCF());
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFStringCreateWithCString(nullptr, kManufacturer, kCFStringEncodingUTF8));
        case kSoundboardCustomProperty_Levels: {
            float v[4] = { mLevelL.load(), mLevelR.load(), mPeakL.load(), mPeakR.load() };
            PUT(CFDataRef, CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(v), sizeof(v)));
        }
        case kSoundboardCustomProperty_RingInfo: {     // SHMEM.md §2 — discovery GET
            SoundboardRingInfo ri = mShmRing.info();
            PUT(CFDataRef, CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&ri), sizeof(ri)));
        }
        case kSoundboardCustomProperty_RingSession: {  // SHMEM.md §2 — granted session GET
            uint64_t s = mShmRing.grantedSession();
            PUT(CFDataRef, CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&s), sizeof(s)));
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info[3]{};
            info[0].mSelector = kSoundboardCustomProperty_Levels;
            info[1].mSelector = kSoundboardCustomProperty_RingInfo;
            info[2].mSelector = kSoundboardCustomProperty_RingSession;
            for (auto& it : info) {
                it.mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                it.mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            }
            return putArray(info, sizeof(AudioServerPlugInCustomPropertyInfo), 3, inSize, outSize, outData);
        }
        case kAudioObjectPropertyOwnedObjects: {
            // Input-only: just the input stream; no output stream or output volume.
            AudioObjectID objs[2]; UInt32 n = deviceStreams(scope, objs);
            return putArray(objs, sizeof(AudioObjectID), n, inSize, outSize, outData);
        }
        case kAudioDevicePropertyStreams: { AudioObjectID s[2]; UInt32 n = deviceStreams(scope, s); return putArray(s, sizeof(AudioObjectID), n, inSize, outSize, outData); }
        case kAudioObjectPropertyControlList: { if (outSize) *outSize = 0; return kAudioHardwareNoError; }
        case kAudioDevicePropertyStreamConfiguration: {
            UInt32 nbuf = (scope == kAudioObjectPropertyScopeInput) ? 1 : 0;
            UInt32 size = static_cast<UInt32>(offsetof(AudioBufferList, mBuffers)) + nbuf * static_cast<UInt32>(sizeof(AudioBuffer));
            if (outData && inSize >= size) {
                auto* abl = reinterpret_cast<AudioBufferList*>(outData);
                abl->mNumberBuffers = nbuf;
                for (UInt32 i = 0; i < nbuf; ++i) {
                    abl->mBuffers[i].mNumberChannels = mFormat.mChannelsPerFrame;
                    abl->mBuffers[i].mDataByteSize   = 0;
                    abl->mBuffers[i].mData           = nullptr;
                }
            }
            if (outSize) *outSize = size;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyDeviceUID:    PUT(CFStringRef, CFStringCreateWithCString(nullptr, kDevice_UID, kCFStringEncodingUTF8));
        case kAudioDevicePropertyModelUID:     PUT(CFStringRef, CFStringCreateWithCString(nullptr, kDevice_ModelUID, kCFStringEncodingUTF8));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: { AudioObjectID me = kObjectID_Device; return putArray(&me, sizeof(me), 1, inSize, outSize, outData); }
        case kAudioDevicePropertyClockDomain:  PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceIsRunningSomewhere: PUT(UInt32, mIORunning ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 1);
        case kAudioDevicePropertyLatency:      PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, mFormat.mSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[kNumRates];
            for (UInt32 i = 0; i < kNumRates; ++i) { ranges[i].mMinimum = kSupportedRates[i]; ranges[i].mMaximum = kSupportedRates[i]; }
            return putArray(ranges, sizeof(AudioValueRange), kNumRates, inSize, outSize, outData);
        }
        case kAudioDevicePropertyIsHidden:     PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 ch[2] = {1, 2};
            if (outData && inSize >= sizeof(ch)) std::memcpy(outData, ch, sizeof(ch));
            if (outSize) *outSize = sizeof(ch);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout l{};
            UInt32 ch = mFormat.mChannelsPerFrame;
            l.mChannelLayoutTag = (ch == 1) ? kAudioChannelLayoutTag_Mono
                                : (ch == 2) ? kAudioChannelLayoutTag_Stereo
                                : (kAudioChannelLayoutTag_DiscreteInOrder | ch);
            if (outData && inSize >= sizeof(l)) *reinterpret_cast<AudioChannelLayout*>(outData) = l;
            if (outSize) *outSize = sizeof(l);
            return kAudioHardwareNoError;
        }
        }
        break;

    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:   PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:       PUT(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: { if (outSize) *outSize = 0; return kAudioHardwareNoError; }
        case kAudioStreamPropertyIsActive:    PUT(UInt32, 1);
        case kAudioStreamPropertyDirection:   PUT(UInt32, obj == kObjectID_Stream_Input ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            // Present the input as a real microphone and the output as a speaker.
            // Some apps (FaceTime among them) treat an "unknown" terminal input
            // differently from a proper microphone terminal.
            PUT(UInt32, obj == kObjectID_Stream_Input ? kAudioStreamTerminalTypeMicrophone
                                                       : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency:     PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f = mFormat;
            if (outData && inSize >= sizeof(f)) *reinterpret_cast<AudioStreamBasicDescription*>(outData) = f;
            if (outSize) *outSize = sizeof(f);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription formats[kNumFormats];
            UInt32 n = buildAvailableFormats(formats, kNumFormats);
            return putArray(formats, sizeof(AudioStreamRangedDescription), n, inSize, outSize, outData);
        }
        }
        break;

    case kObjectID_Volume_Output:
        switch (sel) {
        case kAudioObjectPropertyBaseClass:    PUT(AudioClassID, kAudioLevelControlClassID);
        case kAudioObjectPropertyClass:        PUT(AudioClassID, kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner:        PUT(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: { if (outSize) *outSize = 0; return kAudioHardwareNoError; }
        case kAudioControlPropertyScope:       PUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:     PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue:  PUT(Float32, mVolumeScalar.load());
        case kAudioLevelControlPropertyDecibelValue: PUT(Float32, volScalarToDB(mVolumeScalar.load()));
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange r{ kVolumeMinDB, kVolumeMaxDB };
            if (outData && inSize >= sizeof(r)) *reinterpret_cast<AudioValueRange*>(outData) = r;
            if (outSize) *outSize = sizeof(r);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            if (outData && inSize >= sizeof(Float32))
                *reinterpret_cast<Float32*>(outData) = volScalarToDB(*reinterpret_cast<Float32*>(outData));
            if (outSize) *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (outData && inSize >= sizeof(Float32))
                *reinterpret_cast<Float32*>(outData) = volDBToScalar(*reinterpret_cast<Float32*>(outData));
            if (outSize) *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        }
        }
        break;
    }

    // The HAL polls properties we don't implement (e.g. 'taps') continuously, so
    // logging here at all floods logd and can spin the system. Verbose-only.
    VLOG("GetProp UNHANDLED obj=%u sel=%{public}s scope=%{public}s", obj, fourcc(sel, b1), fourcc(scope, b2));
    return kAudioHardwareUnknownPropertyError;
}

Boolean Driver::hasProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a)
{
    UInt32 size = 0;
    return getPropertyData(obj, a, 0, nullptr, 0, &size, nullptr) == kAudioHardwareNoError;
}

OSStatus Driver::isSettable(AudioObjectID obj, const AudioObjectPropertyAddress* a, Boolean* outSettable)
{
    if (!hasProperty(obj, a)) return kAudioHardwareUnknownPropertyError;
    const AudioObjectPropertySelector sel = a->mSelector;
    bool settable =
        (obj == kObjectID_Device && sel == kAudioDevicePropertyNominalSampleRate) ||
        ((obj == kObjectID_Stream_Input || obj == kObjectID_Stream_Output) &&
         (sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat)) ||
        (obj == kObjectID_Volume_Output &&
         (sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue)) ||
        (obj == kObjectID_Device && sel == kSoundboardCustomProperty_RingSession);
    if (outSettable) *outSettable = settable;
    return kAudioHardwareNoError;
}

OSStatus Driver::setPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                                 UInt32 qSize, const void* qData, UInt32 inSize, const void* inData)
{
    (void)qSize; (void)qData;
    const AudioObjectPropertySelector sel = a->mSelector;

    // --- RingSession: the app claims (or releases, with 0) ring ownership ---
    if (obj == kObjectID_Device && sel == kSoundboardCustomProperty_RingSession) {
        if (!inData) return kAudioHardwareBadPropertySizeError;
        uint64_t session = 0;
        if (inSize == sizeof(CFDataRef)) {                 // marshaled as CFData
            CFDataRef d = *reinterpret_cast<const CFDataRef*>(inData);
            if (d && CFDataGetLength(d) >= (CFIndex)sizeof(session))
                CFDataGetBytes(d, CFRangeMake(0, sizeof(session)), reinterpret_cast<UInt8*>(&session));
        } else if (inSize >= sizeof(session)) {
            session = *reinterpret_cast<const uint64_t*>(inData);
        }
        mShmRing.setSession(session);
        os_log(gLog, "RingSession -> %llu", (unsigned long long)session);
        return kAudioHardwareNoError;
    }

    // --- Output volume control ---
    if (obj == kObjectID_Volume_Output &&
        (sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue)) {
        if (inSize < sizeof(Float32) || !inData) return kAudioHardwareBadPropertySizeError;
        Float32 value = *reinterpret_cast<const Float32*>(inData);
        Float32 scalar = (sel == kAudioLevelControlPropertyScalarValue) ? value : volDBToScalar(value);
        scalar = scalar < 0 ? 0 : (scalar > 1 ? 1 : scalar);
        mVolumeScalar.store(scalar);
        VLOG("SetProp Volume -> %.3f", scalar);
        if (mHost && mHost->PropertiesChanged) {
            AudioObjectPropertyAddress addrs[] = {
                { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
            };
            mHost->PropertiesChanged(mHost, kObjectID_Volume_Output, 2, addrs);
        }
        return kAudioHardwareNoError;
    }

    // --- Sample rate ---
    if (obj == kObjectID_Device && sel == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64) || !inData) return kAudioHardwareBadPropertySizeError;
        Float64 newRate = *reinterpret_cast<const Float64*>(inData);
        if (!rateSupported(newRate)) {
            // (Commented out: FaceTime loopback debugging session.)
            // os_log_error(gLog, "SetProp NominalSampleRate REJECTED (unsupported): %.0f Hz", newRate);
            return kAudioDeviceUnsupportedFormatError;
        }
        AudioStreamBasicDescription nf = mFormat;
        nf.mSampleRate = newRate;
        os_log(gLog, "SetProp NominalSampleRate -> %.0f", newRate);
        return requestFormatChange(nf);
    }

    // --- Stream format (channels / int|float / bits / rate) ---
    if ((obj == kObjectID_Stream_Input || obj == kObjectID_Stream_Output) &&
        (sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize < sizeof(AudioStreamBasicDescription) || !inData) return kAudioHardwareBadPropertySizeError;
        const auto& req = *reinterpret_cast<const AudioStreamBasicDescription*>(inData);
        UInt32 bytesPerSample = 0;
        if (!formatSupported(req, bytesPerSample)) {
            // (Commented out: FaceTime loopback debugging session.)
            // os_log_error(gLog, "SetProp Format REJECTED (unsupported): %.0f Hz %u ch %u-bit flags=0x%x",
            //              req.mSampleRate, req.mChannelsPerFrame, req.mBitsPerChannel, (unsigned)req.mFormatFlags);
            return kAudioDeviceUnsupportedFormatError;
        }
        bool isFloat = (req.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        AudioStreamBasicDescription nf = makeASBD(req.mSampleRate, req.mChannelsPerFrame, req.mBitsPerChannel, bytesPerSample, isFloat);
        os_log(gLog, "SetProp Format -> %.0f Hz %u ch %u-bit %{public}s", nf.mSampleRate, nf.mChannelsPerFrame, nf.mBitsPerChannel, isFloat ? "float" : "int");
        return requestFormatChange(nf);
    }

    return kAudioHardwareUnknownPropertyError;
}

// --------------------------------------------------------------------- IO
OSStatus Driver::startIO()
{
    UInt64 count;
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (mIOCount++ == 0) {
            mAnchorHostTime = mach_absolute_time();
            mIORunning = true;
            // The mix ring is created + owned at Initialize and lives for the
            // driver's lifetime, so there is nothing to attach/detach per IO
            // session — and nothing touches the mapping from a non-RT path here.
        }
        count = mIOCount;
    }
    os_log(gLog, "StartIO (clients now %llu)", count);
    return kAudioHardwareNoError;
}

OSStatus Driver::stopIO()
{
    UInt64 count;
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (mIOCount && --mIOCount == 0) mIORunning = false;   // keep the ring mapped
        count = mIOCount;
    }
    if (count == 0) { mLevelL = 0; mLevelR = 0; mPeakL = 0; mPeakR = 0; }
    os_log(gLog, "StopIO (clients now %llu)", count);
    // (Commented out: FaceTime loopback debugging session.)
    // if (count == 0) {
    //     // Session post-mortem. If a consumer (e.g. FaceTime) was reading our
    //     // input (readInput > 0) but the engine never delivered audible audio
    //     // (writeMix == 0 or peak ~= 0), the loopback was fed silence -> "nobody
    //     // can hear me". If writeMix peak is healthy, the device is fine and the
    //     // far end's silence is happening downstream (e.g. voice-processing AEC).
    //     os_log(gLog, "StopIO session summary: writeMix=%llu readInput=%llu outputPeak=%.4f",
    //            mWriteMixCycles.load(), mReadInputCycles.load(), (double)mSessionPeak.load());
    // }
    return kAudioHardwareNoError;
}

OSStatus Driver::getZeroTimeStamp(Float64* outSample, UInt64* outHost, UInt64* outSeed)
{
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = mHostTicksPerFrame * static_cast<Float64>(kRingFrames);
    UInt64 periods = ticksPerRing > 0 ? static_cast<UInt64>(static_cast<Float64>(now - mAnchorHostTime) / ticksPerRing) : 0;
    if (outSample) *outSample = static_cast<Float64>(periods * kRingFrames);
    if (outHost)   *outHost   = mAnchorHostTime + static_cast<UInt64>(static_cast<Float64>(periods) * ticksPerRing);
    if (outSeed)   *outSeed   = 1;
    return kAudioHardwareNoError;
}

OSStatus Driver::doIO(UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer)
{
    UInt32 bpf = mBytesPerFrame.load(std::memory_order_relaxed);
    if (bpf == 0 || !mainBuffer ||
        (op != kAudioServerPlugInIOOperationWriteMix && op != kAudioServerPlugInIOOperationReadInput))
        return kAudioHardwareNoError;
    (void)cycle;

    if (op == kAudioServerPlugInIOOperationWriteMix) {
        // The device output isn't looped anywhere — the input comes from the app's
        // mix ring. We only apply the output volume and update the level meters.
        applyGain(mainBuffer, frames, mVolumeScalar.load(std::memory_order_relaxed), mFormat);
        float pL, pR; computePeaks(mainBuffer, frames, mFormat, pL, pR);
        constexpr float kDecay = 0.80f, kPeakDecay = 0.992f;
        mLevelL.store(std::max(pL, mLevelL.load() * kDecay));
        mLevelR.store(std::max(pR, mLevelR.load() * kDecay));
        mPeakL.store(std::max(pL, mPeakL.load() * kPeakDecay));
        mPeakR.store(std::max(pR, mPeakR.load() * kPeakDecay));
    } else {
        // ReadInput: the device's input is the app's mix, drained from the driver-
        // owned shared ring (SHMEM.md §4) — decoupled from the output, RT-safe,
        // silence when no producer is granted/live.
        RingOutFormat fmt{ mFormat.mChannelsPerFrame, mFormat.mBitsPerChannel,
                           (mFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0 };
        mShmRing.consume(mainBuffer, frames, fmt);
    }
    return kAudioHardwareNoError;
}

} // namespace

#pragma mark - Factory (the only exported symbol)

extern "C" void* SoundboardDriver_Create(CFAllocatorRef, CFUUIDRef requestedTypeUUID)
{
    if (!gLog) gLog = os_log_create("ca.borisvanin.soundboard", "driver");
    os_log(gLog, "factory: SoundboardDriver_Create called");
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        os_log_error(gLog, "factory: wrong type UUID");
        return nullptr;
    }
    Driver& d = Driver::shared();
    d.buildInterface();
    return d.ref();
}
