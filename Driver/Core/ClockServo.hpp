// ClockServo.hpp
// The proxy device's clock is synthetic: it is derived from the host clock in
// GetZeroTimeStamp. Left alone it would drift against the physical device's
// crystal (typically 10-300 ppm), and the ring buffer would slowly run dry or
// overflow. This servo makes the proxy clock follow the target device:
//
//  * feed-forward: the target's measured rate scalar (AudioTimeStamp.mRateScalar)
//  * feedback: a PI controller on the phase between the two time lines, measured
//    in the target IOProc each cycle and applied once per zero-time-stamp period
//
// Adapted from briankendall/proxy-audio-device (Unlicense). This class is not
// thread-safe; the owner serializes access (see ProxyEngine).

#pragma once

#include <cmath>
#include <cstdint>

namespace sam {

class ClockServo
{
public:
    struct Tuning
    {
        double gainP = 1.0 / (64.0 * 16384.0);
        double gainI = (1.0 / (64.0 * 16384.0)) / 128.0;
        double maxCorrection = 500e-6; // +-500 ppm
    };

    ClockServo() = default;
    explicit ClockServo(Tuning tuning)
        : tuning_(tuning)
    {
    }

    // (Re)starts the time line at anchorHostTime. Sample time 0 == anchor.
    void Start(uint64_t anchorHostTime, double nominalTicksPerFrame, uint32_t periodFrames)
    {
        anchorHostTime_ = anchorHostTime;
        nominalTicksPerFrame_ = nominalTicksPerFrame;
        periodFrames_ = periodFrames == 0 ? 1 : periodFrames;
        periods_ = 0;
        elapsedTicks_ = 0.0;
        rateRatio_ = 1.0;
        rateAccum_ = 0.0;
        rateSamples_ = 0;
        correction_ = 1.0;
        ResetFeedback();
        running_ = true;
    }

    bool IsRunning() const { return running_; }
    void Stop() { running_ = false; }

    // Called from the proxy's GetZeroTimeStamp.
    void ZeroTimeStamp(uint64_t now, double& outSampleTime, uint64_t& outHostTime)
    {
        const double ticksPerPeriod = TicksPerFrame() * double(periodFrames_);
        if (ticksPerPeriod > 0.0) {
            const double sinceAnchor = double(int64_t(now - anchorHostTime_));
            const double sinceStamp = sinceAnchor - elapsedTicks_;
            if (sinceStamp >= ticksPerPeriod) {
                const uint64_t n = uint64_t(sinceStamp / ticksPerPeriod);
                periods_ += n;
                elapsedTicks_ += double(n) * ticksPerPeriod;
                UpdateCorrection();
            }
        }
        outSampleTime = double(periods_) * double(periodFrames_);
        outHostTime = anchorHostTime_ + uint64_t(elapsedTicks_);
    }

    // Projects the proxy time line onto a host time.
    double SampleTimeAt(uint64_t hostTime) const
    {
        const double tpf = TicksPerFrame();
        if (tpf <= 0.0) {
            return 0.0;
        }
        const uint64_t lastStampHost = anchorHostTime_ + uint64_t(elapsedTicks_);
        const double ticks = double(int64_t(hostTime - lastStampHost));
        return double(periods_) * double(periodFrames_) + ticks / tpf;
    }

    // Feed-forward: target's rate scalar (host ticks per frame / nominal).
    void AddRateScalar(double scalar)
    {
        if (scalar > 0.9 && scalar < 1.1 && rateSamples_ < 100000) {
            rateAccum_ += scalar;
            rateSamples_ += 1;
        }
    }

    // Feedback: phase = proxy sample time at the target's output host time
    // minus the frame being read. AnchorPhase records the set point.
    // Keeps the learned integral: crystal drift does not change when the
    // target's time line restarts.
    void AnchorPhase(double phaseFrames)
    {
        phaseAnchor_ = phaseFrames;
        phaseAnchored_ = true;
        phaseAccum_ = 0.0;
        phaseSamples_ = 0;
    }

    void AddPhaseSample(double phaseFrames)
    {
        if (phaseAnchored_ && phaseSamples_ < 100000) {
            phaseAccum_ += phaseFrames - phaseAnchor_;
            phaseSamples_ += 1;
        }
    }

    void ResetFeedback()
    {
        phaseAnchored_ = false;
        phaseAnchor_ = 0.0;
        phaseAccum_ = 0.0;
        phaseSamples_ = 0;
        integral_ = 0.0;
        lastMeanPhaseError_ = 0.0;
    }

    double TicksPerFrame() const { return nominalTicksPerFrame_ * rateRatio_ * correction_; }
    double CorrectionPPM() const { return (correction_ - 1.0) * 1e6; }
    double RateRatio() const { return rateRatio_; }
    double LastMeanPhaseError() const { return lastMeanPhaseError_; }
    uint32_t PeriodFrames() const { return periodFrames_; }

private:
    void UpdateCorrection()
    {
        if (rateSamples_ > 0) {
            rateRatio_ = rateAccum_ / double(rateSamples_);
            rateAccum_ = 0.0;
            rateSamples_ = 0;
        }
        if (phaseSamples_ == 0) {
            return;
        }
        const double meanError = phaseAccum_ / double(phaseSamples_);
        phaseAccum_ = 0.0;
        phaseSamples_ = 0;
        lastMeanPhaseError_ = meanError;

        const double maxIntegral = tuning_.maxCorrection / tuning_.gainI;
        integral_ = std::fmax(-maxIntegral, std::fmin(maxIntegral, integral_ + meanError));

        // Positive error: the proxy clock is ahead (data is produced faster than
        // the target consumes it), so lengthen the proxy's frame period.
        double c = tuning_.gainP * meanError + tuning_.gainI * integral_;
        c = std::fmax(-tuning_.maxCorrection, std::fmin(tuning_.maxCorrection, c));
        correction_ = 1.0 + c;
    }

    Tuning tuning_{};
    bool running_ = false;
    uint64_t anchorHostTime_ = 0;
    double nominalTicksPerFrame_ = 0.0;
    uint32_t periodFrames_ = 16384;
    uint64_t periods_ = 0;
    double elapsedTicks_ = 0.0;

    double rateRatio_ = 1.0;
    double rateAccum_ = 0.0;
    uint32_t rateSamples_ = 0;

    double correction_ = 1.0;
    bool phaseAnchored_ = false;
    double phaseAnchor_ = 0.0;
    double phaseAccum_ = 0.0;
    uint32_t phaseSamples_ = 0;
    double integral_ = 0.0;
    double lastMeanPhaseError_ = 0.0;
};

} // namespace sam
