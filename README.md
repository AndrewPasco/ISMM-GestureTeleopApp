# ISMMGestureTeleopApp

An iOS application that captures synchronized frames from the iPhone’s wide and ultra-wide rear cameras using `AVCaptureMultiCamSession`, encodes both images as JPEGs, and streams them over TCP to a server. This system is designed for stereo-based gesture recognition or vision-based robotic teleoperation.

---

## Features

- Captures frames simultaneously from wide and ultra-wide rear cameras
- Synchronizes frames using `AVCaptureDataOutputSynchronizer`
- Encodes both frames as JPEG for efficient streaming
- Streams frame pairs over a TCP connection to a remote server
- Simple UI for IP entry and connection status
- Auto-reconnect on connection loss
- Live camera preview

---

## Requirements

- iPhone with wide and ultra-wide rear cameras (e.g., iPhone 11 or newer)
- iOS 15 or later
- Xcode 13+
- Swift 5.5+

---

## Project Structure

### `ViewController.swift`

Handles the app UI:
- `UITextField` for IP address input
- `UIButton` to initiate connection
- `UILabel` to display connection status

Also initializes the app coordination logic and connects the camera preview to the screen.

### `ISMMGestureTeleopApp.swift`

Coordinates the full application:
- Instantiates and starts the camera manager
- Receives synchronized wide + ultra-wide frames
- Encodes both frames using `FrameEncoder`
- Sends encoded data to the TCP server
- Handles connection lifecycle

### `CameraManager.swift`

Manages camera input:
- Configures `AVCaptureMultiCamSession`
- Captures from wide and ultra-wide rear cameras
- Uses `AVCaptureDataOutputSynchronizer` for frame synchronization
- Provides preview via `AVCaptureVideoPreviewLayer`

### `FrameEncoder.swift`

Encodes frames for transmission:
- Converts `CVPixelBuffer`s to `CIImage`
- Encodes each image as JPEG
- Constructs a packet with the format:

[4 bytes wide JPEG size] [4 bytes ultra-wide JPEG size] [wide JPEG data] [ultra-wide JPEG data]

- Length values are big-endian `UInt32`s.
- Both JPEGs are encoded using Core Image (`CIContext.jpegRepresentation`).

---

## Frame Synchronization

- Frames are synchronized using `AVCaptureDataOutputSynchronizer`.
- Only synchronized pairs are sent.
- Both frames are captured at 640x480 resolution by default (configurable).

---

## Reconnection Logic

If the TCP stream disconnects:
- The app updates the status label
- It attempts to reconnect every 3 seconds until successful or terminated

---

## Permissions

The app requires access to the rear-facing camera. Be sure to include the following in your `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to capture stereo images for teleoperation</string>
/xml```

## Limitations

Designed for iPhones with both wide and ultra-wide cameras
No built-in encryption (data sent in plain TCP)
No background streaming support
No server-side logic included
UI is UIKit-based (not yet migrated to SwiftUI)

## Future Improvements

Migrate UI to SwiftUI
Add FPS control
Enable adjustable resolution or frame rate
Support optional depth estimation on-device


## License

This project is licensed under the BSD 3-clause license. See the LICENSE file for details.

## Author

Developed by Andrew Pasco (apascos@gmail.com) for gesture-based robot teleoperation research.
