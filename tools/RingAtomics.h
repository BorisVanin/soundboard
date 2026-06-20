// Tiny C shim so Swift can do correct acquire/release atomics on the shared
// ring indices (Swift can't call __atomic builtins directly). Throwaway, paired
// with tap_feed.swift. Layout matches LoopbackDriver/src/SoundboardRing.h.
#pragma once
#include <stdint.h>
#include <sys/mman.h>
#include <sys/fcntl.h>

// shm_open is variadic (mode arg) and thus unreachable from Swift; wrap it.
static inline int ring_shm_open(const char *name, int oflag, mode_t mode) { return shm_open(name, oflag, mode); }

static inline uint64_t ring_load_acquire(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline uint64_t ring_load_relaxed(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
static inline void     ring_store_release(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
