import AppKit
import Foundation

enum HapticPattern {
    case tick
    case lock
    case transferStart
    case queued
    case success
    case failure
}

final class HapticService {
    func fire(_ pattern: HapticPattern) {
        let feedbackPattern: NSHapticFeedbackManager.FeedbackPattern
        let performanceTime: NSHapticFeedbackManager.PerformanceTime

        switch pattern {
        case .tick:
            feedbackPattern = .generic
            performanceTime = .now
        case .lock:
            feedbackPattern = .alignment
            performanceTime = .now
        case .transferStart:
            feedbackPattern = .generic
            performanceTime = .now
        case .queued:
            feedbackPattern = .levelChange
            performanceTime = .default
        case .success:
            feedbackPattern = .levelChange
            performanceTime = .now
        case .failure:
            // Keep failure tactile restrained; the visual shake carries state.
            feedbackPattern = .generic
            performanceTime = .default
        }

        NSHapticFeedbackManager.defaultPerformer.perform(
            feedbackPattern,
            performanceTime: performanceTime
        )
    }
}
