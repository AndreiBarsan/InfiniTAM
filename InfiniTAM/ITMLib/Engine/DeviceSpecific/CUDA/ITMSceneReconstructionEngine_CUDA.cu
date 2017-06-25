// Copyright 2014-2015 Isis Innovation Limited and the authors of InfiniTAM

#include "ITMSceneReconstructionEngine_CUDA.h"
#include "ITMCUDAUtils.h"
#include "../../DeviceAgnostic/ITMSceneReconstructionEngine.h"
#include "../../../Objects/ITMRenderState_VH.h"

struct AllocationTempData {
	int noAllocatedVoxelEntries;
	int noAllocatedExcessEntries;
	int noVisibleEntries;
};

using namespace ITMLib::Engine;

template<class TVoxel, bool stopMaxW, bool approximateIntegration>
__global__ void integrateIntoScene_device(TVoxel *localVBA, const ITMHashEntry *hashTable, int *noVisibleEntryIDs,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i imgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW);

template<class TVoxel, bool stopMaxW, bool approximateIntegration>
__global__ void integrateIntoScene_device(TVoxel *voxelArray, const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i depthImgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW);

__global__ void buildHashAllocAndVisibleType_device(uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords, const float *depth,
	Matrix4f invM_d, Vector4f projParams_d, float mu, Vector2i _imgSize, float _voxelSize, ITMHashEntry *hashTable, float viewFrustum_min,
	float viewFrustrum_max);

__global__ void allocateVoxelBlocksList_device(int *voxelAllocationList, int *excessAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	AllocationTempData *allocData, uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords);

__global__ void reAllocateSwappedOutVoxelBlocks_device(int *voxelAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	AllocationTempData *allocData, uchar *entriesVisibleType);

__global__ void setToType3(uchar *entriesVisibleType, int *visibleEntryIDs, int noVisibleEntries);

template<bool useSwapping>
__global__ void buildVisibleList_device(ITMHashEntry *hashTable, ITMHashSwapState *swapStates, int noTotalEntries,
	int *visibleEntryIDs, AllocationTempData *allocData, uchar *entriesVisibleType,
	Matrix4f M_d, Vector4f projParams_d, Vector2i depthImgSize, float voxelSize);

template<class TVoxel>
__global__ void decay_device(TVoxel *localVBA, const ITMHashEntry *hashTable, int *visibleEntryIDs, int maxWeight);

// host methods

template<class TVoxel>
ITMSceneReconstructionEngine_CUDA<TVoxel,ITMVoxelBlockHash>::ITMSceneReconstructionEngine_CUDA(void) 
{
	ITMSafeCall(cudaMalloc((void**)&allocationTempData_device, sizeof(AllocationTempData)));
	ITMSafeCall(cudaMallocHost((void**)&allocationTempData_host, sizeof(AllocationTempData)));

	int noTotalEntries = ITMVoxelBlockHash::noTotalEntries;
	ITMSafeCall(cudaMalloc((void**)&entriesAllocType_device, noTotalEntries));
	ITMSafeCall(cudaMalloc((void**)&blockCoords_device, noTotalEntries * sizeof(Vector4s)));
}

template<class TVoxel>
ITMSceneReconstructionEngine_CUDA<TVoxel,ITMVoxelBlockHash>::~ITMSceneReconstructionEngine_CUDA(void) 
{
	ITMSafeCall(cudaFreeHost(allocationTempData_host));
	ITMSafeCall(cudaFree(allocationTempData_device));
	ITMSafeCall(cudaFree(entriesAllocType_device));
	ITMSafeCall(cudaFree(blockCoords_device));
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel,ITMVoxelBlockHash>::ResetScene(ITMScene<TVoxel, ITMVoxelBlockHash> *scene)
{
	int numBlocks = scene->index.getNumAllocatedVoxelBlocks();
	int blockSize = scene->index.getVoxelBlockSize();

	TVoxel *voxelBlocks_ptr = scene->localVBA.GetVoxelBlocks();
	memsetKernel<TVoxel>(voxelBlocks_ptr, TVoxel(), numBlocks * blockSize);
	int *vbaAllocationList_ptr = scene->localVBA.GetAllocationList();
	fillArrayKernel<int>(vbaAllocationList_ptr, numBlocks);
	scene->localVBA.lastFreeBlockId = numBlocks - 1;

	ITMHashEntry tmpEntry;
	memset(&tmpEntry, 0, sizeof(ITMHashEntry));
	tmpEntry.ptr = -2;
	ITMHashEntry *hashEntry_ptr = scene->index.GetEntries();
	memsetKernel<ITMHashEntry>(hashEntry_ptr, tmpEntry, scene->index.noTotalEntries);
	int *excessList_ptr = scene->index.GetExcessAllocationList();
	fillArrayKernel<int>(excessList_ptr, SDF_EXCESS_LIST_SIZE);

	scene->index.SetLastFreeExcessListId(SDF_EXCESS_LIST_SIZE - 1);
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMVoxelBlockHash>::AllocateSceneFromDepth(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view, 
	const ITMTrackingState *trackingState, const ITMRenderState *renderState, bool onlyUpdateVisibleList)
{
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, invM_d;
	Vector4f projParams_d, invProjParams_d;

	ITMRenderState_VH *renderState_vh = (ITMRenderState_VH*)renderState;
	M_d = trackingState->pose_d->GetM(); M_d.inv(invM_d);

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	invProjParams_d = projParams_d;
	invProjParams_d.x = 1.0f / invProjParams_d.x;
	invProjParams_d.y = 1.0f / invProjParams_d.y;

	float mu = scene->sceneParams->mu;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	int *voxelAllocationList = scene->localVBA.GetAllocationList();
	int *excessAllocationList = scene->index.GetExcessAllocationList();
	ITMHashEntry *hashTable = scene->index.GetEntries();
	ITMHashSwapState *swapStates = scene->useSwapping ? scene->globalCache->GetSwapStates(true) : 0;

	// The sum of the nr of buckets, plus the excess list size
	int noTotalEntries = scene->index.noTotalEntries;
	int *visibleEntryIDs = renderState_vh->GetVisibleEntryIDs();
	uchar *entriesVisibleType = renderState_vh->GetEntriesVisibleType();

	dim3 cudaBlockSizeHV(16, 16);
	dim3 gridSizeHV((int)ceil((float)depthImgSize.x / (float)cudaBlockSizeHV.x), (int)ceil((float)depthImgSize.y / (float)cudaBlockSizeHV.y));

	dim3 cudaBlockSizeAL(256, 1);
	dim3 gridSizeAL((int)ceil((float)noTotalEntries / (float)cudaBlockSizeAL.x));

	dim3 cudaBlockSizeVS(256, 1);
	dim3 gridSizeVS((int)ceil((float)renderState_vh->noVisibleEntries / (float)cudaBlockSizeVS.x));

	float oneOverVoxelSize = 1.0f / (voxelSize * SDF_BLOCK_SIZE);

	AllocationTempData *tempData = static_cast<AllocationTempData*>(allocationTempData_host);
	tempData->noAllocatedVoxelEntries = scene->localVBA.lastFreeBlockId;
	tempData->noAllocatedExcessEntries = scene->index.GetLastFreeExcessListId();
	tempData->noVisibleEntries = 0;
	ITMSafeCall(cudaMemcpyAsync(allocationTempData_device, tempData, sizeof(AllocationTempData), cudaMemcpyHostToDevice));

	ITMSafeCall(cudaMemsetAsync(entriesAllocType_device, 0, sizeof(unsigned char)* noTotalEntries));

	if (gridSizeVS.x > 0) {
		// TODO(andrei): What does visibility type 3 mean?
		setToType3<<<gridSizeVS, cudaBlockSizeVS>>>(entriesVisibleType, visibleEntryIDs, renderState_vh->noVisibleEntries);
	}

	buildHashAllocAndVisibleType_device << <gridSizeHV, cudaBlockSizeHV >> >(entriesAllocType_device, entriesVisibleType,
		blockCoords_device, depth, invM_d, invProjParams_d, mu, depthImgSize, oneOverVoxelSize, hashTable,
		scene->sceneParams->viewFrustum_min, scene->sceneParams->viewFrustum_max);

	bool useSwapping = scene->useSwapping;
	if (onlyUpdateVisibleList) useSwapping = false;
	if (!onlyUpdateVisibleList)
	{
		allocateVoxelBlocksList_device << <gridSizeAL, cudaBlockSizeAL >> >(voxelAllocationList, excessAllocationList, hashTable,
			noTotalEntries, (AllocationTempData*)allocationTempData_device, entriesAllocType_device, entriesVisibleType,
			blockCoords_device);
	}

	if (useSwapping) {
		buildVisibleList_device<true> << <gridSizeAL, cudaBlockSizeAL >> >(hashTable, swapStates, noTotalEntries, visibleEntryIDs,
			(AllocationTempData*)allocationTempData_device, entriesVisibleType, M_d, projParams_d, depthImgSize, voxelSize);
	}
	else {
      printf("Launching visible list building kernel. Maximum possible ID is noTotalEntries = %d (bucket count + excess list size)\n",
	         noTotalEntries);
		buildVisibleList_device<false> << <gridSizeAL, cudaBlockSizeAL >> >(hashTable, swapStates, noTotalEntries, visibleEntryIDs,
			(AllocationTempData*)allocationTempData_device, entriesVisibleType, M_d, projParams_d, depthImgSize, voxelSize);
	}

	if (useSwapping)
	{
		reAllocateSwappedOutVoxelBlocks_device << <gridSizeAL, cudaBlockSizeAL >> >(voxelAllocationList, hashTable, noTotalEntries,
			(AllocationTempData*)allocationTempData_device, entriesVisibleType);
	}

	ITMSafeCall(cudaMemcpy(tempData, allocationTempData_device, sizeof(AllocationTempData), cudaMemcpyDeviceToHost));
	renderState_vh->noVisibleEntries = tempData->noVisibleEntries;
	scene->localVBA.lastFreeBlockId = tempData->noAllocatedVoxelEntries;
	scene->index.SetLastFreeExcessListId(tempData->noAllocatedExcessEntries);

	// visibleEntryIDs is now populated with block IDs which are visible.
	int totalBlockCount = scene->index.getNumAllocatedVoxelBlocks();
	size_t visibleBlockCount = static_cast<size_t>(tempData->noVisibleEntries);

	size_t visibleEntryIDsByteCount = visibleBlockCount * sizeof(int);
	auto *visibleEntryIDsCopy = new ORUtils::MemoryBlock<int>(
			visibleEntryIDsByteCount, MEMORYDEVICE_CUDA);

	ITMSafeCall(cudaMemcpy(visibleEntryIDsCopy->GetData(MEMORYDEVICE_CUDA),
						   visibleEntryIDs,
						   visibleEntryIDsByteCount,
						   cudaMemcpyDeviceToDevice));
	VisibleBlockInfo visibleBlockInfo = {
		visibleBlockCount,
		visibleEntryIDsCopy
	};
	frameVisibleBlocks.push(visibleBlockInfo);

	// TODO(andrei): Remove this once code's working.
	// Sanity check
  	int *visibleEntryIDs_h = new int[totalBlockCount];
	ITMSafeCall(cudaMemcpy(visibleEntryIDs_h,
						   visibleEntryIDs,
						   totalBlockCount * sizeof(int),
						   cudaMemcpyDeviceToHost));
	int visibleBlocks = 0;
	for (int i = 0; i < totalBlockCount; ++i) {
		if (visibleEntryIDs_h[i] != 0) {
			visibleBlocks++;
		}
	}

	printf("I counted %d visible blocks.\n\n", visibleBlocks);
	printf("IDs: %d %d %d", visibleEntryIDs_h[visibleBlocks - 1],
		   visibleEntryIDs_h[visibleBlocks],
		   visibleEntryIDs_h[visibleBlocks + 1]);
	delete[] visibleEntryIDs_h;
	// end sanity check


	// This just returns the size of the pre-allocated buffer.
	long allocatedBlocks = scene->index.getNumAllocatedVoxelBlocks();
	// This is the number of blocks we are using out of the chunk that was allocated initially on
	// the GPU (for non-swapping case).
	long usedBlocks = allocatedBlocks - scene->localVBA.lastFreeBlockId;
	long allocatedExcessBlocks = SDF_EXCESS_LIST_SIZE;
	long usedExcessBlocks = allocatedExcessBlocks - tempData->noAllocatedExcessEntries;

	if (usedBlocks > allocatedBlocks) {
		usedBlocks = allocatedBlocks;
	}
	if (usedExcessBlocks > allocatedExcessBlocks) {
		usedExcessBlocks = allocatedExcessBlocks;
	}

	float percentFree = 100.0f * (1.0f - static_cast<float>(usedBlocks) / allocatedBlocks);

	// Display some memory stats, useful for debugging mapping failures.
	printf("Visible entries: %8d | Used blocks in main GPU buffer: %8ld/%ld (%.2f%% free) | "
			"Used blocks in excess list: %8ld/%ld | Allocated size: %8d\n",
			tempData->noVisibleEntries,
			usedBlocks,
			allocatedBlocks,
			percentFree,
			usedExcessBlocks,
			allocatedExcessBlocks,
			scene->localVBA.allocatedSize);

	ITMHashEntry *entries = scene->index.GetEntries();
	if (scene->localVBA.lastFreeBlockId < 0) {
		fprintf(stderr, "ERROR: Last free block ID was negative (%d). This may indicate an "
				"allocation failure, causing your map to stop being able to grow.\n", scene->localVBA.lastFreeBlockId);
		throw std::runtime_error(
				"Invalid free voxel block ID. InfiniTAM has likely run out of GPU memory.");
	}
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMVoxelBlockHash>::IntegrateIntoScene(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
	Vector2i rgbImgSize = view->rgb->noDims;
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, M_rgb;
	Vector4f projParams_d, projParams_rgb;

	ITMRenderState_VH *renderState_vh = (ITMRenderState_VH*)renderState;
	if (renderState_vh->noVisibleEntries == 0) {
		// Our view has no useful data, so there's nothing to allocate. This happens, e.g., when
		// we fuse frames belonging to object instances, in which the actual instance is too far
		// away. Its depth values are over the max depth threshold (and, likely too noisy) and
		// they get ignored, leading to a blank ITMView with nothing new to integrate.
		return;
	}

	M_d = trackingState->pose_d->GetM();
	if (TVoxel::hasColorInformation) M_rgb = view->calib->trafo_rgb_to_depth.calib_inv * M_d;

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	projParams_rgb = view->calib->intrinsics_rgb.projectionParamsSimple.all;

	float mu = scene->sceneParams->mu; int maxW = scene->sceneParams->maxW;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	Vector4u *rgb = view->rgb->GetData(MEMORYDEVICE_CUDA);
	TVoxel *localVBA = scene->localVBA.GetVoxelBlocks();
	ITMHashEntry *hashTable = scene->index.GetEntries();

	int *visibleEntryIDs = renderState_vh->GetVisibleEntryIDs();

	dim3 cudaBlockSize(SDF_BLOCK_SIZE, SDF_BLOCK_SIZE, SDF_BLOCK_SIZE);
	dim3 gridSize(renderState_vh->noVisibleEntries);

	// These kernels are launched over ALL visible blocks, whose IDs are placed conveniently as the
	// first `renderState_vh->noVisibleEntries` elements of the `visibleEntryIDs` array, which could,
	// in theory, accommodate ALL possible blocks, but usually contains O(10k) blocks.
	if (scene->sceneParams->stopIntegratingAtMaxW) {
		if (trackingState->requiresFullRendering) {
			integrateIntoScene_device<TVoxel, true, false> << < gridSize, cudaBlockSize >> > (
				localVBA, hashTable, visibleEntryIDs, rgb, rgbImgSize, depth, depthImgSize,
				M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		} else {
			integrateIntoScene_device<TVoxel, true, true> << < gridSize, cudaBlockSize >> > (
				localVBA, hashTable, visibleEntryIDs, rgb, rgbImgSize, depth, depthImgSize,
				M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		}
	}
	else {
		if (trackingState->requiresFullRendering) {
			integrateIntoScene_device<TVoxel, false, false> << < gridSize, cudaBlockSize >> > (
					localVBA, hashTable, visibleEntryIDs, rgb, rgbImgSize, depth, depthImgSize,
						M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		}
		else {
			integrateIntoScene_device<TVoxel, false, true> << < gridSize, cudaBlockSize >> > (
				localVBA, hashTable, visibleEntryIDs, rgb, rgbImgSize, depth, depthImgSize,
						M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		}
	}
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMVoxelBlockHash>::Decay(
		ITMScene<TVoxel, ITMVoxelBlockHash> *scene,
		int maxWeight,
		int minAge
) {
	// TODO(andrei): Make the timing actually work properly, and don't run it every frame unless it's very fast.
	if (frameVisibleBlocks.size() > minAge) {
		VisibleBlockInfo visible = frameVisibleBlocks.front();
		frameVisibleBlocks.pop();

		assert(visible.count >= 0);
		dim3 cudaBlockSize(SDF_BLOCK_SIZE, SDF_BLOCK_SIZE, SDF_BLOCK_SIZE);
		dim3 gridSize(static_cast<uint32_t>(visible.count));

		TVoxel *localVBA = scene->localVBA.GetVoxelBlocks();
		ITMHashEntry *hashTable = scene->index.GetEntries();
		printf("Calling decay kernel... gs = %d, maxWeight = %d\n\n", gridSize.x, maxWeight);
		fflush(stdout);

		ITMSafeCall(cudaDeviceSynchronize());	// paranoia

		visible.blockIDs->UpdateDeviceFromHost();		// needed?

		decay_device <TVoxel> <<<gridSize, cudaBlockSize>>>(
				localVBA,
				hashTable,
				visible.blockIDs->GetData(MEMORYDEVICE_CUDA),
				maxWeight);
      ITMSafeCall(cudaDeviceSynchronize());	// debug

//		delete visible.blockIDs;		// probably safe to re-enable
	}

	// Launch kernel for entire voxel hash (?), invalidate all voxels <maxWeight, >minAge.
	// (Every block <=> voxel block.)
	// Each block then sums up the number of voxels with valid data in them. If it's zero (or,
	// maybe, close to zero?), then put that number in a list, and deallocate the blocks.
	// Look at the swapping engine to see how they deal with fragmentation.
	// This will be SLOW.
	// Speedup idea: keep track of a list of the blocks ALLOCATED 'minAge' ago, and only run the
	// decay check on them. Bear in mind that the weight currently cannot go down. If we change the
	// error models, we may reach a point in the future where the weight does go down, but even so
	// it would be quite unlikely to go down a lot after 5 frames have already elapsed. Maybe we
	// could do this, but for the list of previously visible blocks.
}

// plain voxel array

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel,ITMPlainVoxelArray>::ResetScene(ITMScene<TVoxel, ITMPlainVoxelArray> *scene)
{
	int numBlocks = scene->index.getNumAllocatedVoxelBlocks();
	int blockSize = scene->index.getVoxelBlockSize();

	TVoxel *voxelBlocks_ptr = scene->localVBA.GetVoxelBlocks();
	memsetKernel<TVoxel>(voxelBlocks_ptr, TVoxel(), numBlocks * blockSize);
	int *vbaAllocationList_ptr = scene->localVBA.GetAllocationList();
	fillArrayKernel<int>(vbaAllocationList_ptr, numBlocks);
	scene->localVBA.lastFreeBlockId = numBlocks - 1;
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMPlainVoxelArray>::AllocateSceneFromDepth(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState, bool onlyUpdateVisibleList)
{
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMPlainVoxelArray>::IntegrateIntoScene(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
	Vector2i rgbImgSize = view->rgb->noDims;
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, M_rgb;
	Vector4f projParams_d, projParams_rgb;

	M_d = trackingState->pose_d->GetM();
	if (TVoxel::hasColorInformation) M_rgb = view->calib->trafo_rgb_to_depth.calib_inv * M_d;

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	projParams_rgb = view->calib->intrinsics_rgb.projectionParamsSimple.all;

	float mu = scene->sceneParams->mu; int maxW = scene->sceneParams->maxW;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	Vector4u *rgb = view->rgb->GetData(MEMORYDEVICE_CUDA);
	TVoxel *localVBA = scene->localVBA.GetVoxelBlocks();
	const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo = scene->index.getIndexData();

	dim3 cudaBlockSize(8, 8, 8);
	dim3 gridSize(
		scene->index.getVolumeSize().x / cudaBlockSize.x,
		scene->index.getVolumeSize().y / cudaBlockSize.y,
		scene->index.getVolumeSize().z / cudaBlockSize.z);

	if (scene->sceneParams->stopIntegratingAtMaxW) {
		if (trackingState->requiresFullRendering)
			integrateIntoScene_device < TVoxel, true, false> << <gridSize, cudaBlockSize >> >(localVBA, arrayInfo,
				rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		else
			integrateIntoScene_device < TVoxel, true, true> << <gridSize, cudaBlockSize >> >(localVBA, arrayInfo,
				rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
	}
	else
	{
		if (trackingState->requiresFullRendering)
			integrateIntoScene_device < TVoxel, false, false> << <gridSize, cudaBlockSize >> >(localVBA, arrayInfo,
				rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
		else
			integrateIntoScene_device < TVoxel, false, true> << <gridSize, cudaBlockSize >> >(localVBA, arrayInfo,
				rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
	}
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMPlainVoxelArray>::Decay(
		ITMScene<TVoxel, ITMPlainVoxelArray> *scene,
		int maxWeight,
		int minAge
) {
  throw std::runtime_error("Map decay is not supported in conjunction with plain voxel arrays, "
						   "only with voxel block hashing.");
}


// device functions

template<class TVoxel, bool stopMaxW, bool approximateIntegration>
__global__ void integrateIntoScene_device(TVoxel *voxelArray, const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i depthImgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW)
{
	int x = blockIdx.x*blockDim.x+threadIdx.x;
	int y = blockIdx.y*blockDim.y+threadIdx.y;
	int z = blockIdx.z*blockDim.z+threadIdx.z;

	Vector4f pt_model; int locId;

	locId = x + y * arrayInfo->size.x + z * arrayInfo->size.x * arrayInfo->size.y;
	
	if (stopMaxW) if (voxelArray[locId].w_depth == maxW) return;
//	if (approximateIntegration) if (voxelArray[locId].w_depth != 0) return;

	pt_model.x = (float)(x + arrayInfo->offset.x) * _voxelSize;
	pt_model.y = (float)(y + arrayInfo->offset.y) * _voxelSize;
	pt_model.z = (float)(z + arrayInfo->offset.z) * _voxelSize;
	pt_model.w = 1.0f;

	ComputeUpdatedVoxelInfo<TVoxel::hasColorInformation,TVoxel>::compute(
			voxelArray[locId],
			pt_model,
			M_d,
			projParams_d,
			M_rgb,
			projParams_rgb,
			mu,
			maxW,
			depth,
			depthImgSize,
			rgb,
			rgbImgSize);
}

template<class TVoxel, bool stopMaxW, bool approximateIntegration>
__global__ void integrateIntoScene_device(TVoxel *localVBA,
										  const ITMHashEntry *hashTable,
										  int *visibleEntryIDs,
										  const Vector4u *rgb,
										  Vector2i rgbImgSize,
										  const float *depth, Vector2i depthImgSize,
										  Matrix4f M_d, Matrix4f M_rgb,
										  Vector4f projParams_d,
										  Vector4f projParams_rgb,
										  float _voxelSize,
										  float mu,
										  int maxW)
{
	Vector3i globalPos;
	int entryId = visibleEntryIDs[blockIdx.x];

	const ITMHashEntry &currentHashEntry = hashTable[entryId];

	if (currentHashEntry.ptr < 0) return;

	globalPos = currentHashEntry.pos.toInt() * SDF_BLOCK_SIZE;

	TVoxel *localVoxelBlock = &(localVBA[currentHashEntry.ptr * SDF_BLOCK_SIZE3]);

	int x = threadIdx.x, y = threadIdx.y, z = threadIdx.z;

	Vector4f pt_model; int locId;

	locId = x + y * SDF_BLOCK_SIZE + z * SDF_BLOCK_SIZE * SDF_BLOCK_SIZE;

	if (stopMaxW) if (localVoxelBlock[locId].w_depth == maxW) return;
	if (approximateIntegration) if (localVoxelBlock[locId].w_depth != 0) return;

	if (blockIdx.x % 3121 == 0 && 0 == locId) {
		printf("integrateIntoScene_device: ID %8d | localVBA = %p | localVoxelBlock = %p\n",
			   entryId,
               localVBA,
			   localVoxelBlock);
	}

	pt_model.x = (float)(globalPos.x + x) * _voxelSize;
	pt_model.y = (float)(globalPos.y + y) * _voxelSize;
	pt_model.z = (float)(globalPos.z + z) * _voxelSize;
	pt_model.w = 1.0f;

	ComputeUpdatedVoxelInfo<TVoxel::hasColorInformation,TVoxel>::compute(localVoxelBlock[locId], pt_model, M_d, projParams_d, M_rgb, projParams_rgb, mu, maxW, depth, depthImgSize, rgb, rgbImgSize);
}

__global__ void buildHashAllocAndVisibleType_device(uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords, const float *depth,
	Matrix4f invM_d, Vector4f projParams_d, float mu, Vector2i _imgSize, float _voxelSize, ITMHashEntry *hashTable, float viewFrustum_min,
	float viewFrustum_max)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x, y = threadIdx.y + blockIdx.y * blockDim.y;

	if (x > _imgSize.x - 1 || y > _imgSize.y - 1) return;

	buildHashAllocAndVisibleTypePP(entriesAllocType, entriesVisibleType, x, y, blockCoords, depth, invM_d,
		projParams_d, mu, _imgSize, _voxelSize, hashTable, viewFrustum_min, viewFrustum_max);
}

__global__ void setToType3(uchar *entriesVisibleType, int *visibleEntryIDs, int noVisibleEntries)
{
	int entryId = threadIdx.x + blockIdx.x * blockDim.x;
	if (entryId > noVisibleEntries - 1) return;
	entriesVisibleType[visibleEntryIDs[entryId]] = 3;
}

__global__ void allocateVoxelBlocksList_device(
		int *voxelAllocationList, int *excessAllocationList,
		ITMHashEntry *hashTable, int noTotalEntries,
		AllocationTempData *allocData,
		uchar *entriesAllocType, uchar *entriesVisibleType,
		Vector4s *blockCoords
) {
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	int vbaIdx, exlIdx;

	switch (entriesAllocType[targetIdx])
	{
		case 0: // TODO(andrei): Could we please use constants/enums/defines for these values?
			// 0 == Invisible block.
		break;

	case 1:
		// 1 == block visible and needs allocation, fits in the ordered list.
		vbaIdx = atomicSub(&allocData->noAllocatedVoxelEntries, 1);

		if (vbaIdx >= 0) //there is room in the voxel block array
		{
			Vector4s pt_block_all = blockCoords[targetIdx];

			ITMHashEntry hashEntry;
			hashEntry.pos.x = pt_block_all.x; hashEntry.pos.y = pt_block_all.y; hashEntry.pos.z = pt_block_all.z;
			hashEntry.ptr = voxelAllocationList[vbaIdx];
			hashEntry.offset = 0;

			hashTable[targetIdx] = hashEntry;
		}
		else
		{
			// TODO(andrei): Handle this better.
			printf("WARNING: No more room in VBA! vbaIdx became %d.\n", vbaIdx);
			printf("exlIdx is %d.\n", allocData->noAllocatedExcessEntries);
		}
		break;

	case 2:
		// 2 == block visible and needs allocation in the excess list
		vbaIdx = atomicSub(&allocData->noAllocatedVoxelEntries, 1);
		exlIdx = atomicSub(&allocData->noAllocatedExcessEntries, 1);

		if (vbaIdx >= 0 && exlIdx >= 0) //there is room in the voxel block array and excess list
		{
			Vector4s pt_block_all = blockCoords[targetIdx];

			ITMHashEntry hashEntry;
			hashEntry.pos.x = pt_block_all.x; hashEntry.pos.y = pt_block_all.y; hashEntry.pos.z = pt_block_all.z;
			hashEntry.ptr = voxelAllocationList[vbaIdx];
			hashEntry.offset = 0;

			int exlOffset = excessAllocationList[exlIdx];

			hashTable[targetIdx].offset = exlOffset + 1; //connect to child

			hashTable[SDF_BUCKET_NUM + exlOffset] = hashEntry; //add child to the excess list

			entriesVisibleType[SDF_BUCKET_NUM + exlOffset] = 1; //make child visible
		}
		else
		{
			// TODO(andrei): Handle this better.
			if (vbaIdx >= 0)
			{
				printf("WARNING: Could not allocate in excess list! There was still room in the main VBA, "
						   "but exlIdx = %d! Consider increasing the overall hash table size, or at least the "
						   "bucket size.\n", exlIdx);
			}
			else if(exlIdx)
			{
				printf("WARNING: Tried to allocate in excess list, but failed because the main VBA is "
							 "full. vbaIdx = %d\n", vbaIdx);
			}
			else
			{
				printf("WARNING: No more room in VBA or in the excess list! vbaIdx became %d.\n", vbaIdx);
				printf("exlIdx is %d.\n", exlIdx);
			}
		}
		break;

		default:
			printf("Unexpected alloc type: %d\n", static_cast<int>(entriesAllocType[targetIdx]));

		break;
	}
}

__global__ void reAllocateSwappedOutVoxelBlocks_device(int *voxelAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	AllocationTempData *allocData, /*int *noAllocatedVoxelEntries,*/ uchar *entriesVisibleType)
{
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	int vbaIdx;
	int hashEntry_ptr = hashTable[targetIdx].ptr;

	if (entriesVisibleType[targetIdx] > 0 && hashEntry_ptr == -1) //it is visible and has been previously allocated inside the hash, but deallocated from VBA
	{
		vbaIdx = atomicSub(&allocData->noAllocatedVoxelEntries, 1);
		if (vbaIdx >= 0) hashTable[targetIdx].ptr = voxelAllocationList[vbaIdx];
	}
}

template<bool useSwapping>
__global__ void buildVisibleList_device(
		ITMHashEntry *hashTable,
		ITMHashSwapState *swapStates,
		int noTotalEntries,
		int *visibleEntryIDs,
		AllocationTempData *allocData,
		uchar *entriesVisibleType,
		Matrix4f M_d,
		Vector4f projParams_d,
		Vector2i depthImgSize,
		float voxelSize
) {
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	__shared__ bool shouldPrefix;
	shouldPrefix = false;
	__syncthreads();

	unsigned char hashVisibleType = entriesVisibleType[targetIdx];
	const ITMHashEntry & hashEntry = hashTable[targetIdx];

	if (hashVisibleType == 3)
	{
		bool isVisibleEnlarged, isVisible;

		if (useSwapping)
		{
			checkBlockVisibility<true>(isVisible, isVisibleEnlarged, hashEntry.pos, M_d, projParams_d, voxelSize, depthImgSize);
			if (!isVisibleEnlarged) hashVisibleType = 0;
		} else {
			checkBlockVisibility<false>(isVisible, isVisibleEnlarged, hashEntry.pos, M_d, projParams_d, voxelSize, depthImgSize);
			if (!isVisible) hashVisibleType = 0;
		}
		entriesVisibleType[targetIdx] = hashVisibleType;
	}

	if (hashVisibleType > 0) shouldPrefix = true;

	if (useSwapping)
	{
		if (hashVisibleType > 0 && swapStates[targetIdx].state != 2) swapStates[targetIdx].state = 1;
	}

	__syncthreads();

	if (shouldPrefix)
	{
		int offset = computePrefixSum_device<int>(hashVisibleType > 0,
												  &allocData->noVisibleEntries,
												  blockDim.x * blockDim.y,
												  threadIdx.x);
		if (offset != -1) visibleEntryIDs[offset] = targetIdx;
	}

#if 0
	// "active list": blocks that have new information from depth image
	// currently not used...
	__syncthreads();

	if (shouldPrefix)
	{
		int offset = computePrefixSum_device<int>(hashVisibleType == 1, noActiveEntries, blockDim.x * blockDim.y, threadIdx.x);
		if (offset != -1) activeEntryIDs[offset] = targetIdx;
	}
#endif
}

template<class TVoxel>
__global__
void decay_device(TVoxel *localVBA, const ITMHashEntry *hashTable, int *visibleEntryIDs, int maxWeight) {
	// Note: there are no range checks because we launch exactly as many threads as we need.

	int entryId = visibleEntryIDs[blockIdx.x];
	const ITMHashEntry &currentHashEntry = hashTable[entryId];

	if (currentHashEntry.ptr < 0) {
		printf("currentHashEntry.ptr < 0...\n");
		return;
	}

	//*
	// The global position of the voxel block.
	Vector3i globalPos = currentHashEntry.pos.toInt() * SDF_BLOCK_SIZE;
	TVoxel *localVoxelBlock = &(localVBA[currentHashEntry.ptr * SDF_BLOCK_SIZE3]);

	int x = threadIdx.x, y = threadIdx.y, z = threadIdx.z;

//	Vector4f pt_model;

	// The local offset of the voxel in the current block.
	int locId = x + y * SDF_BLOCK_SIZE + z * SDF_BLOCK_SIZE * SDF_BLOCK_SIZE;

//	if (blockIdx.x % 200 == 31 && 0 == locId) {
//		printf("Entry ID from visible list: %8d | localVBA = %p | localVoxelBlock = %p\n",
//			   entryId,
//			   localVBA,
//			   localVoxelBlock);
//
//		short depth = localVoxelBlock[locId].w_depth;
//		printf("...[locId].w_depth = %d\n", static_cast<int>(depth));
//	}


  //*
	if (localVoxelBlock[locId].w_depth <= maxWeight && localVoxelBlock[locId].w_depth > 0) {
		localVoxelBlock[locId].clr = Vector3u(0, 0, 0);
		localVoxelBlock[locId].sdf = 100;

	}
}


template class ITMLib::Engine::ITMSceneReconstructionEngine_CUDA<ITMVoxel, ITMVoxelIndex>;

