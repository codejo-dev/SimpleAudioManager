// SAMDriverAPI.h
// Contract between the SimpleAudioManager HAL driver (C++) and the app (Swift).
// The driver is the source of truth for proxy devices. The app talks to it only
// through Core Audio custom properties on the driver's plug-in object.

#ifndef SAMDriverAPI_h
#define SAMDriverAPI_h

#define SAM_DRIVER_BUNDLE_ID "dev.codejo.SimpleAudioManager.Driver"
#define SAM_PROXY_UID_PREFIX "dev.codejo.sam.proxy."
#define SAM_MANUFACTURER "SimpleAudioManager"
#define SAM_MODEL_UID "dev.codejo.sam.proxy"

// Custom properties on the plug-in object (global scope, main element).
// Both carry a CFPropertyList (a CFDictionary).
#define SAM_PROPERTY_CONFIG 0x53636667u // 'Scfg' read/write: { version, proxies: [ProxySpec] }
#define SAM_PROPERTY_STATUS 0x53737461u // 'Ssta' read-only:  { proxies: [ProxyStatus] }

#define SAM_CONFIG_VERSION 1

// Config dictionary keys
#define SAM_KEY_VERSION "version"
#define SAM_KEY_PROXIES "proxies"

// ProxySpec keys
#define SAM_KEY_UID "uid"               // CFString, must start with SAM_PROXY_UID_PREFIX
#define SAM_KEY_NAME "name"             // CFString, shown in macOS device lists
#define SAM_KEY_TARGET_UID "targetUID"  // CFString, UID of the physical output device
#define SAM_KEY_TARGET_NAME "targetName"// CFString, fallback match if the UID changed
#define SAM_KEY_ICON_URL "iconURL"      // CFString, file:// URL of a PNG/ICNS (optional)
#define SAM_KEY_TRANSPORT "transport"   // CFNumber, transport type fourcc (optional, default 'virt')
#define SAM_KEY_VOLUME_MODE "volumeMode"// CFString, "software" | "hardware"
#define SAM_KEY_HIDDEN "hidden"         // CFBoolean (optional)

#define SAM_VOLUME_MODE_SOFTWARE "software"
#define SAM_VOLUME_MODE_HARDWARE "hardware"

// ProxyStatus keys (plus SAM_KEY_UID)
#define SAM_KEY_PUBLISHED "published"         // CFBoolean, proxy device currently exists
#define SAM_KEY_TARGET_PRESENT "targetPresent"// CFBoolean
#define SAM_KEY_TARGET_RUNNING "targetRunning"// CFBoolean, forwarding IOProc is running
#define SAM_KEY_SAMPLE_RATE "sampleRate"      // CFNumber (double)
#define SAM_KEY_CHANNELS "channels"           // CFNumber
#define SAM_KEY_LATENCY "latencyFrames"       // CFNumber, reported proxy latency
#define SAM_KEY_UNDERRUNS "underruns"         // CFNumber, read cycles that hit missing data
#define SAM_KEY_OVERRUNS "overruns"           // CFNumber, read cycles that hit overwritten data
#define SAM_KEY_RESYNCS "resyncs"             // CFNumber, re-anchors after timeline jumps
#define SAM_KEY_CLOCK_PPM "clockCorrectionPPM"// CFNumber (double)
#define SAM_KEY_HOG_PID "hogPID"              // CFNumber, -1 when the target is not hogged
#define SAM_KEY_ERROR "error"                 // CFString (optional)

#endif /* SAMDriverAPI_h */
