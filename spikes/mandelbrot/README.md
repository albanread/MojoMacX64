# Cocoa Mandelbrot

![Mojo Mandelbrot running on the Radeon Pro Vega II](mandelbrot.png)

*Live on the 2019 Intel Mac Pro: seahorse valley at 60fps, every pixel and
every colour computed by a Mojo kernel on the AMD Radeon Pro Vega II through
this fork's AIR backend — no shader anywhere in the pipeline.*

A native macOS app written entirely in Mojo — the Mac answer to the Windows
Direct3D mandelbrot. Every pixel is computed by a Mojo kernel on the AMD Radeon
Pro Vega II (through this fork's AIR backend); the frame is handed to a
`CAMetalLayer` and presented at 60fps.

```
vega-sdk/bin/mojo build --target-accelerator=metal-vega2 -o mandel spikes/mandelbrot/mandelbrot.mojo
./mandel
```

It prints the CPU-vs-GPU timing, then opens a live-zooming window:

```
Mandelbrot 1024 x 768 , 256 iterations
  CPU: 149.8 ms
  GPU: AMD Radeon Pro Vega II (Apple Metal)
  GPU: 0.40 ms  ( 374.5 x faster )
Rendering. Close the window to quit.
  frame 120 — 60.3 fps
```

Nothing here uses a hand-rolled Objective-C binding. `NSApplication`,
`NSWindow`, `NSView`, `CAMetalLayer` and `CAMetalDrawable` are all driven
through `std.objc`, with every selector, dispatch stub, argument count and
register file checked at compile time against the SDK database — and the Metal
protocol objects (`id<MTLTexture>`, `id<MTLCommandQueue>`, …) through the
selector-keyed `std.objc.send`.

The pieces, each also a standalone spike:
- `window_smoke.mojo` — NSWindow + AppKit event loop from Mojo
- `compute_smoke.mojo` — CPU vs GPU mandelbrot, timed and cross-checked
- `mandelbrot.mojo` — the full app
