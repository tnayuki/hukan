// What the macOS agent asks of the system and cannot say in Zig: CoreFoundation values unwrapped
// into C ones, and the corners of AppKit and Carbon it needs. Zig declares these itself rather
// than reading this header, since its clang cannot read the SDK's frameworks. The decisions are
// all in screen.zig; these only read and post.

#include <ApplicationServices/ApplicationServices.h>

// A CFString as a C string the caller frees, or NULL when the value is not a string.
char *hk_string(CFTypeRef value);
// A CFNumber or CFBoolean as a double; 0 when the value is neither.
int hk_number(CFTypeRef value, double *out);
// An AXValue holding a point or a size.
int hk_point(CFTypeRef value, double *x, double *y);
int hk_size(CFTypeRef value, double *width, double *height);
int hk_is_element(CFTypeRef value);

// An attribute of an element, which the caller releases, or NULL.
CFTypeRef hk_attribute(AXUIElementRef element, const char *name);
// The element at a point of the screen, or NULL; its pid in *pid.
AXUIElementRef hk_element_at(double x, double y, pid_t *pid);
int hk_perform(AXUIElementRef element, const char *action);
int hk_set_value(AXUIElementRef element, const char *value);

typedef struct {
  long id;
  long layer;
  int pid;
  double x, y, width, height;
  char *owner;
  char *name;
} hk_window;
// The window server's account of one window, or of every window on screen with the desktop's
// left out. The caller frees with hk_free_windows.
int hk_windows(long id, hk_window **out);
void hk_free_windows(hk_window *windows, int count);

// Running applications, from AppKit.
pid_t hk_frontmost(void);
pid_t hk_application(const char *name);
char *hk_application_name(pid_t pid);

typedef struct {
  CGDisplayModeRef mode;
  size_t width, height, pixelWidth, pixelHeight;
  uint32_t flags;
} hk_mode;
// Every mode of the main display, low-resolution duplicates included. hk_free_modes releases.
int hk_modes(hk_mode **out);
void hk_free_modes(hk_mode *modes, int count);
int hk_set_mode(CGDisplayModeRef mode);
double hk_scale(void);

void hk_post_mouse(CGEventType type, double x, double y, CGMouseButton button, int64_t clicks,
                   int flags);
void hk_post_unicode(const UniChar *units, int count, int down);
void hk_post_key(CGKeyCode code, CGEventFlags flags, int down);
void hk_post_released(void);

// Select an input source, or with enable only turn it on: an OSStatus, or 1 when there is none.
int hk_input_source(const char *id, int enable);

// Where the character that starts at `index` ends, in UTF-16 units: what a person would call one
// character, an accent or a flag's two halves or a family joined by ZWJ included.
int hk_cluster_end(const UniChar *units, int count, int index);
