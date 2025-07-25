// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// See GestureRecognition/LICENSE_MP for license.

import Foundation
import UIKit
import MediaPipeTasksVision

// MARK: Define default constants
struct DefaultConstants {
    static let lineWidth: CGFloat = 2
    static let pointRadius: CGFloat = 5
    static let pointColor = UIColor.yellow
    static let pointFillColor = UIColor.red
    static let lineColor = UIColor(red: 0, green: 127/255.0, blue: 139/255.0, alpha: 1)

    static var minHandDetectionConfidence: Float = 0.5
    static var minHandPresenceConfidence: Float = 0.3
    static var minTrackingConfidence: Float = 0.3
    static let modelPath: String? = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task")
    static let delegate: GestureRecognizerDelegate = .CPU

    static let PALM_INDICES = [0, 5, 12, 17]
    static let PREVIEW_DIMS = (WIDTH: 390, HEIGHT: 763) // should probably be grabbing these from device config
    static let IMAGE_DIMS = (WIDTH: 1920.0, HEIGHT: 1080.0)
    
    static let SLERP_T = 0.2 // lower seems better on this, probably 0.15/0.2, higher is still too noisy and lower seems to limit range of motion
    static let EMA_ALPHA = 0.5
    
    static let MAX_ANGLE_DIFF = Double.pi/6 // 30 degrees
    static let MAX_POS_DIFF = 0.25 // 250cm
}

// MARK: GestureRecognizerDelegate
enum GestureRecognizerDelegate: CaseIterable {
  case GPU
  case CPU

  var name: String {
    switch self {
    case .GPU:
      return "GPU"
    case .CPU:
      return "CPU"
    }
  }

  var delegate: Delegate {
    switch self {
    case .GPU:
      return .GPU
    case .CPU:
      return .CPU
    }
  }

  init?(name: String) {
    switch name {
    case GestureRecognizerDelegate.CPU.name:
      self = GestureRecognizerDelegate.CPU
    case GestureRecognizerDelegate.GPU.name:
      self = GestureRecognizerDelegate.GPU
    default:
      return nil
    }
  }
}

