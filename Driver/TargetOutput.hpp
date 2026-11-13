// TargetOutput.hpp
// The physical output device a proxy forwards to. Runs inside coreaudiod and
// uses the HAL *client* API on that device: an IOProc that reads the proxy's
// ring buffer, applies the volume ramp and feeds the clock servo, plus property
// listeners for rate, liveness, hog mode and hardware volume.
//
// Threading: every method except the IOProc runs on the manager's serial
// control queue. Never call into this class from a HAL plug-in callback
// directly; dispatch to the queue instead. Property listeners are registered
// on a separate listener queue and only hand off to the control queue, so the
// HAL never waits for the control queue (that deadlocked when a device died
// while the control queue was removing its listeners).

#pragma once

#include "Core/GainRamp.hpp"
#include "ProxyEngine.hpp"

#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace sam {

struct TargetInfo
{
    AudioObjectID id = kAudioObjectUnknown;
    std::string uid;
    std::string name;
    UInt32 transport = 0;
    UInt32 channels = 0;
    Float64 sampleRate = 0;
    std::vector<Float64> sampleRates;
    UInt32 bufferFrames = 0;
    UInt32 safetyOffset = 0;
    UInt32 latency = 0;
    UInt32 streamLatency = 0;
    bool hasVolume = false;
    bool hasMute = false;
    bool alive = false;
    pid_t hogPID = -1;
};

// Reads everything we need about an output device (control queue only).
TargetInfo QueryTargetInfo(AudioObjectID device);

// All HAL devices as (id, uid, name) — control queue only.
struct HALDevice
{
    AudioObjectID id;
    std::string uid;
    std::string name;
    UInt32 outputChannels;
};
std::vector<HALDevice> ListHALDevices();

class TargetOutput : public std::enable_shared_from_this<TargetOutput>
{
public:
    TargetOutput(std::shared_ptr<ProxyEngine> engine, dispatch_queue_t controlQueue, dispatch_queue_t listenerQueue);
    ~TargetOutput();

    bool Attach(AudioObjectID device);
    void Detach();
    bool IsAttached() const { return device_ != kAudioObjectUnknown; }
    AudioObjectID DeviceID() const { return device_; }

    void Start();
    void Stop();
    bool IsRunning() const { return running_; }

    void Refresh(); // re-read info after a change notification
    const TargetInfo& Info() const { return info_; }

    OSStatus SetSampleRate(Float64 rate);
    void SetHardwareVolume(Float32 scalar);
    void SetHardwareMute(bool muted);
    Float32 HardwareVolume() const;

    // Reported proxy latency for lip sync (frames).
    UInt32 ForwardingLatency() const;

    // Notifications (delivered on the control queue).
    std::function<void()> OnChanged;               // rate, config, liveness, hog
    std::function<void(Float32)> OnVolumeChanged;  // hardware volume moved

private:
    static OSStatus IOProcTrampoline(AudioObjectID device,
        const AudioTimeStamp* now,
        const AudioBufferList* input,
        const AudioTimeStamp* inputTime,
        AudioBufferList* output,
        const AudioTimeStamp* outputTime,
        void* clientData);
    OSStatus Render(AudioBufferList* output, const AudioTimeStamp* outputTime);

    void AddListener(AudioObjectPropertySelector selector,
        AudioObjectPropertyScope scope,
        AudioObjectPropertyElement element,
        bool volume);
    void RemoveListeners();

    std::shared_ptr<ProxyEngine> engine_;
    dispatch_queue_t queue_;
    dispatch_queue_t listenerQueue_;
    AudioObjectID device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProc_ = nullptr;
    bool running_ = false;
    TargetInfo info_;

    struct Listener
    {
        AudioObjectPropertyAddress address;
        AudioObjectPropertyListenerBlock block;
    };
    std::vector<Listener> listeners_;

    // Shared with the IOProc.
    std::atomic<Float64> targetRate_{0};
    std::atomic<UInt32> safetyOffset_{0};

    // IOProc-only state.
    std::vector<float> scratch_;
    GainRamp ramp_;
    Float64 expectedSampleTime_ = -1;
    Float64 delta_ = 0;
    bool needAnchor_ = true;
    bool everAnchored_ = false;
    uint32_t lastGeneration_ = 0;
};

} // namespace sam
