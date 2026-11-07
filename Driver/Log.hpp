// Log.hpp
// Driver logging. View with:
//   log stream --predicate 'subsystem == "dev.codejo.SimpleAudioManager.Driver"'

#pragma once

#include <os/log.h>

namespace sam {

inline os_log_t Log()
{
    static os_log_t log = os_log_create("dev.codejo.SimpleAudioManager.Driver", "driver");
    return log;
}

} // namespace sam

#define SAM_LOG_INFO(fmt, ...) os_log(sam::Log(), fmt, ##__VA_ARGS__)
#define SAM_LOG_ERROR(fmt, ...) os_log_error(sam::Log(), fmt, ##__VA_ARGS__)
