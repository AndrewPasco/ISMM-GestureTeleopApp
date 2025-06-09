//
//  GestureRecognizerResultDelegate.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 02/06/25.
//
//  Description: Delegate class for MediaPipe gesture recognition results.
//  Implements the GestureRecognizerLiveStreamDelegate protocol to receive
//  asynchronous gesture recognition results and forward them via callback closures.
//

import MediaPipeTasksVision

/**
 * Delegate class that receives MediaPipe gesture recognition results.
 *
 * This class serves as a bridge between MediaPipe's gesture recognizer and the main
 * application logic. It implements the required delegate protocol and uses callback
 * closures to forward results, enabling multiple recognizer instances with different
 * processing logic.
 *
 * Features:
 * - Implements MediaPipe's live stream delegate protocol
 * - Provides callback-based result forwarding
 * - Handles error conditions gracefully
 * - Supports multiple recognizer instances
 */
class GestureRecognizerResultDelegate: NSObject, GestureRecognizerLiveStreamDelegate {
    
    // MARK: - Properties
    
    /// Callback closure for forwarding gesture recognition results
    /// Parameters: (result, timestampInMilliseconds)
    var onGestureResult: ((GestureRecognizerResult, Int) -> Void)?

    // MARK: - GestureRecognizerLiveStreamDelegate
    
    /**
     * Called when MediaPipe gesture recognizer completes processing a frame.
     *
     * This method is invoked asynchronously by MediaPipe when gesture recognition
     * is complete for a frame. It validates the result and forwards it via the
     * callback closure if successful.
     *
     * - Parameters:
     *   - gestureRecognizer: The MediaPipe gesture recognizer instance
     *   - result: The recognition result containing detected gestures and landmarks
     *   - timestampInMilliseconds: Frame timestamp for synchronization
     *   - error: Any error that occurred during recognition
     */
    func gestureRecognizer(
            _ gestureRecognizer: GestureRecognizer,
            didFinishGestureRecognition result: GestureRecognizerResult?,
            timestampInMilliseconds: Int,
            error: Error?
        ) {
        guard error == nil, let result = result else {
            print("Error or no result: \(String(describing: error))")
            return
        }
        onGestureResult?(result, timestampInMilliseconds)
    }
}
