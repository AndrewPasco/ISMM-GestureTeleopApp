//
//  TCPClient.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//


import Foundation

class TCPClient: NSObject, StreamDelegate {
    private var outputStream: OutputStream?
    private var reconnectTimer: Timer?
    private var host: String
    private var port: Int
    var isConnected = false
    var onStatusChange: ((ConnectionStatus) -> Void)?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

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

    private func scheduleReconnect() {
        if reconnectTimer != nil { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.connect()
        }
    }

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
