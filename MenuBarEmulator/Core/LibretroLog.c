#include <stdarg.h>
#include <stdio.h>
#include "libretro.h"

static void host_log(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

retro_log_printf_t host_log_callback(void) { return host_log; }
