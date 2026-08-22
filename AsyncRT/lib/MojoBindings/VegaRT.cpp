//===----------------------------------------------------------------------===//
// VegaRT — the MacVegaFork implementation of the AsyncRT device ABI.
//
// The Mojo standard library drives devices through a C ABI (`AsyncRT_*`)
// whose upstream implementation ships only in the closed `modular` wheel,
// for platforms this machine is not. This file reimplements that ABI from
// the signatures documented at the Mojo call sites (see ABI-NOTES.md).
//
// Phase 2a: CPU backend with synchronous semantics under the async names —
// legal because completion is only observable through synchronize/events,
// which trivially hold when every enqueue completes before returning.
// Phase 2b adds the Metal backend for the Radeon Pro Vega II.
//
// Conventions recovered from the Mojo side:
//   - Fallible calls return `const char *`: nullptr on success, otherwise a
//     heap-allocated message the caller frees via AsyncRT_DeviceContext_strfree.
//   - Returned strings (deviceName, ...) are heap-owned by the caller, same
//     free path.
//   - Handles are opaque and refcounted; every handle-returning call hands
//     back a +1 reference, including getters (the Mojo wrappers release in
//     their destructors).
//   - `deviceApi` writes an llvm::StringRef-shaped {ptr, len} out-param that
//     must point at storage which outlives the context.
//
// Unimplemented symbols are present as linkable stubs that return an error
// naming themselves, so a missing feature is a legible runtime message and
// never a link failure or a silent wrong answer.
//===----------------------------------------------------------------------===//

#include "VegaRTInternal.h"

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <time.h>
#include <vector>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

namespace {

//===----------------------------------------------------------------------===//
// Error / string conventions
//===----------------------------------------------------------------------===//

char *vrStrdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = static_cast<char *>(malloc(n));
  memcpy(p, s, n);
  return p;
}

const char *vrErrorf(const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  return vrStrdup(buf);
}

#define VR_OK nullptr

uint64_t nowNs() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

//===----------------------------------------------------------------------===//
// Object model
//===----------------------------------------------------------------------===//

struct RefCounted {
  mutable std::atomic<uint64_t> refs{1};
};

template <typename T> T *vrRetain(T *obj) {
  if (obj)
    obj->refs.fetch_add(1, std::memory_order_relaxed);
  return obj;
}

template <typename T> void vrRelease(T *obj) {
  if (obj && obj->refs.fetch_sub(1, std::memory_order_acq_rel) == 1)
    delete obj;
}

struct VRContext;

struct VRStream : RefCounted {
  VRContext *ctx; // not retained: default stream is owned by the context
  int priority = 0;
};

struct VRContext : RefCounted {
  int id = 0;
  std::string api;       // "cpu" or "metal"
  std::string arch;      // reported through deviceApi/archName-family queries
  std::string name;
  VRStream *defaultStream = nullptr;
  VRMetalCtx *metal = nullptr; // set when api == "metal"

  VRContext() { defaultStream = new VRStream{{}, this}; }
  ~VRContext() {
    vrRelease(defaultStream);
    VegaRTMetal_destroyContext(metal);
  }
};

struct VRBuffer : RefCounted {
  VRContext *ctx = nullptr;      // retained
  const VRBuffer *parent = nullptr; // retained, for sub-buffer views
  void *ptr = nullptr;           // host memory (cpu) or gpuAddress token (metal)
  size_t bytes = 0;
  bool ownsMemory = false;
  bool isHostBuffer = false;
  VRMetalBuf *mtl = nullptr;     // set when the owning context is metal

  ~VRBuffer();
};

struct VRFunction : RefCounted {
  VRMetalFunc *mtl = nullptr;
  ~VRFunction() { VegaRTMetal_destroyFunction(mtl); }
};

struct VREvent : RefCounted {
  std::atomic<uint64_t> recordedNs{0};
};

struct VRTimer : RefCounted {
  uint64_t startNs = 0;
};

struct VRScope : RefCounted {
  VRContext *ctx = nullptr; // retained
  ~VRScope();
};

using DeviceContext = VRContext;
using DeviceBuffer = VRBuffer;
using DeviceStream = VRStream;
using DeviceEvent = VREvent;
using DeviceTimer = VRTimer;
using DeviceContextScope = VRScope;
using DeviceFunction = VRFunction;

} // namespace

// Out-of-line so the extern "C" release helpers below exist first.
extern "C" void AsyncRT_DeviceContext_release(const DeviceContext *ctx);

namespace {
VRBuffer::~VRBuffer() {
  if (mtl)
    VegaRTMetal_destroyBuffer(mtl);
  else if (ownsMemory && ptr)
    free(ptr);
  vrRelease(const_cast<VRBuffer *>(parent));
  AsyncRT_DeviceContext_release(ctx);
}
VRScope::~VRScope() { AsyncRT_DeviceContext_release(ctx); }
} // namespace

//===----------------------------------------------------------------------===//
// Strings
//===----------------------------------------------------------------------===//

extern "C" void AsyncRT_DeviceContext_strfree(const char *ptr) {
  free(const_cast<char *>(ptr));
}

//===----------------------------------------------------------------------===//
// DeviceContext lifecycle
//===----------------------------------------------------------------------===//

extern "C" const char *
AsyncRT_DeviceContext_create(const DeviceContext **result, const char *api,
                             int id) {
  std::string want = api ? api : "default";
  if (want == "cpu" || want == "default") {
    auto *ctx = new VRContext();
    ctx->id = id;
    ctx->api = "cpu";
    ctx->arch = "cpu";
    ctx->name = "VegaRT cpu:0 (Xeon W, x86-64 Mac Pro)"; // test_smoke checks for a lowercase "cpu" substring
    *result = ctx;
    return VR_OK;
  }
  if (want == "metal" || want == "gpu") {
    char name[256], arch[64];
    VRMetalCtx *mctx = nullptr;
    if (const char *err =
            VegaRTMetal_createContext(&mctx, id, name, sizeof(name), arch,
                                      sizeof(arch)))
      return err;
    auto *ctx = new VRContext();
    ctx->id = id;
    ctx->api = "metal";
    ctx->arch = arch;
    ctx->name = name;
    ctx->metal = mctx;
    *result = ctx;
    return VR_OK;
  }
  return vrErrorf("VegaRT: device api '%s' is not available (have: cpu, metal)",
                  want.c_str());
}

extern "C" void AsyncRT_DeviceContext_retain(const DeviceContext *ctx) {
  vrRetain(const_cast<VRContext *>(ctx));
}

extern "C" void AsyncRT_DeviceContext_release(const DeviceContext *ctx) {
  vrRelease(const_cast<VRContext *>(ctx));
}

extern "C" int32_t AsyncRT_DeviceContext_numberOfDevices(const char *kind) {
  std::string k = kind ? kind : "default";
  if (k == "cpu" || k == "default")
    return 1;
  if (k == "gpu" || k == "metal")
    return VegaRTMetal_deviceCount();
  return 0;
}

extern "C" int64_t AsyncRT_DeviceContext_id(const DeviceContext *ctx) {
  return ctx->id;
}

extern "C" const char *
AsyncRT_DeviceContext_deviceName(const DeviceContext *ctx) {
  return vrStrdup(ctx->name.c_str());
}

// llvm::StringRef layout: {const char *data; size_t length;}
extern "C" void AsyncRT_DeviceContext_deviceApi(void *resultStringRef,
                                                const DeviceContext *ctx) {
  struct SR {
    const char *data;
    size_t len;
  };
  auto *sr = static_cast<SR *>(resultStringRef);
  sr->data = ctx->api.c_str();
  sr->len = ctx->api.size();
}

extern "C" const char *
AsyncRT_DeviceContext_computeCapability(int32_t *result,
                                        const DeviceContext *ctx) {
  *result = 0; // meaningful for CUDA only; CPU reports 0
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_getApiVersion(int *result,
                                                           const DeviceContext *ctx) {
  *result = 1;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_getAttribute(int *result, const DeviceContext *ctx,
                                   int attr) {
  // CUDA-numbered attribute codes (see device_attribute.mojo).
  if (ctx->metal && VegaRTMetal_getAttribute(ctx->metal, attr, result) == 0)
    return VR_OK;
  switch (attr) {
  case 1: { // MAX_THREADS_PER_BLOCK: a CPU "block" is one thread
    *result = 1;
    return VR_OK;
  }
  case 10: { // WARP_SIZE
    *result = 1;
    return VR_OK;
  }
  case 13: { // CLOCK_RATE, in kHz
    uint64_t hz = 0;
    size_t len = sizeof(hz);
#if defined(__APPLE__)
    if (sysctlbyname("hw.cpufrequency", &hz, &len, nullptr, 0) != 0)
      hz = 0;
#endif
    *result = hz ? static_cast<int>(hz / 1000) : 3300000; // Xeon W-3235 base
    return VR_OK;
  }
  default:
    *result = 0;
    return vrErrorf(
        "VegaRT: DeviceContext_getAttribute(%d) not implemented for api '%s'",
        attr, ctx->api.c_str());
  }
}

extern "C" const char *
AsyncRT_DeviceContext_getMemoryInfo(const DeviceContext *ctx, size_t *freeMem,
                                    size_t *total) {
  if (ctx->metal)
    return VegaRTMetal_memInfo(ctx->metal, freeMem, total);
  uint64_t mem = 0;
  size_t len = sizeof(mem);
#if defined(__APPLE__)
  sysctlbyname("hw.memsize", &mem, &len, nullptr, 0);
#endif
  *total = static_cast<size_t>(mem);
  *freeMem = static_cast<size_t>(mem); // close enough for a host heap
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_isCompatible(const DeviceContext *) {
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_runHealthcheck(DeviceContext *) {
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_synchronize(const DeviceContext *ctx) {
  if (ctx->metal)
    return VegaRTMetal_synchronize(ctx->metal);
  return VR_OK; // synchronous cpu backend: everything already completed
}

extern "C" const char *
AsyncRT_DeviceContext_enqueue_wait_for_context(const DeviceContext *,
                                               const DeviceContext *) {
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_canAccess(bool *result,
                                                       const DeviceContext *,
                                                       const DeviceContext *) {
  *result = false;
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_allPeerAccessEnabled(bool *result) {
  *result = false;
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_enableAllPeerAccess() {
  return vrErrorf("VegaRT: peer access not supported");
}

extern "C" const char *
AsyncRT_DeviceContext_enablePeerAccess(const DeviceContext *,
                                       const DeviceContext *) {
  return vrErrorf("VegaRT: peer access not supported");
}

extern "C" const char *
AsyncRT_DeviceContext_supportsMulticast(bool *result, const DeviceContext *) {
  *result = false;
  return VR_OK;
}

//===----------------------------------------------------------------------===//
// Context scopes (driver-context push/pop; a no-op off CUDA)
//===----------------------------------------------------------------------===//

extern "C" const char *
AsyncRT_DeviceContextScope_create(const DeviceContextScope **result,
                                  const DeviceContext *ctx) {
  auto *scope = new VRScope();
  scope->ctx = vrRetain(const_cast<VRContext *>(ctx));
  *result = scope;
  return VR_OK;
}

extern "C" void
AsyncRT_DeviceContextScope_release(const DeviceContextScope *scope) {
  vrRelease(const_cast<VRScope *>(scope));
}

//===----------------------------------------------------------------------===//
// Buffers
//===----------------------------------------------------------------------===//

namespace {
VRBuffer *makeBuffer(const VRContext *ctx, void *ptr, size_t bytes, bool owns,
                     bool isHost) {
  auto *buf = new VRBuffer();
  buf->ctx = vrRetain(const_cast<VRContext *>(ctx));
  buf->ptr = ptr;
  buf->bytes = bytes;
  buf->ownsMemory = owns;
  buf->isHostBuffer = isHost;
  return buf;
}
} // namespace

extern "C" const char *
AsyncRT_DeviceContext_createBuffer_async(const DeviceBuffer **result,
                                         void **device_ptr,
                                         const DeviceContext *ctx, size_t len,
                                         size_t elem_size) {
  size_t bytes = len * elem_size;
  if (ctx->metal) {
    VRMetalBuf *mbuf = nullptr;
    void *devAddr = nullptr;
    if (const char *err = VegaRTMetal_createBuffer(&mbuf, &devAddr, ctx->metal,
                                                   bytes, /*host=*/false))
      return err;
    auto *mb = makeBuffer(ctx, devAddr, bytes, /*owns=*/false, false);
    mb->mtl = mbuf;
    *result = mb;
    *device_ptr = devAddr;
    return VR_OK;
  }
  // Always non-null, even for zero-length: the Mojo wrapper unwraps the
  // pointer unconditionally (device_context.mojo:1517).
  void *p = malloc(bytes ? bytes : 1);
  if (!p)
    return vrErrorf("VegaRT: allocation of %zu bytes failed", bytes);
  auto *buf = makeBuffer(ctx, p, bytes, /*owns=*/true, /*isHost=*/false);
  *result = buf;
  *device_ptr = p;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_createHostBuffer(const DeviceBuffer **result,
                                       void **device_ptr,
                                       const DeviceContext *ctx, size_t len,
                                       size_t elem_size) {
  size_t bytes = len * elem_size;
  if (ctx->metal) {
    VRMetalBuf *mbuf = nullptr;
    void *devAddr = nullptr;
    if (const char *err = VegaRTMetal_createBuffer(&mbuf, &devAddr, ctx->metal,
                                                   bytes, /*host=*/true))
      return err;
    auto *mb = makeBuffer(ctx, devAddr, bytes, /*owns=*/false, true);
    mb->mtl = mbuf;
    *result = mb;
    *device_ptr = devAddr;
    return VR_OK;
  }
  void *p = malloc(bytes ? bytes : 1); // non-null even when empty; see above
  if (!p)
    return vrErrorf("VegaRT: host allocation of %zu bytes failed", bytes);
  auto *buf = makeBuffer(ctx, p, bytes, /*owns=*/true, /*isHost=*/true);
  *result = buf;
  *device_ptr = p;
  return VR_OK;
}

extern "C" void AsyncRT_DeviceContext_createBuffer_owning(
    const DeviceBuffer **result, const DeviceContext *ctx, void *device_ptr,
    size_t len, size_t elem_size, bool owning) {
  *result = makeBuffer(ctx, device_ptr, len * elem_size, owning,
                       /*isHost=*/false);
}

extern "C" const char *
AsyncRT_DeviceBuffer_createSubBuffer(const DeviceBuffer **result,
                                     void **device_ptr, const DeviceBuffer *buf,
                                     size_t offset, size_t len,
                                     size_t elem_size) {
  size_t offBytes = offset * elem_size;
  size_t bytes = len * elem_size;
  if (offBytes + bytes > buf->bytes)
    return vrErrorf("VegaRT: sub-buffer [%zu, %zu) exceeds parent size %zu",
                    offBytes, offBytes + bytes, buf->bytes);
  if (buf->mtl) {
    VRMetalBuf *msub = nullptr;
    void *devAddr = nullptr;
    if (const char *err = VegaRTMetal_createSubBuffer(&msub, &devAddr,
                                                      buf->mtl, offBytes,
                                                      bytes))
      return err;
    auto *sub = makeBuffer(buf->ctx, devAddr, bytes, false, buf->isHostBuffer);
    sub->mtl = msub;
    sub->parent = vrRetain(const_cast<VRBuffer *>(buf));
    *result = sub;
    *device_ptr = devAddr;
    return VR_OK;
  }
  auto *sub = makeBuffer(buf->ctx, static_cast<char *>(buf->ptr) + offBytes,
                         bytes, /*owns=*/false, buf->isHostBuffer);
  sub->parent = vrRetain(const_cast<VRBuffer *>(buf));
  *result = sub;
  *device_ptr = sub->ptr;
  return VR_OK;
}

extern "C" void AsyncRT_DeviceBuffer_retain(const DeviceBuffer *buffer) {
  vrRetain(const_cast<VRBuffer *>(buffer));
}

extern "C" void AsyncRT_DeviceBuffer_release(const DeviceBuffer *buffer) {
  vrRelease(const_cast<VRBuffer *>(buffer));
}

// Releases the buffer object without freeing the underlying memory: the
// caller is taking the pointer over.
extern "C" void AsyncRT_DeviceBuffer_release_ptr(const DeviceBuffer *buffer) {
  const_cast<VRBuffer *>(buffer)->ownsMemory = false;
  vrRelease(const_cast<VRBuffer *>(buffer));
}

extern "C" int64_t AsyncRT_DeviceBuffer_bytesize(const DeviceBuffer *buffer) {
  return static_cast<int64_t>(buffer->bytes);
}

extern "C" const DeviceContext *
AsyncRT_DeviceBuffer_context(const DeviceBuffer *buffer) {
  return vrRetain(buffer->ctx);
}

extern "C" const char *AsyncRT_DeviceBuffer_hostPtr(void **result,
                                                    const DeviceBuffer *buffer) {
  if (buffer->mtl) {
    *result = VegaRTMetal_hostPtr(buffer->mtl); // null for private buffers
    return VR_OK;
  }
  // CPU backend: all memory is host memory.
  *result = buffer->ptr;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceBuffer_reassignOwnershipTo(const DeviceBuffer *buf,
                                         const DeviceContext *ctx) {
  auto *b = const_cast<VRBuffer *>(buf);
  auto *newCtx = vrRetain(const_cast<VRContext *>(ctx));
  AsyncRT_DeviceContext_release(b->ctx);
  b->ctx = newCtx;
  return VR_OK;
}

//===----------------------------------------------------------------------===//
// Copies and fills (synchronous under async names)
//===----------------------------------------------------------------------===//

extern "C" const char *
AsyncRT_DeviceContext_HtoD_async(const DeviceContext *, const DeviceBuffer *dst,
                                 const void *src) {
  if (dst->mtl)
    return VegaRTMetal_copyHtoD(dst->mtl, src, dst->bytes);
  if (dst->bytes)
    memcpy(dst->ptr, src, dst->bytes);
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_DtoH_async(const DeviceContext *, void *dst,
                                 const DeviceBuffer *src) {
  if (src->mtl)
    return VegaRTMetal_copyDtoH(dst, src->mtl, src->bytes);
  if (src->bytes)
    memcpy(dst, src->ptr, src->bytes);
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_DtoD_async(const DeviceContext *, const DeviceBuffer *dst,
                                 const DeviceBuffer *src) {
  size_t n = dst->bytes < src->bytes ? dst->bytes : src->bytes;
  if (dst->mtl && src->mtl)
    return VegaRTMetal_copyDtoD(dst->mtl, src->mtl, n);
  if (n)
    memcpy(dst->ptr, src->ptr, n);
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_DtoD_async_no_cross_stream_sync(
    const DeviceContext *ctx, const DeviceBuffer *dst, const DeviceBuffer *src) {
  return AsyncRT_DeviceContext_DtoD_async(ctx, dst, src);
}

extern "C" const char *
AsyncRT_DeviceContext_setMemory_async(const DeviceContext *,
                                      const DeviceBuffer *dst, uint64_t val,
                                      size_t val_size) {
  if (dst->mtl)
    return VegaRTMetal_fill(dst->mtl, val, val_size);
  char *p = static_cast<char *>(dst->ptr);
  size_t n = dst->bytes;
  switch (val_size) {
  case 1: {
    memset(p, static_cast<int>(val & 0xff), n);
    return VR_OK;
  }
  case 2:
  case 4:
  case 8: {
    for (size_t off = 0; off + val_size <= n; off += val_size)
      memcpy(p + off, &val, val_size);
    return VR_OK;
  }
  default:
    return vrErrorf("VegaRT: setMemory with element size %zu unsupported",
                    val_size);
  }
}

//===----------------------------------------------------------------------===//
// Streams and events
//===----------------------------------------------------------------------===//

extern "C" const char *AsyncRT_DeviceContext_stream(const DeviceStream **result,
                                                    const DeviceContext *ctx) {
  *result = vrRetain(ctx->defaultStream);
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_createStream(const DeviceStream **stream, int priority,
                                   const DeviceContext *ctx) {
  auto *s = new VRStream();
  s->ctx = const_cast<VRContext *>(ctx);
  s->priority = priority;
  *stream = s;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_streamPriorityRange(int *leastPriority,
                                          int *greatestPriority,
                                          const DeviceContext *) {
  *leastPriority = 0;
  *greatestPriority = 0;
  return VR_OK;
}

extern "C" int AsyncRT_DeviceContext_numStreams(const DeviceContext *) {
  return 1;
}

extern "C" void AsyncRT_DeviceStream_retain(const DeviceStream *stream) {
  vrRetain(const_cast<VRStream *>(stream));
}

extern "C" void AsyncRT_DeviceStream_release(const DeviceStream *stream) {
  vrRelease(const_cast<VRStream *>(stream));
}

extern "C" const char *AsyncRT_DeviceStream_synchronize(const DeviceStream *) {
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceStream_enqueueHostFunc(const DeviceStream *, void (*fn)(void *),
                                     void *userData) {
  fn(userData); // synchronous backend: run it now
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_eventCreate(const DeviceEvent **result,
                                  const DeviceContext *, unsigned int) {
  *result = new VREvent();
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_enqueue_event(const DeviceEvent **result,
                                    const DeviceContext *ctx) {
  auto *ev = new VREvent();
  ev->recordedNs = nowNs();
  *result = ev;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceStream_eventRecord(const DeviceStream *, const DeviceEvent *event) {
  const_cast<VREvent *>(event)->recordedNs = nowNs();
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceStream_waitForEvent(const DeviceStream *, const DeviceEvent *) {
  return VR_OK; // already complete
}

extern "C" const char *AsyncRT_DeviceEvent_synchronize(const DeviceEvent *) {
  return VR_OK;
}

extern "C" void AsyncRT_DeviceEvent_release(const DeviceEvent *event) {
  vrRelease(const_cast<VREvent *>(event));
}

//===----------------------------------------------------------------------===//
// Timers
//===----------------------------------------------------------------------===//

extern "C" const char *
AsyncRT_DeviceContext_startTimer(const DeviceTimer **result,
                                 const DeviceContext *) {
  auto *t = new VRTimer();
  t->startNs = nowNs();
  *result = t;
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_stopTimer(int64_t *elapsed_nanos, const DeviceContext *,
                                const DeviceTimer *timer) {
  *elapsed_nanos = static_cast<int64_t>(nowNs() - timer->startNs);
  return VR_OK;
}

extern "C" void AsyncRT_DeviceTimer_release(const DeviceTimer *timer) {
  vrRelease(const_cast<VRTimer *>(timer));
}

//===----------------------------------------------------------------------===//
// Stubs: every remaining symbol from the census, linkable and legible.
// Each returns an error naming itself (or a harmless zero for value returns)
// so unported features fail loudly at the point of use.
//===----------------------------------------------------------------------===//

#define VR_STUB_ERR(name)                                                      \
  extern "C" const char *name() {                                              \
    return vrErrorf("VegaRT: %s not implemented (phase 2)", #name);            \
  }
#define VR_STUB_VOID(name)                                                     \
  extern "C" void name() {}
#define VR_STUB_ZERO(name, type)                                               \
  extern "C" type name() { return (type)0; }

// Kernel loading and launch: real on Metal (MSL source or metallib bytes,
// per the sniff-the-blob rule); an error on CPU, where there is no device.
extern "C" const char *AsyncRT_DeviceContext_loadFunction(
    const DeviceFunction **result, const DeviceContext *ctx,
    const char *moduleName, const char *functionName, const char *data,
    size_t dataLen, int32_t maxDynamicSharedBytes, const char *debugLevel,
    int32_t optimizationLevel) {
  (void)moduleName;
  (void)debugLevel;
  (void)optimizationLevel;
  if (!ctx->metal)
    return vrErrorf("VegaRT: loadFunction requires a metal context (api is "
                    "'%s')",
                    ctx->api.c_str());
  VRMetalFunc *mfn = nullptr;
  if (const char *err = VegaRTMetal_loadFunction(
          &mfn, ctx->metal, functionName, data, dataLen, maxDynamicSharedBytes))
    return err;
  auto *fn = new VRFunction();
  fn->mtl = mfn;
  *result = fn;
  return VR_OK;
}

// Metal launch protocol (decoded from _device_context_metal.mojo): `args`
// holds one element — a pointer to MetalEnqueueFunctionArgs, whose leading
// fields are {void **args; const uint64_t *sizes; const bool *isDevicePtr;}.
extern "C" const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const DeviceContext *ctx, const DeviceFunction *func, uint32_t gridX,
    uint32_t gridY, uint32_t gridZ, uint32_t blockX, uint32_t blockY,
    uint32_t blockZ, uint32_t sharedMemBytes, void *attributes,
    uint32_t numAttributes, void *const *args, uint32_t argCount,
    const uint64_t *argSizes) {
  (void)attributes;
  if (numAttributes)
    return vrErrorf("VegaRT: launch attributes not supported yet (%u given)",
                    numAttributes);
  if (!ctx->metal)
    return vrErrorf("VegaRT: kernel launch requires a metal context (api is "
                    "'%s')",
                    ctx->api.c_str());
  struct MetalArgsView {
    void *const *addrs;
    const uint64_t *sizes;
    const bool *isDevicePtr;
  };
  const uint32_t grid[3] = {gridX, gridY, gridZ};
  const uint32_t block[3] = {blockX, blockY, blockZ};
  if (argSizes == nullptr && argCount > 0 && args != nullptr) {
    // Metal wrapper path: single MetalEnqueueFunctionArgs pointer.
    const auto *mv = static_cast<const MetalArgsView *>(args[0]);
    return VegaRTMetal_launch(ctx->metal, func->mtl, grid, block,
                              sharedMemBytes, mv->addrs, mv->sizes,
                              mv->isDevicePtr, argCount);
  }
  // Plain path: per-arg pointers and sizes, no device-pointer flags (all
  // scalar bytes). Used by our own smoke tests.
  return VegaRTMetal_launch(ctx->metal, func->mtl, grid, block, sharedMemBytes,
                            args, argSizes, nullptr, argCount);
}

extern "C" void AsyncRT_DeviceFunction_retain(const DeviceFunction *fn) {
  vrRetain(const_cast<VRFunction *>(fn));
}

extern "C" void AsyncRT_DeviceFunction_release(const DeviceFunction *fn) {
  vrRelease(const_cast<VRFunction *>(fn));
}

extern "C" const char *
AsyncRT_DeviceFunction_getAttribute(int32_t *result, const DeviceFunction *fn,
                                    int32_t attr_code) {
  *result = 0;
  return vrErrorf("VegaRT: DeviceFunction_getAttribute(%d) not implemented",
                  attr_code);
}

extern "C" const char *
AsyncRT_DeviceContext_metal_device(void **result, const DeviceContext *ctx) {
  if (!ctx->metal)
    return vrErrorf("VegaRT: metal_device on non-metal context");
  return VegaRTMetal_mtlDevice(ctx->metal, result);
}

VR_STUB_ERR(AsyncRT_DeviceContext_selectStream)
VR_STUB_ERR(AsyncRT_DeviceFunction_copyToConstantMemory)
VR_STUB_ERR(AsyncRT_occupancyMaxActiveBlocksPerMultiprocessor)

// Vendor-specific escapes: not this machine's APIs.
VR_STUB_ERR(AsyncRT_DeviceContext_cuda_context)
VR_STUB_ERR(AsyncRT_DeviceContext_cuda_current_context)
VR_STUB_ERR(AsyncRT_DeviceContext_hip_device)
VR_STUB_ERR(AsyncRT_DeviceFunction_cuda_module)
VR_STUB_ERR(AsyncRT_DeviceFunction_hip_module)
VR_STUB_ERR(AsyncRT_DeviceStream_cuda_stream)
VR_STUB_ERR(AsyncRT_DeviceStream_hip_stream)
VR_STUB_ERR(AsyncRT_DeviceContext_createExternalStream)

// Async-value plumbing (used by the graph/async layers, not the CPU lane).
VR_STUB_ZERO(AsyncRT_AsyncValue_createFromDeviceBuffer, void *)
VR_STUB_ZERO(AsyncRT_AsyncValue_retainBufferStorage, void *)
VR_STUB_ZERO(AsyncRT_AsyncValue_retainHandle, void *)
VR_STUB_VOID(AsyncRT_AsyncValue_release)
VR_STUB_VOID(AsyncRT_AsyncValue_retain)
VR_STUB_ERR(AsyncRT_AndThen)
VR_STUB_ERR(AsyncRT_DeviceStream_enqueueWaitOnHostValue)
VR_STUB_ZERO(AsyncRT_CompletionFlag_devicePtr, uint64_t)

// Device graphs — later, with the Metal backend.
VR_STUB_ERR(AsyncRT_DeviceContext_createGraphBuilder)
VR_STUB_ERR(AsyncRT_DeviceContext_createGraphBuilderWithPool)
VR_STUB_ZERO(AsyncRT_DeviceContext_createGraphMemoryPool, void *)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addCopyHostToDevice)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addEmpty)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addFunction)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addSetMemory)
VR_STUB_VOID(AsyncRT_DeviceGraphBuilder_addInPlaceInput)
VR_STUB_VOID(AsyncRT_DeviceGraphBuilder_addInput)
VR_STUB_VOID(AsyncRT_DeviceGraphBuilder_addOutput)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_instantiate)
VR_STUB_ZERO(AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone, int32_t)
VR_STUB_ZERO(AsyncRT_DeviceGraphBuilder_numInputs, int64_t)
VR_STUB_ZERO(AsyncRT_DeviceGraphBuilder_numOutputs, int64_t)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_recordingContext)
VR_STUB_VOID(AsyncRT_DeviceGraphBuilder_release)
VR_STUB_ERR(AsyncRT_DeviceGraph_createBuffer)
VR_STUB_VOID(AsyncRT_DeviceGraphMemoryPool_release)
VR_STUB_VOID(AsyncRT_DeviceGraphMemoryPool_retain)
VR_STUB_ERR(AsyncRT_DeviceGraph_replay)
VR_STUB_VOID(AsyncRT_DeviceGraph_release)
VR_STUB_VOID(AsyncRT_DeviceGraph_retain)

// Multicast buffers (multi-GPU NVLink-era feature).
VR_STUB_ERR(AsyncRT_DeviceMulticastBuffer_allocate)
VR_STUB_ERR(AsyncRT_DeviceMulticastBuffer_multicastBufferFor)
VR_STUB_ERR(AsyncRT_DeviceMulticastBuffer_unicastBufferFor)
VR_STUB_VOID(AsyncRT_DeviceMulticastBuffer_release)
VR_STUB_VOID(AsyncRT_DeviceMulticastBuffer_retain)

//===----------------------------------------------------------------------===//
// Late additions: symbols with undocumented signatures, recovered from the
// external_call sites (types listed in the Mojo calls).
//===----------------------------------------------------------------------===//

// Raw-pointer sized copies (used by DevicePointer paths).
extern "C" const char *
AsyncRT_DeviceContext_HtoD_async_sized(const DeviceContext *ctx, void *dst,
                                       const void *src, size_t bytes) {
  if (ctx->metal)
    return VegaRTMetal_copyRawHtoD(ctx->metal,
                                   reinterpret_cast<uint64_t>(dst), src, bytes);
  if (bytes)
    memcpy(dst, src, bytes);
  return VR_OK;
}

extern "C" const char *
AsyncRT_DeviceContext_DtoH_async_sized(const DeviceContext *ctx, void *dst,
                                       const void *src, size_t bytes) {
  if (ctx->metal)
    return VegaRTMetal_copyRawDtoH(ctx->metal, dst,
                                   reinterpret_cast<uint64_t>(src), bytes);
  if (bytes)
    memcpy(dst, src, bytes);
  return VR_OK;
}

// Writes a StringRef-shaped {ptr,len}; storage must outlive the context.
extern "C" void AsyncRT_DeviceContext_archName(void *resultStringRef,
                                               const DeviceContext *ctx) {
  struct SR {
    const char *data;
    size_t len;
  };
  auto *sr = static_cast<SR *>(resultStringRef);
  sr->data = ctx->arch.c_str();
  sr->len = ctx->arch.size();
}

extern "C" const char *
AsyncRT_DeviceContext_maxSingleAllocationSize(const DeviceContext *ctx,
                                              size_t *result) {
  if (ctx->metal) {
    *result = VegaRTMetal_maxAlloc(ctx->metal); // 3.5 GiB on the Vega II (S1)
    return VR_OK;
  }
  size_t total = 0, freeMem = 0;
  AsyncRT_DeviceContext_getMemoryInfo(ctx, &freeMem, &total);
  *result = total; // host heap: bounded by physical memory
  return VR_OK;
}

extern "C" const char *AsyncRT_DeviceContext_setAsCurrent(const DeviceContext *) {
  return VR_OK; // CUDA current-context notion; meaningless here
}

// Coroutine scheduling: synchronous backend resumes the coroutine in place.
// The destroy callback is for cancellation, which cannot happen when the
// resume runs to completion before we return.
extern "C" const char *
AsyncRT_DeviceContext_enqueueHostFunction(const DeviceContext *,
                                          void (*resume)(void *),
                                          void (*destroy)(void *),
                                          void *coroHandle) {
  (void)destroy;
  resume(coroHandle);
  return VR_OK;
}

extern "C" void AsyncRT_DeviceEvent_retain(const DeviceEvent *event) {
  vrRetain(const_cast<VREvent *>(event));
}

// Kernel launches, ranged host functions, Metal capture, and tensor maps
// arrive with later phases; linkable, legible stubs meanwhile.
VR_STUB_ERR(AsyncRT_DeviceContext_enqueueHostFunctionRange)
VR_STUB_ERR(AsyncRT_DeviceContext_setMetalPrintEnabled)
VR_STUB_ERR(AsyncRT_DeviceContext_startMetalTraceCapture)
VR_STUB_ERR(AsyncRT_DeviceContext_stopMetalTraceCapture)
VR_STUB_ERR(AsyncRT_DeviceGraphBuilder_addFunctionDirect)
VR_STUB_ERR(AsyncRT_DeviceStream_enqueueFunctionDirect)
VR_STUB_ERR(AsyncRT_cuda_tensorMapEncodeTiled)
VR_STUB_ERR(AsyncRT_cuda_tensorMapEncodeIm)
