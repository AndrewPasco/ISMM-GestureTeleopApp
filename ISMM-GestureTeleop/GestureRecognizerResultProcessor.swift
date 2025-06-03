//
//  and.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 02/06/25.
//


import MediaPipeTasksVision

// Class that conforms to the `GestureRecognizerLiveStreamDelegate` protocol and
// implements the method that the gesture recognizer calls once it finishes
// performing recognizing hand gestures in each input frame.
class GestureRecognizerResultProcessor: NSObject, GestureRecognizerLiveStreamDelegate {

  func gestureRecognizer(
    _ gestureRecognizer: GestureRecognizer,
    didFinishRecognition result: GestureRecognizerResult?,
    timestampInMilliseconds: Int,
    error: Error?) {

    // Process the gesture recognizer result or errors here.

  }
}

let modelPath = Bundle.main.path(
  forResource: "gesture_recognizer",
  ofType: "task")

let options = GestureRecognizerOptions()
options.baseOptions.modelAssetPath = modelPath
options.runningMode = .liveStream
options.minHandDetectionConfidence = minHandDetectionConfidence
options.minHandPresenceConfidence = minHandPresenceConfidence
options.minTrackingConfidence = minHandTrackingConfidence
options.numHands = numHands

// Assign an object of the class to the `gestureRecognizerLiveStreamDelegate`
// property.
let processor = GestureRecognizerResultProcessor()
options.gestureRecognizerLiveStreamDelegate = processor

let gestureRecognizer = try GestureRecognizer(options: options)
    