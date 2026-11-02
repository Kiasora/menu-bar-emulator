#include "VulkanBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include "libretro.h"
#include "libretro_vulkan.h"

static PFN_vkGetInstanceProcAddr get_instance_proc;

// What the core asked for while loading its game.
static bool requested;
static struct retro_hw_render_callback hw;
static const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation;

static struct {
    PFN_vkCreateInstance CreateInstance;
    PFN_vkEnumerateInstanceExtensionProperties EnumerateInstanceExtensionProperties;
    PFN_vkDestroyInstance DestroyInstance;
    PFN_vkEnumeratePhysicalDevices EnumeratePhysicalDevices;
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
    PFN_vkGetDeviceProcAddr GetDeviceProcAddr;
    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkDeviceWaitIdle DeviceWaitIdle;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkResetCommandBuffer ResetCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkCreateFence CreateFence;
    PFN_vkDestroyFence DestroyFence;
    PFN_vkWaitForFences WaitForFences;
    PFN_vkResetFences ResetFences;
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkInvalidateMappedMemoryRanges InvalidateMappedMemoryRanges;
} vk;

static VkInstance instance;
static VkPhysicalDevice gpu;
static VkDevice device;
static VkQueue queue;
static uint32_t queue_family;
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static struct retro_hw_render_interface_vulkan interface;

// The frame the core handed over last, and what it asked to wait for, run or signal along with it.
static struct retro_vulkan_image image;
static bool has_image;
static VkSemaphore waits[8];
static uint32_t wait_count;
static VkCommandBuffer core_commands[8];
static uint32_t core_command_count;
static VkSemaphore signal_semaphore;

// The copy of each frame back to memory.
static VkCommandPool pool;
static VkCommandBuffer commands;
static VkFence fence;
static VkBuffer buffer;
static VkDeviceMemory memory;
static VkDeviceSize buffer_size;
static void *mapped;
static bool coherent;

static void set_image(void *handle, const struct retro_vulkan_image *new_image, uint32_t num_semaphores,
                      const VkSemaphore *semaphores, uint32_t src_queue_family) {
    image = *new_image;
    has_image = true;
    wait_count = num_semaphores < 8 ? num_semaphores : 8;
    if (wait_count) memcpy(waits, semaphores, wait_count * sizeof *waits);
}

// Each frame is copied back, and waited for, before the core starts the next one, so one sync slot is enough.
static uint32_t get_sync_index(void *handle) { return 0; }
static uint32_t get_sync_index_mask(void *handle) { return 1; }
static void wait_sync_index(void *handle) {}

static void set_command_buffers(void *handle, uint32_t count, const VkCommandBuffer *buffers) {
    core_command_count = count < 8 ? count : 8;
    if (core_command_count) memcpy(core_commands, buffers, core_command_count * sizeof *buffers);
}

static void lock_queue(void *handle) { pthread_mutex_lock(&queue_lock); }
static void unlock_queue(void *handle) { pthread_mutex_unlock(&queue_lock); }
static void set_signal_semaphore(void *handle, VkSemaphore semaphore) { signal_semaphore = semaphore; }

bool vkbridge_load(const char *path) {
    if (get_instance_proc) return true;
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "MoltenVK: %s\n", dlerror());
        return false;
    }
    get_instance_proc = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
    return get_instance_proc != NULL;
}

bool vkbridge_environment(unsigned cmd, void *data, bool *answer) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        *answer = get_instance_proc != NULL;
        if (*answer) *(enum retro_hw_context_type *)data = RETRO_HW_CONTEXT_VULKAN;
        return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        const struct retro_hw_render_callback *callback = data;
        *answer = get_instance_proc && callback->context_type == RETRO_HW_CONTEXT_VULKAN;
        if (*answer) {
            hw = *callback;
            requested = true;
        }
        return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        const struct retro_hw_render_context_negotiation_interface *offered = data;
        *answer = offered->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
        if (*answer) negotiation = data;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        *answer = device != VK_NULL_HANDLE;
        if (*answer) *(const struct retro_hw_render_interface **)data = (const struct retro_hw_render_interface *)&interface;
        return true;
    default:
        return false;
    }
}

bool vkbridge_requested(void) { return requested; }

static bool fail(const char *what) {
    fprintf(stderr, "Vulkan: %s failed\n", what);
    vkbridge_close();
    return false;
}

static bool has_instance_extension(const char *name) {
    uint32_t count = 0;
    vk.EnumerateInstanceExtensionProperties(NULL, &count, NULL);
    VkExtensionProperties found[count ? count : 1];
    vk.EnumerateInstanceExtensionProperties(NULL, &count, found);
    for (uint32_t i = 0; i < count; i++) {
        if (!strcmp(found[i].extensionName, name)) return true;
    }
    return false;
}

#define INSTANCE_FN(name) vk.name = (PFN_vk##name)get_instance_proc(instance, "vk" #name)
#define DEVICE_FN(name) vk.name = (PFN_vk##name)vk.GetDeviceProcAddr(device, "vk" #name)

bool vkbridge_start(void) {
    if (!requested || !get_instance_proc || device) return false;
    vk.CreateInstance = (PFN_vkCreateInstance)get_instance_proc(NULL, "vkCreateInstance");
    vk.EnumerateInstanceExtensionProperties =
        (PFN_vkEnumerateInstanceExtensionProperties)get_instance_proc(NULL, "vkEnumerateInstanceExtensionProperties");
    if (!vk.CreateInstance || !vk.EnumerateInstanceExtensionProperties) return fail("loading Vulkan");

    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Menu Bar Emulator"};
    const VkApplicationInfo *core_app = negotiation && negotiation->get_application_info ? negotiation->get_application_info() : NULL;
    if (core_app) app = *core_app;
    if (app.apiVersion < VK_API_VERSION_1_1) app.apiVersion = VK_API_VERSION_1_1;
    // MoltenVK only implements part of Vulkan, so it's listed as a "portability" driver that has to be asked for.
    const char *extensions[2];
    uint32_t extension_count = 0;
    VkInstanceCreateFlags flags = 0;
    if (has_instance_extension(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        extensions[extension_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    if (has_instance_extension(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)) {
        extensions[extension_count++] = VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME;
    }
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .flags = flags, .pApplicationInfo = &app,
        .enabledExtensionCount = extension_count, .ppEnabledExtensionNames = extensions,
    };
    if (vk.CreateInstance(&instance_info, NULL, &instance) != VK_SUCCESS) return fail("vkCreateInstance");
    INSTANCE_FN(DestroyInstance);
    INSTANCE_FN(EnumeratePhysicalDevices);
    INSTANCE_FN(GetPhysicalDeviceMemoryProperties);
    INSTANCE_FN(GetDeviceProcAddr);
    uint32_t gpu_count = 1;
    VkResult listed = vk.EnumeratePhysicalDevices(instance, &gpu_count, &gpu);
    if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || gpu_count == 0) return fail("finding the GPU");

    // shortcut: only cores that make their own device through negotiation (Azahar does); give the bridge a default
    // device if another GPU core ever needs one.
    struct retro_vulkan_context context = {0};
    VkPhysicalDeviceFeatures no_features = {0};
    if (!negotiation || !negotiation->create_device ||
        !negotiation->create_device(&context, instance, gpu, VK_NULL_HANDLE, get_instance_proc, NULL, 0, NULL, 0, &no_features))
        return fail("creating the device");
    gpu = context.gpu;
    device = context.device;
    queue = context.queue;
    queue_family = context.queue_family_index;
    DEVICE_FN(DestroyDevice);
    DEVICE_FN(DeviceWaitIdle);
    DEVICE_FN(CreateCommandPool);
    DEVICE_FN(DestroyCommandPool);
    DEVICE_FN(AllocateCommandBuffers);
    DEVICE_FN(BeginCommandBuffer);
    DEVICE_FN(EndCommandBuffer);
    DEVICE_FN(ResetCommandBuffer);
    DEVICE_FN(CmdPipelineBarrier);
    DEVICE_FN(CmdCopyImageToBuffer);
    DEVICE_FN(QueueSubmit);
    DEVICE_FN(CreateFence);
    DEVICE_FN(DestroyFence);
    DEVICE_FN(WaitForFences);
    DEVICE_FN(ResetFences);
    DEVICE_FN(CreateBuffer);
    DEVICE_FN(DestroyBuffer);
    DEVICE_FN(GetBufferMemoryRequirements);
    DEVICE_FN(AllocateMemory);
    DEVICE_FN(FreeMemory);
    DEVICE_FN(BindBufferMemory);
    DEVICE_FN(MapMemory);
    DEVICE_FN(InvalidateMappedMemoryRanges);

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = queue_family,
    };
    if (vk.CreateCommandPool(device, &pool_info, NULL, &pool) != VK_SUCCESS) return fail("vkCreateCommandPool");
    VkCommandBufferAllocateInfo command_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
    };
    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (vk.AllocateCommandBuffers(device, &command_info, &commands) != VK_SUCCESS ||
        vk.CreateFence(device, &fence_info, NULL, &fence) != VK_SUCCESS)
        return fail("setting up the frame copy");

    interface = (struct retro_hw_render_interface_vulkan){
        .interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN,
        .interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION,
        .handle = &interface,
        .instance = instance,
        .gpu = gpu,
        .device = device,
        .get_device_proc_addr = vk.GetDeviceProcAddr,
        .get_instance_proc_addr = get_instance_proc,
        .queue = queue,
        .queue_index = queue_family,
        .set_image = set_image,
        .get_sync_index = get_sync_index,
        .get_sync_index_mask = get_sync_index_mask,
        .set_command_buffers = set_command_buffers,
        .wait_sync_index = wait_sync_index,
        .lock_queue = lock_queue,
        .unlock_queue = unlock_queue,
        .set_signal_semaphore = set_signal_semaphore,
    };
    if (hw.context_reset) hw.context_reset();
    return true;
}

static void free_buffer(void) {
    if (buffer) vk.DestroyBuffer(device, buffer, NULL);
    if (memory) vk.FreeMemory(device, memory, NULL); // unmaps it too
    buffer = VK_NULL_HANDLE;
    memory = VK_NULL_HANDLE;
    mapped = NULL;
    buffer_size = 0;
}

static bool make_buffer(VkDeviceSize size) {
    free_buffer();
    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vk.CreateBuffer(device, &info, NULL, &buffer) != VK_SUCCESS) return false;
    VkMemoryRequirements needs;
    vk.GetBufferMemoryRequirements(device, buffer, &needs);
    VkPhysicalDeviceMemoryProperties properties;
    vk.GetPhysicalDeviceMemoryProperties(gpu, &properties);
    // Memory the CPU can read, cached if there is any (much faster to read back).
    uint32_t type = UINT32_MAX;
    for (int cached = 1; cached >= 0 && type == UINT32_MAX; cached--) {
        VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | (cached ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0);
        for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
            if ((needs.memoryTypeBits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) {
                type = i;
                break;
            }
        }
    }
    if (type == UINT32_MAX) return false;
    coherent = properties.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    VkMemoryAllocateInfo allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = needs.size, .memoryTypeIndex = type,
    };
    if (vk.AllocateMemory(device, &allocation, NULL, &memory) != VK_SUCCESS ||
        vk.BindBufferMemory(device, buffer, memory, 0) != VK_SUCCESS ||
        vk.MapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) {
        free_buffer();
        return false;
    }
    buffer_size = size;
    return true;
}

bool vkbridge_read_frame(void *out, unsigned width, unsigned height) {
    if (!device || !has_image || !width || !height) return false;
    VkDeviceSize size = (VkDeviceSize)width * height * 4;
    if (size > buffer_size && !make_buffer(size)) return false;

    VkImageSubresourceRange range = image.create_info.subresourceRange;
    range.levelCount = 1;
    range.layerCount = 1;
    VkImageMemoryBarrier to_copy = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = image.image_layout, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image.create_info.image, .subresourceRange = range,
    };
    VkImageMemoryBarrier back = to_copy;
    back.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    back.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    back.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    back.newLayout = image.image_layout;
    VkBufferMemoryBarrier to_host = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer, .size = VK_WHOLE_SIZE,
    };
    VkBufferImageCopy region = {
        .imageSubresource = {range.aspectMask, range.baseMipLevel, range.baseArrayLayer, 1},
        .imageExtent = {width, height, 1},
    };
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vk.ResetCommandBuffer(commands, 0);
    vk.BeginCommandBuffer(commands, &begin);
    // The core already submitted its drawing to this queue; the barrier waits for all of it.
    vk.CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                          0, 0, NULL, 0, NULL, 1, &to_copy);
    vk.CmdCopyImageToBuffer(commands, image.create_info.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    vk.CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT,
                          VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
                          0, 0, NULL, 1, &to_host, 1, &back);
    vk.EndCommandBuffer(commands);

    VkCommandBuffer list[9];
    uint32_t list_count = 0;
    for (uint32_t i = 0; i < core_command_count; i++) list[list_count++] = core_commands[i];
    list[list_count++] = commands;
    VkPipelineStageFlags stages[8];
    for (uint32_t i = 0; i < wait_count; i++) stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = wait_count, .pWaitSemaphores = waits, .pWaitDstStageMask = stages,
        .commandBufferCount = list_count, .pCommandBuffers = list,
        .signalSemaphoreCount = signal_semaphore ? 1 : 0, .pSignalSemaphores = &signal_semaphore,
    };
    pthread_mutex_lock(&queue_lock);
    VkResult submitted = vk.QueueSubmit(queue, 1, &submit, fence);
    pthread_mutex_unlock(&queue_lock);
    wait_count = 0;
    core_command_count = 0;
    signal_semaphore = VK_NULL_HANDLE;
    if (submitted != VK_SUCCESS) return false;
    vk.WaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
    vk.ResetFences(device, 1, &fence);
    if (!coherent) {
        VkMappedMemoryRange whole = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = memory, .size = VK_WHOLE_SIZE};
        vk.InvalidateMappedMemoryRanges(device, 1, &whole);
    }

    // XRGB8888 sits in memory as B, G, R, X; RGBA images need red and blue swapped.
    VkFormat format = image.create_info.format;
    if (format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB) {
        const uint32_t *from = mapped;
        uint32_t *to = out;
        for (size_t i = 0, count = (size_t)width * height; i < count; i++) {
            uint32_t p = from[i];
            to[i] = (p & 0xFF00FF00) | ((p & 0xFF) << 16) | ((p >> 16) & 0xFF);
        }
    } else {
        memcpy(out, mapped, size);
    }
    return true;
}

void vkbridge_end_drawing(void) {
    if (!device) return;
    pthread_mutex_lock(&queue_lock);
    vk.DeviceWaitIdle(device);
    pthread_mutex_unlock(&queue_lock);
    if (hw.context_destroy) hw.context_destroy();
}

void vkbridge_close(void) {
    if (device) {
        pthread_mutex_lock(&queue_lock);
        vk.DeviceWaitIdle(device);
        pthread_mutex_unlock(&queue_lock);
        free_buffer();
        if (fence) vk.DestroyFence(device, fence, NULL);
        if (pool) vk.DestroyCommandPool(device, pool, NULL);
        vk.DestroyDevice(device, NULL); // Azahar leaves its device to the frontend
    }
    if (instance) vk.DestroyInstance(instance, NULL);
    instance = VK_NULL_HANDLE;
    gpu = VK_NULL_HANDLE;
    device = VK_NULL_HANDLE;
    queue = VK_NULL_HANDLE;
    pool = VK_NULL_HANDLE;
    commands = VK_NULL_HANDLE;
    fence = VK_NULL_HANDLE;
    has_image = false;
    wait_count = 0;
    core_command_count = 0;
    signal_semaphore = VK_NULL_HANDLE;
    requested = false;
    negotiation = NULL;
    memset(&hw, 0, sizeof hw);
}
