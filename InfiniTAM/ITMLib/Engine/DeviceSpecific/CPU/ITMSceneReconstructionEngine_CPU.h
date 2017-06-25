// Copyright 2014-2015 Isis Innovation Limited and the authors of InfiniTAM

#pragma once

#include "../../ITMSceneReconstructionEngine.h"

namespace ITMLib
{
	namespace Engine
	{
		template<class TVoxel, class TIndex>
		class ITMSceneReconstructionEngine_CPU : public ITMSceneReconstructionEngine < TVoxel, TIndex >
		{};

		template<class TVoxel>
		class ITMSceneReconstructionEngine_CPU<TVoxel, ITMVoxelBlockHash> : public ITMSceneReconstructionEngine < TVoxel, ITMVoxelBlockHash >
		{
		protected:
			ORUtils::MemoryBlock<unsigned char> *entriesAllocType;
			ORUtils::MemoryBlock<Vector4s> *blockCoords;

		public:
			void ResetScene(ITMScene<TVoxel, ITMVoxelBlockHash> *scene);

			void AllocateSceneFromDepth(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view, const ITMTrackingState *trackingState,
				const ITMRenderState *renderState, bool onlyUpdateVisibleList = false);

			void IntegrateIntoScene(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view, const ITMTrackingState *trackingState,
				const ITMRenderState *renderState);

			void Decay(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, int maxWeight, int minAge) override;

			ITMSceneReconstructionEngine_CPU(void);
			~ITMSceneReconstructionEngine_CPU(void);
		};

		template<class TVoxel>
		class ITMSceneReconstructionEngine_CPU<TVoxel, ITMPlainVoxelArray> : public ITMSceneReconstructionEngine < TVoxel, ITMPlainVoxelArray >
		{
		public:
			void ResetScene(ITMScene<TVoxel, ITMPlainVoxelArray> *scene);

			void AllocateSceneFromDepth(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view, const ITMTrackingState *trackingState,
				const ITMRenderState *renderState, bool onlyUpdateVisibleList = false);

			void IntegrateIntoScene(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view, const ITMTrackingState *trackingState,
				const ITMRenderState *renderState);

			void Decay(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, int maxWeight, int minAge) override;

			ITMSceneReconstructionEngine_CPU(void);
			~ITMSceneReconstructionEngine_CPU(void);
		};
	}
}
