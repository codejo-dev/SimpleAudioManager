#include "ProxyDevice.hpp"

#include "Core/GainRamp.hpp"
#include "VolumeCurve.hpp" // libASPL private header: completes aspl::VolumeCurve

#include <aspl/IORequestHandler.hpp>

#include <mach/mach_time.h>

namespace sam {

AudioStreamBasicDescription MakeFloatFormat(Float64 rate, UInt32 channels)
{
    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = channels;
    f.mBytesPerFrame = 4 * channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 4 * channels;
    return f;
}

// MARK: - Volume / mute

ProxyVolumeControl::ProxyVolumeControl(std::shared_ptr<const aspl::Context> context,
    const aspl::VolumeControlParameters& params,
    std::shared_ptr<ProxyEngine> engine)
    : aspl::VolumeControl(std::move(context), params)
    , engine_(std::move(engine))
{
    UpdateGain();
}

ProxyVolumeControl::~ProxyVolumeControl() = default;

OSStatus ProxyVolumeControl::SetRawValueImpl(SInt32 value)
{
    const OSStatus status = aspl::VolumeControl::SetRawValueImpl(value);
    if (status == kAudioHardwareNoError) {
        UpdateGain();
        if (OnChanged) {
            OnChanged(GetScalarValue());
        }
    }
    return status;
}

void ProxyVolumeControl::UpdateGain()
{
    const bool atMinimum = GetRawValue() <= SInt32(GetRawRange().mMinimum);
    engine_->gain.store(atMinimum ? 0.0f : DecibelsToGain(GetDecibelValue()), std::memory_order_release);
}

ProxyMuteControl::ProxyMuteControl(std::shared_ptr<const aspl::Context> context,
    const aspl::MuteControlParameters& params,
    std::shared_ptr<ProxyEngine> engine)
    : aspl::MuteControl(std::move(context), params)
    , engine_(std::move(engine))
{
}

OSStatus ProxyMuteControl::SetIsMutedImpl(bool isMuted)
{
    const OSStatus status = aspl::MuteControl::SetIsMutedImpl(isMuted);
    if (status == kAudioHardwareNoError) {
        engine_->muted.store(isMuted, std::memory_order_release);
        if (OnChanged) {
            OnChanged(isMuted);
        }
    }
    return status;
}

// MARK: - Stream

ProxyStream::ProxyStream(std::shared_ptr<const aspl::Context> context,
    std::shared_ptr<ProxyDevice> device,
    const aspl::StreamParameters& params)
    : aspl::Stream(std::move(context), device, params)
    , device_(device)
{
}

void ProxyStream::ApplySampleRate(Float64 rate)
{
    auto format = GetPhysicalFormat();
    if (format.mSampleRate == rate) {
        return;
    }
    format.mSampleRate = rate;
    aspl::Stream::SetPhysicalFormatImpl(format);
    aspl::Stream::SetVirtualFormatImpl(format);
    NotifyPropertiesChanged({kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat});
}

void ProxyStream::ApplyAvailableRates(const std::vector<Float64>& rates)
{
    const UInt32 channels = GetPhysicalFormat().mChannelsPerFrame;
    std::vector<AudioStreamRangedDescription> formats;
    for (Float64 rate : rates) {
        AudioStreamRangedDescription d = {};
        d.mFormat = MakeFloatFormat(rate, channels);
        d.mSampleRateRange.mMinimum = rate;
        d.mSampleRateRange.mMaximum = rate;
        formats.push_back(d);
    }
    aspl::Stream::SetAvailablePhysicalFormatsImpl(formats);
    aspl::Stream::SetAvailableVirtualFormatsImpl(formats);
    NotifyPropertiesChanged(
        {kAudioStreamPropertyAvailablePhysicalFormats, kAudioStreamPropertyAvailableVirtualFormats});
}

OSStatus ProxyStream::SetPhysicalFormatImpl(const AudioStreamBasicDescription& format)
{
    const OSStatus status = aspl::Stream::SetPhysicalFormatImpl(format);
    if (status == kAudioHardwareNoError) {
        aspl::Stream::SetVirtualFormatImpl(format);
        if (auto device = device_.lock()) {
            device->ApplyRateFromStream(format.mSampleRate);
        }
    }
    return status;
}

OSStatus ProxyStream::SetVirtualFormatImpl(const AudioStreamBasicDescription& format)
{
    const OSStatus status = aspl::Stream::SetVirtualFormatImpl(format);
    if (status == kAudioHardwareNoError) {
        aspl::Stream::SetPhysicalFormatImpl(format);
        if (auto device = device_.lock()) {
            device->ApplyRateFromStream(format.mSampleRate);
        }
    }
    return status;
}

// MARK: - IO handler

namespace {

// Writes the final mix into the ring buffer. Volume is applied later, in the
// target IOProc, so the default per-stream processing is disabled.
class ProxyIOHandler : public aspl::IORequestHandler
{
public:
    explicit ProxyIOHandler(std::shared_ptr<ProxyEngine> engine)
        : engine_(std::move(engine))
    {
    }

    void OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        Float32*,
        UInt32,
        UInt32) override
    {
    }

    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        Float32*,
        UInt32,
        UInt32) override
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        auto& e = *engine_;
        const UInt32 frames = bytesCount / (sizeof(Float32) * e.channels);
        const UInt32 epoch = e.epoch.load(std::memory_order_acquire);
        const bool restart = epoch != lastEpoch_;
        lastEpoch_ = epoch;
        e.ring.Write(int64_t(timestamp), static_cast<const float*>(bytes), frames, restart);
        e.lastWriteFrames.store(frames, std::memory_order_release);
    }

private:
    std::shared_ptr<ProxyEngine> engine_;
    UInt32 lastEpoch_ = UINT32_MAX; // only touched on the proxy's IO thread
};

double HostTicksPerSecond()
{
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return (double(info.denom) / double(info.numer)) * 1e9;
}

} // namespace

// MARK: - Device

ProxyDevice::ProxyDevice(std::shared_ptr<const aspl::Context> context,
    const aspl::DeviceParameters& params,
    std::shared_ptr<ProxyEngine> engine,
    UInt32 transportType)
    : aspl::Device(std::move(context), params)
    , engine_(std::move(engine))
    , name_(params.Name)
    , iconURL_(params.IconURL)
    , transport_(transportType)
    , hostTicksPerSecond_(HostTicksPerSecond())
{
    engine_->proxySampleRate.store(params.SampleRate);
}

void ProxyDevice::Setup(const std::vector<Float64>& sampleRates)
{
    auto self = std::static_pointer_cast<ProxyDevice>(shared_from_this());

    aspl::StreamParameters streamParams;
    streamParams.Direction = aspl::Direction::Output;
    streamParams.Format = MakeFloatFormat(GetNominalSampleRate(), engine_->channels);
    stream_ = std::make_shared<ProxyStream>(GetContext(), self, streamParams);
    stream_->ApplyAvailableRates(sampleRates);
    AddStreamAsync(stream_);

    std::vector<AudioValueRange> ranges;
    for (Float64 rate : sampleRates) {
        ranges.push_back({rate, rate});
    }
    SetAvailableSampleRatesAsync(ranges);

    aspl::VolumeControlParameters volumeParams;
    volumeParams.Scope = kAudioObjectPropertyScopeOutput;
    volumeParams.MinRawVolume = 0;
    volumeParams.MaxRawVolume = 140; // 0.5 dB steps
    volumeParams.MinDecibelVolume = -70.0f;
    volumeParams.MaxDecibelVolume = 0.0f;
    volume_ = std::make_shared<ProxyVolumeControl>(GetContext(), volumeParams, engine_);
    AddVolumeControlAsync(volume_);

    aspl::MuteControlParameters muteParams;
    muteParams.Scope = kAudioObjectPropertyScopeOutput;
    mute_ = std::make_shared<ProxyMuteControl>(GetContext(), muteParams, engine_);
    AddMuteControlAsync(mute_);

    ioHandler_ = std::make_shared<ProxyIOHandler>(engine_);
    SetIOHandler(ioHandler_);
}

void ProxyDevice::UpdateName(const std::string& name)
{
    {
        std::lock_guard lock(attrMutex_);
        if (name_ == name) {
            return;
        }
        name_ = name;
    }
    NotifyPropertyChanged(kAudioObjectPropertyName);
}

void ProxyDevice::UpdateIconURL(const std::string& url)
{
    {
        std::lock_guard lock(attrMutex_);
        if (iconURL_ == url) {
            return;
        }
        iconURL_ = url;
    }
    NotifyPropertyChanged(kAudioDevicePropertyIcon);
}

void ProxyDevice::UpdateTransportType(UInt32 transport)
{
    if (transport_.exchange(transport) != transport) {
        NotifyPropertyChanged(kAudioDevicePropertyTransportType);
    }
}

std::string ProxyDevice::GetName() const
{
    std::lock_guard lock(attrMutex_);
    return name_;
}

std::string ProxyDevice::GetIconURL() const
{
    std::lock_guard lock(attrMutex_);
    return iconURL_;
}

UInt32 ProxyDevice::GetTransportType() const
{
    return transport_.load();
}

void ProxyDevice::ApplyRateFromStream(Float64 rate)
{
    if (rate > 0 && rate != GetNominalSampleRate()) {
        SetNominalSampleRateImpl(rate);
        NotifyPropertyChanged(kAudioDevicePropertyNominalSampleRate);
    }
}

OSStatus ProxyDevice::SetNominalSampleRateImpl(Float64 rate)
{
    const OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
    if (status != kAudioHardwareNoError) {
        return status;
    }
    engine_->proxySampleRate.store(rate, std::memory_order_release);
    if (stream_) {
        stream_->ApplySampleRate(rate);
    }
    if (OnSampleRateChanged) {
        OnSampleRateChanged(rate);
    }
    return status;
}

OSStatus ProxyDevice::StartIOImpl(UInt32 clientID, UInt32 startCount)
{
    const OSStatus status = aspl::Device::StartIOImpl(clientID, startCount);
    if (status != kAudioHardwareNoError || startCount != 0) {
        return status;
    }
    auto& e = *engine_;
    const double rate = GetNominalSampleRate();
    os_unfair_lock_lock(&e.clockLock);
    e.servo.Start(mach_absolute_time(), hostTicksPerSecond_ / rate, ProxyEngine::kPeriodFrames);
    os_unfair_lock_unlock(&e.clockLock);
    e.epoch.fetch_add(1, std::memory_order_acq_rel);
    e.proxyRunning.store(true, std::memory_order_release);
    if (OnStartIO) {
        OnStartIO();
    }
    return status;
}

OSStatus ProxyDevice::StopIOImpl(UInt32 clientID, UInt32 startCount)
{
    const OSStatus status = aspl::Device::StopIOImpl(clientID, startCount);
    if (startCount == 0) {
        engine_->proxyRunning.store(false, std::memory_order_release);
        os_unfair_lock_lock(&engine_->clockLock);
        engine_->servo.Stop();
        os_unfair_lock_unlock(&engine_->clockLock);
        if (OnStopIO) {
            OnStopIO();
        }
    }
    return status;
}

OSStatus ProxyDevice::GetZeroTimeStampImpl(UInt32,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    auto& e = *engine_;
    double sampleTime = 0;
    uint64_t hostTime = 0;
    os_unfair_lock_lock(&e.clockLock);
    e.servo.ZeroTimeStamp(mach_absolute_time(), sampleTime, hostTime);
    const double ppm = e.servo.CorrectionPPM();
    os_unfair_lock_unlock(&e.clockLock);
    e.correctionPPM.store(ppm, std::memory_order_relaxed);
    *outSampleTime = sampleTime;
    *outHostTime = hostTime;
    *outSeed = 1;
    return kAudioHardwareNoError;
}

} // namespace sam
