#include "ProxyManager.hpp"

#include "Log.hpp"
#include "SAMDriverAPI.h"

#include <Block.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>

namespace sam {

namespace {

constexpr UInt32 kMaxChannels = 8;
constexpr double kIdleStopSeconds = 10.0;
constexpr const char* kConfigKey = "config";
constexpr const char* kAppBundleID = "dev.codejo.SimpleAudioManager";

void Post(dispatch_queue_t queue, std::function<void()> fn)
{
    auto* heap = new std::function<void()>(std::move(fn));
    dispatch_async_f(queue, heap, [](void* ctx) {
        auto* f = static_cast<std::function<void()>*>(ctx);
        (*f)();
        delete f;
    });
}

void PostAfter(dispatch_queue_t queue, double seconds, std::function<void()> fn)
{
    auto* heap = new std::function<void()>(std::move(fn));
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, int64_t(seconds * NSEC_PER_SEC)), queue, heap, [](void* ctx) {
        auto* f = static_cast<std::function<void()>*>(ctx);
        (*f)();
        delete f;
    });
}

bool StartsWith(const std::string& s, const std::string& prefix)
{
    return s.compare(0, prefix.size(), prefix) == 0;
}

} // namespace

ProxyManager::ProxyManager(std::shared_ptr<const aspl::Context> context, std::shared_ptr<aspl::Plugin> plugin)
    : context_(std::move(context))
    , plugin_(std::move(plugin))
    , queue_(dispatch_queue_create("dev.codejo.sam.driver.control", DISPATCH_QUEUE_SERIAL))
{
}

ProxyManager::~ProxyManager()
{
    if (status_) {
        CFRelease(status_);
    }
}

void ProxyManager::RegisterProperties()
{
    std::weak_ptr<ProxyManager> weak = weak_from_this();
    plugin_->RegisterCustomProperty(
        SAM_PROPERTY_CONFIG,
        [weak]() -> CFPropertyListRef {
            auto self = weak.lock();
            return self ? self->CopyConfig() : CreateConfig({});
        },
        [weak](CFPropertyListRef value) {
            if (auto self = weak.lock()) {
                self->SetConfig(value);
            }
        });
    plugin_->RegisterCustomProperty(
        SAM_PROPERTY_STATUS,
        [weak]() -> CFPropertyListRef {
            auto self = weak.lock();
            if (!self) {
                return CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0, nullptr, nullptr);
            }
            return self->CopyStatus();
        },
        std::function<void(CFPropertyListRef)>{});
}

void ProxyManager::Start(std::shared_ptr<aspl::Storage> storage)
{
    storage_ = std::move(storage);
    auto [stored, ok] = storage_->ReadCustom(kConfigKey);
    if (ok && stored) {
        auto specs = ParseConfig(stored);
        CFRelease(stored);
        std::lock_guard lock(snapshotMutex_);
        specs_ = std::move(specs);
    }
    SAM_LOG_INFO("driver started with %zu proxies", specs_.size());

    std::weak_ptr<ProxyManager> weak = weak_from_this();
    Post(queue_, [weak] {
        if (auto self = weak.lock()) {
            self->InstallSystemListener();
        }
    });
    // The HAL client API may not be ready while coreaudiod is still loading
    // plug-ins, so reconcile a few times; the device-list listener covers the rest.
    ScheduleReconcile(0.5);
    ScheduleReconcile(2.0);
    ScheduleReconcile(6.0);

    // Refresh the status snapshot periodically (counters change continuously).
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{
        if (auto self = weak.lock()) {
            self->UpdateStatusSnapshot();
        }
    });
    dispatch_resume(timer);
}

CFPropertyListRef ProxyManager::CopyConfig() const
{
    std::lock_guard lock(snapshotMutex_);
    return CreateConfig(specs_);
}

void ProxyManager::SetConfig(CFPropertyListRef config)
{
    auto specs = ParseConfig(config);
    {
        std::lock_guard lock(snapshotMutex_);
        specs_ = specs;
    }
    SAM_LOG_INFO("config updated: %zu proxies", specs.size());
    std::weak_ptr<ProxyManager> weak = weak_from_this();
    Post(queue_, [weak] {
        if (auto self = weak.lock()) {
            self->PersistConfig();
            self->Reconcile();
        }
    });
}

CFPropertyListRef ProxyManager::CopyStatus() const
{
    std::lock_guard lock(snapshotMutex_);
    if (!status_) {
        return CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0, nullptr, nullptr);
    }
    CFRetain(status_);
    return status_;
}

void ProxyManager::PersistConfig()
{
    if (!storage_) {
        return;
    }
    CFPropertyListRef config = CopyConfig();
    if (config) {
        storage_->WriteCustom(kConfigKey, config);
        CFRelease(config);
    }
}

void ProxyManager::ScheduleReconcile(double delaySeconds)
{
    std::weak_ptr<ProxyManager> weak = weak_from_this();
    PostAfter(queue_, delaySeconds, [weak] {
        if (auto self = weak.lock()) {
            self->Reconcile();
        }
    });
}

void ProxyManager::InstallSystemListener()
{
    if (devicesListener_) {
        return;
    }
    std::weak_ptr<ProxyManager> weak = weak_from_this();
    AudioObjectPropertyListenerBlock block = ^(UInt32, const AudioObjectPropertyAddress*) {
        if (auto self = weak.lock()) {
            self->Reconcile();
        }
    };
    devicesListener_ = Block_copy(block);
    const AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    const OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, queue_, devicesListener_);
    if (status != noErr) {
        SAM_LOG_ERROR("could not listen for device changes: %d", int(status));
        Block_release(devicesListener_);
        devicesListener_ = nullptr;
        PostAfter(queue_, 2.0, [weak] {
            if (auto self = weak.lock()) {
                self->InstallSystemListener();
            }
        });
    }
}

ProxyManager::Entry* ProxyManager::Find(const std::string& uid)
{
    auto it = entries_.find(uid);
    return it == entries_.end() ? nullptr : &it->second;
}

void ProxyManager::Reconcile()
{
    std::vector<ProxySpec> specs;
    {
        std::lock_guard lock(snapshotMutex_);
        specs = specs_;
    }

    // Drop entries that are no longer configured.
    for (auto it = entries_.begin(); it != entries_.end();) {
        const bool keep = std::any_of(specs.begin(), specs.end(), [&](const auto& s) { return s.uid == it->first; });
        if (!keep) {
            Unpublish(it->second);
            it = entries_.erase(it);
        } else {
            ++it;
        }
    }

    const auto devices = ListHALDevices();
    for (const auto& spec : specs) {
        Entry& entry = entries_[spec.uid];
        const bool specChanged = !(entry.spec == spec);
        entry.spec = spec;

        // Find the target: by UID, else by name (UIDs of some devices change).
        const HALDevice* target = nullptr;
        for (const auto& d : devices) {
            if (d.uid == spec.targetUID) {
                target = &d;
            }
        }
        if (!target && !spec.targetName.empty()) {
            for (const auto& d : devices) {
                if (d.name == spec.targetName && d.outputChannels > 0 && !StartsWith(d.uid, SAM_PROXY_UID_PREFIX)) {
                    target = &d;
                }
            }
        }

        if (!target || target->outputChannels == 0) {
            if (entry.device) {
                SAM_LOG_INFO("target of %{public}s disappeared", spec.uid.c_str());
                Unpublish(entry);
            }
            entry.error = "Target device is not connected";
            continue;
        }

        const UInt32 channels = std::min(target->outputChannels, kMaxChannels);
        const bool upToDate = entry.device && entry.target && entry.target->DeviceID() == target->id &&
                              entry.engine->channels == channels;
        if (upToDate) {
            if (specChanged) {
                ApplyAttributes(entry);
            }
            continue;
        }
        Unpublish(entry);
        Publish(entry, target->id);
    }
    UpdateStatusSnapshot();
}

void ProxyManager::Publish(Entry& entry, AudioObjectID targetID)
{
    const ProxySpec& spec = entry.spec;
    const TargetInfo info = QueryTargetInfo(targetID);
    if (!info.alive || info.channels == 0 || info.sampleRate <= 0) {
        entry.error = "Target device is not ready";
        return;
    }
    const UInt32 channels = std::min(info.channels, kMaxChannels);

    auto engine = std::make_shared<ProxyEngine>(channels);
    engine->softwareVolume.store(spec.volumeMode == VolumeMode::Software);
    auto target = std::make_shared<TargetOutput>(engine, queue_);
    if (!target->Attach(targetID)) {
        entry.error = "Could not open the target device";
        return;
    }

    aspl::DeviceParameters params;
    params.Name = spec.name.empty() ? info.name : spec.name;
    params.Manufacturer = SAM_MANUFACTURER;
    params.DeviceUID = spec.uid;
    params.ModelUID = SAM_MODEL_UID;
    params.IconURL = spec.iconURL;
    params.ConfigurationApplicationBundleID = kAppBundleID;
    params.SampleRate = UInt32(info.sampleRate);
    params.ChannelCount = channels;
    params.Latency = target->ForwardingLatency();
    params.SafetyOffset = 0;
    params.ZeroTimeStampPeriod = ProxyEngine::kPeriodFrames;
    params.CanBeDefault = true;
    params.CanBeDefaultForSystemSounds = true;

    auto device = std::make_shared<ProxyDevice>(context_, params, engine, spec.transport);
    device->Setup(info.sampleRates);

    // Restore volume and mute before callbacks are attached.
    Float32 volume = 0.5f;
    if (spec.volumeMode == VolumeMode::Hardware && info.hasVolume) {
        volume = target->HardwareVolume();
    } else if (storage_) {
        if (auto [stored, ok] = storage_->ReadFloat("volume." + spec.uid); ok) {
            volume = Float32(stored);
        }
    }
    device->Volume()->SetScalarValue(volume);
    if (storage_) {
        if (auto [stored, ok] = storage_->ReadBoolean("mute." + spec.uid); ok) {
            device->Mute()->SetIsMuted(stored);
        }
    }
    if (spec.hidden) {
        device->SetIsHidden(true);
    }

    std::weak_ptr<ProxyManager> weak = weak_from_this();
    const std::string uid = spec.uid;
    dispatch_queue_t queue = queue_;
    device->OnStartIO = [weak, uid, queue] {
        Post(queue, [weak, uid] {
            if (auto self = weak.lock()) {
                self->HandleStartIO(uid);
            }
        });
    };
    device->OnStopIO = [weak, uid, queue] {
        Post(queue, [weak, uid] {
            if (auto self = weak.lock()) {
                self->HandleStopIO(uid);
            }
        });
    };
    device->OnSampleRateChanged = [weak, uid, queue](Float64 rate) {
        Post(queue, [weak, uid, rate] {
            if (auto self = weak.lock()) {
                self->HandleProxyRate(uid, rate);
            }
        });
    };
    device->Volume()->OnChanged = [weak, uid, queue](Float32 scalar) {
        Post(queue, [weak, uid, scalar] {
            if (auto self = weak.lock()) {
                self->HandleProxyVolume(uid, scalar);
            }
        });
    };
    device->Mute()->OnChanged = [weak, uid, queue](bool muted) {
        Post(queue, [weak, uid, muted] {
            if (auto self = weak.lock()) {
                self->HandleProxyMute(uid, muted);
            }
        });
    };
    target->OnChanged = [weak, uid] {
        if (auto self = weak.lock()) {
            self->HandleTargetChanged(uid);
        }
    };
    target->OnVolumeChanged = [weak, uid](Float32 scalar) {
        if (auto self = weak.lock()) {
            self->HandleTargetVolume(uid, scalar);
        }
    };

    entry.engine = engine;
    entry.target = target;
    entry.device = device;
    entry.proxyIOActive = false;
    entry.error.clear();
    plugin_->AddDevice(device);
    SAM_LOG_INFO("published %{public}s -> %{public}s (%u ch, %.0f Hz)",
        spec.uid.c_str(),
        info.uid.c_str(),
        channels,
        info.sampleRate);
}

void ProxyManager::Unpublish(Entry& entry)
{
    if (entry.device) {
        plugin_->RemoveDevice(entry.device);
        SAM_LOG_INFO("removed %{public}s", entry.spec.uid.c_str());
    }
    if (entry.target) {
        entry.target->Detach();
    }
    entry.device.reset();
    entry.target.reset();
    entry.engine.reset();
    entry.proxyIOActive = false;
    entry.stopToken++;
}

void ProxyManager::ApplyAttributes(Entry& entry)
{
    const ProxySpec& spec = entry.spec;
    entry.device->UpdateName(spec.name.empty() ? entry.target->Info().name : spec.name);
    entry.device->UpdateIconURL(spec.iconURL);
    entry.device->UpdateTransportType(spec.transport);
    if (entry.device->GetIsHidden() != spec.hidden) {
        entry.device->SetIsHidden(spec.hidden);
    }
    const bool software = spec.volumeMode == VolumeMode::Software;
    entry.engine->softwareVolume.store(software);
    if (!software && entry.target->Info().hasVolume) {
        entry.device->Volume()->SetScalarValue(entry.target->HardwareVolume());
    }
}

void ProxyManager::HandleStartIO(const std::string& uid)
{
    Entry* entry = Find(uid);
    if (!entry || !entry->target) {
        return;
    }
    entry->proxyIOActive = true;
    entry->stopToken++;
    entry->target->Start();
}

void ProxyManager::HandleStopIO(const std::string& uid)
{
    Entry* entry = Find(uid);
    if (!entry || !entry->target) {
        return;
    }
    entry->proxyIOActive = false;
    const uint64_t token = ++entry->stopToken;
    std::weak_ptr<ProxyManager> weak = weak_from_this();
    // Keep the target running a little longer so short, repeated sounds are not
    // clipped by the target's start-up time.
    PostAfter(queue_, kIdleStopSeconds, [weak, uid, token] {
        auto self = weak.lock();
        if (!self) {
            return;
        }
        Entry* e = self->Find(uid);
        if (e && e->target && e->stopToken == token && !e->proxyIOActive) {
            e->target->Stop();
        }
    });
}

void ProxyManager::HandleProxyRate(const std::string& uid, Float64 rate)
{
    Entry* entry = Find(uid);
    if (!entry || !entry->target) {
        return;
    }
    if (entry->target->Info().sampleRate == rate) {
        return;
    }
    const OSStatus status = entry->target->SetSampleRate(rate);
    if (status != noErr) {
        SAM_LOG_ERROR("target refused %.0f Hz (%d); reverting proxy", rate, int(status));
        entry->device->SetNominalSampleRateAsync(entry->target->Info().sampleRate);
    }
}

void ProxyManager::HandleTargetChanged(const std::string& uid)
{
    Entry* entry = Find(uid);
    if (!entry || !entry->target || !entry->device) {
        return;
    }
    const TargetInfo& info = entry->target->Info();
    if (!info.alive || std::min(info.channels, kMaxChannels) != entry->engine->channels) {
        Reconcile();
        return;
    }
    if (info.sampleRate > 0 && info.sampleRate != entry->device->GetNominalSampleRate()) {
        const auto& rates = info.sampleRates;
        const auto available = entry->device->GetAvailableSampleRates();
        const bool supported = std::any_of(available.begin(), available.end(), [&](const auto& r) {
            return info.sampleRate >= r.mMinimum && info.sampleRate <= r.mMaximum;
        });
        if (!supported || rates.size() != available.size()) {
            // The target's rate list changed: rebuild the proxy.
            Unpublish(*entry);
            Reconcile();
            return;
        }
        entry->device->SetNominalSampleRateAsync(info.sampleRate);
    }
    const UInt32 latency = entry->target->ForwardingLatency();
    if (latency != entry->device->GetLatency()) {
        entry->device->SetLatencyAsync(latency);
    }
    UpdateStatusSnapshot();
}

void ProxyManager::HandleProxyVolume(const std::string& uid, Float32 scalar)
{
    Entry* entry = Find(uid);
    if (!entry) {
        return;
    }
    if (storage_) {
        storage_->WriteFloat("volume." + uid, scalar);
    }
    if (entry->spec.volumeMode == VolumeMode::Hardware && entry->target && entry->target->Info().hasVolume &&
        std::fabs(entry->target->HardwareVolume() - scalar) > 0.001f) {
        entry->target->SetHardwareVolume(scalar);
    }
}

void ProxyManager::HandleProxyMute(const std::string& uid, bool muted)
{
    Entry* entry = Find(uid);
    if (!entry) {
        return;
    }
    if (storage_) {
        storage_->WriteBoolean("mute." + uid, muted);
    }
    if (entry->spec.volumeMode == VolumeMode::Hardware && entry->target && entry->target->Info().hasMute) {
        entry->target->SetHardwareMute(muted);
    }
}

void ProxyManager::HandleTargetVolume(const std::string& uid, Float32 scalar)
{
    Entry* entry = Find(uid);
    if (!entry || !entry->device || entry->spec.volumeMode != VolumeMode::Hardware) {
        return;
    }
    if (std::fabs(entry->device->Volume()->GetScalarValue() - scalar) > 0.001f) {
        entry->device->Volume()->SetScalarValue(scalar);
    }
}

void ProxyManager::UpdateStatusSnapshot()
{
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (auto& [uid, entry] : entries_) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SetString(d, SAM_KEY_UID, uid);
        SetBool(d, SAM_KEY_PUBLISHED, entry.device != nullptr);
        SetBool(d, SAM_KEY_TARGET_PRESENT, entry.target != nullptr);
        SetBool(d, SAM_KEY_TARGET_RUNNING, entry.target && entry.target->IsRunning());
        if (entry.device && entry.engine && entry.target) {
            SetNumber(d, SAM_KEY_SAMPLE_RATE, entry.device->GetNominalSampleRate());
            SetInt(d, SAM_KEY_CHANNELS, entry.engine->channels);
            SetInt(d, SAM_KEY_LATENCY, entry.device->GetLatency());
            SetInt(d, SAM_KEY_UNDERRUNS, int64_t(entry.engine->underruns.load()));
            SetInt(d, SAM_KEY_OVERRUNS, int64_t(entry.engine->overruns.load()));
            SetInt(d, SAM_KEY_RESYNCS, int64_t(entry.engine->resyncs.load()));
            SetNumber(d, SAM_KEY_CLOCK_PPM, entry.engine->correctionPPM.load());
            const pid_t hog = entry.target->Info().hogPID;
            SetInt(d, SAM_KEY_HOG_PID, hog);
            if (hog != -1 && hog != getpid()) {
                entry.error = "Target is in exclusive use by another app";
            } else if (entry.error == "Target is in exclusive use by another app") {
                entry.error.clear();
            }
        }
        if (!entry.error.empty()) {
            SetString(d, SAM_KEY_ERROR, entry.error);
        }
        CFArrayAppendValue(array, d);
        CFRelease(d);
    }
    CFMutableDictionaryRef root = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef key = CreateCFString(SAM_KEY_PROXIES);
    CFDictionarySetValue(root, key, array);
    CFRelease(key);
    CFRelease(array);

    std::lock_guard lock(snapshotMutex_);
    if (status_) {
        CFRelease(status_);
    }
    status_ = root;
}

} // namespace sam
