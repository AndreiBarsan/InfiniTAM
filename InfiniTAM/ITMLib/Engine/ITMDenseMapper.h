// Copyright 2014-2015 Isis Innovation Limited and the authors of InfiniTAM

#pragma once

#include "../Utils/ITMLibDefines.h"
#include "../Utils/ITMLibSettings.h"

#include "../Objects/ITMScene.h"
#include "../Objects/ITMTrackingState.h"
#include "../Objects/ITMRenderState.h"

#include "../Engine/ITMSceneReconstructionEngine.h"
#include "../Engine/ITMVisualisationEngine.h"
#include "../Engine/ITMSwappingEngine.h"

namespace ITMLib
{
	namespace Engine
	{
		/** \brief
		*/
		template<class TVoxel, class TIndex>
		class ITMDenseMapper
		{
		private:
			ITMSceneReconstructionEngine<TVoxel,TIndex> *sceneRecoEngine;
			ITMSwappingEngine<TVoxel,TIndex> *swappingEngine;

		public:
			void ResetScene(ITMScene<TVoxel,TIndex> *scene);

			/// Process a single frame
			void ProcessFrame(const ITMView *view, const ITMTrackingState *trackingState, ITMScene<TVoxel,TIndex> *scene, ITMRenderState *renderState_live);

			/// Update the visible list (this can be called to update the visible list when fusion is turned off)
			void UpdateVisibleList(const ITMView *view, const ITMTrackingState *trackingState, ITMScene<TVoxel,TIndex> *scene, ITMRenderState *renderState);

			/// Removes voxels with a weight smaller than `maxWeight` and an age greater than
			/// `minAge` de-allocating blocks which become empty in the process.
			void Decay(ITMScene<TVoxel, TIndex> *scene,
					   int maxWeight,
					   int minAge);

			/** \brief Constructor
			    Ommitting a separate image size for the depth images
			    will assume same resolution as for the RGB images.
			*/
			explicit ITMDenseMapper(const ITMLibSettings *settings);
			~ITMDenseMapper();
		};
	}
}

