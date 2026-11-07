// DriverCoreTests.mm
// Tests for the header-only real-time core of the driver: ring buffer, gain
// ramp, dB conversion and the clock servo (simulated drift and time line jumps).

#import <XCTest/XCTest.h>

#include "ClockServo.hpp"
#include "GainRamp.hpp"
#include "RingBuffer.hpp"

#include <cmath>
#include <vector>

using namespace sam;

@interface RingBufferTests : XCTestCase
@end

@implementation RingBufferTests

static std::vector<float> Ramp(int64_t start, uint32_t frames, uint32_t channels)
{
    std::vector<float> v(size_t(frames) * channels);
    for (uint32_t f = 0; f < frames; ++f) {
        for (uint32_t c = 0; c < channels; ++c) {
            v[size_t(f) * channels + c] = float(start + f) + 0.25f * float(c);
        }
    }
    return v;
}

- (void)testWriteThenReadRoundTripsAcrossWrap
{
    RingBuffer ring(1024, 2);
    std::vector<float> out(512 * 2);
    for (int64_t t = 0; t < 5000; t += 256) {
        auto data = Ramp(t, 256, 2);
        ring.Write(t, data.data(), 256);
    }
    const int64_t start = ring.EndFrame() - 600; // spans the wrap point
    auto result = ring.Read(start, out.data(), 512);
    XCTAssertEqual(result.validFrames, 512u);
    XCTAssertEqual(result.missingFrames, 0u);
    XCTAssertEqual(result.lostFrames, 0u);
    auto expected = Ramp(start, 512, 2);
    XCTAssertTrue(out == expected);
}

- (void)testUnderrunIsZeroFilledAndReported
{
    RingBuffer ring(1024, 1);
    auto data = Ramp(0, 100, 1);
    ring.Write(0, data.data(), 100);
    std::vector<float> out(64, 7.0f);
    auto result = ring.Read(80, out.data(), 64);
    XCTAssertEqual(result.validFrames, 20u);
    XCTAssertEqual(result.missingFrames, 44u);
    XCTAssertEqual(out[19], 99.0f);
    XCTAssertEqual(out[20], 0.0f);
    XCTAssertEqual(out[63], 0.0f);
}

- (void)testOverrunIsZeroFilledAndReported
{
    RingBuffer ring(256, 1);
    for (int64_t t = 0; t < 1024; t += 64) {
        auto data = Ramp(t, 64, 1);
        ring.Write(t, data.data(), 64);
    }
    std::vector<float> out(64, 7.0f);
    auto result = ring.Read(100, out.data(), 64); // long overwritten
    XCTAssertEqual(result.validFrames, 0u);
    XCTAssertEqual(result.lostFrames, 64u);
    XCTAssertEqual(out[0], 0.0f);
}

- (void)testBackwardsWriteStartsNewGeneration
{
    RingBuffer ring(1024, 1);
    auto a = Ramp(5000, 512, 1);
    ring.Write(5000, a.data(), 512);
    const uint32_t gen = ring.Generation();
    auto b = Ramp(0, 512, 1);
    ring.Write(0, b.data(), 512);
    XCTAssertNotEqual(ring.Generation(), gen);
    XCTAssertEqual(ring.EndFrame(), 512);
    std::vector<float> out(512);
    auto result = ring.Read(5000, out.data(), 512);
    XCTAssertEqual(result.validFrames, 0u);
}

- (void)testForcedRestartAndGapFill
{
    RingBuffer ring(1024, 1);
    auto a = Ramp(0, 100, 1);
    ring.Write(0, a.data(), 100);
    const uint32_t gen = ring.Generation();
    ring.Write(100, a.data(), 100, /*forceRestart*/ true);
    XCTAssertNotEqual(ring.Generation(), gen);

    // A gap must read back as silence, not stale data from an earlier lap.
    RingBuffer gap(256, 1);
    for (int64_t t = 0; t < 256; t += 64) {
        auto d = Ramp(t, 64, 1);
        gap.Write(t, d.data(), 64);
    }
    auto d = Ramp(400, 64, 1);
    gap.Write(400, d.data(), 64);
    std::vector<float> out(64, 7.0f);
    gap.Read(300, out.data(), 64);
    for (float v : out) {
        XCTAssertEqual(v, 0.0f);
    }
}

@end

@interface GainRampTests : XCTestCase
@end

@implementation GainRampTests

- (void)testUnityIsBitTransparent
{
    GainRamp ramp(480);
    std::vector<float> samples = {0.123456789f, -0.987654321f, 1e-9f, -1.0f, 0.5f, 0.25f};
    auto copy = samples;
    ramp.Process(samples.data(), 3, 2, 1.0f);
    XCTAssertTrue(std::memcmp(samples.data(), copy.data(), samples.size() * sizeof(float)) == 0);
}

- (void)testRampIsMonotonicAndReachesTarget
{
    GainRamp ramp(100);
    std::vector<float> ones(300 * 2, 1.0f);
    ramp.Process(ones.data(), 300, 2, 0.0f);
    float previous = 1.0f;
    for (uint32_t f = 0; f < 300; ++f) {
        const float v = ones[f * 2];
        XCTAssertEqual(v, ones[f * 2 + 1]); // channels stay in lockstep
        XCTAssertLessThanOrEqual(v, previous);
        XCTAssertLessThanOrEqual(previous - v, 1.0f / 100.0f + 1e-6f); // no jumps
        previous = v;
    }
    XCTAssertEqual(ones[99 * 2], 0.0f);
    XCTAssertEqual(ramp.Current(), 0.0f);
}

- (void)testRampContinuesAcrossBuffers
{
    GainRamp ramp(1000);
    ramp.SetImmediate(0.0f);
    std::vector<float> buf(64, 1.0f);
    ramp.Process(buf.data(), 64, 1, 1.0f);
    const float end1 = buf[63];
    std::fill(buf.begin(), buf.end(), 1.0f);
    ramp.Process(buf.data(), 64, 1, 1.0f);
    XCTAssertGreaterThan(buf[0], end1);
    XCTAssertLessThan(buf[0] - end1, 0.0011f);
}

- (void)testDecibelConversion
{
    XCTAssertEqual(DecibelsToGain(0.0f), 1.0f);
    XCTAssertEqual(DecibelsToGain(-200.0f), 0.0f);
    XCTAssertEqualWithAccuracy(DecibelsToGain(-6.0206f), 0.5f, 1e-4);
    XCTAssertEqualWithAccuracy(DecibelsToGain(-20.0f), 0.1f, 1e-6);
}

@end

@interface ClockServoTests : XCTestCase
@end

@implementation ClockServoTests

struct SimResult
{
    double maxError = 0;
    double maxErrorAfterSettling = 0;
    double finalCorrectionPPM = 0;
};

// Simulates a target device whose crystal is off by driftPPM and a reader
// that holds a fixed lag behind the proxy time line, for `seconds`.
static SimResult Simulate(double driftPPM, bool feedForward, double seconds, double jumpAtSecond = -1)
{
    const double hz = 24e6, rate = 48000, nominal = hz / rate;
    const double trueTicks = nominal / (1.0 + driftPPM * 1e-6);
    const uint32_t buffer = 512;
    const double lag = 2048;
    ClockServo servo;
    servo.Start(1000, nominal, 16384);
    SimResult r;
    double delta = 0;
    bool anchored = false;
    uint64_t targetSample = 0;
    const uint64_t cycles = uint64_t(seconds * rate / buffer);
    const uint64_t jumpCycle = jumpAtSecond < 0 ? UINT64_MAX : uint64_t(jumpAtSecond * rate / buffer);
    for (uint64_t k = 0; k < cycles; ++k) {
        const uint64_t host = 1000 + uint64_t(double(k * buffer) * trueTicks);
        double st;
        uint64_t ht;
        servo.ZeroTimeStamp(host, st, ht);
        if (feedForward) {
            servo.AddRateScalar(trueTicks / nominal);
        }
        if (k == jumpCycle) {
            targetSample = 0; // target restarted its time line
            anchored = false;
        }
        const double proxyNow = servo.SampleTimeAt(host);
        if (!anchored) {
            const double start = proxyNow - lag;
            delta = start - double(targetSample);
            servo.AnchorPhase(proxyNow - start);
            anchored = true;
        } else {
            const double start = double(targetSample) + delta;
            const double phase = proxyNow - start;
            servo.AddPhaseSample(phase);
            const double err = std::fabs(phase - lag);
            r.maxError = std::max(r.maxError, err);
            if (k > cycles / 10) {
                r.maxErrorAfterSettling = std::max(r.maxErrorAfterSettling, err);
            }
        }
        targetSample += buffer;
    }
    r.finalCorrectionPPM = servo.CorrectionPPM();
    return r;
}

- (void)testServoTracksDriftWithoutFeedForward
{
    for (double drift : {-300.0, -50.0, 50.0, 300.0}) {
        auto r = Simulate(drift, false, 3600);
        XCTAssertLessThan(r.maxError, 1024.0, @"drift %f", drift); // never empties the ring
        XCTAssertLessThan(r.maxErrorAfterSettling, 2.0, @"drift %f", drift);
        // A target that runs fast (+drift) needs a shorter proxy frame period.
        XCTAssertEqualWithAccuracy(r.finalCorrectionPPM, -drift, 1.0);
    }
}

- (void)testServoWithFeedForwardBarelyMoves
{
    for (double drift : {-300.0, 300.0}) {
        auto r = Simulate(drift, true, 600);
        XCTAssertLessThan(r.maxError, 16.0, @"drift %f", drift);
    }
}

- (void)testServoRecoversAfterTimelineJump
{
    auto r = Simulate(120, false, 1200, 400);
    XCTAssertLessThan(r.maxError, 1024.0);
    XCTAssertLessThan(r.maxErrorAfterSettling, 400.0);
}

- (void)testZeroTimeStampsAreMonotonic
{
    ClockServo servo;
    servo.Start(0, 500.0, 16384);
    double lastSample = -1;
    uint64_t lastHost = 0;
    for (uint64_t h = 0; h < 24000000ull * 10; h += 240000) {
        double s;
        uint64_t ht;
        servo.ZeroTimeStamp(h, s, ht);
        XCTAssertGreaterThanOrEqual(s, lastSample);
        XCTAssertGreaterThanOrEqual(ht, lastHost);
        XCTAssertLessThanOrEqual(ht, h);
        lastSample = s;
        lastHost = ht;
    }
    XCTAssertGreaterThan(lastSample, 0);
}

@end
