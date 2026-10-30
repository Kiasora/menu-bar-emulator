#include "libretro.h"

// Swift can't define C variadic functions, so the core's log callback lives in LibretroLog.c.
retro_log_printf_t host_log_callback(void);
