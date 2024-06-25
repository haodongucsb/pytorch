#include <torch/csrc/distributed/c10d/CUDASymmetricMemory.hpp>

#include <ATen/ceil_div.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDACachingAllocator.h>
#include <c10/cuda/CUDAGuard.h>

#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
#include <c10/cuda/driver_api.h>
#endif

#include <sys/syscall.h>
#include <unistd.h>

namespace {

constexpr size_t signal_pad_size = 2048;
const std::string store_comm_prefix = "CUDASymmetricMemory";

static size_t store_comm_seq_id = 0;

template <typename T>
std::vector<T> store_all_gather(
    const c10::intrusive_ptr<c10d::Store>& store,
    int rank,
    int world_size,
    T val) {
  static_assert(std::is_trivially_copyable_v<T>);

  std::vector<std::string> peer_keys;
  for (int r = 0; r < world_size; ++r) {
    std::ostringstream oss;
    oss << store_comm_prefix << "/" << store_comm_seq_id << "/" << r;
    peer_keys.push_back(oss.str());
  }
  ++store_comm_seq_id;

  {
    std::vector<uint8_t> payload(
        reinterpret_cast<uint8_t*>(&val),
        reinterpret_cast<uint8_t*>(&val) + sizeof(T));
    store->set(peer_keys[rank], payload);
  }

  std::vector<T> peer_vals;
  for (int r = 0; r < world_size; ++r) {
    if (r == rank) {
      peer_vals.push_back(val);
      continue;
    }
    store->wait({peer_keys[r]});
    auto payload = store->get(peer_keys[r]);
    TORCH_CHECK(payload.size() == sizeof(T));
    T peer_val{};
    std::memcpy(&peer_val, payload.data(), sizeof(T));
    peer_vals.push_back(peer_val);
  }
  return peer_vals;
}

void store_barrier(
    const c10::intrusive_ptr<c10d::Store>& store,
    int rank,
    int world_size) {
  store_all_gather(store, rank, world_size, 0);
}

int import_remote_fd(int pid, int fd) {
#if defined(SYS_pidfd_open) and defined(SYS_pidfd_getfd)
  int pidfd = syscall(SYS_pidfd_open, pid, 0);
  return syscall(SYS_pidfd_getfd, pidfd, fd, 0);
#else
  TORCH_CHECK(
      false,
      "CUDASymmetricMemory requires pidfd_open ",
      "and pidfd_getfd support");
#endif
}

void map_block(
    void** ptr,
    c10d::symmetric_memory::HandleType handle,
    size_t size,
    int device_idx) {
#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
  auto driver_api = c10::cuda::DriverAPI::get();
  auto dev_ptr = reinterpret_cast<CUdeviceptr*>(ptr);
  C10_CUDA_DRIVER_CHECK(
      driver_api->cuMemAddressReserve_(dev_ptr, size, 0ULL, 0, 0ULL));
  C10_CUDA_DRIVER_CHECK(driver_api->cuMemMap_(*dev_ptr, size, 0, handle, 0ULL));

  CUmemAccessDesc desc;
  desc.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
  // NOLINTNEXTLINE(bugprone-signed-char-misuse)
  desc.location.id = static_cast<int>(device_idx);
  desc.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
  C10_CUDA_DRIVER_CHECK(driver_api->cuMemSetAccess_(*dev_ptr, size, &desc, 1));
#else
  TORCH_CHECK(
      false, "CUDASymmetricMemory requires PYTORCH_C10_DRIVER_API_SUPPORTED");
#endif
}

} // namespace

namespace c10d {
namespace symmetric_memory {

CUDASymmetricMemory::CUDASymmetricMemory(
    std::vector<HandleType> handles,
    size_t block_size,
    std::vector<void*> buffers,
    std::vector<void*> signal_pads,
    size_t buffer_size,
    int local_device_idx,
    int rank,
    int world_size)
    : handles_(std::move(handles)),
      block_size_(block_size),
      buffers_(std::move(buffers)),
      signal_pads_(std::move(signal_pads)),
      buffer_size_(buffer_size),
      local_device_idx_(local_device_idx),
      rank_(rank),
      world_size_(world_size) {
  const size_t arr_size = sizeof(void*) * world_size_;
  buffers_dev_ = reinterpret_cast<void**>(
      c10::cuda::CUDACachingAllocator::raw_alloc(arr_size));
  signal_pads_dev_ = reinterpret_cast<void**>(
      c10::cuda::CUDACachingAllocator::raw_alloc(arr_size));

  c10::cuda::CUDAGuard guard(local_device_idx);
  AT_CUDA_CHECK(cudaMemcpy(
      buffers_dev_, buffers_.data(), arr_size, cudaMemcpyHostToDevice));
  AT_CUDA_CHECK(cudaMemcpy(
      signal_pads_dev_, signal_pads_.data(), arr_size, cudaMemcpyHostToDevice));
}

CUDASymmetricMemory::~CUDASymmetricMemory() {
#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
  // Leak the cuda allocations during static deinitialization
  if (is_finalizing()) {
    return;
  }
  c10::cuda::CUDAGuard guard(local_device_idx_);
  C10_CUDA_CHECK(cudaDeviceSynchronize());

  auto driver_api = c10::cuda::DriverAPI::get();
  for (int r = 0; r < world_size_; ++r) {
    C10_CUDA_DRIVER_CHECK(driver_api->cuMemUnmap_(
        reinterpret_cast<CUdeviceptr>(buffers_[r]), block_size_));
    C10_CUDA_DRIVER_CHECK(driver_api->cuMemRelease_(handles_[r]));
  }
  c10::cuda::CUDACachingAllocator::raw_delete(buffers_dev_);
  c10::cuda::CUDACachingAllocator::raw_delete(signal_pads_dev_);
#else
  TORCH_CHECK(
      false, "CUDASymmetricMemory requires PYTORCH_C10_DRIVER_API_SUPPORTED");
#endif
}

std::vector<void*> CUDASymmetricMemory::get_buffer_ptrs() {
  return buffers_;
}

std::vector<void*> CUDASymmetricMemory::get_signal_pad_ptrs() {
  return signal_pads_;
}

void** CUDASymmetricMemory::get_buffer_ptrs_dev() {
  return buffers_dev_;
}

void** CUDASymmetricMemory::get_signal_pad_ptrs_dev() {
  return signal_pads_dev_;
}

size_t CUDASymmetricMemory::get_buffer_size() {
  return buffer_size_;
}

size_t CUDASymmetricMemory::get_signal_pad_size() {
  return signal_pad_size;
}

at::Tensor CUDASymmetricMemory::get_buffer(
    int rank,
    c10::IntArrayRef sizes,
    c10::ScalarType dtype,
    int64_t storage_offset) {
  const auto numel =
      std::accumulate(sizes.begin(), sizes.end(), 1, std::multiplies<int>());
  const auto element_size = c10::elementSize(dtype);
  const auto req_size = (numel + storage_offset) * element_size;
  TORCH_CHECK(
      req_size <= buffer_size_,
      "CUDASymmetricMemory::get_buffer: the requested size (",
      req_size,
      " bytes) exceeds the allocated size (",
      buffer_size_,
      " bytes)");
  auto device = c10::Device(c10::DeviceType::CUDA, local_device_idx_);
  auto options = at::TensorOptions().dtype(dtype).device(device);
  return at::for_blob(buffers_[rank], sizes)
      .storage_offset(storage_offset)
      .options(options)
      .target_device(device)
      .make_tensor();
}

void check_channel(int channel, int world_size) {
  TORCH_CHECK(
      channel >= 0,
      "channel for barrier(), put_signal() and wait_signal() ",
      "must be greater than 0 (got ",
      channel,
      ")");
  const size_t num_channels = signal_pad_size / sizeof(uint32_t) * world_size;
  TORCH_CHECK(
      static_cast<size_t>(channel) < num_channels,
      "The maximum supported channel for barrier(), put_signal() and wait_signal() is ",
      num_channels - 1,
      " (got ",
      channel,
      ")");
}

__device__ __forceinline__ void release_signal(uint32_t* addr) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  volatile uint32_t* signal = addr;
  uint32_t val;
  do {
    val = *signal;
  } while (val != 0 || atomicCAS_system(addr, 0, 1) != 0);
#endif
}

__device__ __forceinline__ void acquire_signal(uint32_t* addr) {
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  CUDA_KERNEL_ASSERT(false);
#else
  volatile uint32_t* signal = addr;
  uint32_t val;
  do {
    val = *signal;
  } while (val != 1 || atomicCAS_system(addr, 1, 0) != 1);
#endif
}

static __global__ void barrier_kernel(
    uint32_t** signal_pads,
    int channel,
    int rank,
    int world_size) {
  if (threadIdx.x < world_size) {
    auto target_rank = threadIdx.x;
    release_signal(signal_pads[target_rank] + world_size * channel + rank);
    acquire_signal(signal_pads[rank] + world_size * channel + target_rank);
  }
}

void CUDASymmetricMemory::barrier(int channel) {
  check_channel(channel, world_size_);
  c10::cuda::CUDAGuard guard(local_device_idx_);
  barrier_kernel<<<1, C10_WARP_SIZE, 0, at::cuda::getCurrentCUDAStream()>>>(
      reinterpret_cast<uint32_t**>(signal_pads_dev_),
      channel,
      rank_,
      world_size_);
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

static __global__ void put_signal_kernel(
    uint32_t** signal_pads,
    int dst_rank,
    int channel,
    int rank,
    int world_size) {
  if (threadIdx.x == 0) {
    release_signal(signal_pads[dst_rank] + world_size * channel + rank);
  }
}

void CUDASymmetricMemory::put_signal(int dst_rank, int channel) {
  check_channel(channel, world_size_);
  c10::cuda::CUDAGuard guard(local_device_idx_);
  put_signal_kernel<<<1, C10_WARP_SIZE, 0, at::cuda::getCurrentCUDAStream()>>>(
      reinterpret_cast<uint32_t**>(signal_pads_dev_),
      dst_rank,
      channel,
      rank_,
      world_size_);
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

static __global__ void wait_signal_kernel(
    uint32_t** signal_pads,
    int src_rank,
    int channel,
    int rank,
    int world_size) {
  if (threadIdx.x == 0) {
    acquire_signal(signal_pads[rank] + world_size * channel + src_rank);
  }
  __threadfence_system();
}

void CUDASymmetricMemory::wait_signal(int src_rank, int channel) {
  check_channel(channel, world_size_);
  c10::cuda::CUDAGuard guard(local_device_idx_);
  wait_signal_kernel<<<1, C10_WARP_SIZE, 0, at::cuda::getCurrentCUDAStream()>>>(
      reinterpret_cast<uint32_t**>(signal_pads_dev_),
      src_rank,
      channel,
      rank_,
      world_size_);
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

int CUDASymmetricMemory::get_rank() {
  return rank_;
}

int CUDASymmetricMemory::get_world_size() {
  return world_size_;
}

void* CUDASymmetricMemoryAllocator::alloc(
    size_t size,
    int device_idx,
    const std::string& group_name) {
#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
  auto driver_api = c10::cuda::DriverAPI::get();

  CUmemAllocationProp prop = {};
  prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
  prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
  // NOLINTNEXTLINE(bugprone-signed-char-misuse)
  prop.location.id = device_idx;
  prop.requestedHandleTypes = CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR;

  size_t signal_pad_offset = at::round_up(size, 16UL);
  size_t block_size = signal_pad_offset + signal_pad_size;

  size_t granularity;
  C10_CUDA_DRIVER_CHECK(driver_api->cuMemGetAllocationGranularity_(
      &granularity, &prop, CU_MEM_ALLOC_GRANULARITY_RECOMMENDED));
  block_size = at::round_up(block_size, granularity);

  HandleType handle;
  C10_CUDA_DRIVER_CHECK(
      driver_api->cuMemCreate_(&handle, block_size, &prop, 0));

  void* ptr = nullptr;
  map_block(&ptr, handle, block_size, device_idx);

  c10::cuda::CUDAGuard guard(device_idx);
  AT_CUDA_CHECK(cudaMemset(ptr, 0, block_size));

  auto block = c10::make_intrusive<Block>(
      handle, device_idx, block_size, size, signal_pad_offset, group_name);
  {
    std::unique_lock lock(mutex_);
    ptr_to_block_.emplace(ptr, std::move(block));
  }
  return ptr;
#else
  TORCH_CHECK(
      false, "CUDASymmetricMemory requires PYTORCH_C10_DRIVER_API_SUPPORTED");
#endif
}

void CUDASymmetricMemoryAllocator::free(void* ptr) {
#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
  auto block = find_block(ptr);
  // Leak the cuda allocations during static deinitialization
  if (block == nullptr || is_finalizing()) {
    return;
  }
  // Initializing CUDASymmetricMemory with an allocation transfers its
  // ownership to the CUDASymmetricMemory object.
  if (block->symm_mem == nullptr) {
    auto driver_api = c10::cuda::DriverAPI::get();
    C10_CUDA_DRIVER_CHECK(driver_api->cuMemUnmap_(
        reinterpret_cast<CUdeviceptr>(ptr), block->block_size));
    C10_CUDA_DRIVER_CHECK(driver_api->cuMemRelease_(block->handle));
  }
  {
    std::unique_lock lock(mutex_);
    ptr_to_block_.erase(ptr);
  }
#else
  TORCH_CHECK(
      false, "CUDASymmetricMemory requires PYTORCH_C10_DRIVER_API_SUPPORTED");
#endif
}

size_t CUDASymmetricMemoryAllocator::get_alloc_size(void* ptr) {
  auto block = find_block(ptr);
  TORCH_CHECK(
      block != nullptr,
      "CUDASymmetricMemoryAllocator::get_alloc_size: input must be allocated ",
      "via CUDASymmetricMemoryAllocator::alloc");
  return block->buffer_size;
}

struct RendezvousRequest {
  int device_idx;
  int block_fd;
  int pid;
  size_t block_size;
  size_t buffer_size;
  size_t signal_pad_offset;
};

void validate_rendezvous_requests(
    const std::vector<RendezvousRequest> reqs,
    int world_size) {
  TORCH_CHECK(reqs.size() == (size_t)world_size);

  std::unordered_set<int> device_indices;
  device_indices.reserve(world_size);
  for (auto req : reqs) {
    device_indices.insert(req.device_idx);
  }
  if (device_indices.size() < (size_t)world_size) {
    TORCH_CHECK(
        false,
        "CUDASymmetricMemoryAllocator::rendezvous: ",
        "detected allocations from overlapping devices ",
        "from different ranks.");
  }

  for (int r = 1; r < world_size; ++r) {
    TORCH_CHECK(reqs[r].block_size == reqs[0].block_size);
    TORCH_CHECK(reqs[r].buffer_size == reqs[0].buffer_size);
    TORCH_CHECK(reqs[r].signal_pad_offset == reqs[0].signal_pad_offset);
  }
}

c10::intrusive_ptr<SymmetricMemory> CUDASymmetricMemoryAllocator::rendezvous(
    void* ptr) {
#if !defined(USE_ROCM) && defined(PYTORCH_C10_DRIVER_API_SUPPORTED)
  auto block = find_block(ptr);
  TORCH_CHECK(
      block != nullptr,
      "CUDASymmetricMemoryAllocator::rendezvous: input must be allocated ",
      "via CUDASymmetricMemoryAllocator::alloc");

  if (block->symm_mem != nullptr) {
    return block->symm_mem;
  }

  auto group_info = get_group_info(block->group_name);
  auto driver_api = c10::cuda::DriverAPI::get();
  int block_fd;
  C10_CUDA_DRIVER_CHECK(driver_api->cuMemExportToShareableHandle_(
      &block_fd, block->handle, CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR, 0));

  auto local_req = RendezvousRequest{
      .device_idx = block->device_idx,
      .block_fd = block_fd,
      .pid = getpid(),
      .block_size = block->block_size,
      .buffer_size = block->buffer_size,
      .signal_pad_offset = block->signal_pad_offset};
  auto reqs = store_all_gather(
      group_info.store, group_info.rank, group_info.world_size, local_req);
  validate_rendezvous_requests(reqs, group_info.world_size);

  std::vector<HandleType> handles(group_info.world_size);
  std::vector<void*> buffers(group_info.world_size, nullptr);
  std::vector<void*> signal_pads(group_info.world_size, nullptr);
  for (int r = 0; r < group_info.world_size; ++r) {
    if (r == group_info.rank) {
      handles[r] = block->handle;
      buffers[r] = ptr;
      signal_pads[r] = (void*)((uintptr_t)ptr + block->signal_pad_offset);
      continue;
    }
    int imported_fd = import_remote_fd(reqs[r].pid, reqs[r].block_fd);
    C10_CUDA_DRIVER_CHECK(driver_api->cuMemImportFromShareableHandle_(
        &handles[r],
        (void*)(uintptr_t)imported_fd,
        CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR));
    map_block(&buffers[r], handles[r], block->block_size, block->device_idx);
    signal_pads[r] = (void*)((uintptr_t)buffers[r] + block->signal_pad_offset);
    close(imported_fd);
  }
  store_barrier(group_info.store, group_info.rank, group_info.world_size);
  close(block_fd);

  // Initializing CUDASymmetricMemory with an allocation transfers its
  // ownership to the CUDASymmetricMemory object. So that outstanding
  // references to the CUDASymmetricMemory object can keep the allocation
  // alive.
  block->symm_mem = c10::make_intrusive<CUDASymmetricMemory>(
      std::move(handles),
      block->block_size,
      std::move(buffers),
      std::move(signal_pads),
      block->buffer_size,
      block->device_idx,
      group_info.rank,
      group_info.world_size);
  return block->symm_mem;
#else
  TORCH_CHECK(
      false, "CUDASymmetricMemory requires PYTORCH_C10_DRIVER_API_SUPPORTED");
#endif
}

bool CUDASymmetricMemoryAllocator::is_rendezvous_completed(void* ptr) {
  auto block = find_block(ptr);
  TORCH_CHECK(
      block != nullptr,
      "CUDASymmetricMemoryAllocator::is_rendezvous_completed: input must be allocated ",
      "via CUDASymmetricMemoryAllocator::alloc");
  return block->symm_mem != nullptr;
}

c10::intrusive_ptr<Block> CUDASymmetricMemoryAllocator::find_block(void* ptr) {
  std::shared_lock lock(mutex_);
  auto it = ptr_to_block_.find(ptr);
  if (it == ptr_to_block_.end()) {
    return nullptr;
  }
  return it->second;
}

struct RegisterCUDASymmetricMemoryAllocator {
  RegisterCUDASymmetricMemoryAllocator() {
    register_allocator(
        c10::DeviceType::CUDA,
        c10::make_intrusive<CUDASymmetricMemoryAllocator>());
  }
};

static RegisterCUDASymmetricMemoryAllocator register_allocator_;

} // namespace symmetric_memory
} // namespace c10d
