// The C half of screen.zig; see screen.h.

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <stdlib.h>
#include <string.h>

#include "screen.h"

char *hk_string(CFTypeRef value) {
  if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) return NULL;
  CFStringRef string = (CFStringRef)value;
  CFIndex size =
      CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
  char *buffer = malloc(size);
  if (!CFStringGetCString(string, buffer, size, kCFStringEncodingUTF8)) {
    free(buffer);
    return NULL;
  }
  return buffer;
}

int hk_number(CFTypeRef value, double *out) {
  if (value == NULL) return 0;
  if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    *out = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    return 1;
  }
  if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    return CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, out);
  }
  return 0;
}

int hk_point(CFTypeRef value, double *x, double *y) {
  if (value == NULL || CFGetTypeID(value) != AXValueGetTypeID()) return 0;
  CGPoint point;
  if (!AXValueGetValue((AXValueRef)value, kAXValueTypeCGPoint, &point)) return 0;
  *x = point.x;
  *y = point.y;
  return 1;
}

int hk_size(CFTypeRef value, double *width, double *height) {
  if (value == NULL || CFGetTypeID(value) != AXValueGetTypeID()) return 0;
  CGSize size;
  if (!AXValueGetValue((AXValueRef)value, kAXValueTypeCGSize, &size)) return 0;
  *width = size.width;
  *height = size.height;
  return 1;
}

int hk_is_element(CFTypeRef value) {
  return value != NULL && CFGetTypeID(value) == AXUIElementGetTypeID();
}

static CFStringRef hk_cf(const char *text) {
  return CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
}

CFTypeRef hk_attribute(AXUIElementRef element, const char *name) {
  CFStringRef key = hk_cf(name);
  CFTypeRef value = NULL;
  AXError error = AXUIElementCopyAttributeValue(element, key, &value);
  CFRelease(key);
  return error == kAXErrorSuccess ? value : NULL;
}

AXUIElementRef hk_element_at(double x, double y, pid_t *pid) {
  AXUIElementRef system = AXUIElementCreateSystemWide();
  AXUIElementRef hit = NULL;
  AXError error = AXUIElementCopyElementAtPosition(system, x, y, &hit);
  CFRelease(system);
  if (error != kAXErrorSuccess || hit == NULL) return NULL;
  *pid = 0;
  AXUIElementGetPid(hit, pid);
  return hit;
}

int hk_perform(AXUIElementRef element, const char *action) {
  CFStringRef name = hk_cf(action);
  AXError error = AXUIElementPerformAction(element, name);
  CFRelease(name);
  return error;
}

int hk_set_value(AXUIElementRef element, const char *value) {
  CFStringRef text = hk_cf(value);
  AXError error = AXUIElementSetAttributeValue(element, kAXValueAttribute, text);
  CFRelease(text);
  return error;
}

int hk_windows(long id, hk_window **out) {
  CFArrayRef list =
      id >= 0 ? CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)id)
              : CGWindowListCopyWindowInfo(
                    kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                    kCGNullWindowID);
  *out = NULL;
  if (list == NULL) return 0;
  CFIndex count = CFArrayGetCount(list);
  hk_window *windows = calloc(count > 0 ? count : 1, sizeof(hk_window));
  int filled = 0;
  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
    hk_window *window = &windows[filled];
    double number;
    window->id = hk_number(CFDictionaryGetValue(info, kCGWindowNumber), &number) ? number : -1;
    window->layer = hk_number(CFDictionaryGetValue(info, kCGWindowLayer), &number) ? number : -1;
    window->pid = hk_number(CFDictionaryGetValue(info, kCGWindowOwnerPID), &number) ? number : -1;
    CFDictionaryRef bounds = CFDictionaryGetValue(info, kCGWindowBounds);
    CGRect rect;
    // A window with no bounds is one nothing here can place, so it is not listed.
    if (bounds == NULL || !CGRectMakeWithDictionaryRepresentation(bounds, &rect)) continue;
    window->x = rect.origin.x;
    window->y = rect.origin.y;
    window->width = rect.size.width;
    window->height = rect.size.height;
    window->owner = hk_string(CFDictionaryGetValue(info, kCGWindowOwnerName));
    window->name = hk_string(CFDictionaryGetValue(info, kCGWindowName));
    filled++;
  }
  CFRelease(list);
  *out = windows;
  return filled;
}

void hk_free_windows(hk_window *windows, int count) {
  for (int i = 0; i < count; i++) {
    free(windows[i].owner);
    free(windows[i].name);
  }
  free(windows);
}

pid_t hk_frontmost(void) {
  @autoreleasepool {
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    return app ? app.processIdentifier : -1;
  }
}

pid_t hk_application(const char *name) {
  @autoreleasepool {
    NSString *wanted = [NSString stringWithUTF8String:name];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
      if ([app.localizedName isEqualToString:wanted] ||
          [app.bundleIdentifier isEqualToString:wanted]) {
        return app.processIdentifier;
      }
    }
    return -1;
  }
}

char *hk_application_name(pid_t pid) {
  @autoreleasepool {
    NSString *name = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName;
    return name ? strdup(name.UTF8String) : NULL;
  }
}

int hk_modes(hk_mode **out) {
  const void *keys[] = {kCGDisplayShowDuplicateLowResolutionModes};
  const void *values[] = {kCFBooleanTrue};
  CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
  CFArrayRef list = CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options);
  CFRelease(options);
  *out = NULL;
  if (list == NULL) return 0;
  CFIndex count = CFArrayGetCount(list);
  hk_mode *modes = calloc(count > 0 ? count : 1, sizeof(hk_mode));
  for (CFIndex i = 0; i < count; i++) {
    CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(list, i);
    modes[i].mode = CGDisplayModeRetain(mode);
    modes[i].width = CGDisplayModeGetWidth(mode);
    modes[i].height = CGDisplayModeGetHeight(mode);
    modes[i].pixelWidth = CGDisplayModeGetPixelWidth(mode);
    modes[i].pixelHeight = CGDisplayModeGetPixelHeight(mode);
    modes[i].flags = CGDisplayModeGetIOFlags(mode);
  }
  CFRelease(list);
  *out = modes;
  return (int)count;
}

void hk_free_modes(hk_mode *modes, int count) {
  for (int i = 0; i < count; i++) CGDisplayModeRelease(modes[i].mode);
  free(modes);
}

int hk_set_mode(CGDisplayModeRef mode) {
  CGDisplayConfigRef config;
  CGError error = CGBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess) return -1;
  CGConfigureDisplayWithDisplayMode(config, CGMainDisplayID(), mode, NULL);
  return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}

double hk_scale(void) {
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
  if (mode == NULL) return 1;
  double scale = CGDisplayModeGetWidth(mode) > 0 ? (double)CGDisplayModeGetPixelWidth(mode) /
                                                       (double)CGDisplayModeGetWidth(mode)
                                                 : 1;
  CGDisplayModeRelease(mode);
  return scale;
}

void hk_post_mouse(CGEventType type, double x, double y, CGMouseButton button, int64_t clicks,
                   int flags) {
  CGEventRef event = CGEventCreateMouseEvent(NULL, type, CGPointMake(x, y), button);
  if (event == NULL) return;
  if (clicks > 0) CGEventSetIntegerValueField(event, kCGMouseEventClickState, clicks);
  if (flags) CGEventSetFlags(event, 0);
  CGEventPost(kCGHIDEventTap, event);
  CFRelease(event);
}

void hk_post_unicode(const UniChar *units, int count, int down) {
  CGEventRef event = CGEventCreateKeyboardEvent(NULL, 0, down);
  if (event == NULL) return;
  CGEventKeyboardSetUnicodeString(event, count, units);
  CGEventSetFlags(event, 0);
  CGEventPost(kCGHIDEventTap, event);
  CFRelease(event);
}

void hk_post_key(CGKeyCode code, CGEventFlags flags, int down) {
  CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, down);
  if (event == NULL) return;
  CGEventSetFlags(event, flags);
  CGEventPost(kCGHIDEventTap, event);
  CFRelease(event);
}

void hk_post_released(void) {
  CGEventRef event = CGEventCreate(NULL);
  if (event == NULL) return;
  CGEventSetType(event, kCGEventFlagsChanged);
  CGEventSetFlags(event, 0);
  CGEventPost(kCGHIDEventTap, event);
  CFRelease(event);
}

int hk_input_source(const char *id, int enable) {
  CFStringRef wanted = hk_cf(id);
  const void *keys[] = {kTISPropertyInputSourceID};
  const void *values[] = {wanted};
  CFDictionaryRef filter = CFDictionaryCreate(NULL, keys, values, 1,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
  CFRelease(wanted);
  CFArrayRef sources = TISCreateInputSourceList(filter, true);
  CFRelease(filter);
  if (sources == NULL) return 1;
  if (CFArrayGetCount(sources) == 0) {
    CFRelease(sources);
    return 1;
  }
  TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, 0);
  OSStatus status = enable ? TISEnableInputSource(source) : TISSelectInputSource(source);
  CFRelease(sources);
  return status;
}

int hk_cluster_end(const UniChar *units, int count, int index) {
  CFStringRef string = CFStringCreateWithCharactersNoCopy(NULL, units, count, kCFAllocatorNull);
  if (string == NULL) return index + 1;
  CFRange range = CFStringGetRangeOfComposedCharactersAtIndex(string, index);
  CFRelease(string);
  return (int)(range.location + range.length);
}
