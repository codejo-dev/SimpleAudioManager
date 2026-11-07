// Entry.cpp
// CFPlugIn factory for the SimpleAudioManager AudioServerPlugIn.

#include "Log.hpp"
#include "ProxyManager.hpp"
#include "SAMDriverAPI.h"

#include <aspl/Driver.hpp>
#include <aspl/DriverRequestHandler.hpp>
#include <aspl/Tracer.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <memory>

namespace {

class InitHandler : public aspl::DriverRequestHandler
{
public:
    InitHandler(std::shared_ptr<sam::ProxyManager> manager)
        : manager_(std::move(manager))
    {
    }

    void SetDriver(std::weak_ptr<aspl::Driver> driver) { driver_ = std::move(driver); }

    OSStatus OnInitialize() override
    {
        if (auto driver = driver_.lock()) {
            manager_->Start(driver->GetStorage());
        }
        return kAudioHardwareNoError;
    }

private:
    std::shared_ptr<sam::ProxyManager> manager_;
    std::weak_ptr<aspl::Driver> driver_;
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    // libASPL's own tracing is very chatty; we log through os_log instead.
    auto tracer = std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop);
    auto context = std::make_shared<aspl::Context>(tracer);

    aspl::PluginParameters pluginParams;
    pluginParams.Manufacturer = SAM_MANUFACTURER;
    auto plugin = std::make_shared<aspl::Plugin>(context, pluginParams);

    auto manager = std::make_shared<sam::ProxyManager>(context, plugin);
    manager->RegisterProperties();

    auto driver = std::make_shared<aspl::Driver>(context, plugin);
    auto handler = std::make_shared<InitHandler>(manager);
    handler->SetDriver(driver);
    driver->SetDriverHandler(handler);
    SAM_LOG_INFO("SimpleAudioManager driver loaded");
    return driver;
}

} // namespace

extern "C" __attribute__((visibility("default"))) void* SAMDriverEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
