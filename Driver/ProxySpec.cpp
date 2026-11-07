#include "ProxySpec.hpp"

#include "SAMDriverAPI.h"

#include <cstring>

namespace sam {

namespace {

CFTypeRef Lookup(CFDictionaryRef dict, const char* key)
{
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef value = CFDictionaryGetValue(dict, cfKey);
    CFRelease(cfKey);
    return value;
}

std::string GetString(CFDictionaryRef dict, const char* key)
{
    CFTypeRef value = Lookup(dict, key);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        return ToStdString(static_cast<CFStringRef>(value));
    }
    return {};
}

bool GetBool(CFDictionaryRef dict, const char* key, bool fallback)
{
    CFTypeRef value = Lookup(dict, key);
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    }
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        int v = 0;
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &v);
        return v != 0;
    }
    return fallback;
}

bool GetUInt32(CFDictionaryRef dict, const char* key, UInt32& out)
{
    CFTypeRef value = Lookup(dict, key);
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        SInt64 v = 0;
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &v);
        out = UInt32(v);
        return true;
    }
    return false;
}

} // namespace

std::string ToStdString(CFStringRef string)
{
    if (!string) {
        return {};
    }
    if (const char* fast = CFStringGetCStringPtr(string, kCFStringEncodingUTF8)) {
        return fast;
    }
    const CFIndex length = CFStringGetLength(string);
    const CFIndex max = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string result(size_t(max), '\0');
    if (!CFStringGetCString(string, result.data(), max, kCFStringEncodingUTF8)) {
        return {};
    }
    result.resize(std::strlen(result.c_str()));
    return result;
}

CFStringRef CreateCFString(const std::string& string)
{
    return CFStringCreateWithCString(kCFAllocatorDefault, string.c_str(), kCFStringEncodingUTF8);
}

void SetString(CFMutableDictionaryRef dict, const char* key, const std::string& value)
{
    CFStringRef k = CreateCFString(key);
    CFStringRef v = CreateCFString(value);
    CFDictionarySetValue(dict, k, v);
    CFRelease(v);
    CFRelease(k);
}

void SetNumber(CFMutableDictionaryRef dict, const char* key, double value)
{
    CFStringRef k = CreateCFString(key);
    CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    CFDictionarySetValue(dict, k, v);
    CFRelease(v);
    CFRelease(k);
}

void SetInt(CFMutableDictionaryRef dict, const char* key, int64_t value)
{
    CFStringRef k = CreateCFString(key);
    CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(dict, k, v);
    CFRelease(v);
    CFRelease(k);
}

void SetBool(CFMutableDictionaryRef dict, const char* key, bool value)
{
    CFStringRef k = CreateCFString(key);
    CFDictionarySetValue(dict, k, value ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(k);
}

std::vector<ProxySpec> ParseConfig(CFPropertyListRef plist)
{
    std::vector<ProxySpec> specs;
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        return specs;
    }
    auto root = static_cast<CFDictionaryRef>(plist);
    CFTypeRef proxies = Lookup(root, SAM_KEY_PROXIES);
    if (!proxies || CFGetTypeID(proxies) != CFArrayGetTypeID()) {
        return specs;
    }
    auto array = static_cast<CFArrayRef>(proxies);
    const std::string prefix = SAM_PROXY_UID_PREFIX;
    for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
        CFTypeRef item = CFArrayGetValueAtIndex(array, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) {
            continue;
        }
        auto dict = static_cast<CFDictionaryRef>(item);
        ProxySpec spec;
        spec.uid = GetString(dict, SAM_KEY_UID);
        spec.name = GetString(dict, SAM_KEY_NAME);
        spec.targetUID = GetString(dict, SAM_KEY_TARGET_UID);
        spec.targetName = GetString(dict, SAM_KEY_TARGET_NAME);
        spec.iconURL = GetString(dict, SAM_KEY_ICON_URL);
        GetUInt32(dict, SAM_KEY_TRANSPORT, spec.transport);
        spec.volumeMode = GetString(dict, SAM_KEY_VOLUME_MODE) == SAM_VOLUME_MODE_HARDWARE
                              ? VolumeMode::Hardware
                              : VolumeMode::Software;
        spec.hidden = GetBool(dict, SAM_KEY_HIDDEN, false);

        const bool validUID = spec.uid.size() > prefix.size() &&
                              spec.uid.compare(0, prefix.size(), prefix) == 0;
        const bool targetsProxy = spec.targetUID.compare(0, prefix.size(), prefix) == 0;
        if (!validUID || spec.targetUID.empty() || targetsProxy) {
            continue;
        }
        bool duplicate = false;
        for (const auto& existing : specs) {
            duplicate = duplicate || existing.uid == spec.uid;
        }
        if (!duplicate) {
            specs.push_back(std::move(spec));
        }
    }
    return specs;
}

CFDictionaryRef CreateConfig(const std::vector<ProxySpec>& specs)
{
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (const auto& spec : specs) {
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SetString(dict, SAM_KEY_UID, spec.uid);
        SetString(dict, SAM_KEY_NAME, spec.name);
        SetString(dict, SAM_KEY_TARGET_UID, spec.targetUID);
        SetString(dict, SAM_KEY_TARGET_NAME, spec.targetName);
        SetString(dict, SAM_KEY_ICON_URL, spec.iconURL);
        SetInt(dict, SAM_KEY_TRANSPORT, spec.transport);
        SetString(dict,
            SAM_KEY_VOLUME_MODE,
            spec.volumeMode == VolumeMode::Hardware ? SAM_VOLUME_MODE_HARDWARE : SAM_VOLUME_MODE_SOFTWARE);
        SetBool(dict, SAM_KEY_HIDDEN, spec.hidden);
        CFArrayAppendValue(array, dict);
        CFRelease(dict);
    }
    CFMutableDictionaryRef root = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SetInt(root, SAM_KEY_VERSION, SAM_CONFIG_VERSION);
    CFStringRef key = CreateCFString(SAM_KEY_PROXIES);
    CFDictionarySetValue(root, key, array);
    CFRelease(key);
    CFRelease(array);
    return root;
}

} // namespace sam
