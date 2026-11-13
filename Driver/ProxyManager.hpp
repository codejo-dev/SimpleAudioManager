// ProxyManager.hpp
// Owns the configured proxies. Publishes a proxy device while its target is
// present, wires it to a TargetOutput, keeps sample rates and (in hardware
// mode) volume in sync, persists config and volume, and exposes status.
//
// All work happens on one serial dispatch queue. HAL plug-in callbacks only
// enqueue work; they never wait for the queue. HAL client property listeners
// run on a separate listener queue and only hand off to the control queue:
// Core Audio calls them synchronously (while holding its own locks), so they
// must never wait for the control queue, which may itself be inside a HAL call
// such as AudioObjectRemovePropertyListenerBlock.

#pragma once

#include "ProxyDevice.hpp"
#include "ProxySpec.hpp"
#include "TargetOutput.hpp"

#include <aspl/Context.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Storage.hpp>

#include <dispatch/dispatch.h>

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace sam {

class ProxyManager : public std::enable_shared_from_this<ProxyManager>
{
public:
    ProxyManager(std::shared_ptr<const aspl::Context> context, std::shared_ptr<aspl::Plugin> plugin);
    ~ProxyManager();

    // Registers the custom properties. Call before the driver initializes.
    void RegisterProperties();

    // Called once the host is available (storage works from here on).
    void Start(std::shared_ptr<aspl::Storage> storage);

    // Custom property accessors (HAL threads). Return +1 objects.
    CFPropertyListRef CopyConfig() const;
    void SetConfig(CFPropertyListRef config);
    CFPropertyListRef CopyStatus() const;

private:
    struct Entry
    {
        ProxySpec spec;
        std::shared_ptr<ProxyEngine> engine;
        std::shared_ptr<ProxyDevice> device;
        std::shared_ptr<TargetOutput> target;
        bool proxyIOActive = false;
        uint64_t stopToken = 0;
        std::string error;
    };

    void Reconcile();
    void Publish(Entry& entry, AudioObjectID targetID);
    void Unpublish(Entry& entry);
    void ApplyAttributes(Entry& entry);
    void UpdateStatusSnapshot();
    void ScheduleReconcile(double delaySeconds);
    void InstallSystemListener();
    void PersistConfig();

    void HandleStartIO(const std::string& uid);
    void HandleStopIO(const std::string& uid);
    void HandleProxyRate(const std::string& uid, Float64 rate);
    void HandleProxyVolume(const std::string& uid, Float32 scalar);
    void HandleProxyMute(const std::string& uid, bool muted);
    void HandleTargetChanged(const std::string& uid);
    void HandleTargetVolume(const std::string& uid, Float32 scalar);

    Entry* Find(const std::string& uid);

    std::shared_ptr<const aspl::Context> context_;
    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<aspl::Storage> storage_;
    dispatch_queue_t queue_;
    dispatch_queue_t listenerQueue_;
    AudioObjectPropertyListenerBlock devicesListener_ = nullptr;

    // Queue-owned.
    std::map<std::string, Entry> entries_;

    // Snapshots readable from any thread.
    mutable std::mutex snapshotMutex_;
    std::vector<ProxySpec> specs_;
    CFDictionaryRef status_ = nullptr;
};

} // namespace sam
