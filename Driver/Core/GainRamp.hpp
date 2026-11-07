// GainRamp.hpp
// Smoothed gain for interleaved Float32 audio. Volume changes glide linearly
// over a short ramp so there is no zipper noise. At unity gain the samples are
// left untouched (bit-transparent).

#pragma once

#include <Accelerate/Accelerate.h>

#include <cmath>
#include <cstdint>
#include <cstring>

namespace sam {

// Converts a volume in decibels to a linear amplitude. Anything at or below
// silenceDB maps to exactly 0.
inline float DecibelsToGain(float db, float silenceDB = -120.0f)
{
    if (db <= silenceDB) {
        return 0.0f;
    }
    if (db >= 0.0f) {
        return 1.0f;
    }
    return std::pow(10.0f, db / 20.0f);
}

class GainRamp
{
public:
    explicit GainRamp(uint32_t rampFrames = 960)
        : rampFrames_(rampFrames == 0 ? 1 : rampFrames)
    {
    }

    void SetRampFrames(uint32_t frames) { rampFrames_ = frames == 0 ? 1 : frames; }

    // Jump straight to a gain without ramping (used when playback starts).
    void SetImmediate(float gain)
    {
        current_ = gain;
        target_ = gain;
        step_ = 0.0f;
        remaining_ = 0;
    }

    float Current() const { return current_; }

    void Process(float* samples, uint32_t frames, uint32_t channels, float target)
    {
        if (target != target_) {
            target_ = target;
            remaining_ = rampFrames_;
            step_ = (target_ - current_) / float(rampFrames_);
        }

        uint32_t frame = 0;
        for (; frame < frames && remaining_ > 0; ++frame) {
            // Count frames instead of comparing floats so the ramp lands
            // exactly on the target after rampFrames_ frames.
            current_ = (--remaining_ == 0) ? target_ : current_ + step_;
            float* f = samples + size_t(frame) * channels;
            for (uint32_t c = 0; c < channels; ++c) {
                f[c] *= current_;
            }
        }

        if (frame >= frames) {
            return;
        }

        // Steady state for the rest of the buffer.
        float* rest = samples + size_t(frame) * channels;
        const vDSP_Length count = vDSP_Length(frames - frame) * channels;
        if (current_ == 1.0f) {
            return; // bit-transparent
        }
        if (current_ == 0.0f) {
            std::memset(rest, 0, count * sizeof(float));
            return;
        }
        vDSP_vsmul(rest, 1, &current_, rest, 1, count);
    }

private:
    uint32_t rampFrames_;
    float current_ = 1.0f;
    float target_ = 1.0f;
    float step_ = 0.0f;
    uint32_t remaining_ = 0;
};

} // namespace sam
