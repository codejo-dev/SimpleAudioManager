// ProxyDevice.hpp
// The virtual output device that apps play to. It publishes a real volume and
// mute control (so macOS enables its own volume UI), writes the mixed output
// into the engine's ring buffer and runs a synthetic clock that the target
// output steers via the clock servo.

#pragma once

#include "ProxyEngine.hpp"

#include <aspl/Device.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace sam {

class ProxyDevice;

class ProxyVolumeControl : public aspl::VolumeControl
{
public:
    ProxyVolumeControl(std::shared_ptr<const aspl::Context> context,
        const aspl::VolumeControlParameters& params,
        std::shared_ptr<ProxyEngine> engine);
    ~ProxyVolumeControl() override;

    // Called (on a HAL thread) after every change; must not block.
    std::function<void(Float32 scalar)> OnChanged;

protected:
    OSStatus SetRawValueImpl(SInt32 value) override;

private:
    void UpdateGain();
    std::shared_ptr<ProxyEngine> engine_;
};

class ProxyMuteControl : public aspl::MuteControl
{
public:
    ProxyMuteControl(std::shared_ptr<const aspl::Context> context,
        const aspl::MuteControlParameters& params,
        std::shared_ptr<ProxyEngine> engine);

    std::function<void(bool muted)> OnChanged;

protected:
    OSStatus SetIsMutedImpl(bool isMuted) override;

private:
    std::shared_ptr<ProxyEngine> engine_;
};

// Output stream whose format follows the device's nominal sample rate (and
// vice versa when a client sets the stream format directly).
class ProxyStream : public aspl::Stream
{
public:
    ProxyStream(std::shared_ptr<const aspl::Context> context,
        std::shared_ptr<ProxyDevice> device,
        const aspl::StreamParameters& params);

    // Only call from inside a configuration change (or before publishing).
    void ApplySampleRate(Float64 rate);
    void ApplyAvailableRates(const std::vector<Float64>& rates);

protected:
    OSStatus SetPhysicalFormatImpl(const AudioStreamBasicDescription& format) override;
    OSStatus SetVirtualFormatImpl(const AudioStreamBasicDescription& format) override;

private:
    std::weak_ptr<ProxyDevice> device_;
};

class ProxyDevice : public aspl::Device
{
public:
    ProxyDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<ProxyEngine> engine,
        UInt32 transportType);

    // Builds stream, controls and IO handler. Call once, before AddDevice().
    void Setup(const std::vector<Float64>& sampleRates);

    std::shared_ptr<ProxyEngine> Engine() const { return engine_; }
    std::shared_ptr<ProxyVolumeControl> Volume() const { return volume_; }
    std::shared_ptr<ProxyMuteControl> Mute() const { return mute_; }

    // Attributes that can change while the device is published.
    void UpdateName(const std::string& name);
    void UpdateIconURL(const std::string& url);
    void UpdateTransportType(UInt32 transport);

    std::string GetName() const override;
    std::string GetIconURL() const override;
    UInt32 GetTransportType() const override;

    // Callbacks into the manager. Invoked on HAL threads; must not block.
    std::function<void()> OnStartIO;
    std::function<void()> OnStopIO;
    std::function<void(Float64)> OnSampleRateChanged;

    // Used by ProxyStream when a client changes the stream format.
    void ApplyRateFromStream(Float64 rate);

protected:
    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override;
    OSStatus SetNominalSampleRateImpl(Float64 rate) override;

private:
    std::shared_ptr<ProxyEngine> engine_;
    std::shared_ptr<ProxyStream> stream_;
    std::shared_ptr<ProxyVolumeControl> volume_;
    std::shared_ptr<ProxyMuteControl> mute_;
    std::shared_ptr<aspl::IORequestHandler> ioHandler_;

    mutable std::mutex attrMutex_;
    std::string name_;
    std::string iconURL_;
    std::atomic<UInt32> transport_;

    double hostTicksPerSecond_ = 0.0;
};

AudioStreamBasicDescription MakeFloatFormat(Float64 rate, UInt32 channels);

} // namespace sam
