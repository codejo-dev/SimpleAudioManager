// ProxyEngine.hpp
// Real-time state shared by one proxy device (writer + clock) and its target
// output (reader). Everything touched on an IO thread is atomic or guarded by
// a short os_unfair_lock (clock only).

#pragma once

#include "Core/ClockServo.hpp"
#include "Core/RingBuffer.hpp"

#include <os/lock.h>

#include <atomic>
#include <cstdint>

namespace sam {

struct ProxyEngine
{
    static constexpr uint32_t kRingFrames = 16384;
    static constexpr uint32_t kPeriodFrames = 16384; // zero time stamp period
    static constexpr uint32_t kMaxIOFrames = 8192;

    explicit ProxyEngine(uint32_t channelCount)
        : channels(channelCount)
        , ring(kRingFrames, channelCount)
    {
    }

    const uint32_t channels;
    RingBuffer ring;

    // Proxy clock. Locked briefly by GetZeroTimeStamp (proxy IO thread) and by
    // the target IOProc (which only ever try-locks for measurements).
    os_unfair_lock clockLock = OS_UNFAIR_LOCK_INIT;
    ClockServo servo;

    // Writer state.
    std::atomic<uint32_t> epoch{0};          // bumped on every proxy StartIO
    std::atomic<uint32_t> lastWriteFrames{0};
    std::atomic<bool> proxyRunning{false};
    std::atomic<double> proxySampleRate{48000.0};

    // Volume, written by control threads, read by the target IOProc.
    std::atomic<float> gain{1.0f};
    std::atomic<bool> muted{false};
    std::atomic<bool> softwareVolume{true};

    // Diagnostics.
    std::atomic<uint64_t> underruns{0};
    std::atomic<uint64_t> overruns{0};
    std::atomic<uint64_t> resyncs{0};
    std::atomic<double> correctionPPM{0.0};
};

} // namespace sam
