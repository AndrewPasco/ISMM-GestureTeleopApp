//
//  GestureRecognizerResultDelegate.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 02/06/25.
//

import MediaPipeTasksVision

// Class that conforms to the `GestureRecognizerLiveStreamDelegate` protocol and
// implements the method that the gesture recognizer calls once it finishes
// performing recognizing hand gestures in each input frame.
// Simply return the result back to the main class, necessary given multiple recognizer instances
class GestureRecognizerResultDelegate: NSObject, GestureRecognizerLiveStreamDelegate {
    var onGestureResult: ((GestureRecognizerResult, Int) -> Void)?

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
