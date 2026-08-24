# AsyncRT_* C ABI — signatures recovered from .mojo call-site comments

AsyncValue *AsyncRT_AsyncValue_createFromDeviceBuffer(
AsyncValue *AsyncRT_AsyncValue_retainBufferStorage(
AsyncValue *AsyncRT_AsyncValue_retainHandle(AnyAsyncValueRef *handle)
DeviceGraphMemoryPool *AsyncRT_DeviceContext_createGraphMemoryPool(
const DeviceContext *AsyncRT_DeviceBuffer_context(const DeviceBuffer *buffer)
const char * AsyncRT_DeviceBuffer_reassignOwnershipTo(const DeviceBuffer *buf, const DeviceContext *ctx)
const char * AsyncRT_DeviceContext_DtoD_async(const DeviceContext *ctx, const DeviceBuffer *dst, const DeviceBuffer *src)
const char * AsyncRT_DeviceContext_DtoD_async_no_cross_stream_sync(const DeviceContext *ctx, const DeviceBuffer *dst, const DeviceBuffer *src)
const char * AsyncRT_DeviceContext_DtoH_async(const DeviceContext *ctx, void *dst, const DeviceBuffer *src)
const char * AsyncRT_DeviceContext_HtoD_async(const DeviceContext *ctx, const DeviceBuffer *dst, const void *src)
const char * AsyncRT_DeviceContext_computeCapability(int32_t *result, const DeviceContext *ctx)
const char * AsyncRT_DeviceContext_enqueue_wait_for_context(const DeviceContext *ctx, const DeviceContext *other)
const char * AsyncRT_DeviceContext_getApiVersion(int *result, const DeviceContext *ctx)
const char * AsyncRT_DeviceContext_getAttribute(int *result, const DeviceContext *ctx, int attr)
const char * AsyncRT_DeviceContext_isCompatible(const DeviceContext *ctx)
const char * AsyncRT_DeviceContext_synchronize(const DeviceContext *ctx)
const char * AsyncRT_DeviceGraph_createBuffer(DeviceBuffer **result, void **devicePtr, DeviceGraphBuilder *builder, size_t len, size_t elemSize, bool isHost)
const char *AsyncRT_DeviceBuffer_createSubBuffer(
const char *AsyncRT_DeviceBuffer_hostPtr(
const char *AsyncRT_DeviceContextScope_create(const DeviceContextScope **result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_allPeerAccessEnabled(bool *result)
const char *AsyncRT_DeviceContext_canAccess(bool *result, const DeviceContext *ctx, const DeviceContext *peer)
const char *AsyncRT_DeviceContext_create(const DeviceContext **result, const char *api, int id)
const char *AsyncRT_DeviceContext_createBuffer_async(const DeviceBuffer **result, void **device_ptr, const DeviceContext *ctx, size_t len, size_t elem_size)
const char *AsyncRT_DeviceContext_createExternalStream(const DeviceStream **stream, void *externalStream, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_createGraphBuilder(
const char *AsyncRT_DeviceContext_createGraphBuilderWithPool(
const char *AsyncRT_DeviceContext_createHostBuffer(const DeviceBuffer **result, void **device_ptr, const DeviceContext *ctx, size_t len, size_t elem_size)
const char *AsyncRT_DeviceContext_createStream(const DeviceStream **stream, int priority, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_cuda_context(CUcontext *result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_cuda_current_context(CUcontext *result)
const char *AsyncRT_DeviceContext_deviceName(const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_enableAllPeerAccess()
const char *AsyncRT_DeviceContext_enablePeerAccess(const DeviceContext *ctx, const DeviceContext *peer)
const char *AsyncRT_DeviceContext_enqueue_event(const DeviceEvent **result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_eventCreate(const DeviceEvent **result, const DeviceContext *ctx, unsigned int flags)
const char *AsyncRT_DeviceContext_getMemoryInfo(const DeviceContext *ctx, size_t *free, size_t *total)
const char *AsyncRT_DeviceContext_hip_device(hipDevice_t *result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_loadFunction(
const char *AsyncRT_DeviceContext_metal_device(MTL::Device **result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_runHealthcheck(DeviceContext *ctx)
const char *AsyncRT_DeviceContext_selectStream(
const char *AsyncRT_DeviceContext_setMemory_async(const DeviceContext *ctx, const DeviceBuffer *dst, uint64_t val, size_t val_size)
const char *AsyncRT_DeviceContext_stream(const DeviceStream **result, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_streamPriorityRange(int *leastPriority, int *greatestPriority, const DeviceContext *ctx)
const char *AsyncRT_DeviceContext_supportsMulticast(bool *result, const DeviceContext *ctx)
const char *AsyncRT_DeviceEvent_synchronize(const DeviceEvent *event)
const char *AsyncRT_DeviceFunction_copyToConstantMemory(
const char *AsyncRT_DeviceFunction_cuda_module(CUmodule *result, const DeviceFunction *func)
const char *AsyncRT_DeviceFunction_getAttribute(int32_t *result, const DeviceFunction *func, int32_t attr_code)
const char *AsyncRT_DeviceFunction_hip_module(hipModule_t *result, const DeviceFunction *func)
const char *AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice(
const char *AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost(
const char *AsyncRT_DeviceGraphBuilder_addCopyHostToDevice(
const char *AsyncRT_DeviceGraphBuilder_addEmpty(
const char *AsyncRT_DeviceGraphBuilder_addSetMemory(
const char *AsyncRT_DeviceGraphBuilder_instantiate(
const char *AsyncRT_DeviceGraphBuilder_recordingContext(
const char *AsyncRT_DeviceGraph_replay(DeviceGraph *graph)
const char *AsyncRT_DeviceStream_cuda_stream(CUstream *result, const DeviceStream *stream)
const char *AsyncRT_DeviceStream_enqueueHostFunc(const DeviceStream *stream, void (*fn)(void *), void *userData)
const char *AsyncRT_DeviceStream_enqueueWaitOnHostValue(
const char *AsyncRT_DeviceStream_eventRecord(const DeviceStream *stream, const DeviceEvent *event)
const char *AsyncRT_DeviceStream_hip_stream(hipStream_t *result, const DeviceStream *stream)
const char *AsyncRT_DeviceStream_synchronize(const DeviceStream *stream)
const char *AsyncRT_DeviceStream_waitForEvent(const DeviceStream *stream, const DeviceEvent *event)
const char *AsyncRT_occupancyMaxActiveBlocksPerMultiprocessor(int *numBlocks, const DeviceContext *ctx, const DeviceFunction *func, int blockSize, size_t dynamicSharedMemSize)
const char* AsyncRT_DeviceMulticastBuffer_allocate(const DeviceMulticastBuffer **result, size_t ctxsLen, const DeviceContext **ctxs, size_t len, size_t elemSize)
const char* AsyncRT_DeviceMulticastBuffer_multicastBufferFor(const DeviceBuffer **result, void **devicePtr, const DeviceMulticastBuffer *multiBuffer, const DeviceContext* ctx)
const char* AsyncRT_DeviceMulticastBuffer_unicastBufferFor(const DeviceBuffer **result, void **devicePtr, const DeviceMulticastBuffer *multiBuffer, const DeviceContext* ctx)
int AsyncRT_DeviceContext_numStreams(const DeviceContext *ctx)
int32_t *AsyncRT_DeviceContext_numberOfDevices(const char* kind)
int32_t AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(
int64_t AsyncRT_DeviceBuffer_bytesize(const DeviceBuffer *buffer)
int64_t AsyncRT_DeviceContext_id(const DeviceContext *ctx)
int64_t AsyncRT_DeviceGraphBuilder_numInputs(
int64_t AsyncRT_DeviceGraphBuilder_numOutputs(
uint64_t AsyncRT_CompletionFlag_devicePtr(const CompletionFlag *flag)
void AsyncRT_AsyncValue_release(AsyncValue *value)
void AsyncRT_AsyncValue_retain(AsyncValue *value)
void AsyncRT_DeviceBuffer_release(const DeviceBuffer *buffer)
void AsyncRT_DeviceBuffer_release_ptr(const DeviceBuffer *buffer)
void AsyncRT_DeviceBuffer_retain(const DeviceBuffer *buffer)
void AsyncRT_DeviceContextScope_release(const DeviceContextScope *scope)
void AsyncRT_DeviceContext_createBuffer_owning(
void AsyncRT_DeviceContext_deviceApi(llvm::StringRef *result, const DeviceContext *ctx)
void AsyncRT_DeviceContext_release(const DeviceContext *ctx)
void AsyncRT_DeviceContext_retain(const DeviceContext *ctx)
void AsyncRT_DeviceContext_strfree(const char* ptr)
void AsyncRT_DeviceEvent_release(const DeviceEvent *event)
void AsyncRT_DeviceFunction_release(const DeviceFunction *ctx)
void AsyncRT_DeviceFunction_retain(const DeviceFunction *ctx)
void AsyncRT_DeviceGraphBuilder_addInPlaceInput(
void AsyncRT_DeviceGraphBuilder_addInput(
void AsyncRT_DeviceGraphBuilder_addOutput(
void AsyncRT_DeviceGraphBuilder_release(DeviceGraphBuilder *builder)
void AsyncRT_DeviceGraphMemoryPool_release(DeviceGraphMemoryPool *pool)
void AsyncRT_DeviceGraphMemoryPool_retain(DeviceGraphMemoryPool *pool)
void AsyncRT_DeviceGraph_release(DeviceGraph *graph)
void AsyncRT_DeviceGraph_retain(DeviceGraph *graph)
void AsyncRT_DeviceStream_release(const DeviceStream *stream)
void AsyncRT_DeviceStream_retain(const DeviceStream *stream)
void AsyncRT_DeviceTimer_release(const DviceTimer *timer)

# Capability table

<!-- GENERATED by tools/check-abi-symbols.py --table; do not edit -->

| symbol | what it does when called | called from Mojo |
|---|---|---|
| `AsyncRT_AndThen` | stub — returns “not implemented” | no |
| `AsyncRT_AsyncValue_createFromDeviceBuffer` | stub — returns 0 | yes |
| `AsyncRT_AsyncValue_release` | stub — no-op | yes |
| `AsyncRT_AsyncValue_retain` | stub — no-op | yes |
| `AsyncRT_AsyncValue_retainBufferStorage` | stub — returns 0 | yes |
| `AsyncRT_AsyncValue_retainHandle` | stub — returns 0 | yes |
| `AsyncRT_CompletionFlag_devicePtr` | stub — returns 0 | yes |
| `AsyncRT_DeviceBuffer_bytesize` | implemented | yes |
| `AsyncRT_DeviceBuffer_context` | implemented | yes |
| `AsyncRT_DeviceBuffer_createSubBuffer` | implemented | yes |
| `AsyncRT_DeviceBuffer_hostPtr` | implemented | yes |
| `AsyncRT_DeviceBuffer_reassignOwnershipTo` | implemented | yes |
| `AsyncRT_DeviceBuffer_release` | implemented | yes |
| `AsyncRT_DeviceBuffer_release_ptr` | implemented | yes |
| `AsyncRT_DeviceBuffer_retain` | implemented | yes |
| `AsyncRT_DeviceContextScope_create` | implemented | yes |
| `AsyncRT_DeviceContextScope_release` | implemented | yes |
| `AsyncRT_DeviceContext_DtoD_async` | implemented | yes |
| `AsyncRT_DeviceContext_DtoD_async_no_cross_stream_sync` | implemented | yes |
| `AsyncRT_DeviceContext_DtoH_async` | implemented | yes |
| `AsyncRT_DeviceContext_DtoH_async_sized` | implemented | yes |
| `AsyncRT_DeviceContext_HtoD_async` | implemented | yes |
| `AsyncRT_DeviceContext_HtoD_async_sized` | implemented | yes |
| `AsyncRT_DeviceContext_allPeerAccessEnabled` | implemented | yes |
| `AsyncRT_DeviceContext_archName` | implemented | yes |
| `AsyncRT_DeviceContext_canAccess` | implemented | yes |
| `AsyncRT_DeviceContext_computeCapability` | implemented | yes |
| `AsyncRT_DeviceContext_create` | implemented | yes |
| `AsyncRT_DeviceContext_createBuffer_async` | implemented | yes |
| `AsyncRT_DeviceContext_createBuffer_owning` | implemented | yes |
| `AsyncRT_DeviceContext_createExternalStream` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_createGraphBuilder` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_createGraphBuilderWithPool` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_createGraphMemoryPool` | stub — returns 0 | yes |
| `AsyncRT_DeviceContext_createHostBuffer` | implemented | yes |
| `AsyncRT_DeviceContext_createStream` | implemented | yes |
| `AsyncRT_DeviceContext_cuda_context` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_cuda_current_context` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_deviceApi` | implemented | yes |
| `AsyncRT_DeviceContext_deviceName` | implemented | yes |
| `AsyncRT_DeviceContext_enableAllPeerAccess` | implemented | yes |
| `AsyncRT_DeviceContext_enablePeerAccess` | implemented | yes |
| `AsyncRT_DeviceContext_enqueueFunctionDirect` | implemented | yes |
| `AsyncRT_DeviceContext_enqueueHostFunction` | implemented | yes |
| `AsyncRT_DeviceContext_enqueueHostFunctionRange` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_enqueue_event` | implemented | yes |
| `AsyncRT_DeviceContext_enqueue_wait_for_context` | implemented | yes |
| `AsyncRT_DeviceContext_eventCreate` | implemented | yes |
| `AsyncRT_DeviceContext_getApiVersion` | implemented | yes |
| `AsyncRT_DeviceContext_getAttribute` | implemented | yes |
| `AsyncRT_DeviceContext_getMemoryInfo` | implemented | yes |
| `AsyncRT_DeviceContext_hip_device` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_id` | implemented | yes |
| `AsyncRT_DeviceContext_isCompatible` | implemented | yes |
| `AsyncRT_DeviceContext_loadFunction` | implemented | yes |
| `AsyncRT_DeviceContext_maxSingleAllocationSize` | implemented | yes |
| `AsyncRT_DeviceContext_metal_device` | implemented | yes |
| `AsyncRT_DeviceContext_numStreams` | implemented | yes |
| `AsyncRT_DeviceContext_numberOfDevices` | implemented | yes |
| `AsyncRT_DeviceContext_release` | implemented | yes |
| `AsyncRT_DeviceContext_retain` | implemented | yes |
| `AsyncRT_DeviceContext_runHealthcheck` | implemented | yes |
| `AsyncRT_DeviceContext_selectStream` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_setAsCurrent` | implemented | yes |
| `AsyncRT_DeviceContext_setMemory_async` | implemented | yes |
| `AsyncRT_DeviceContext_setMetalPrintEnabled` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_startMetalTraceCapture` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_startTimer` | implemented | yes |
| `AsyncRT_DeviceContext_stopMetalTraceCapture` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceContext_stopTimer` | implemented | yes |
| `AsyncRT_DeviceContext_stream` | implemented | yes |
| `AsyncRT_DeviceContext_streamPriorityRange` | implemented | yes |
| `AsyncRT_DeviceContext_strfree` | implemented | yes |
| `AsyncRT_DeviceContext_supportsMulticast` | implemented | yes |
| `AsyncRT_DeviceContext_synchronize` | implemented | yes |
| `AsyncRT_DeviceEvent_release` | implemented | yes |
| `AsyncRT_DeviceEvent_retain` | implemented | yes |
| `AsyncRT_DeviceEvent_synchronize` | implemented | yes |
| `AsyncRT_DeviceFunction_copyToConstantMemory` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceFunction_cuda_module` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceFunction_getAttribute` | implemented | yes |
| `AsyncRT_DeviceFunction_hip_module` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceFunction_release` | implemented | yes |
| `AsyncRT_DeviceFunction_retain` | implemented | yes |
| `AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_addCopyHostToDevice` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_addEmpty` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_addFunction` | stub — returns “not implemented” | no |
| `AsyncRT_DeviceGraphBuilder_addFunctionDirect` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_addInPlaceInput` | stub — no-op | yes |
| `AsyncRT_DeviceGraphBuilder_addInput` | stub — no-op | yes |
| `AsyncRT_DeviceGraphBuilder_addOutput` | stub — no-op | yes |
| `AsyncRT_DeviceGraphBuilder_addSetMemory` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_instantiate` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone` | stub — returns 0 | yes |
| `AsyncRT_DeviceGraphBuilder_numInputs` | stub — returns 0 | yes |
| `AsyncRT_DeviceGraphBuilder_numOutputs` | stub — returns 0 | yes |
| `AsyncRT_DeviceGraphBuilder_recordingContext` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraphBuilder_release` | stub — no-op | yes |
| `AsyncRT_DeviceGraphMemoryPool_release` | stub — no-op | yes |
| `AsyncRT_DeviceGraphMemoryPool_retain` | stub — no-op | yes |
| `AsyncRT_DeviceGraph_createBuffer` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraph_release` | stub — no-op | yes |
| `AsyncRT_DeviceGraph_replay` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceGraph_retain` | stub — no-op | yes |
| `AsyncRT_DeviceMulticastBuffer_allocate` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceMulticastBuffer_multicastBufferFor` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceMulticastBuffer_release` | stub — no-op | no |
| `AsyncRT_DeviceMulticastBuffer_retain` | stub — no-op | no |
| `AsyncRT_DeviceMulticastBuffer_unicastBufferFor` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceStream_cuda_stream` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceStream_enqueueFunctionDirect` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceStream_enqueueHostFunc` | implemented | yes |
| `AsyncRT_DeviceStream_enqueueWaitOnHostValue` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceStream_eventRecord` | implemented | yes |
| `AsyncRT_DeviceStream_hip_stream` | stub — returns “not implemented” | yes |
| `AsyncRT_DeviceStream_release` | implemented | yes |
| `AsyncRT_DeviceStream_retain` | implemented | yes |
| `AsyncRT_DeviceStream_synchronize` | implemented | yes |
| `AsyncRT_DeviceStream_waitForEvent` | implemented | yes |
| `AsyncRT_DeviceTimer_release` | implemented | yes |
| `AsyncRT_cuda_tensorMapEncodeIm2col` | stub — returns “not implemented” | yes |
| `AsyncRT_cuda_tensorMapEncodeTiled` | stub — returns “not implemented” | yes |
| `AsyncRT_occupancyMaxActiveBlocksPerMultiprocessor` | stub — returns “not implemented” | yes |

69 implemented, 56 stubbed or missing, of 125 symbols across both directions.
