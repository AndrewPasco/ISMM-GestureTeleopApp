# ISMM-GestureTeleop

An iOS app for real-time gesture-based teleoperation. This app captures synchronized RGB and depth frames from the iPhone camera, detects hand gestures using MediaPipe, estimates the 3D pose of the user's palm, and streams the relevant information to a remote server over TCP.

## Features

- Real-time hand gesture recognition using MediaPipe's GestureRecognizer.
- 3D palm pose estimation using RGB-D input and SVD-based plane fitting.
- TCP-based communication with a remote robot or server.
- Visual overlay for recognized gestures and landmark positions.
- Modular design for camera handling, gesture recognition, and networking.

## Getting Started

### Prerequisites

- Xcode 15 or later
- iOS device with TrueDepth or LiDAR camera (for depth capture)
- Swift 5.9+
- CocoaPods
- MediaPipeTasksVision framework integrated into the project

### Installation

1. **Clone this repository:**
   ```bash
   git clone https://github.com/AndrewPasco/ISMM-GestureTeleop.git
   cd ISMM-GestureTeleop/bash```

2. **Install dependencies** (e.g., via CocoaPods or SPM):
Make sure MediaPipeTasksVision and any other required frameworks are linked.

3. **Build and run on a real device** — depth capture is not available in the simulator.

## App Structure
- ISMMGestureTeleopApp: Main coordinator handling camera capture, gesture recognition, depth data processing, and TCP streaming.
- CameraManager: Manages synchronized RGB and depth capture using AVCaptureMultiCamSession.
- TCPClient: Handles low-level TCP socket communication.
- FrameEncoder: (optional) Handles JPEG compression and packaging of data (not shown in main file).
- ResultOverlayView: Renders hand landmarks and recognized gesture label on top of the preview.

### How It Works

1. Frame Capture:
- Captures RGB and depth frames using CameraManager.
- Attaches intrinsic matrix metadata from the camera.
2. Gesture Recognition:
- Converts the RGB frame to MPImage with correct orientation.
- Passes the image and timestamp to MediaPipe’s GestureRecognizer.
3. 3D Pose Estimation:
- Matches the recognition result to the cached depth frame by timestamp.
- Extracts depth values at key palm landmark positions.
- Computes 3D palm orientation using SVD plane fitting.
- Builds a 4×4 transformation matrix (pose).
4. Networking:
- Sends recognized gesture and pose data to a remote server via TCPClient.
5. Visualization:
- Draws 2D palm landmarks and gesture labels on the camera preview.

### Configuration

Adjust constants (such as the model path and gesture confidence thresholds) in the DefaultConstants struct. Ensure a compatible MediaPipe hand gesture model is available and correctly referenced.

### Future Improvements

- Add camera switching support (e.g., LiDAR vs TrueDepth).
- Enhance gesture filtering and prediction smoothing.
- Consider removing OpenCV framework (not currently used due to plane-normal approach)

## License

This project is licensed under the BSD 3-clause license. See the LICENSE file for details.

Some files were adapted from MediaPipe example implementations. See GestureRecognition/LICENSE\_MP file for details. 

## Author

Developed by Andrew Pasco (apascos@gmail.com) for gesture-based robot teleoperation research.
