#include <torch/torch.h>
#include <torch/cuda.h>
#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/native/cuda/foreach/Utils.cuh>

namespace at { namespace native {

namespace {

template<typename T, typename U, typename... ArgTypes>
C10_LAUNCH_BOUNDS_1(BLOCK_SIZE)
__global__ void 
multi_tensor_apply_kernel(
    T tensorListMeta,
    U callable,
    ArgTypes... args) {
  // Hand the chunk information to the user-supplied functor to process however it likes.
  callable(CHUNK_SIZE, tensorListMeta, args...); 
}

template<int depth, typename T, typename... ArgTypes>
void multi_tensor_apply(
    std::vector<std::vector<at::Tensor>>& tensor_lists,
    T callable,
    ArgTypes... args) {
        int n_tensors = tensor_lists[0].size();
        TensorListMetadata<depth> tensorListMeta;
    
        int loc_block_info = 0;
        int loc_tensor_info = 0;
        for(int t = 0; t < n_tensors; t++) {
            tensorListMeta.sizes[loc_tensor_info] = tensor_lists[0][t].numel();
            for (int d = 0; d < depth; d++) {
                tensorListMeta.addresses[d][loc_tensor_info] = tensor_lists[d][t].data_ptr();
            }
            loc_tensor_info++;

            int chunks = (tensor_lists[0][t].numel() + CHUNK_SIZE - 1)/CHUNK_SIZE;
            for (int chunk = 0; chunk < chunks; chunk++) {
                tensorListMeta.block_to_tensor[loc_block_info] = loc_tensor_info - 1;
                tensorListMeta.block_to_chunk[loc_block_info] = chunk;
                loc_block_info++;

                bool tensors_full = (loc_tensor_info == depth_to_max_tensors[depth-1] &&
                    chunk == chunks - 1);
                bool blocks_full = (loc_block_info == depth_to_max_blocks[depth-1]);
                bool last_chunk = (t == n_tensors - 1 && chunk == chunks - 1);
    
                if (tensors_full || blocks_full || last_chunk) {
                    multi_tensor_apply_kernel<<<loc_block_info, BLOCK_SIZE, 0, at::cuda::getCurrentCUDAStream()>>>(
                        tensorListMeta,
                        callable,
                        args...);
                  
                    AT_CUDA_CHECK(cudaGetLastError());
    
                    // Reset.
                    loc_block_info = 0;
                    if(chunk == chunks - 1) {
                        loc_tensor_info = 0; 
                    }
                    else {
                        tensorListMeta.sizes[0] = tensorListMeta.sizes[loc_tensor_info-1];
                        for(int d = 0; d < depth; d++) {
                            tensorListMeta.addresses[d][0] = tensorListMeta.addresses[d][loc_tensor_info-1];
                        }
                        loc_tensor_info = 1;
                    }
                }
            }
        }
    }
} // namespace
}} // at::native