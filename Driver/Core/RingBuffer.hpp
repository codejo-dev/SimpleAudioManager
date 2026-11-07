// RingBuffer.hpp
// Single-producer / single-consumer ring of interleaved Float32 frames that is
// addressed by absolute sample time. The proxy device's IO thread writes the
// mixed output at its sample time; the target device's IOProc reads any span by
// sample time. Lock-free and allocation-free after construction.

#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace sam {

class RingBuffer
{
public:
    struct ReadResult
    {
        uint32_t validFrames = 0;   // frames copied from the ring
        uint32_t missingFrames = 0; // frames not written yet (underrun), zero-filled
        uint32_t lostFrames = 0;    // frames already overwritten (overrun), zero-filled
    };

    // capacityFrames is rounded up to a power of two.
    RingBuffer(uint32_t capacityFrames, uint32_t channels)
        : capacity_(RoundUpPow2(capacityFrames))
        , mask_(capacity_ - 1)
        , channels_(channels)
        , data_(size_t(capacity_) * channels, 0.0f)
    {
    }

    uint32_t Capacity() const { return capacity_; }
    uint32_t Channels() const { return channels_; }

    // Newest written frame + 1, or -1 if nothing was written since the last reset.
    int64_t EndFrame() const { return end_.load(std::memory_order_acquire); }

    // Increments whenever the writer's time line restarts (reset or backwards jump).
    uint32_t Generation() const { return generation_.load(std::memory_order_acquire); }

    // Producer side. Writes frameCount interleaved frames at startFrame.
    // forceRestart starts a new time line (the writer's clock was re-anchored).
    void Write(int64_t startFrame, const float* frames, uint32_t frameCount, bool forceRestart = false)
    {
        if (frameCount == 0) {
            return;
        }
        int64_t end = end_.load(std::memory_order_relaxed);
        int64_t begin = begin_.load(std::memory_order_relaxed);

        // The HAL's output sample times only move forward. A write that lies
        // entirely in the past means the device's time line restarted.
        const bool restart = forceRestart || end < 0 || startFrame + int64_t(frameCount) <= end ||
                             startFrame < end - int64_t(capacity_);
        if (restart) {
            // New time line. Invalidate everything first so a concurrent reader
            // never pairs old data with new positions.
            end_.store(-1, std::memory_order_release);
            begin = startFrame;
            begin_.store(begin, std::memory_order_release);
            generation_.fetch_add(1, std::memory_order_acq_rel);
            end = startFrame;
        } else if (startFrame > end) {
            // Gap (the writer skipped cycles): fill with silence so stale
            // samples from a previous lap are never played.
            const int64_t gap = std::min<int64_t>(startFrame - end, capacity_);
            ZeroSpan(startFrame - gap, uint32_t(gap));
        }

        CopyIn(startFrame, frames, frameCount);

        const int64_t newEnd = std::max(end, startFrame + int64_t(frameCount));
        const int64_t newBegin = std::max(begin, newEnd - int64_t(capacity_));
        begin_.store(newBegin, std::memory_order_release);
        end_.store(newEnd, std::memory_order_release);
    }

    // Consumer side. Copies frameCount frames starting at startFrame into out.
    // Frames that are not available are zero-filled and reported.
    ReadResult Read(int64_t startFrame, float* out, uint32_t frameCount) const
    {
        ReadResult result;
        const uint32_t gen = generation_.load(std::memory_order_acquire);
        const int64_t end = end_.load(std::memory_order_acquire);
        const int64_t begin = begin_.load(std::memory_order_acquire);
        const int64_t stop = startFrame + int64_t(frameCount);

        std::memset(out, 0, size_t(frameCount) * channels_ * sizeof(float));
        if (end < 0) {
            result.missingFrames = frameCount;
            return result;
        }

        const int64_t validStart = std::max(startFrame, begin);
        const int64_t validStop = std::min(stop, end);
        if (validStop > validStart) {
            CopyOut(validStart,
                out + size_t(validStart - startFrame) * channels_,
                uint32_t(validStop - validStart));
        }

        // Re-check after copying: anything the writer lapped meanwhile is garbage.
        const int64_t endAfter = end_.load(std::memory_order_acquire);
        const uint32_t genAfter = generation_.load(std::memory_order_acquire);
        int64_t safeStart = validStart;
        if (genAfter != gen || endAfter < 0) {
            safeStart = validStop; // everything copied is suspect
        } else if (endAfter - int64_t(capacity_) > validStart) {
            safeStart = std::min(validStop, endAfter - int64_t(capacity_));
        }
        if (safeStart > validStart) {
            std::memset(out + size_t(validStart - startFrame) * channels_,
                0,
                size_t(safeStart - validStart) * channels_ * sizeof(float));
        }

        const int64_t good = std::max<int64_t>(0, validStop - safeStart);
        result.validFrames = uint32_t(good);
        result.missingFrames = uint32_t(std::max<int64_t>(0, stop - std::max(startFrame, end)));
        result.lostFrames = frameCount - result.validFrames - result.missingFrames;
        return result;
    }

    // Only call while neither side is running.
    void Reset()
    {
        end_.store(-1, std::memory_order_release);
        begin_.store(0, std::memory_order_release);
        generation_.fetch_add(1, std::memory_order_acq_rel);
        std::fill(data_.begin(), data_.end(), 0.0f);
    }

private:
    static uint32_t RoundUpPow2(uint32_t v)
    {
        uint32_t p = 1;
        while (p < v) {
            p <<= 1;
        }
        return p;
    }

    uint32_t Index(int64_t frame) const { return uint32_t(uint64_t(frame) & mask_); }

    void CopyIn(int64_t frame, const float* src, uint32_t count)
    {
        while (count > 0) {
            const uint32_t idx = Index(frame);
            const uint32_t chunk = std::min(count, capacity_ - idx);
            std::memcpy(&data_[size_t(idx) * channels_], src, size_t(chunk) * channels_ * sizeof(float));
            src += size_t(chunk) * channels_;
            frame += chunk;
            count -= chunk;
        }
    }

    void ZeroSpan(int64_t frame, uint32_t count)
    {
        while (count > 0) {
            const uint32_t idx = Index(frame);
            const uint32_t chunk = std::min(count, capacity_ - idx);
            std::memset(&data_[size_t(idx) * channels_], 0, size_t(chunk) * channels_ * sizeof(float));
            frame += chunk;
            count -= chunk;
        }
    }

    void CopyOut(int64_t frame, float* dst, uint32_t count) const
    {
        while (count > 0) {
            const uint32_t idx = Index(frame);
            const uint32_t chunk = std::min(count, capacity_ - idx);
            std::memcpy(dst, &data_[size_t(idx) * channels_], size_t(chunk) * channels_ * sizeof(float));
            dst += size_t(chunk) * channels_;
            frame += chunk;
            count -= chunk;
        }
    }

    const uint32_t capacity_;
    const uint32_t mask_;
    const uint32_t channels_;
    std::vector<float> data_;
    std::atomic<int64_t> end_{-1};
    std::atomic<int64_t> begin_{0};
    std::atomic<uint32_t> generation_{0};
};

} // namespace sam
