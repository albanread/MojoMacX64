// VegaRT Metal smoke: the phase-2b acceptance gate.
// Exercises the AsyncRT_* ABI through local prototypes only — the same way
// Mojo's external_call finds it. MSL source path (the AIR trio does not
// exist yet); saxpy on the Vega II; every element verified.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Ctx Ctx;
typedef struct Buf Buf;
typedef struct Fn Fn;

extern const char *AsyncRT_DeviceContext_create(const Ctx **r, const char *api, int id);
extern void AsyncRT_DeviceContext_release(const Ctx *c);
extern int32_t AsyncRT_DeviceContext_numberOfDevices(const char *kind);
extern const char *AsyncRT_DeviceContext_deviceName(const Ctx *c);
extern void AsyncRT_DeviceContext_strfree(const char *p);
extern const char *AsyncRT_DeviceContext_createBuffer_async(const Buf **r, void **dp, const Ctx *c, size_t len, size_t elem);
extern void AsyncRT_DeviceBuffer_release(const Buf *b);
extern const char *AsyncRT_DeviceContext_HtoD_async(const Ctx *c, const Buf *dst, const void *src);
extern const char *AsyncRT_DeviceContext_DtoH_async(const Ctx *c, void *dst, const Buf *src);
extern const char *AsyncRT_DeviceContext_setMemory_async(const Ctx *c, const Buf *dst, uint64_t val, size_t vs);
extern const char *AsyncRT_DeviceContext_synchronize(const Ctx *c);
extern const char *AsyncRT_DeviceContext_getMemoryInfo(const Ctx *c, size_t *freeM, size_t *tot);
extern const char *AsyncRT_DeviceContext_maxSingleAllocationSize(const Ctx *c, size_t *r);
extern const char *AsyncRT_DeviceContext_getAttribute(int *r, const Ctx *c, int attr);
extern const char *AsyncRT_DeviceContext_loadFunction(
    const Fn **r, const Ctx *c, const char *module, const char *fname,
    const char *data, size_t dataLen, int32_t maxDynShared,
    const char *debugLevel, int32_t optLevel);
extern void AsyncRT_DeviceFunction_release(const Fn *f);
extern const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const Ctx *c, const Fn *f, uint32_t gx, uint32_t gy, uint32_t gz,
    uint32_t bx, uint32_t by, uint32_t bz, uint32_t smem, void *attrs,
    uint32_t nattrs, void *const *args, uint32_t argc, const uint64_t *sizes);

static const char *kSaxpy =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void saxpy(device float *y [[buffer(0)]],\n"
    "                  device const float *x [[buffer(1)]],\n"
    "                  constant float &a [[buffer(2)]],\n"
    "                  constant uint &n [[buffer(3)]],\n"
    "                  uint id [[thread_position_in_grid]]) {\n"
    "  if (id < n) y[id] = a * x[id] + y[id];\n"
    "}\n";

#define CHECK(expr)                                                            \
  do {                                                                         \
    const char *_err = (expr);                                                 \
    if (_err) {                                                                \
      fprintf(stderr, "SMOKE FAIL at %s:%d: %s\n  from: %s\n", __FILE__,       \
              __LINE__, _err, #expr);                                          \
      AsyncRT_DeviceContext_strfree(_err);                                     \
      return 1;                                                                \
    }                                                                          \
  } while (0)

int main(void) {
  printf("metal devices: %d\n", AsyncRT_DeviceContext_numberOfDevices("gpu"));

  const Ctx *ctx = NULL;
  CHECK(AsyncRT_DeviceContext_create(&ctx, "metal", 0));
  const char *name = AsyncRT_DeviceContext_deviceName(ctx);
  printf("device: %s\n", name);
  AsyncRT_DeviceContext_strfree(name);

  size_t freeM = 0, tot = 0, maxAlloc = 0;
  int warp = 0;
  CHECK(AsyncRT_DeviceContext_getMemoryInfo(ctx, &freeM, &tot));
  CHECK(AsyncRT_DeviceContext_maxSingleAllocationSize(ctx, &maxAlloc));
  CHECK(AsyncRT_DeviceContext_getAttribute(&warp, ctx, 10));
  printf("memory: %.1f GiB total, maxAlloc %.1f GiB, warp %d\n",
         tot / 1073741824.0, maxAlloc / 1073741824.0, warp);

  enum { N = 1 << 20 };
  const Buf *x = NULL, *y = NULL;
  void *xAddr = NULL, *yAddr = NULL;
  CHECK(AsyncRT_DeviceContext_createBuffer_async(&x, &xAddr, ctx, N, 4));
  CHECK(AsyncRT_DeviceContext_createBuffer_async(&y, &yAddr, ctx, N, 4));
  printf("buffers: x@0x%llx y@0x%llx (private, HBM2)\n",
         (unsigned long long)(uintptr_t)xAddr,
         (unsigned long long)(uintptr_t)yAddr);

  float *hostX = malloc(N * 4), *hostY = malloc(N * 4);
  for (int i = 0; i < N; i++) {
    hostX[i] = (float)i;
    hostY[i] = 2.0f * (float)i;
  }
  CHECK(AsyncRT_DeviceContext_HtoD_async(ctx, x, hostX));
  CHECK(AsyncRT_DeviceContext_HtoD_async(ctx, y, hostY));

  // Load from MSL source (the sniff path) and launch: y = 3x + y.
  const Fn *fn = NULL;
  CHECK(AsyncRT_DeviceContext_loadFunction(&fn, ctx, "", "saxpy", kSaxpy,
                                           strlen(kSaxpy), -1, "none", 3));
  printf("pipeline: built from MSL source\n");

  float a = 3.0f;
  uint32_t n = N;
  uint64_t xA = (uint64_t)(uintptr_t)xAddr, yA = (uint64_t)(uintptr_t)yAddr;
  // Metal-wrapper protocol: args[0] -> {addrs, sizes, isDevicePtr}.
  void *addrs[4] = {&yA, &xA, &a, &n};
  uint64_t sizes[4] = {8, 8, 4, 4};
  bool isDev[4] = {true, true, false, false};
  struct {
    void *const *addrs;
    const uint64_t *sizes;
    const bool *isDev;
  } metalArgs = {addrs, sizes, isDev};
  void *packed[1] = {&metalArgs};
  CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
      ctx, fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, 0, packed, 4, NULL));
  CHECK(AsyncRT_DeviceContext_synchronize(ctx));

  CHECK(AsyncRT_DeviceContext_DtoH_async(ctx, hostY, y));
  size_t bad = 0;
  for (int i = 0; i < N; i++) {
    float want = 3.0f * (float)i + 2.0f * (float)i;
    if (hostY[i] != want && bad++ < 3)
      fprintf(stderr, "  wrong at %d: got %f want %f\n", i, hostY[i], want);
  }
  printf("saxpy: %zu/%d wrong\n", bad, N);

  // memset path too.
  CHECK(AsyncRT_DeviceContext_setMemory_async(ctx, y, 0, 4));
  CHECK(AsyncRT_DeviceContext_DtoH_async(ctx, hostY, y));
  for (int i = 0; i < N; i++)
    if (hostY[i] != 0.0f)
      bad++;
  printf("memset: verified zero\n");

  AsyncRT_DeviceFunction_release(fn);
  AsyncRT_DeviceBuffer_release(x);
  AsyncRT_DeviceBuffer_release(y);
  AsyncRT_DeviceContext_release(ctx);
  free(hostX);
  free(hostY);

  if (bad) {
    fprintf(stderr, "SMOKE FAIL: %zu wrong elements\n", bad);
    return 1;
  }
  printf("VEGART METAL SMOKE: ALL PASS\n");
  return 0;
}
