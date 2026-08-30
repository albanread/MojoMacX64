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

// A device pointer that the AIR backend hoisted out of a capture struct into
// a real buffer parameter (see AIR_on_AMD.md): the kernel expects a bound
// resource at `bufferIndex`, and the address to bind is stored in the packed
// argument at `srcArg`, `byteOffset` bytes in. Recovered from the parameter
// name via pipeline reflection.
struct HoistedCapture {
  unsigned bufferIndex;
  unsigned srcArg;
  uint64_t byteOffset;
};

// One kernel buffer slot, as the KERNEL declares it -- read from pipeline
// reflection rather than guessed from the value the host happens to pass.
struct VRMetalArgSlot {
  bool known = false;        // reflection told us about this index
  bool deviceBuffer = false; // a device pointer, not typed bytes
  unsigned long declaredSize = 0;
};

struct VRMetalFunc {
  id library = nullptr;
  id function = nullptr;
  id pipeline = nullptr; // id<MTLComputePipelineState>
  std::string name;
  int32_t maxDynamicSharedBytes = -1;
  std::vector<HoistedCapture> hoists;
  std::vector<VRMetalArgSlot> argSlots;
  // True when the module came from an MTLB container (our own compiled AIR).
  // The reflection discriminator below only has its intended meaning there --
  // see the note in loadFunction.
  bool fromMTLB = false;
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

// Why a GPU present in this machine is not offered, or null if it is fine.
//
// A Mac Pro has two AMD GPUs and only one of them is the target. The AIR this
// fork emits is a metal-vega2 profile -- LLVM-17 bitcode, wave64, Metal 3
// family -- and the Radeon Pro 580X is Polaris on Metal 2. There is no profile
// for it and there is not going to be one, so a context on it can allocate
// buffers and copy memory and then fail on the first kernel, deep in the
// driver, with a complaint about bitcode rather than about the device.
const char *unsupportedReason(const std::string &name) {
  if (name.find("Vega II") != std::string::npos)
    return nullptr;
  if (name.find("580X") != std::string::npos)
    return "Radeon Pro 580X is Polaris on Metal 2; this fork emits a "
           "metal-vega2 AIR profile and has none for it";
  return "no AIR profile for this GPU in this fork";
}

// Usable devices, and what was excluded and why.
//
// Ranking used to be the whole of this: Metal3 first, then working set, which
// put the Vega II at id 0 and the 580X at id 1. That is right for whoever takes
// the default and wrong for everyone else, because it left the 580X REACHABLE
// -- device 1, or any loop over deviceCount, handed back a context that cannot
// run a kernel. Excluding it makes the count honest: one device here can do
// this work. The ranking is kept for the usable set, which costs nothing and
// stays correct if a second supported GPU is ever installed.
struct DeviceTable {
  std::vector<id> usable;
  std::vector<std::pair<std::string, std::string>> rejected;
};

DeviceTable &deviceTable() {
  static DeviceTable table = [] {
    DeviceTable t;
    id array = MTLCopyAllDevices();
    unsigned long count = msg<unsigned long>(array, "count");
    for (unsigned long i = 0; i < count; i++) {
      id dev = msg<id>(array, "objectAtIndex:", i);
      std::string name = nsstringToStd(msg<id>(dev, "name"));
      if (const char *why = unsupportedReason(name)) {
        t.rejected.push_back({name, why});
        continue;
      }
      t.usable.push_back(dev);
    }
    auto rank = [](id dev) {
      bool metal3 = msg<bool>(dev, "supportsFamily:", (long)5001);
      unsigned long long ws =
          msg<unsigned long long>(dev, "recommendedMaxWorkingSetSize");
      return (metal3 ? (1ull << 62) : 0) + ws;
    };
    for (size_t i = 0; i < t.usable.size(); i++)
      for (size_t j = i + 1; j < t.usable.size(); j++)
        if (rank(t.usable[j]) > rank(t.usable[i]))
          std::swap(t.usable[i], t.usable[j]);
    return t;
  }();
  return table;
}

std::vector<id> &allDevices() { return deviceTable().usable; }

std::string archForName(const std::string &name) {
  // Arch strings must classify as APPLE_GPU in the stdlib's
  // _vendor_from_arch (substring matching: "amd"/"gfx"/"mi" would misroute
  // device codegen to HIP paths). Hence metal-*.
  if (name.find("Vega II") != std::string::npos)
    return "metal-vega2";
  if (name.find("580X") != std::string::npos)
    return "metal-polaris";
  return "metal-unknown";
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
  if (id_ < 0 || static_cast<size_t>(id_) >= devices.size()) {
    // Name what was excluded. Without it this reads as "your Mac has one GPU"
    // on a machine whose About This Mac plainly says two, and the next hour
    // goes into the wrong question.
    std::string excluded;
    for (auto &r : deviceTable().rejected)
      excluded += "; excluded: " + r.first + " -- " + r.second;
    return vrmErrorf("VegaRT[metal]: device id %d out of range (%zu usable "
                     "Metal device%s)%s",
                     id_, devices.size(), devices.size() == 1 ? "" : "s",
                     excluded.c_str());
  }
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
  // The address handed to Mojo (and used as this buffer's registry base):
  // device buffers expose their GPU virtual address; host (shared-storage)
  // buffers expose their CPU-dereferenceable contents pointer — Mojo reads
  // and writes host buffers directly.
  buf->gpuBase = host ? reinterpret_cast<uint64_t>(msg<char *>(buffer,
                                                               "contents"))
                      : msg<unsigned long long>(buffer, "gpuAddress");
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
  bool fromMTLB = dataLen >= 4 && memcmp(data, "MTLB", 4) == 0;
  if (fromMTLB) {
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
  // MTLPipelineOptionBindingInfo(1) | MTLPipelineOptionBufferTypeInfo(2).
  // BindingInfo carries the parameter NAMES (how hoisted captures are
  // recovered); BufferTypeInfo carries each slot's declared TYPE, which is
  // the kernel's own argument contract -- see the launch path.
  id reflection = nullptr;
  id pipeline = msg<id>(
      ctx->device,
      "newComputePipelineStateWithFunction:options:reflection:error:", function,
      (unsigned long)3, &reflection, &nserr);
  if (!pipeline) {
    objcRelease(function);
    objcRelease(library);
    return errorFromNSError("newComputePipelineStateWithFunction", nserr);
  }

  std::vector<HoistedCapture> hoists;
  std::vector<VRMetalArgSlot> argSlots;
  if (reflection) {
    id bindings = msg<id>(reflection, "bindings");
    unsigned long n = bindings ? msg<unsigned long>(bindings, "count") : 0;
    for (unsigned long i = 0; i < n; i++) {
      id b = msg<id>(bindings, "objectAtIndex:", i);
      // MTLBindingTypeBuffer == 0. Threadgroup memory and textures are bound
      // by other paths and carry no argument contract here.
      if (msg<long>(b, "type") != 0)
        continue;
      unsigned long idx = msg<unsigned long>(b, "index");

      // The kernel's own contract for this slot. The discriminator is
      // `bufferDataType == MTLDataTypeNone(0)`: a slot Metal cannot give a
      // data type to is a device POINTER, whereas typed bytes report their
      // actual type. That is a fact about the kernel, unlike the value-based
      // guess it replaces.
      //
      // But it only means that for OUR OWN compiled AIR, which declares
      // device parameters with an opaque pointee. An MSL kernel declares
      // `device float *`, so Metal reports Float/4 for a parameter that is
      // very much a buffer -- same API, opposite meaning, and nothing in the
      // reflection distinguishes them. Hence the provenance check: without it
      // this test silently classifies every MSL buffer as constant bytes.
      if (!fromMTLB)
        continue;
      unsigned long dataType = msg<unsigned long>(b, "bufferDataType");
      unsigned long dataSize = msg<unsigned long>(b, "bufferDataSize");
      if (argSlots.size() <= idx)
        argSlots.resize(idx + 1);
      argSlots[idx] = {true, dataType == 0, dataSize};

      std::string bname = nsstringToStd(msg<id>(b, "name"));
      unsigned srcArg = 0;
      unsigned long long off = 0;
      if (sscanf(bname.c_str(), "__vega_cap_%u_%llu", &srcArg, &off) == 2)
        hoists.push_back({static_cast<unsigned>(idx), srcArg,
                          static_cast<uint64_t>(off)});
    }
  }

  auto *fn = new VRMetalFunc();
  fn->library = library;
  fn->function = function;
  fn->pipeline = pipeline;
  fn->name = functionName;
  fn->maxDynamicSharedBytes = maxDynamicSharedBytes;
  fn->hoists = std::move(hoists);
  fn->argSlots = std::move(argSlots);
  fn->fromMTLB = fromMTLB;
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
  // Metal can silently no-op a dispatch whose threadgroup is too large for
  // the pipeline (SDL #15241); validate against the pipeline's own limit and
  // fail loudly instead.
  unsigned long maxThreads =
      msg<unsigned long>(fn->pipeline, "maxTotalThreadsPerThreadgroup");
  unsigned long requested =
      static_cast<unsigned long>(block[0]) * block[1] * block[2];
  if (maxThreads && requested > maxThreads)
    return vrmErrorf("VegaRT[metal]: threadgroup %ux%ux%u = %lu threads "
                     "exceeds this pipeline's maxTotalThreadsPerThreadgroup "
                     "(%lu) for '%s'",
                     block[0], block[1], block[2], requested, maxThreads,
                     fn->name.c_str());

  id cb = msg<id>(ctx->queue, "commandBuffer");
  if (!cb)
    return vrmErrorf("VegaRT[metal]: commandBuffer creation failed");
  id enc = msg<id>(cb, "computeCommandEncoder");
  msg<void>(enc, "setComputePipelineState:", fn->pipeline);

  for (uint32_t i = 0; i < argc; i++) {
    // Prefer the KERNEL'S OWN CONTRACT, read from pipeline reflection at load
    // time, over any guess about the value being passed.
    //
    // The old rule was: any >=8-byte argument whose leading word resolves in
    // the allocation registry is a device pointer. That is a guess about a
    // value, and it is wrong in one direction or the other -- a scalar that
    // happens to hold a live GPU address binds as a buffer and the kernel
    // reads the wrong memory, silently. The contract cannot be fooled that
    // way: the kernel either declares the slot as a pointer or it does not.
    //
    // Explicit caller flags still win (the caller knows what it packed), and
    // the value heuristic remains only for the case where reflection was
    // unavailable, so a missing contract degrades rather than refuses.
    bool isDev = argIsDevicePtr ? argIsDevicePtr[i] : false;
    const VRMetalArgSlot *slot =
        i < fn->argSlots.size() && fn->argSlots[i].known ? &fn->argSlots[i]
                                                         : nullptr;
    if (!argIsDevicePtr) {
      if (slot) {
        isDev = slot->deviceBuffer;
      } else if (argSizes && argSizes[i] >= 8) {
        uint64_t maybe = 0;
        memcpy(&maybe, argAddrs[i], sizeof(maybe));
        size_t off = 0;
        if (resolveAddress(maybe, &off))
          isDev = true;
      }
    }
    if (isDev) {
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

  // Bind the hoisted captured pointers: read the address out of the packed
  // argument the compiler recorded, resolve it in the allocation registry,
  // and bind the owning buffer as a real resource.
  for (const HoistedCapture &h : fn->hoists) {
    if (h.srcArg >= argc) {
      msg<void>(enc, "endEncoding");
      return vrmErrorf("VegaRT[metal]: hoisted capture names arg %u but the "
                       "launch has %u args",
                       h.srcArg, argc);
    }
    uint64_t addr = 0;
    memcpy(&addr,
           static_cast<const char *>(argAddrs[h.srcArg]) + h.byteOffset,
           sizeof(addr));
    size_t off = 0;
    id buffer = resolveAddress(addr, &off);
    if (!buffer) {
      msg<void>(enc, "endEncoding");
      return vrmErrorf("VegaRT[metal]: hoisted capture at arg %u+%llu holds "
                       "0x%llx, which is not a known device allocation",
                       h.srcArg, (unsigned long long)h.byteOffset,
                       (unsigned long long)addr);
    }
    msg<void>(enc, "setBuffer:offset:atIndex:", buffer,
              static_cast<unsigned long>(off),
              static_cast<unsigned long>(h.bufferIndex));
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
