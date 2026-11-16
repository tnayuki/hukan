// MAP_32BIT under Rosetta, for an x86_64 program in a Linux guest.
//
// x86_64 Linux puts a mapping asked for with MAP_32BIT below 2GB; Rosetta ignores the flag and
// hands back one anywhere, and a program that relies on it — Mono's JIT, and with it Unity's
// editor — then aborts on an address it cannot encode. Preloaded into every x86_64 process, this
// answers those requests the way the kernel would, by placing them below 2GB itself; every other
// mapping goes to the kernel untouched.
//
// Built by Vendor/build-rosetta-low32.sh. Calls the kernel directly rather than through libc's
// mmap, which is the very function this replaces.
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

static void *kernel_mmap(void *address, size_t length, int prot, int flags, int fd, off_t offset) {
  long result = syscall(SYS_mmap, address, length, prot, flags, fd, offset);
  return (void *)result;
}

// Where the next search starts, so a run of requests does not walk the same full pages again.
static uintptr_t hint = 0x10000000;

static void *below_2gb(size_t length, int prot, int flags, int fd, off_t offset) {
  const uintptr_t floor = 0x10000000, ceiling = 0x80000000, step = 0x10000;
  size_t size = (length + step - 1) & ~(step - 1);
  if (size == 0 || size > ceiling - floor) {
    errno = ENOMEM;
    return MAP_FAILED;
  }
  int fixed = (flags & ~MAP_32BIT) | MAP_FIXED_NOREPLACE;
  uintptr_t start = __atomic_load_n(&hint, __ATOMIC_RELAXED);
  if (start < floor || start + size > ceiling) start = floor;
  // Twice round at most: from the hint to the ceiling, then from the floor to the hint.
  for (int pass = 0; pass < 2; pass++) {
    uintptr_t from = pass == 0 ? start : floor, to = pass == 0 ? ceiling : start + size;
    for (uintptr_t at = from; at + size <= to && at + size <= ceiling; at += step) {
      void *mapped = kernel_mmap((void *)at, length, prot, fixed, fd, offset);
      if (mapped == (void *)at) {
        __atomic_store_n(&hint, at + size, __ATOMIC_RELAXED);
        return mapped;
      }
      if (mapped != MAP_FAILED) {
        // A kernel too old for NOREPLACE treats it as a hint and may place it elsewhere.
        syscall(SYS_munmap, mapped, length);
      } else if (errno != EEXIST) {
        return MAP_FAILED;
      }
    }
  }
  errno = ENOMEM;
  return MAP_FAILED;
}

void *mmap(void *address, size_t length, int prot, int flags, int fd, off_t offset) {
  if ((flags & MAP_32BIT) && !(flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) && address == NULL)
    return below_2gb(length, prot, flags, fd, offset);
  return kernel_mmap(address, length, prot, flags, fd, offset);
}

void *mmap64(void *address, size_t length, int prot, int flags, int fd, off_t offset)
    __attribute__((alias("mmap")));
