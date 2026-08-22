//===----------------------------------------------------------------------===//
// VegaRT internal interface between the ABI layer (VegaRT.cpp) and the Metal
// backend (VegaRTMetal.cpp).
//===----------------------------------------------------------------------===//
#pragma once
#include <cstddef>
#include <cstdint>

struct VRMetalCtx;
struct VRMetalBuf;
struct VRMetalFunc;

extern "C" {
int VegaRTMetal_deviceCount(void);
const char *VegaRTMetal_createContext(VRMetalCtx **out, int id, char *nameOut,
                                      size_t nameCap, char *archOut,
                                      size_t archCap);
void VegaRTMetal_destroyContext(VRMetalCtx *ctx);
const char *VegaRTMetal_mtlDevice(VRMetalCtx *ctx, void **out);
const char *VegaRTMetal_synchronize(VRMetalCtx *ctx);
const char *VegaRTMetal_memInfo(VRMetalCtx *ctx, size_t *freeMem, size_t *total);
size_t VegaRTMetal_maxAlloc(VRMetalCtx *ctx);
int VegaRTMetal_getAttribute(VRMetalCtx *ctx, int attr, int *out);
const char *VegaRTMetal_createBuffer(VRMetalBuf **out, void **devAddr,
                                     VRMetalCtx *ctx, size_t bytes, bool host);
const char *VegaRTMetal_createSubBuffer(VRMetalBuf **out, void **devAddr,
                                        VRMetalBuf *parent, size_t offBytes,
                                        size_t bytes);
void VegaRTMetal_destroyBuffer(VRMetalBuf *buf);
void *VegaRTMetal_hostPtr(VRMetalBuf *buf);
const char *VegaRTMetal_copyHtoD(VRMetalBuf *dst, const void *src, size_t bytes);
const char *VegaRTMetal_copyDtoH(void *dst, VRMetalBuf *src, size_t bytes);
const char *VegaRTMetal_copyDtoD(VRMetalBuf *dst, VRMetalBuf *src, size_t bytes);
const char *VegaRTMetal_copyRawHtoD(VRMetalCtx *ctx, uint64_t dstAddr,
                                    const void *src, size_t bytes);
const char *VegaRTMetal_copyRawDtoH(VRMetalCtx *ctx, void *dst,
                                    uint64_t srcAddr, size_t bytes);
const char *VegaRTMetal_fill(VRMetalBuf *dst, uint64_t val, size_t valSize);
const char *VegaRTMetal_loadFunction(VRMetalFunc **out, VRMetalCtx *ctx,
                                     const char *functionName, const char *data,
                                     size_t dataLen,
                                     int32_t maxDynamicSharedBytes);
void VegaRTMetal_destroyFunction(VRMetalFunc *fn);
const char *VegaRTMetal_launch(VRMetalCtx *ctx, VRMetalFunc *fn,
                               const uint32_t grid[3], const uint32_t block[3],
                               uint32_t sharedMemBytes, void *const *argAddrs,
                               const uint64_t *argSizes,
                               const bool *argIsDevicePtr, uint32_t argc);
}
