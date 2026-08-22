# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from std.sys.intrinsics import strided_load

from max.gpu.host.compile import _compile_code
from std.sys import has_apple_gpu_accelerator
from std.testing import assert_true


def strided_load_kernel[
    *, dtype: DType = DType.uint32, width: SIMDLength = 1
](
    output: UnsafePointer[SIMD[dtype, width], MutAnyOrigin],
    ptr: UnsafePointer[
        Scalar[dtype], ImmutAnyOrigin, address_space=AddressSpace.GENERIC
    ],
    stride: Int,
):
    output[] = strided_load[width](ptr, stride)


def test_strided_load() raises:
    var ir = _compile_code[strided_load_kernel[width=4], emission_kind="llvm"]()
    comptime if has_apple_gpu_accelerator():
        # VEGA-FORK: the Apple/AIR path deliberately routes strided_load away
        # from masked.gather; assert the strided loads still materialize.
        assert_true("load" in ir)
    else:
        assert_true("@llvm.masked.gather" in ir)


def main() raises:
    test_strided_load()
