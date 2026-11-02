#include <stdbool.h>

// Lets a core that draws with Vulkan (the 3DS) run on MoltenVK. Every finished frame is copied back to memory, so it
// reaches the screen the same way a software core's frame does.

/// Loads MoltenVK from `path` (once). Returns whether Vulkan is ready.
bool vkbridge_load(const char *path);
/// Answers the environment calls that set up hardware rendering: returns true if `cmd` is one of them, with the
/// answer for the core in `*answer`.
bool vkbridge_environment(unsigned cmd, void *data, bool *answer);
/// Whether the core asked to draw with Vulkan while loading its game.
bool vkbridge_requested(void);
/// Makes the GPU device with the core and tells it to start drawing. Cores that draw with the GPU load their game here.
bool vkbridge_start(void);
/// Copies the core's latest frame into `out` as XRGB8888, `width` × `height` pixels.
bool vkbridge_read_frame(void *out, unsigned width, unsigned height);
/// Tells the core its GPU context is going away. Call before retro_unload_game.
void vkbridge_end_drawing(void);
/// Destroys the device once the game is unloaded, and forgets what the core asked for.
void vkbridge_close(void);
