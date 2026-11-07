// ProxySpec.hpp
// One configured proxy device, and conversion to/from the CFPropertyList that
// travels through the 'Scfg' custom property and the driver's storage.

#pragma once

#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CoreFoundation.h>

#include <string>
#include <vector>

namespace sam {

enum class VolumeMode
{
    Software, // DSP gain inside the driver (targets without hardware volume)
    Hardware, // forward to the target's own volume control
};

struct ProxySpec
{
    std::string uid;
    std::string name;
    std::string targetUID;
    std::string targetName;
    std::string iconURL;
    UInt32 transport = kAudioDeviceTransportTypeVirtual;
    VolumeMode volumeMode = VolumeMode::Software;
    bool hidden = false;

    bool operator==(const ProxySpec&) const = default;
};

// Parses { version, proxies: [...] }. Invalid entries are skipped.
std::vector<ProxySpec> ParseConfig(CFPropertyListRef plist);

// Returns a +1 CFDictionary.
CFDictionaryRef CreateConfig(const std::vector<ProxySpec>& specs);

// CF helpers shared by the driver.
std::string ToStdString(CFStringRef string);
CFStringRef CreateCFString(const std::string& string);
void SetString(CFMutableDictionaryRef dict, const char* key, const std::string& value);
void SetNumber(CFMutableDictionaryRef dict, const char* key, double value);
void SetInt(CFMutableDictionaryRef dict, const char* key, int64_t value);
void SetBool(CFMutableDictionaryRef dict, const char* key, bool value);

} // namespace sam
