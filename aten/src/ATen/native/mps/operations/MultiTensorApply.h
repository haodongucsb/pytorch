#pragma once
#include <ATen/core/Tensor.h>
#include <ATen/mps/MPSProfiler.h>
#include <ATen/native/mps/operations/FusedOptimizerOps.h>

namespace at::native {
namespace mps {

static constexpr int64_t kChunkSize = 65536;
static constexpr int64_t kmaxThreadGroups = 32;
static constexpr int64_t kmaxTensors = 32;

struct MetadataArguments { // the size of this struct must be less than 4 bytes
  uint numels[kmaxTensors];
  uint threadgroup_to_tensor[kmaxThreadGroups];
  uint threadgroup_to_chunk[kmaxThreadGroups];
};

template <int depth, uint32_t kThreadGroupSize>
static void multi_tensor_apply_for_fused_adam(
    const std::string& kernel_name,
    std::vector<std::vector<at::Tensor>>& tensor_lists,
    at::TensorList state_steps,
    const double lr,
    const double beta1,
    const double beta2,
    const double weight_decay,
    const double eps,
    const bool maximize
    ) {
  const auto num_tensors = tensor_lists[0].size();

  if (num_tensors == 0) {
    return;
  }

  TORCH_CHECK(
      tensor_lists.size() == depth,
      "Number of tensor lists has to match the depth");
  for (const auto& d : c10::irange(depth)) {
    TORCH_CHECK(
      tensor_lists[d][0].scalar_type() == at::ScalarType::Float || tensor_lists[d][0].scalar_type() == at::ScalarType::Half, "Only float and half are supported");
  }

  id<MTLDevice> device = MPSDevice::getInstance()->device();
  MPSStream* mpsStream = getCurrentMPSStream();

  float lr_lv = lr;
  float beta1_lv = beta1;
  float beta2_lv = beta2;
  float weight_decay_lv = weight_decay;
  float eps_lv = eps;
  uint8_t maximize_lv = maximize;

  // Remove comment for debugging
  /*
  mpsStream->addCompletedHandler(^(id<MTLCommandBuffer> cb) {
    [cb.logs enumerateObjectsUsingBlock:^(NSString* log, NSUInteger idx, BOOL* stop) {
      NSLog(@"MPSStream: %@", log);
      }
    ];
  });
  */

  dispatch_sync_with_rethrow(mpsStream->queue(), ^() {
    @autoreleasepool {
      id<MTLComputeCommandEncoder> computeEncoder = mpsStream->commandEncoder();
      auto [fusedOptimizerPSO, fusedOptimizerFunc] = getCPLState(kernel_name);

      // this function call is a no-op if MPS Profiler is not enabled
      getMPSProfiler().beginProfileKernel(fusedOptimizerPSO, kernel_name, {tensor_lists[0]});

      [computeEncoder setComputePipelineState:fusedOptimizerPSO];

      // BufferIndex is the index in the kernel function
      auto tensorArgumentEncoder = [[fusedOptimizerFunc newArgumentEncoderWithBufferIndex:0] autorelease];
      id<MTLBuffer> tensorArgumentBuffer = [[device newBufferWithLength:tensorArgumentEncoder.encodedLength options:0] autorelease];
      [tensorArgumentEncoder setArgumentBuffer:tensorArgumentBuffer offset:0];

      int64_t tensor_loc = 0;
      int64_t threadgroup_loc = 0;
      MetadataArguments metadata_arguments;

      for (const auto tensor_index : c10::irange(num_tensors)) {
        // short-circuit to avoid adding empty tensors to tensorListMeta
        if (tensor_lists[0][tensor_index].numel() == 0) {
          continue;
        }

        for (const auto& d : c10::irange(depth)) {
            [tensorArgumentEncoder setBuffer:getMTLBufferStorage(tensor_lists[d][tensor_index])
                                      offset:tensor_lists[d][tensor_index].storage_offset() * tensor_lists[d][tensor_index].element_size()
                                     atIndex:d * kmaxTensors + tensor_loc];
            [computeEncoder useResource:getMTLBufferStorage(tensor_lists[d][tensor_index]) usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        }
        [tensorArgumentEncoder setBuffer:getMTLBufferStorage(state_steps[tensor_index])
                           offset:state_steps[tensor_index].storage_offset() * state_steps[tensor_index].element_size()
                          atIndex:depth * kmaxTensors + tensor_loc];
        [computeEncoder useResource:getMTLBufferStorage(state_steps[tensor_index]) usage:MTLResourceUsageRead];
        metadata_arguments.numels[tensor_loc] = tensor_lists[0][tensor_index].numel();

        tensor_loc++;

        const auto numel = tensor_lists[0][tensor_index].numel();
        const auto chunks = numel / kChunkSize + (numel % kChunkSize != 0);
        TORCH_CHECK(chunks > -1);

        for (const auto& chunk : c10::irange(chunks)) {
            metadata_arguments.threadgroup_to_tensor[threadgroup_loc] = tensor_loc - 1;
            metadata_arguments.threadgroup_to_chunk[threadgroup_loc] = chunk;

            threadgroup_loc++;

            const auto tensor_full = tensor_loc == kmaxTensors && chunk == chunks - 1;
            // Reach the maximum threadgroups per dispatch
            const auto blocks_full = threadgroup_loc == kmaxThreadGroups;

            if (tensor_full || blocks_full){
                [computeEncoder setBuffer:tensorArgumentBuffer
                                offset:0
                                atIndex:0];
                [computeEncoder setBytes:&metadata_arguments
                                length:sizeof(MetadataArguments)
                                atIndex:1];
                [computeEncoder  setBytes:&lr_lv length:sizeof(float) atIndex:2];
                [computeEncoder  setBytes:&beta1_lv length:sizeof(float) atIndex:3];
                [computeEncoder  setBytes:&beta2_lv length:sizeof(float) atIndex:4];
                [computeEncoder  setBytes:&weight_decay_lv length:sizeof(float) atIndex:5];
                [computeEncoder  setBytes:&eps_lv length:sizeof(float) atIndex:6];
                [computeEncoder  setBytes:&maximize_lv length:sizeof(uint8_t) atIndex:7];
                MTLSize gridSize = MTLSizeMake(threadgroup_loc, 1, 1);
                uint32_t maxThreadsPerGroup = [fusedOptimizerPSO maxTotalThreadsPerThreadgroup];
                MTLSize threadGroupSize = MTLSizeMake(std::min(maxThreadsPerGroup, kThreadGroupSize), 1, 1);
                [computeEncoder dispatchThreadgroups:gridSize threadsPerThreadgroup:threadGroupSize];

                // Reset
                threadgroup_loc = 0;
                if (chunk == chunks - 1) {
                  // last chunk
                  tensor_loc = 0;
                  tensorArgumentBuffer = [[device newBufferWithLength:tensorArgumentEncoder.encodedLength options:0] autorelease];
                  [tensorArgumentEncoder setArgumentBuffer:tensorArgumentBuffer offset:0];
                } else {
                  // reuse the current tensor since the current one isn't done.
                  metadata_arguments.numels[0] = metadata_arguments.numels[tensor_loc - 1];

                  tensorArgumentBuffer = [[device newBufferWithLength:tensorArgumentEncoder.encodedLength options:0] autorelease];
                  [tensorArgumentEncoder setArgumentBuffer:tensorArgumentBuffer offset:0];

                  for (const auto& d : c10::irange(depth)) {
                      [tensorArgumentEncoder setBuffer:getMTLBufferStorage(tensor_lists[d][tensor_index])
                                                offset:tensor_lists[d][tensor_index].storage_offset() * tensor_lists[d][tensor_index].element_size()
                                              atIndex:d * kmaxTensors + 0];
                      [computeEncoder useResource:getMTLBufferStorage(tensor_lists[d][tensor_index]) usage:MTLResourceUsageWrite | MTLResourceUsageRead];
                  }
                  [tensorArgumentEncoder setBuffer:getMTLBufferStorage(state_steps[tensor_index])
                                    offset:state_steps[tensor_index].storage_offset() * state_steps[tensor_index].element_size()
                                    atIndex:depth * kmaxTensors + 0];
                  [computeEncoder useResource:getMTLBufferStorage(state_steps[tensor_index]) usage:MTLResourceUsageRead];

                  tensor_loc = 1;
                }
            }
        }
      }

      if (threadgroup_loc != 0) {

        [computeEncoder setBuffer:tensorArgumentBuffer offset:0 atIndex:0];
        [computeEncoder setBytes:&metadata_arguments length:sizeof(MetadataArguments) atIndex:1];
        [computeEncoder setBytes:&lr_lv length:sizeof(float) atIndex:2];
        [computeEncoder setBytes:&beta1_lv length:sizeof(float) atIndex:3];
        [computeEncoder setBytes:&beta2_lv length:sizeof(float) atIndex:4];
        [computeEncoder setBytes:&weight_decay_lv length:sizeof(float) atIndex:5];
        [computeEncoder setBytes:&eps_lv length:sizeof(float) atIndex:6];
        [computeEncoder setBytes:&maximize_lv length:sizeof(uint8_t) atIndex:7];
        MTLSize gridSize = MTLSizeMake(threadgroup_loc, 1, 1);
        uint32_t maxThreadsPerGroup = [fusedOptimizerPSO maxTotalThreadsPerThreadgroup];
        MTLSize threadGroupSize = MTLSizeMake(std::min(maxThreadsPerGroup, kThreadGroupSize), 1, 1);
        [computeEncoder dispatchThreadgroups:gridSize threadsPerThreadgroup:threadGroupSize];
      }

      getMPSProfiler().endProfileKernel(fusedOptimizerPSO);

    }
  });
}

} // namespace mps
} // namespace at::native
