//===----------------------------------------------------------------------===//
// S1 — Metal smoke test on the Radeon Pro Vega II (PORT_DESIGN.md §8).
//
// Answers, per device:
//   - identity: name, VRAM, unified memory, location, peer group
//   - GPU family support (Mac2 / Common3 / Metal3 / Apple7)
//   - highest MSL language version the runtime compiler accepts
//   - threadExecutionWidth (API) AND empirical SIMD-group width
//   - SIMD-group ops: sum, ballot, shuffle_xor — compiled and executed
//   - simdgroup_matrix / bfloat / double availability (expect: no on GCN)
//   - correctness: vector add, verified element by element
//   - bandwidth: on-device copy kernel (HBM2) and blit HtoD (PCIe)
//   - optional: load a prebuilt .metallib passed as argv[1] (S4 preview)
//
// Build:  clang -fobjc-arc -framework Metal -framework Foundation \
//             -o s1 s1_metal_smoke.m
// Run:    ./s1 [kernels.metallib]
//===----------------------------------------------------------------------===//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

// Kernels compiled at runtime. Baseline MSL only — feature probes are separate
// sources so one unsupported feature cannot take down the main library.
static NSString *const kMainSrc = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void vadd(device const float *a [[buffer(0)]],\n"
"                 device const float *b [[buffer(1)]],\n"
"                 device float *c [[buffer(2)]],\n"
"                 uint id [[thread_position_in_grid]]) {\n"
"  c[id] = a[id] + b[id];\n"
"}\n"
"kernel void simdprobe(device uint *out [[buffer(0)]],\n"
"                      uint tps  [[threads_per_simdgroup]],\n"
"                      uint lane [[thread_index_in_simdgroup]],\n"
"                      uint sg   [[simdgroup_index_in_threadgroup]]) {\n"
"  uint s = simd_sum(1u);\n"
"  simd_vote v = simd_ballot(true);\n"
"  uint64_t bits = (simd_vote::vote_t)v;\n"
"  uint pop = 0;\n"
"  for (int i = 0; i < 64; i++) pop += (uint)((bits >> i) & 1);\n"
"  uint x = simd_shuffle_xor(lane, 1u);\n"
"  bool ok = simd_all(x == (lane ^ 1u));\n"
"  if (sg == 0 && lane == 0) {\n"
"    out[0] = tps;      // attribute value\n"
"    out[1] = s;        // simd_sum(1) == active width\n"
"    out[2] = pop;      // ballot popcount == active width\n"
"    out[3] = ok ? 1u : 0u;\n"
"  }\n"
"}\n"
"kernel void bwcopy(device const float4 *src [[buffer(0)]],\n"
"                   device float4 *dst [[buffer(1)]],\n"
"                   uint id [[thread_position_in_grid]]) {\n"
"  dst[id] = src[id];\n"
"}\n";

static NSString *const kMatrixSrc = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void mm(device const float *a [[buffer(0)]],\n"
"               device float *c [[buffer(1)]]) {\n"
"  simdgroup_float8x8 A;\n"
"  simdgroup_load(A, a, 8);\n"
"  simdgroup_float8x8 C;\n"
"  simdgroup_multiply(C, A, A);\n"
"  simdgroup_store(C, c, 8);\n"
"}\n";

static NSString *const kBfloatSrc = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void bf(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {\n"
"  bfloat b = bfloat(o[id]);\n"
"  o[id] = float(b) * 2.0f;\n"
"}\n";

static NSString *const kDoubleSrc = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void dp(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {\n"
"  double d = (double)o[id];\n"
"  o[id] = (float)(d * 2.0);\n"
"}\n";

static NSString *firstLine(NSString *s) {
  NSRange r = [s rangeOfString:@"\n"];
  return r.location == NSNotFound ? s : [s substringToIndex:r.location];
}

// Compile source; on success optionally build a pipeline for `fn`.
// Returns a status string for the report.
static NSString *tryFeature(id<MTLDevice> dev, NSString *src, NSString *fn,
                            MTLLanguageVersion ver) {
  NSError *err = nil;
  MTLCompileOptions *opts = [MTLCompileOptions new];
  if (ver) opts.languageVersion = ver;
  id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&err];
  if (!lib)
    return [NSString stringWithFormat:@"NO  (compile: %@)",
            firstLine(err.localizedDescription ?: @"?")];
  id<MTLFunction> f = [lib newFunctionWithName:fn];
  if (!f) return @"NO  (function missing after compile)";
  id<MTLComputePipelineState> ps =
      [dev newComputePipelineStateWithFunction:f error:&err];
  if (!ps)
    return [NSString stringWithFormat:@"NO  (pipeline: %@)",
            firstLine(err.localizedDescription ?: @"?")];
  return @"YES";
}

static double gpuSeconds(id<MTLCommandBuffer> cb) {
  return cb.GPUEndTime - cb.GPUStartTime;
}

static void probeDevice(id<MTLDevice> dev, NSString *metallibPath) {
  printf("\n================================================================\n");
  printf("DEVICE: %s\n", dev.name.UTF8String);
  printf("================================================================\n");
  printf("  registryID              : 0x%llx\n", dev.registryID);
  printf("  hasUnifiedMemory        : %s\n", dev.hasUnifiedMemory ? "yes" : "NO (discrete)");
  printf("  recommendedMaxWorkingSet: %.1f GiB\n",
         dev.recommendedMaxWorkingSetSize / 1073741824.0);
  printf("  maxBufferLength         : %.1f GiB\n",
         dev.maxBufferLength / 1073741824.0);
  printf("  maxThreadgroupMemory    : %lu KiB\n",
         (unsigned long)(dev.maxThreadgroupMemoryLength / 1024));
  printf("  maxThreadsPerThreadgroup: %lu x %lu x %lu\n",
         (unsigned long)dev.maxThreadsPerThreadgroup.width,
         (unsigned long)dev.maxThreadsPerThreadgroup.height,
         (unsigned long)dev.maxThreadsPerThreadgroup.depth);
  printf("  location                : %lu (num %lu)  removable=%s lowPower=%s\n",
         (unsigned long)dev.location, (unsigned long)dev.locationNumber,
         dev.removable ? "y" : "n", dev.lowPower ? "y" : "n");
  printf("  peerGroupID/index/count : %llu / %u / %u\n",
         dev.peerGroupID, dev.peerIndex, dev.peerCount);
  if (dev.maxTransferRate > 0)
    printf("  maxTransferRate         : %.2f GB/s\n", dev.maxTransferRate / 1e9);

  // --- GPU families (numeric so this builds on any SDK) ---
  struct { const char *name; NSInteger val; } fams[] = {
    {"Common3", 3003}, {"Mac2", 2002}, {"Metal3", 5001},
    {"Apple7 (simdgroup_matrix tier)", 1007},
  };
  printf("  families                : ");
  for (unsigned i = 0; i < sizeof(fams)/sizeof(fams[0]); i++)
    printf("%s=%s  ", fams[i].name,
           [dev supportsFamily:(MTLGPUFamily)fams[i].val] ? "yes" : "no");
  printf("\n");

  // --- highest accepted MSL version ---
  struct { const char *label; int maj, min; } vers[] = {
    {"3.2", 3, 2}, {"3.1", 3, 1}, {"3.0", 3, 0}, {"2.4", 2, 4},
  };
  MTLLanguageVersion bf16ver = 0;
  printf("  MSL accepted            : ");
  for (unsigned i = 0; i < sizeof(vers)/sizeof(vers[0]); i++) {
    MTLLanguageVersion v = (MTLLanguageVersion)((vers[i].maj << 16) + vers[i].min);
    NSError *err = nil;
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.languageVersion = v;
    id<MTLLibrary> l = [dev newLibraryWithSource:@"kernel void k(){}"
                                         options:o error:&err];
    printf("%s=%s ", vers[i].label, l ? "yes" : "no");
    if (l && vers[i].maj == 3 && vers[i].min >= 1 && !bf16ver) bf16ver = v;
  }
  printf("\n");

  // --- main library ---
  NSError *err = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:kMainSrc options:nil error:&err];
  if (!lib) {
    printf("  [FAIL] main library compile: %s\n",
           err.localizedDescription.UTF8String);
    return;
  }
  id<MTLCommandQueue> q = [dev newCommandQueue];

  id<MTLComputePipelineState> (^pipe)(NSString *) = ^(NSString *name) {
    NSError *e = nil;
    id<MTLFunction> f = [lib newFunctionWithName:name];
    id<MTLComputePipelineState> p =
        f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
    if (!p) printf("  [FAIL] pipeline %s: %s\n", name.UTF8String,
                   e.localizedDescription.UTF8String);
    return p;
  };

  // --- threadExecutionWidth + empirical SIMD width ---
  id<MTLComputePipelineState> sp = pipe(@"simdprobe");
  if (sp) {
    printf("  threadExecutionWidth    : %lu (API, simdprobe)\n",
           (unsigned long)sp.threadExecutionWidth);
    printf("  maxTotalThreadsPerTG    : %lu\n",
           (unsigned long)sp.maxTotalThreadsPerThreadgroup);
    id<MTLBuffer> out = [dev newBufferWithLength:4 * sizeof(uint32_t)
                                         options:MTLResourceStorageModeShared];
    memset(out.contents, 0, 16);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:sp];
    [e setBuffer:out offset:0 atIndex:0];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusCompleted) {
      uint32_t *r = out.contents;
      printf("  SIMD width (empirical)  : threads_per_simdgroup=%u  simd_sum=%u"
             "  ballot_popcount=%u  shuffle_xor=%s\n",
             r[0], r[1], r[2], r[3] ? "OK" : "BROKEN");
    } else {
      printf("  [FAIL] simdprobe exec: %s\n",
             cb.error.localizedDescription.UTF8String);
    }
  }

  // --- vector add, verified ---
  id<MTLComputePipelineState> vp = pipe(@"vadd");
  if (vp) {
    const size_t n = 1u << 20;
    id<MTLBuffer> a = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> c = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    float *fa = a.contents, *fb = b.contents;
    for (size_t i = 0; i < n; i++) { fa[i] = (float)i; fb[i] = 2.0f * i; }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:vp];
    [e setBuffer:a offset:0 atIndex:0];
    [e setBuffer:b offset:0 atIndex:1];
    [e setBuffer:c offset:0 atIndex:2];
    [e dispatchThreadgroups:MTLSizeMake(n / 256, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    size_t bad = 0;
    float *fc = c.contents;
    for (size_t i = 0; i < n; i++)
      if (fc[i] != 3.0f * i) bad++;
    printf("  vadd correctness        : %s (%zu/%zu wrong, %.3f ms GPU)\n",
           bad ? "FAIL" : "PASS", bad, n, gpuSeconds(cb) * 1e3);
  }

  // --- feature probes ---
  printf("  simdgroup_matrix        : %s\n",
         tryFeature(dev, kMatrixSrc, @"mm", 0).UTF8String);
  printf("  bfloat (MSL>=3.1)       : %s\n",
         bf16ver ? tryFeature(dev, kBfloatSrc, @"bf", bf16ver).UTF8String
                 : "NO  (runtime rejects MSL 3.1)");
  printf("  double                  : %s\n",
         tryFeature(dev, kDoubleSrc, @"dp", 0).UTF8String);

  // --- bandwidth: on-device copy (private<->private) ---
  id<MTLComputePipelineState> bp = pipe(@"bwcopy");
  if (bp) {
    const size_t bytes = 512u << 20; // 512 MiB per buffer
    id<MTLBuffer> src = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    id<MTLBuffer> dst = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    if (src && dst) {
      double best = 0;
      for (int iter = 0; iter < 4; iter++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:bp];
        [e setBuffer:src offset:0 atIndex:0];
        [e setBuffer:dst offset:0 atIndex:1];
        [e dispatchThreadgroups:MTLSizeMake(bytes / 16 / 256, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        double t = gpuSeconds(cb);
        double gbps = (2.0 * bytes / t) / 1e9; // read + write
        if (iter > 0 && gbps > best) best = gbps; // skip warmup
      }
      printf("  VRAM copy bandwidth     : %.0f GB/s (kernel r+w, 512 MiB)\n", best);
    }

    // --- blit HtoD (shared -> private): the PCIe path ---
    id<MTLBuffer> host = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (host && dst) {
      double best = 0;
      for (int iter = 0; iter < 4; iter++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromBuffer:host sourceOffset:0 toBuffer:dst
             destinationOffset:0 size:bytes];
        [bl endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        double t = gpuSeconds(cb);
        double gbps = (bytes / t) / 1e9;
        if (iter > 0 && gbps > best) best = gbps;
      }
      printf("  HtoD blit bandwidth     : %.1f GB/s (shared->private, PCIe)\n", best);
    }
  }

  // --- managed-storage smoke ---
  id<MTLBuffer> m = [dev newBufferWithLength:4096
                                     options:MTLResourceStorageModeManaged];
  if (m) {
    memset(m.contents, 0xAB, 4096);
    [m didModifyRange:NSMakeRange(0, 4096)];
    printf("  managed storage         : OK\n");
  } else {
    printf("  managed storage         : [FAIL] alloc\n");
  }

  // --- optional: prebuilt metallib load (S4 preview) ---
  if (metallibPath) {
    NSError *le = nil;
    id<MTLLibrary> ml = [dev newLibraryWithURL:
        [NSURL fileURLWithPath:metallibPath] error:&le];
    if (!ml) {
      printf("  metallib load           : NO (%s)\n",
             firstLine(le.localizedDescription ?: @"?").UTF8String);
    } else {
      NSString *fn = ml.functionNames.firstObject;
      id<MTLFunction> f = fn ? [ml newFunctionWithName:fn] : nil;
      id<MTLComputePipelineState> p =
          f ? [dev newComputePipelineStateWithFunction:f error:&le] : nil;
      printf("  metallib load           : lib=OK fns=[%s] pipeline=%s\n",
             [ml.functionNames componentsJoinedByString:@","].UTF8String,
             p ? "OK" : firstLine(le.localizedDescription ?: @"?").UTF8String);
    }
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *metallib = argc > 1
        ? [NSString stringWithUTF8String:argv[1]] : nil;
    NSOperatingSystemVersion os =
        [NSProcessInfo processInfo].operatingSystemVersion;
    printf("S1 metal smoke — macOS %ld.%ld.%ld, %s\n",
           (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion,
#if defined(__x86_64__)
           "x86_64"
#else
           "arm64"
#endif
    );
    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    if (devs.count == 0) { printf("[FAIL] no Metal devices\n"); return 1; }
    for (id<MTLDevice> d in devs) probeDevice(d, metallib);
    printf("\ndone.\n");
  }
  return 0;
}
