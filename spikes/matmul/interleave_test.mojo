from std.gpu import global_idx
from max.gpu.host import DeviceContext

def k(o: Pointer[Float32, MutAnyOrigin], a: Pointer[Float32, MutAnyOrigin]):
    var i = Int(global_idx.x)
    var x = SIMD[DType.float32, 4](a[unsafe_offset=i*4], a[unsafe_offset=i*4+1], a[unsafe_offset=i*4+2], a[unsafe_offset=i*4+3])
    var y = x + 100.0
    var z = x.interleave(y)          # -> llvm.vector.interleave2
    for j in range(8):
        o[unsafe_offset = i*8 + j] = z[j]

def main() raises:
    var ctx = DeviceContext(api="metal")
    var a = ctx.enqueue_create_buffer[DType.float32](16)
    var o = ctx.enqueue_create_buffer[DType.float32](32)
    with a.map_to_host() as ah:
        for i in range(16): ah[i] = Float32(i)
    var f = ctx.compile_function[k]()
    ctx.enqueue_function(f, o, a, grid_dim=(1), block_dim=(4))
    ctx.synchronize()
    with o.map_to_host() as oh:
        print("interleave[0..3]:", oh[0], oh[1], oh[2], oh[3])
        var ok = oh[0] == 0.0 and oh[1] == 100.0 and oh[2] == 1.0 and oh[3] == 101.0
        print("INTERLEAVE: PASS" if ok else "INTERLEAVE: FAIL")
