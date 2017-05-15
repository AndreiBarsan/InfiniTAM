

#ifndef INFINITAM_SEGMENTATIONPROVIDER_H
#define INFINITAM_SEGMENTATIONPROVIDER_H

#include <memory>

#include "../ITMLib/Objects/ITMView.h"
#include "InstanceSegmentationResult.h"

namespace InstRecLib {
	namespace Segmentation {

		/// \brief Performs semantic segmentation on input frames.
		class SegmentationProvider {
		public:
			virtual ~SegmentationProvider() { };

			/// \brief Performs semantic segmentation of the given frame.
			/// Usually uses only RGB data, but some segmentation pipelines may leverage e.g., depth as well.
			virtual std::shared_ptr<InstanceSegmentationResult> SegmentFrame(
					ITMLib::Objects::ITMView *view) = 0;

			virtual ITMUChar4Image *GetSegResult() = 0;

			virtual const ITMUChar4Image *GetSegResult() const = 0;
		};
	}
}


#endif //INFINITAM_SEGMENTATIONPROVIDER_H
