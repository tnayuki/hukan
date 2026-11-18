/* libvulkan.1.dylib for Zink, built by Vendor/build-mesa.sh: Zink dlopens the Vulkan loader under
 * that name and asks it for the two proc-address entry points. There is no loader here — one
 * driver, KosmicKrisp, so a loader's search, layers and trampolines would buy nothing — and these
 * go straight to the driver's ICD entry point instead. */
#include <stddef.h>
#include <string.h>

typedef void (*PFN_vkVoidFunction)(void);
typedef void *VkInstance;
typedef void *VkDevice;

extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);

static VkInstance last_instance;

/* Layers are a loader's to enumerate, and Zink will not start without asking: there are none. */
static int enumerate_no_layers(unsigned *count, void *properties)
{
   (void)properties;
   *count = 0;
   return 0; /* VK_SUCCESS */
}

__attribute__((visibility("default"))) PFN_vkVoidFunction
vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
   if (instance)
      last_instance = instance;
   if (!instance && !strcmp(name, "vkEnumerateInstanceLayerProperties"))
      return (PFN_vkVoidFunction)enumerate_no_layers;
   return vk_icdGetInstanceProcAddr(instance, name);
}

/* The driver answers device functions through its instance entry point, as a loader would ask. */
typedef PFN_vkVoidFunction (*PFN_getDeviceProcAddr)(VkDevice, const char *);
static PFN_getDeviceProcAddr get_device_proc_addr;

__attribute__((visibility("default"))) PFN_vkVoidFunction
vkGetDeviceProcAddr(VkDevice device, const char *name)
{
   if (!get_device_proc_addr)
      get_device_proc_addr =
         (PFN_getDeviceProcAddr)vk_icdGetInstanceProcAddr(last_instance, "vkGetDeviceProcAddr");
   return get_device_proc_addr ? get_device_proc_addr(device, name) : NULL;
}
