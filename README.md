# ISMM-GestureTeleop

A real-time iOS application for gesture-based robot teleoperation that captures synchronized RGB and depth data, recognizes hand gestures using MediaPipe, estimates 3D palm poses, and streams teleoperation commands to remote servers via TCP.

## Overview

ISMM-GestureTeleop transforms your iPhone into a sophisticated gesture control interface for robotic systems. The app leverages the device's TrueDepth or LiDAR camera to capture both RGB and depth information, enabling precise 3D hand tracking and pose estimation. Recognized gestures are translated into robot commands and transmitted over TCP for real-time teleoperation.

## Key Features

- **Real-time Hand Gesture Recognition**: Utilizes MediaPipe's GestureRecognizer for accurate hand gesture detection
- **3D Palm Pose Estimation**: Combines RGB-D input with SVD-based plane fitting for precise 3D pose calculation
- **Synchronized Data Capture**: Coordinates RGB and depth frame capture using AVCaptureMultiCamSession
- **TCP Communication**: Reliable streaming of gesture and pose data to remote robot controllers
- **Visual Feedback**: Real-time overlay showing hand landmarks and recognized gestures
- **Modular Architecture**: Clean separation of concerns across camera handling, gesture recognition, and networking

## Supported Gestures

- **Open Palm**: Initiates and maintains tracking mode
- **Closed Fist**: Toggles gripper open/close
- **Victory Sign**: Resets the robot to home position

## System Requirements

### Hardware
- iOS device with TrueDepth camera (iPhone X and later)
    - NOTE: currently only in development testing with iPhone 14
- Minimum iOS 14.0

### Software
- Xcode 15.0 or later
- Swift 5.9+
- CocoaPods or Swift Package Manager

## Installation

### 1. Clone the Repository
```bash
git clone https://github.com/AndrewPasco/ISMM-GestureTeleop.git
cd ISMM-GestureTeleop
```

### 2. Install Dependencies

#### Using CocoaPods
```bash
pod install
open ISMM-GestureTeleop.xcworkspace
```

### 3. Configure MediaPipe Model
1. Download the MediaPipe hand gesture recognition model "gesture_recognizer.task"
2. Add the model file to your Xcode project bundle
3. Update the model path in `DefaultConstants.swift`

### 4. Build and Deploy
1. Connect your iOS device via USB
2. Select your device as the build target
3. Build and run the project (⌘+R)

**Note**: The depth capture functionality requires a physical device and will not work in the iOS Simulator.

## Project Architecture

### Core Components

- **`ISMMGestureTeleopApp`**: Main coordinator managing the entire gesture recognition and teleoperation pipeline
- **`CameraManager`**: Handles synchronized RGB and depth data capture using AVFoundation
- **`PoseEstimator`**: Implements 3D pose estimation algorithms using SVD-based plane fitting
- **`TCPClient`**: Manages reliable TCP socket connections and data transmission
- **`GestureRecognizerResultDelegate`**: Bridges MediaPipe results with the main application logic
- **`ResultOverlayView`**: Provides visual feedback with hand landmark rendering and status display

### Data Flow

1. **Frame Capture**: `CameraManager` captures synchronized RGB and depth frames
2. **Gesture Recognition**: MediaPipe processes RGB frames to detect hand gestures
3. **Pose Estimation**: `PoseEstimator` combines landmark data with depth information for 3D pose calculation
4. **Command Generation**: Recognized gestures are filtered and translated into robot commands
5. **Network Transmission**: `TCPClient` streams commands to the target robot system
6. **Visual Feedback**: `ResultOverlayView` displays real-time tracking information

## Configuration

### Network Settings
Update the default IP address and port in `ViewController.swift`:
```swift
ipTextField.text = "HOST_IP"
let port = 5000  // Adjust as needed
```

### Gesture Recognition Parameters
Modify sensitivity and thresholds in `DefaultConstants.swift`:
```swift
static let minHandDetectionConfidence: Float = 0.5
static let minHandPresenceConfidence: Float = 0.5
static let minTrackingConfidence: Float = 0.5
```

Modify gesture to command behavior in `ISMMGestureTeleopApp.swift`:
```swift
private struct GestureConfig {
    static let maxConfidence: Float = 1.0
    static let minConfidence: Float = 0.0
    static let gestureIncrement: Float = 0.04
    static let gestureDecrement: Float = 0.09
    static let commandThreshold: Float = 0.7
    static let gripperThreshold: Float = 0.9
    static let commandStatusDisplayDurationMs: Int = 500
}
```

### Model Configuration
Ensure the MediaPipe model path is correctly set:
```swift
static let modelPath = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task")
```

## Usage

1. **Launch the App**: Open the app on your iOS device
2. **Enter Robot IP**: Input the IP address of your target robot system
3. **Connect**: Tap the "Connect" button to establish TCP connection
4. **Start Gesturing**: Use the supported hand gestures to control your robot:
   - Hold an open palm to begin tracking
   - Make a fist to toggle the gripper
   - Show a victory sign to reset the robot

## Command Protocol

The app transmits commands in the following format:
```
<Start> x y z qw qx qy qz    # Begin tracking with pose
<Track> x y z qw qx qy qz    # Update tracking pose
<End> x y z qw qx qy qz      # End tracking with final pose
<Gripper>                    # Toggle gripper state
<Reset>                      # Reset robot to home position
```

Where `x y z` represents the 3D translation and `qw qx qy qz` represents the orientation quaternion.

## Known Limitations

- Depth capture requires specific hardware (TrueDepth or LiDAR)
- Performance may vary under different lighting conditions
- Network latency affects real-time control responsiveness
- Single-hand tracking only


## License

This project is licensed under the BSD 3-Clause License. See the [LICENSE](LICENSE) file for details.

Some components are adapted from MediaPipe example implementations. See [GestureRecognition/LICENSE_MP](GestureRecognition/LICENSE_MP) for MediaPipe-specific licensing details.

## Author

**Andrew Pasco** - [apascos@gmail.com](mailto:apascos@gmail.com)

Developed for gesture-based robot teleoperation research at [Cyber Human Lab - Cambridge Institute for Manufacturing](cyberhuman.io).

## Acknowledgments
