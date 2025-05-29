# ISMMGestureTeleopApp

An iOS application that streams synchronized RGB and depth data from the iPhone's TrueDepth front-facing camera over TCP to a remote server. It is designed for use in gesture-based robot teleoperation systems.

---

## Features

- Captures RGB and depth frames using the TrueDepth camera.
- Synchronizes RGB and depth frames to ensure temporal alignment.
- Encodes:
  - RGB images as JPEG
  - Depth maps as 16-bit PNG
- Streams data over TCP with a simple, custom protocol.
- Provides live camera preview and a basic user interface for entering the server IP and managing connection status.
- Automatically attempts to reconnect if the TCP connection is lost.

---

## Requirements

- iPhone or iPad with a TrueDepth front-facing camera (e.g., iPhone X or later)
- iOS 15 or later
- Xcode 13 or later
- Swift 5.5+

---

## Project Structure

### ViewController.swift

Handles UI components:
- `UITextField` for entering server IP address
- `UIButton` to initiate connection
- `UILabel` to show connection status

This file manages user interaction and initializes the main camera streaming logic.

### ISMMGestureTeleopApp.swift

Implements core functionality:
- Configures and starts the AV capture session
- Synchronizes RGB and depth frames
- Encodes RGB as JPEG and depth as 16-bit PNG
- Sends synchronized frame pairs over a TCP socket
- Manages reconnection logic on connection loss

---

## Usage

1. Open the project in Xcode.
2. Connect a physical iOS device (simulators do not support the TrueDepth camera).
3. Build and run the app on the device.
4. Enter the IP address of the remote server.
5. Tap the "Connect" button.
6. The app will begin streaming RGB and depth frames once the connection is established.

---

## TCP Packet Format

Each transmitted frame pair follows this format:

[4 bytes: RGB JPEG size] [4 bytes: Depth PNG size] [RGB JPEG data] [Depth PNG data]

- The first 4 bytes are a big-endian integer representing the size of the JPEG data.
- The next 4 bytes are a big-endian integer representing the size of the PNG data.
- RGB and depth images are then sent consecutively.

---

## Frame Encoding

### RGB

- Captured from the front-facing camera.
- Converted from `CMSampleBuffer` to `UIImage`.
- Encoded to JPEG using `CIContext.jpegRepresentation`.

### Depth

- Captured using `AVDepthData`.
- Converted to 16-bit grayscale format with a maximum depth range of 5.0 meters.
- Encoded as PNG using `CGImageDestination`.

Each pixel in the depth PNG represents the distance in millimeters, normalized to fit within the 16-bit unsigned integer range.

---

## Reconnection Logic

If the TCP socket disconnects:
- The app updates the UI with the disconnection status.
- It attempts to reconnect every 3 seconds until successful or the user quits.

---

## Configuration Details

- TCP port is fixed at `5000`.
- Maximum depth value: `5.0` meters.
- Frame resolution: `640x480` (both RGB and depth).
- Framerate: depends on device and camera performance (typically 30 FPS).

---

## Privacy and Permissions

This app uses the front-facing TrueDepth camera. The user must grant camera permission on first launch. It is recommended to inform users of how their image and depth data will be used.

---

## Limitations

- Does not support background mode; app must be in the foreground to access the TrueDepth camera.
- No built-in encryption; TCP data is sent in plain text over the network.
- No support for multiple concurrent clients.
- Server IP and port are currently hardcoded or manually entered.

---

## Future Improvements

- Support Video encoding style rather than image encoding

---

## License

This project is licensed under the BSD 3-clause license. See the `LICENSE` file for details.

---

## Author

Developed by Andrew Pasco (apascos@gmail.com) for use in gesture-based robot teleoperation systems.

