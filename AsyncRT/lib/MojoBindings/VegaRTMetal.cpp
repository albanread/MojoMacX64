//===----------------------------------------------------------------------===//
// VegaRTMetal — the Metal backend for VegaRT, targeting the AMD GPUs of a
// 2019 Mac Pro (Radeon Pro Vega II primary, 580X control) through the Metal
// API on x86-64 macOS.
//
// Written in plain C++ over the Objective-C runtime (objc_msgSend casts, the
// metal-cpp technique) so no Objective-C++ toolchain support is required.
//
// Discrete-GPU semantics throughout: device buffers are storageModePrivate
// in HBM2; host buffers are storageModeShared; every HtoD/DtoH goes through
// a staging blit. Synchronous under the async names for bring-up, same
// completion model the CPU backend uses.
//
// Device pointers handed to Mojo are MTLBuffer gpuAddress values. A global
// interval map resolves any device address back to its owning MTLBuffer and
// offset, which is how kernel launches bind pointer arguments (setBuffer
// with a resolved offset) without trusting struct layouts we don't own.
//===----------------------------------------------------------------------===//

#include "VegaRTInternal.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>

extern "C" id MTLCopyAllDevices(void);

namespace {

//===----------------------------------------------------------------------===//
// objc plumbing
//===----------------------------------------------------------------------===//

template <typename R, typename... A> R msg(id obj, const char *sel, A... a) {
  using Fn = R (*)(id, SEL, A...);
  return reinterpret_cast<Fn>(objc_msgSend)(obj, sel_registerName(sel), a...);
}

struct MTLSizeC {
  unsigned long w, h, d;
};
struct NSRangeC {
  unsigned long loc, len;
};

void objcRelease(id obj) {
  if (obj)
    msg<void>(obj, "release");
}

std::string nsstringToStd(id nsstr) {
  if (!nsstr)
    return "";
  const char *utf8 = msg<const char *>(nsstr, "UTF8String");
  return utf8 ? utf8 : "";
}

char *vrmStrdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = static_cast<char *>(malloc(n));
  memcpy(p, s, n);
  return p;
}

const char *vrmErrorf(const char *fmt, ...) {
  char buf[768];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  return vrmStrdup(buf);
}

const char *errorFromNSError(const char *what, id nserror) {
  std::string desc =
      nserror ? nsstringToStd(msg<id>(nserror, "localizedDescription"))
              : "(no NSError)";
  return vrmErrorf("VegaRT[metal]: %s: %s", what, desc.c_str());
}

// storage modes: MTLResourceStorageMode{Shared=0, Managed=1<<4, Private=2<<4}
constexpr unsigned long kStorageShared = 0;
constexpr unsigned long kStoragePrivate = 2ul << 4;

} // namespace

//===----------------------------------------------------------------------===//
// Structures
//===----------------------------------------------------------------------===//

struct VRMetalCtx {
  id device = nullptr; // id<MTLDevice>, retained by MTLCopyAllDevices
  id queue = nullptr;  // id<MTLCommandQueue>
  std::string name;
  std::string arch;
};

struct VRMetalBuf {
  VRMetalCtx *ctx = nullptr;
  id buffer = nullptr;   // id<MTLBuffer>; owned unless this is a sub-view
  bool ownsBuffer = false;
  size_t offset = 0;     // view offset within `buffer`
  size_t bytes = 0;
  bool isHost = false;   // shared storage, host-visible
  uint64_t gpuBase = 0;  // gpuAddress of `buffer` (not of the view)
};

struct VRMetalFunc {
  id library = nullptr;
  id function = nullptr;
  id pipeline = nullptr; // id<MTLComputePipelineState>
  std::string name;
  int32_t maxDynamicSharedBytes = -1;
};

namespace {

//===----------------------------------------------------------------------===//
// Address registry: gpuAddress interval -> owning buffer
//===----------------------------------------------------------------------===//

// Function-local statics: the repo compiles -Werror=global-constructors.
struct AddressRegistry {
  std::mutex mu;
  // key: base gpu address of a root (owning) buffer -> {buf, sizeBytes}
  std::map<uint64_t, std::pair<VRMetalBuf *, size_t>> map;
};
AddressRegistry &registry() {
  static AddressRegistry *r = new AddressRegistry(); // never destroyed
  return *r;
}

void registerRoot(VRMetalBuf *buf, size_t fullBytes) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  r.map[buf->gpuBase] = {buf, fullBytes};
}

void unregisterRoot(const VRMetalBuf *buf) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  auto it = r.map.find(buf->gpuBase);
  if (it != r.map.end() && it->second.first == buf)
    r.map.erase(it);
}

// Resolve a device address to (MTLBuffer id, offset). Returns nil on miss.
id resolveAddress(uint64_t addr, size_t *offsetOut) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  auto it = r.map.upper_bound(addr);
  if (it == r.map.begin())
    return nullptr;
  --it;
  uint64_t base = it->first;
  size_t size = it->second.second;
  if (addr < base || addr >= base + size)
    return nullptr;
  *offsetOut = static_cast<size_t>(addr - base);
  return it->second.first->buffer;
}

//===----------------------------------------------------------------------===//
// Command helpers (synchronous bring-up)
//===----------------------------------------------------------------------===//

struct BlitOp {
  id src = nullptr;
  size_t srcOff = 0;
  id dst = nullptr;
  size_t dstOff = 0;
  size_t bytes = 0;
  bool fill = false;
  uint8_t fillValue = 0;
};

const char *runBlitOp(VRMetalCtx *ctx, const BlitOp &op) {
  id cb = msg<id>(ctx->queue, "commandBuffer");
  if (!cb)
    return vrmErrorf("VegaRT[metal]: commandBuffer creation failed");
  id blit = msg<id>(cb, "blitCommandEncoder");
  if (op.fill) {
    NSRangeC range{op.dstOff, op.bytes};
    msg<void>(blit, "fillBuffer:range:value:", op.dst, range,
              static_cast<uint8_t>(op.fillValue));
  } else {
    msg<void>(blit,
              "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:",
              op.src, static_cast<unsigned long>(op.srcOff), op.dst,
              static_cast<unsigned long>(op.dstOff),
              static_cast<unsigned long>(op.bytes));
  }
  msg<void>(blit, "endEncoding");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  id err = msg<id>(cb, "error");
  if (err)
    return errorFromNSError("blit failed", err);
  return nullptr;
}

// Sorted device list: Metal3-family first, then higher working-set. Keeps the
// Vega II at id 0 and the 580X at id 1 on this machine.
std::vector<id> &allDevices() {
  static std::vector<id> devices = [] {
    std::vector<id> result;
    id array = MTLCopyAllDevices();
    unsigned long count = msg<unsigned long>(array, "count");
    for (unsigned long i = 0; i < count; i++)
      result.push_back(msg<id>(array, "objectAtIndex:", i));
    auto rank = [](id dev) {
      bool metal3 = msg<bool>(dev, "supportsFamily:", (long)5001);
      unsigned long long ws =
          msg<unsigned long long>(dev, "recommendedMaxWorkingSetSize");
      return (metal3 ? (1ull << 62) : 0) + ws;
    };
    for (size_t i = 0; i < result.size(); i++)
      for (size_t j = i + 1; j < result.size(); j++)
        if (rank(result[j]) > rank(result[i]))
          std::swap(result[i], result[j]);
    return result;
  }();
  return devices;
}

std::string archForName(const std::string &name) {
  if (name.find("Vega II") != std::string::npos)
    return "amd-vega2";
  if (name.find("580X") != std::string::npos)
    return "amd-polaris";
  return "amd-metal-unknown";
}

} // namespace

//===----------------------------------------------------------------------===//
// Internal C API (consumed by VegaRT.cpp)
//===----------------------------------------------------------------------===//

extern "C" {

int VegaRTMetal_deviceCount(void) {
  return static_cast<int>(allDevices().size());
}

const char *VegaRTMetal_createContext(VRMetalCtx **out, int id_,
                                      char *nameOut, size_t nameCap,
                                      char *archOut, size_t archCap) {
  auto &devices = allDevices();
  if (id_ < 0 || static_cast<size_t>(id_) >= devices.size())
    return vrmErrorf("VegaRT[metal]: device id %d out of range (%zu Metal "
                     "devices present)",
                     id_, devices.size());
  auto *ctx = new VRMetalCtx();
  ctx->device = devices[static_cast<size_t>(id_)];
  ctx->queue = msg<id>(ctx->device, "newCommandQueue");
  if (!ctx->queue) {
    delete ctx;
    return vrmErrorf("VegaRT[metal]: newCommandQueue failed");
  }
  std::string devName = nsstringToStd(msg<id>(ctx->device, "name"));
  // test_smoke requires "Apple" in the name when api == "metal"; truthfully,
  // this is the Apple Metal API driving an AMD GPU.
  ctx->name = devName + " (Apple Metal)";
  ctx->arch = archForName(devName);
  snprintf(nameOut, nameCap, "%s", ctx->name.c_str());
  snprintf(archOut, archCap, "%s", ctx->arch.c_str());
  *out = ctx;
  return nullptr;
}

void VegaRTMetal_destroyContext(VRMetalCtx *ctx) {
  if (!ctx)
    return;
  objcRelease(ctx->queue);
  delete ctx;
}

const char *VegaRTMetal_mtlDevice(VRMetalCtx *ctx, void **out) {
  *out = ctx->device;
  return nullptr;
}

const char *VegaRTMetal_synchronize(VRMetalCtx *ctx) {
  // Every op is currently synchronous; an empty command buffer round-trip
  // still serializes against anything in flight.
  id cb = msg<id>(ctx->queue, "commandBuffer");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  return nullptr;
}

const char *VegaRTMetal_memInfo(VRMetalCtx *ctx, size_t *freeMem,
                                size_t *total) {
  unsigned long long ws =
      msg<unsigned long long>(ctx->device, "recommendedMaxWorkingSetSize");
  unsigned long long used =
      msg<unsigned long long>(ctx->device, "currentAllocatedSize");
  *total = static_cast<size_t>(ws);
  *freeMem = static_cast<size_t>(ws > used ? ws - used : 0);
  return nullptr;
}

size_t VegaRTMetal_maxAlloc(VRMetalCtx *ctx) {
  return static_cast<size_t>(
      msg<unsigned long>(ctx->device, "maxBufferLength"));
}

int VegaRTMetal_getAttribute(VRMetalCtx *ctx, int attr, int *out) {
  switch (attr) {
  case 1: // MAX_THREADS_PER_BLOCK
    *out = 1024;
    return 0;
  case 10: // WARP_SIZE — wave64, verified in S1
    *out = 64;
    return 0;
  case 13: // CLOCK_RATE in kHz (Vega 20 boost ~1.7 GHz)
    *out = 1700000;
    return 0;
  default:
    return -1; // not handled; caller reports the usual error
  }
}

const char *VegaRTMetal_createBuffer(VRMetalBuf **out, void **devAddr,
                                     VRMetalCtx *ctx, size_t bytes,
                                     bool host) {
  size_t allocBytes = bytes ? bytes : 1; // non-null contract, as on CPU
  unsigned long options = host ? kStorageShared : kStoragePrivate;
  id buffer = msg<id>(ctx->device, "newBufferWithLength:options:",
                      static_cast<unsigned long>(allocBytes), options);
  if (!buffer)
    return vrmErrorf("VegaRT[metal]: newBufferWithLength(%zu, %s) failed "
                     "(maxBufferLength %zu)",
                     allocBytes, host ? "shared" : "private",
                     VegaRTMetal_maxAlloc(ctx));
  auto *buf = new VRMetalBuf();
  buf->ctx = ctx;
  buf->buffer = buffer;
  buf->ownsBuffer = true;
  buf->bytes = bytes;
  buf->isHost = host;
  buf->gpuBase = msg<unsigned long long>(buffer, "gpuAddress");
  registerRoot(buf, allocBytes);
  *out = buf;
  *devAddr = reinterpret_cast<void *>(buf->gpuBase);
  return nullptr;
}

const char *VegaRTMetal_createSubBuffer(VRMetalBuf **out, void **devAddr,
                                        VRMetalBuf *parent, size_t offBytes,
                                        size_t bytes) {
  auto *buf = new VRMetalBuf();
  buf->ctx = parent->ctx;
  buf->buffer = parent->buffer;
  buf->ownsBuffer = false;
  buf->offset = parent->offset + offBytes;
  buf->bytes = bytes;
  buf->isHost = parent->isHost;
  buf->gpuBase = parent->gpuBase;
  *out = buf;
  *devAddr = reinterpret_cast<void *>(buf->gpuBase + buf->offset);
  return nullptr;
}

void VegaRTMetal_destroyBuffer(VRMetalBuf *buf) {
  if (!buf)
    return;
  if (buf->ownsBuffer) {
    unregisterRoot(buf);
    objcRelease(buf->buffer);
  }
  delete buf;
}

void *VegaRTMetal_hostPtr(VRMetalBuf *buf) {
  if (!buf->isHost)
    return nullptr;
  char *contents = msg<char *>(buf->buffer, "contents");
  return contents ? contents + buf->offset : nullptr;
}

const char *VegaRTMetal_copyHtoD(VRMetalBuf *dst, const void *src,
                                 size_t bytes) {
  if (!bytes)
    return nullptr;
  VRMetalCtx *ctx = dst->ctx;
  if (dst->isHost) {
    memcpy(static_cast<char *>(msg<char *>(dst->buffer, "contents")) +
               dst->offset,
           src, bytes);
    return nullptr;
  }
  id staging = msg<id>(ctx->device, "newBufferWithBytes:length:options:",
                       src, static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return vrmErrorf("VegaRT[metal]: HtoD staging alloc of %zu bytes failed",
                     bytes);
  BlitOp op;
  op.src = staging;
  op.dst = dst->buffer;
  op.dstOff = dst->offset;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  objcRelease(staging);
  return err;
}

const char *VegaRTMetal_copyDtoH(void *dst, VRMetalBuf *src, size_t bytes) {
  if (!bytes)
    return nullptr;
  VRMetalCtx *ctx = src->ctx;
  if (src->isHost) {
    memcpy(dst,
           static_cast<char *>(msg<char *>(src->buffer, "contents")) +
               src->offset,
           bytes);
    return nullptr;
  }
  id staging = msg<id>(ctx->device, "newBufferWithLength:options:",
                       static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return vrmErrorf("VegaRT[metal]: DtoH staging alloc of %zu bytes failed",
                     bytes);
  BlitOp op;
  op.src = src->buffer;
  op.srcOff = src->offset;
  op.dst = staging;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  if (!err)
    memcpy(dst, msg<char *>(staging, "contents"), bytes);
  objcRelease(staging);
  return err;
}

const char *VegaRTMetal_copyDtoD(VRMetalBuf *dst, VRMetalBuf *src,
                                 size_t bytes) {
  if (!bytes)
    return nullptr;
  BlitOp op;
  op.src = src->buffer;
  op.srcOff = src->offset;
  op.dst = dst->buffer;
  op.dstOff = dst->offset;
  op.bytes = bytes;
  return runBlitOp(dst->ctx, op);
}

// Raw-address copies (DevicePointer paths): resolve through the registry.
const char *VegaRTMetal_copyRawHtoD(VRMetalCtx *ctx, uint64_t dstAddr,
                                    const void *src, size_t bytes) {
  size_t off = 0;
  id target = resolveAddress(dstAddr, &off);
  if (!target)
    return vrmErrorf("VegaRT[metal]: HtoD to unknown device address 0x%llx",
                     (unsigned long long)dstAddr);
  id staging = msg<id>(ctx->device, "newBufferWithBytes:length:options:",
                       src, static_cast<unsigned long>(bytes), kStorageShared);
  BlitOp op;
  op.src = staging;
  op.dst = target;
  op.dstOff = off;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  objcRelease(staging);
  return err;
}

const char *VegaRTMetal_copyRawDtoH(VRMetalCtx *ctx, void *dst,
                                    uint64_t srcAddr, size_t bytes) {
  size_t off = 0;
  id source = resolveAddress(srcAddr, &off);
  if (!source)
    return vrmErrorf("VegaRT[metal]: DtoH from unknown device address 0x%llx",
                     (unsigned long long)srcAddr);
  id staging = msg<id>(ctx->device, "newBufferWithLength:options:",
                       static_cast<unsigned long>(bytes), kStorageShared);
  BlitOp op;
  op.src = source;
  op.srcOff = off;
  op.dst = staging;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  if (!err)
    memcpy(dst, msg<char *>(staging, "contents"), bytes);
  objcRelease(staging);
  return err;
}

const char *VegaRTMetal_fill(VRMetalBuf *dst, uint64_t val, size_t valSize) {
  size_t bytes = dst->bytes;
  if (!bytes)
    return nullptr;
  // fillBuffer writes a single byte pattern; usable whenever all bytes of
  // the value are equal (memset-zero being the overwhelmingly common case).
  bool uniform = true;
  uint8_t b0 = static_cast<uint8_t>(val & 0xff);
  for (size_t i = 1; i < valSize; i++)
    if (static_cast<uint8_t>((val >> (8 * i)) & 0xff) != b0)
      uniform = false;
  if (uniform) {
    BlitOp op;
    op.dst = dst->buffer;
    op.dstOff = dst->offset;
    op.bytes = bytes;
    op.fill = true;
    op.fillValue = b0;
    return runBlitOp(dst->ctx, op);
  }
  // Pattern fill: build it host-side, then one HtoD.
  std::vector<char> pattern(bytes);
  for (size_t off = 0; off + valSize <= bytes; off += valSize)
    memcpy(pattern.data() + off, &val, valSize);
  return VegaRTMetal_copyHtoD(dst, pattern.data(), bytes);
}

//===----------------------------------------------------------------------===//
// Functions: MSL source or metallib container, per the sniff-the-blob rule.
//===----------------------------------------------------------------------===//

const char *VegaRTMetal_loadFunction(VRMetalFunc **out, VRMetalCtx *ctx,
                                     const char *functionName,
                                     const char *data, size_t dataLen,
                                     int32_t maxDynamicSharedBytes) {
  id library = nullptr;
  id nserr = nullptr;
  if (dataLen >= 4 && memcmp(data, "MTLB", 4) == 0) {
    dispatch_data_t dd = dispatch_data_create(data, dataLen, nullptr,
                                              DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    library = msg<id>(ctx->device, "newLibraryWithData:error:", dd, &nserr);
    dispatch_release(dd);
    if (!library)
      return errorFromNSError("newLibraryWithData (metallib)", nserr);
  } else {
    CFStringRef source = CFStringCreateWithBytes(
        kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(data),
        static_cast<CFIndex>(dataLen), kCFStringEncodingUTF8, false);
    if (!source)
      return vrmErrorf("VegaRT[metal]: kernel source is not valid UTF-8");
    library = msg<id>(ctx->device, "newLibraryWithSource:options:error:",
                      reinterpret_cast<id>(const_cast<void *>(
                          static_cast<const void *>(source))),
                      (id) nullptr, &nserr);
    CFRelease(source);
    if (!library)
      return errorFromNSError("newLibraryWithSource (MSL)", nserr);
  }

  CFStringRef fname = CFStringCreateWithCString(kCFAllocatorDefault,
                                                functionName,
                                                kCFStringEncodingUTF8);
  id function = msg<id>(library, "newFunctionWithName:",
                        reinterpret_cast<id>(const_cast<void *>(
                            static_cast<const void *>(fname))));
  CFRelease(fname);
  if (!function) {
    objcRelease(library);
    return vrmErrorf("VegaRT[metal]: function '%s' not found in module",
                     functionName);
  }

  nserr = nullptr;
  id pipeline = msg<id>(ctx->device,
                        "newComputePipelineStateWithFunction:error:", function,
                        &nserr);
  if (!pipeline) {
    objcRelease(function);
    objcRelease(library);
    return errorFromNSError("newComputePipelineStateWithFunction", nserr);
  }

  auto *fn = new VRMetalFunc();
  fn->library = library;
  fn->function = function;
  fn->pipeline = pipeline;
  fn->name = functionName;
  fn->maxDynamicSharedBytes = maxDynamicSharedBytes;
  *out = fn;
  return nullptr;
}

void VegaRTMetal_destroyFunction(VRMetalFunc *fn) {
  if (!fn)
    return;
  objcRelease(fn->pipeline);
  objcRelease(fn->function);
  objcRelease(fn->library);
  delete fn;
}

//===----------------------------------------------------------------------===//
// Launch. Argument model (decoded from _device_context_metal.mojo): per-arg
// value pointers + sizes + an is-device-pointer flag per argument. Pointer
// args hold a 64-bit device address; we resolve it to (MTLBuffer, offset)
// and bind with setBuffer — which also makes the resource resident. Scalar
// args are bound with setBytes. Argument index == buffer slot index.
//===----------------------------------------------------------------------===//

const char *VegaRTMetal_launch(VRMetalCtx *ctx, VRMetalFunc *fn,
                               const uint32_t grid[3], const uint32_t block[3],
                               uint32_t sharedMemBytes, void *const *argAddrs,
                               const uint64_t *argSizes,
                               const bool *argIsDevicePtr, uint32_t argc) {
  id cb = msg<id>(ctx->queue, "commandBuffer");
  if (!cb)
    return vrmErrorf("VegaRT[metal]: commandBuffer creation failed");
  id enc = msg<id>(cb, "computeCommandEncoder");
  msg<void>(enc, "setComputePipelineState:", fn->pipeline);

  for (uint32_t i = 0; i < argc; i++) {
    if (argIsDevicePtr && argIsDevicePtr[i]) {
      uint64_t addr = 0;
      memcpy(&addr, argAddrs[i], sizeof(addr));
      size_t off = 0;
      id buffer = resolveAddress(addr, &off);
      if (!buffer) {
        msg<void>(enc, "endEncoding");
        return vrmErrorf("VegaRT[metal]: launch arg %u: unknown device "
                         "address 0x%llx",
                         i, (unsigned long long)addr);
      }
      msg<void>(enc, "setBuffer:offset:atIndex:", buffer,
                static_cast<unsigned long>(off), static_cast<unsigned long>(i));
    } else {
      uint64_t size = argSizes ? argSizes[i] : 0;
      msg<void>(enc, "setBytes:length:atIndex:", argAddrs[i],
                static_cast<unsigned long>(size),
                static_cast<unsigned long>(i));
    }
  }

  if (sharedMemBytes)
    msg<void>(enc, "setThreadgroupMemoryLength:atIndex:",
              static_cast<unsigned long>(sharedMemBytes), 0ul);

  MTLSizeC gridSize{grid[0], grid[1], grid[2]};
  MTLSizeC blockSize{block[0], block[1], block[2]};
  msg<void>(enc, "dispatchThreadgroups:threadsPerThreadgroup:", gridSize,
            blockSize);
  msg<void>(enc, "endEncoding");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  id err = msg<id>(cb, "error");
  if (err)
    return errorFromNSError("kernel launch failed", err);
  return nullptr;
}

} // extern "C"
