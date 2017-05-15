

#include "InstanceTracker.h"

#include <cassert>

namespace InstRecLib {
	namespace Reconstruction {

		using namespace std;
		using namespace InstRecLib::Segmentation;

		void InstanceTracker::ProcessChunks(
				int frame_idx,
				const vector<InstanceDetection>& new_detections
		) {
			// TODO(andrei): also accept actual DATA!!
			cout << "Frame [" << frame_idx << "]. Processing " << new_detections.size()
			     << " new detections." << endl;

			list<TrackFrame> new_track_frames;
			for(const InstanceDetection& detection : new_detections) {
				new_track_frames.emplace_back(frame_idx, detection);
			}

			// 1. Find a matching track.
			this->AssignToTracks(new_track_frames);

			// 2. For leftover detections, put them into new, single-frame, trackes.
			cout << new_track_frames.size() << " new unassigned frames." << endl;
			for (const TrackFrame &track_frame : new_track_frames) {
				Track new_track;
				new_track.AddFrame(track_frame);
				this->active_tracks_.push_back(new_track);
			}

			cout << "We now have " << this->active_tracks_.size() << " active tracks." << endl;

			// 3. Iterate through tracks, find ``expired'' ones, and discard them.
			this->PruneTracks(frame_idx);
		}

		void InstanceTracker::PruneTracks(int current_frame_idx) {
			for(auto it = active_tracks_.begin(); it != active_tracks_.end(); ++it) {
				int last_active = it->GetEndTime();
				int frame_delta = current_frame_idx - last_active;

				if (frame_delta > inactive_frame_threshold_) {
					it = active_tracks_.erase(it);
				}
			}
		}

		std::pair<Track *, float> InstanceTracker::FindBestTrack(const TrackFrame &track_frame) {
			if (active_tracks_.empty()) {
				return kNoBestTrack;
			}

			float best_score = -1.0f;
			Track *best_track = nullptr;

			for (Track& track : active_tracks_) {
				float score = track.ScoreMatch(track_frame);
				if (score > best_score) {
					best_score = score;
					best_track = &track;
				}
			}

			assert(best_score >= 0.0f);
			assert(best_track != nullptr);
			return std::pair<Track*, float>(best_track, best_score);
		}

		void InstanceTracker::AssignToTracks(std::list<TrackFrame> &new_detections) {
			for(auto it = new_detections.begin(); it != new_detections.end(); ++it) {
				pair<Track*, float> match = FindBestTrack(*it);
				Track* track = match.first;
				float score = match.second;

				if (score > kTrackScoreThreshold) {
					cout << "Found a match based on overlap with score " << score << "." << endl;
					cout << "Adding it to track of length " << track->GetSize() << "." << endl;

					track->AddFrame(*it);
					it = new_detections.erase(it);
				}
//				else {
//					cout << "Best score was: " << score << ", below the threshold. Will create new track."
//					     << endl;
//				}
			}
		}
	}
}

