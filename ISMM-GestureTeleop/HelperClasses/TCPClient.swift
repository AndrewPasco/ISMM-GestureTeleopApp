//
//  TCPClient.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//
//  Description: TCP client implementation for real-time gesture teleop communication.
//  Provides reliable TCP socket connection with automatic reconnection capabilities
//  for sending gesture commands to remote robotic systems.
//


import Foundation

/**
 * TCP client class that manages network communication for gesture teleop commands.
 *
 * Features:
 * - Automatic connection management with retry logic
 * - Stream-based data transmission
 * - Connection status monitoring and callbacks
 * - Robust error handling and reconnection attempts
 */
class TCPClient: NSObject, StreamDelegate {
    
    // MARK: - Properties
    
    /// Output stream for sending data to the server
    private var outputStream: OutputStream?
        
    /// Timer for automatic reconnection attempts
    private var reconnectTimer: Timer?
    
    /// Target server hostname or IP address
    private var host: String
    
    /// Target server port number
    private var port: Int
    
    /// Current connection status flag
    var isConnected = false
    
    /// Callback closure for connection status changes
    var onStatusChange: ((ConnectionStatus) -> Void)?

    // MARK: - Initialization
        
    /**
     * Initializes a new TCP client instance.
     *
     * - Parameters:
     *   - host: The hostname or IP address of the target server
     *   - port: The port number on which the server is listening
     */
    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

    // MARK: - Connection Management
        
    /**
     * Initiates connection to the configured server.
     *
     * Updates connection status to .connecting and creates socket streams.
     * On failure, automatically schedules reconnection attempts.
     */
    func connect() {
        onStatusChange?(.connecting)
        isConnected = false

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let outStream = writeStream?.takeRetainedValue() else {
            print("Failed to create output stream")
            onStatusChange?(.failed)
            scheduleReconnect()
            return
        }

        outputStream = outStream
        outputStream?.delegate = self
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
    }

    /**
     * Schedules automatic reconnection attempts on a timer.
     *
     * Creates a repeating timer that attempts to reconnect every 3 seconds
     * until a successful connection is established.
     */
    private func scheduleReconnect() {
        if reconnectTimer != nil { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.connect()
        }
    }

    // MARK: - Data Transmission
        
    /**
     * Sends data to the connected server.
     *
     * Handles partial writes and ensures all data is transmitted completely.
     * Validates that data is non-empty and stream is available before sending.
     *
     * - Parameter data: The data to be sent to the server
     */
    func send(data: Data) {
        guard !data.isEmpty else {
            print("Attempted to send empty data")
            return
        }
        
        guard let stream = outputStream else { return }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var bytesRemaining = data.count
            var totalBytesSent = 0
            while bytesRemaining > 0 {
                let bytesSent = stream.write(
                    buffer.baseAddress!.advanced(by: totalBytesSent).assumingMemoryBound(to: UInt8.self),
                    maxLength: bytesRemaining
                )
                if bytesSent <= 0 {
                    print("Failed to send data")
                    return
                }
                bytesRemaining -= bytesSent
                totalBytesSent += bytesSent
            }
        }
    }

    // MARK: - StreamDelegate
        
    /**
     * Handles stream events for connection status monitoring.
     *
     * Processes connection establishment, errors, and disconnections.
     * Automatically triggers reconnection on failures or disconnections.
     *
     * - Parameters:
     *   - aStream: The stream that generated the event
     *   - eventCode: The type of stream event that occurred
     */
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            isConnected = true
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            onStatusChange?(.connected)
        case .errorOccurred:
            aStream.close()
            isConnected = false
            onStatusChange?(.failed)
            scheduleReconnect()
        case .endEncountered:
            aStream.close()
            isConnected = false
            onStatusChange?(.disconnected)
            scheduleReconnect()
        default:
            break
        }
    }
}

public enum ConnectionStatus {
    case connecting
    case connected
    case failed
    case disconnected
}
