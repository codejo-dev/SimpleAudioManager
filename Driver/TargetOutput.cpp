#include "TargetOutput.hpp"

#include "Log.hpp"

#include <Block.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace sam {

namespace {

constexpr Float64 kTimelineJumpTolerance = 16384.0;
constexpr UInt32 kMarginFrames = 64;
constexpr UInt32 kWriterFramesEstimate = 512;

AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain)
{
    return {selector, scope, element};
}

template <typename T>
bool Get(AudioObjectID object, const AudioObjectPropertyAddress& address, T& out)
{
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &out) == noErr;
}

std::string GetString(AudioObjectID object, AudioObjectPropertySelector selector)
{
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    const auto address = Address(selector);
    if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value) != noErr || !value) {
        return {};
    }
    char buffer[512] = {};
    CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(value);
    return buffer;
}

template <typename T>
std::vector<T> GetArray(AudioObjectID object, const AudioObjectPropertyAddress& address)
{
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr || size == 0) {
        return {};
    }
    std::vector<T> values(size / sizeof(T));
    if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, values.data()) != noErr) {
        return {};
    }
    values.resize(size / sizeof(T));
    return values;
}

bool IsSettable(AudioObjectID object, const AudioObjectPropertyAddress& address)
{
    if (!AudioObjectHasProperty(object, &address)) {
        return false;
    }
    Boolean settable = false;
    return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable;
}

UInt32 OutputChannelCount(AudioObjectID device)
{
    const auto address = Address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size == 0) {
        return 0;
    }
    std::vector<UInt8> storage(size);
    auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list) != noErr) {
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        channels += list->mBuffers[i].mNumberChannels;
    }
    return channels;
}

std::vector<Float64> ExpandRates(const std::vector<AudioValueRange>& ranges)
{
    static const Float64 standard[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};
    std::vector<Float64> rates;
    for (const auto& range : ranges) {
        if (range.mMinimum == range.mMaximum) {
            rates.push_back(range.mMinimum);
            continue;
        }
        for (Float64 rate : standard) {
            if (rate >= range.mMinimum && rate <= range.mMaximum) {
                rates.push_back(rate);
            }
        }
    }
    std::sort(rates.begin(), rates.end());
    rates.erase(std::unique(rates.begin(), rates.end()), rates.end());
    return rates;
}

AudioObjectPropertyElement VolumeElement(AudioObjectID device)
{
    if (IsSettable(device, Address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput))) {
        return kAudioObjectPropertyElementMain;
    }
    if (IsSettable(device, Address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1))) {
        return 1;
    }
    return UINT32_MAX;
}

} // namespace

TargetInfo QueryTargetInfo(AudioObjectID device)
{
    TargetInfo info;
    info.id = device;
    info.uid = GetString(device, kAudioDevicePropertyDeviceUID);
    info.name = GetString(device, kAudioObjectPropertyName);
    Get(device, Address(kAudioDevicePropertyTransportType), info.transport);
    UInt32 alive = 0;
    info.alive = Get(device, Address(kAudioDevicePropertyDeviceIsAlive), alive) && alive != 0;
    info.channels = OutputChannelCount(device);
    Get(device, Address(kAudioDevicePropertyNominalSampleRate), info.sampleRate);
    info.sampleRates =
        ExpandRates(GetArray<AudioValueRange>(device, Address(kAudioDevicePropertyAvailableNominalSampleRates)));
    if (info.sampleRates.empty() && info.sampleRate > 0) {
        info.sampleRates.push_back(info.sampleRate);
    }
    Get(device, Address(kAudioDevicePropertyBufferFrameSize), info.bufferFrames);
    Get(device, Address(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), info.safetyOffset);
    Get(device, Address(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), info.latency);
    const auto streams = GetArray<AudioObjectID>(device, Address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput));
    if (!streams.empty()) {
        Get(streams.front(), Address(kAudioStreamPropertyLatency), info.streamLatency);
    }
    info.hasVolume = VolumeElement(device) != UINT32_MAX;
    info.hasMute = IsSettable(device, Address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput));
    Get(device, Address(kAudioDevicePropertyHogMode), info.hogPID);
    return info;
}

std::vector<HALDevice> ListHALDevices()
{
    std::vector<HALDevice> result;
    const auto ids = GetArray<AudioObjectID>(kAudioObjectSystemObject, Address(kAudioHardwarePropertyDevices));
    for (AudioObjectID id : ids) {
        result.push_back({id,
            GetString(id, kAudioDevicePropertyDeviceUID),
            GetString(id, kAudioObjectPropertyName),
            OutputChannelCount(id)});
    }
    return result;
}

// MARK: - TargetOutput

TargetOutput::TargetOutput(std::shared_ptr<ProxyEngine> engine, dispatch_queue_t controlQueue, dispatch_queue_t listenerQueue)
    : engine_(std::move(engine))
    , queue_(controlQueue)
    , listenerQueue_(listenerQueue)
    , scratch_(size_t(ProxyEngine::kMaxIOFrames) * engine_->channels, 0.0f)
{
}

TargetOutput::~TargetOutput()
{
    Detach();
}

bool TargetOutput::Attach(AudioObjectID device)
{
    Detach();
    info_ = QueryTargetInfo(device);
    if (!info_.alive || info_.channels == 0) {
        return false;
    }
    const OSStatus status = AudioDeviceCreateIOProcID(device, &TargetOutput::IOProcTrampoline, this, &ioProc_);
    if (status != noErr || !ioProc_) {
        SAM_LOG_ERROR("AudioDeviceCreateIOProcID failed for %{public}s: %d", info_.uid.c_str(), int(status));
        ioProc_ = nullptr;
        return false;
    }
    device_ = device;
    targetRate_.store(info_.sampleRate);
    safetyOffset_.store(info_.safetyOffset);

    AddListener(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, false);
    AddListener(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, false);
    const AudioObjectPropertyElement volumeElement = VolumeElement(device);
    if (volumeElement != UINT32_MAX) {
        AddListener(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, volumeElement, true);
    }
    SAM_LOG_INFO("attached target %{public}s (%u ch @ %.0f Hz)", info_.uid.c_str(), info_.channels, info_.sampleRate);
    return true;
}

void TargetOutput::Detach()
{
    Stop();
    RemoveListeners();
    if (device_ != kAudioObjectUnknown && ioProc_) {
        AudioDeviceDestroyIOProcID(device_, ioProc_);
    }
    ioProc_ = nullptr;
    device_ = kAudioObjectUnknown;
}

void TargetOutput::Start()
{
    if (running_ || !ioProc_) {
        return;
    }
    // Reset IOProc-only state while the IOProc is guaranteed not to run.
    expectedSampleTime_ = -1;
    needAnchor_ = true;
    everAnchored_ = false;
    lastGeneration_ = engine_->ring.Generation();
    ramp_.SetRampFrames(UInt32(std::max(1.0, info_.sampleRate * 0.02))); // 20 ms
    const bool muted = engine_->muted.load();
    ramp_.SetImmediate(muted ? 0.0f : (engine_->softwareVolume.load() ? engine_->gain.load() : 1.0f));

    const OSStatus status = AudioDeviceStart(device_, ioProc_);
    if (status != noErr) {
        SAM_LOG_ERROR("AudioDeviceStart failed for %{public}s: %d", info_.uid.c_str(), int(status));
        return;
    }
    running_ = true;
    SAM_LOG_INFO("forwarding to %{public}s started", info_.uid.c_str());
}

void TargetOutput::Stop()
{
    if (!running_) {
        return;
    }
    AudioDeviceStop(device_, ioProc_);
    running_ = false;
    SAM_LOG_INFO("forwarding to %{public}s stopped", info_.uid.c_str());
}

void TargetOutput::Refresh()
{
    if (device_ == kAudioObjectUnknown) {
        return;
    }
    info_ = QueryTargetInfo(device_);
    targetRate_.store(info_.sampleRate);
    safetyOffset_.store(info_.safetyOffset);
}

OSStatus TargetOutput::SetSampleRate(Float64 rate)
{
    if (device_ == kAudioObjectUnknown) {
        return kAudioHardwareBadDeviceError;
    }
    const auto address = Address(kAudioDevicePropertyNominalSampleRate);
    return AudioObjectSetPropertyData(device_, &address, 0, nullptr, sizeof(rate), &rate);
}

void TargetOutput::SetHardwareVolume(Float32 scalar)
{
    const AudioObjectPropertyElement element = VolumeElement(device_);
    if (element == UINT32_MAX) {
        return;
    }
    if (element == kAudioObjectPropertyElementMain) {
        const auto address = Address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput);
        AudioObjectSetPropertyData(device_, &address, 0, nullptr, sizeof(scalar), &scalar);
        return;
    }
    for (UInt32 channel = 1; channel <= info_.channels; ++channel) {
        const auto address = Address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, channel);
        if (IsSettable(device_, address)) {
            AudioObjectSetPropertyData(device_, &address, 0, nullptr, sizeof(scalar), &scalar);
        }
    }
}

void TargetOutput::SetHardwareMute(bool muted)
{
    const auto address = Address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput);
    if (IsSettable(device_, address)) {
        UInt32 value = muted ? 1 : 0;
        AudioObjectSetPropertyData(device_, &address, 0, nullptr, sizeof(value), &value);
    }
}

Float32 TargetOutput::HardwareVolume() const
{
    const AudioObjectPropertyElement element = VolumeElement(device_);
    Float32 value = 1.0f;
    if (element != UINT32_MAX) {
        Get(device_, Address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element), value);
    }
    return value;
}

UInt32 TargetOutput::ForwardingLatency() const
{
    const UInt32 ringLag = kWriterFramesEstimate + info_.bufferFrames + info_.safetyOffset + kMarginFrames;
    return info_.latency + info_.streamLatency + info_.safetyOffset + info_.bufferFrames + ringLag;
}

void TargetOutput::AddListener(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    bool volume)
{
    std::weak_ptr<TargetOutput> weak = weak_from_this();
    dispatch_queue_t control = queue_;
    // The HAL calls this synchronously on the listener queue, possibly while
    // tearing the device down. Only hand off to the control queue here: work
    // done (or waited for) here can deadlock with RemoveListeners().
    AudioObjectPropertyListenerBlock block = ^(UInt32, const AudioObjectPropertyAddress*) {
        dispatch_async(control, ^{
            auto self = weak.lock();
            if (!self || self->device_ == kAudioObjectUnknown) {
                return;
            }
            if (volume) {
                if (self->OnVolumeChanged) {
                    self->OnVolumeChanged(self->HardwareVolume());
                }
                return;
            }
            self->Refresh();
            if (self->OnChanged) {
                self->OnChanged();
            }
        });
    };
    block = Block_copy(block);
    const auto address = Address(selector, scope, element);
    if (AudioObjectAddPropertyListenerBlock(device_, &address, listenerQueue_, block) == noErr) {
        listeners_.push_back({address, block});
    } else {
        Block_release(block);
    }
}

void TargetOutput::RemoveListeners()
{
    for (auto& listener : listeners_) {
        if (device_ != kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(device_, &listener.address, listenerQueue_, listener.block);
        }
        Block_release(listener.block);
    }
    listeners_.clear();
}

// MARK: - IO

OSStatus TargetOutput::IOProcTrampoline(AudioObjectID,
    const AudioTimeStamp*,
    const AudioBufferList*,
    const AudioTimeStamp*,
    AudioBufferList* output,
    const AudioTimeStamp* outputTime,
    void* clientData)
{
    return static_cast<TargetOutput*>(clientData)->Render(output, outputTime);
}

OSStatus TargetOutput::Render(AudioBufferList* out, const AudioTimeStamp* t)
{
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        if (out->mBuffers[i].mData) {
            std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
        }
    }
    if (out->mNumberBuffers == 0 || out->mBuffers[0].mNumberChannels == 0) {
        return noErr;
    }
    auto& e = *engine_;
    const UInt32 ch = e.channels;
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (out->mBuffers[0].mNumberChannels * sizeof(Float32));
    if (frames == 0 || frames > ProxyEngine::kMaxIOFrames) {
        return noErr;
    }

    // The target restarted its time line (display wake, USB reset, rate change).
    if (expectedSampleTime_ >= 0) {
        const Float64 jump = t->mSampleTime - expectedSampleTime_;
        if (jump < 0 || jump > kTimelineJumpTolerance) {
            needAnchor_ = true;
        }
    }
    expectedSampleTime_ = t->mSampleTime + frames;

    const bool hostValid = (t->mFlags & kAudioTimeStampHostTimeValid) != 0;
    if ((t->mFlags & kAudioTimeStampRateScalarValid) && os_unfair_lock_trylock(&e.clockLock)) {
        e.servo.AddRateScalar(t->mRateScalar);
        os_unfair_lock_unlock(&e.clockLock);
    }

    // Rates must agree; the manager re-syncs them. Play silence meanwhile.
    if (targetRate_.load(std::memory_order_relaxed) != e.proxySampleRate.load(std::memory_order_relaxed)) {
        return noErr;
    }

    const uint32_t generation = e.ring.Generation();
    if (generation != lastGeneration_) {
        lastGeneration_ = generation;
        needAnchor_ = true;
    }
    const int64_t end = e.ring.EndFrame();
    if (end < 0) {
        return noErr;
    }

    const bool proxyRunning = e.proxyRunning.load(std::memory_order_acquire);
    Float64 start = 0;
    if (needAnchor_) {
        if (!hostValid || !proxyRunning) {
            return noErr;
        }
        const Float64 lag = Float64(e.lastWriteFrames.load()) + frames + safetyOffset_.load() + kMarginFrames;
        start = Float64(end) - lag;
        delta_ = start - t->mSampleTime;
        os_unfair_lock_lock(&e.clockLock);
        if (e.servo.IsRunning()) {
            e.servo.AnchorPhase(e.servo.SampleTimeAt(t->mHostTime) - start);
        }
        os_unfair_lock_unlock(&e.clockLock);
        if (everAnchored_) {
            e.resyncs.fetch_add(1, std::memory_order_relaxed);
        }
        everAnchored_ = true;
        needAnchor_ = false;
    } else {
        start = t->mSampleTime + delta_;
        const int64_t fill = end - int64_t(start);
        const int64_t capacity = int64_t(e.ring.Capacity());
        if (fill > capacity || fill < -capacity) {
            needAnchor_ = true;
            return noErr;
        }
        if (hostValid && proxyRunning && os_unfair_lock_trylock(&e.clockLock)) {
            if (e.servo.IsRunning()) {
                e.servo.AddPhaseSample(e.servo.SampleTimeAt(t->mHostTime) - start);
            }
            os_unfair_lock_unlock(&e.clockLock);
        }
    }

    float* scratch = scratch_.data();
    const auto result = e.ring.Read(int64_t(start), scratch, frames);
    if (proxyRunning) {
        if (result.missingFrames > 0) {
            e.underruns.fetch_add(1, std::memory_order_relaxed);
        }
        if (result.lostFrames > 0) {
            e.overruns.fetch_add(1, std::memory_order_relaxed);
        }
    }

    const bool muted = e.muted.load(std::memory_order_relaxed);
    const float gain = e.softwareVolume.load(std::memory_order_relaxed) ? e.gain.load(std::memory_order_relaxed) : 1.0f;
    ramp_.Process(scratch, frames, ch, muted ? 0.0f : gain);

    // Scatter proxy channels onto the target's buffers (interleaved or not).
    UInt32 channel = 0;
    for (UInt32 i = 0; i < out->mNumberBuffers && channel < ch; ++i) {
        AudioBuffer& buffer = out->mBuffers[i];
        const UInt32 n = buffer.mNumberChannels;
        auto* dst = static_cast<float*>(buffer.mData);
        if (!dst || n == 0) {
            continue;
        }
        const UInt32 bufferFrames = std::min(frames, UInt32(buffer.mDataByteSize / (n * sizeof(float))));
        const UInt32 use = std::min(n, ch - channel);
        if (n == ch && channel == 0) {
            std::memcpy(dst, scratch, size_t(bufferFrames) * ch * sizeof(float));
        } else {
            for (UInt32 f = 0; f < bufferFrames; ++f) {
                for (UInt32 c = 0; c < use; ++c) {
                    dst[size_t(f) * n + c] = scratch[size_t(f) * ch + channel + c];
                }
            }
        }
        channel += n;
    }
    return noErr;
}

} // namespace sam
