//
//  SocketProtocol.swift
//
//
//  Created by Evan Anderson on 10/17/24.
//

import Foundation

// MARK: SocketProtocol
public protocol SocketProtocol : ~Copyable {
    static var bufferLength : Int { get }
    var fileDescriptor : Int32 { get }
    var closed : Bool { get set }
    consuming func close()

    func write(_ pointer: UnsafeRawPointer, length: Int) throws
}

public extension SocketProtocol where Self : ~Copyable {
    consuming func close() {
        guard !closed else { return }
        closed = true
        unistd.close(fileDescriptor)
    }

    func deinitalize() {
        guard !closed else { return }
        unistd.close(fileDescriptor)
    }
}

// MARK: SocketProtocol reading
public extension SocketProtocol where Self : ~Copyable {
    @inlinable
    func readHttpRequest() throws -> [Substring] {
        let status:String = try readLine()
        let tokens:[Substring] = status.split(separator: " ")
        guard tokens.count >= 3 else {
            throw SocketError.invalidStatus()
        }
        // 0 == method
        // 1 == path
        // 2 == http version
        return tokens
    }

    /// Reads 1 byte
    @inlinable
    func read() throws -> UInt8 {
        var result:UInt8 = 0
        unistd.read(fileDescriptor, &result, 1)
        guard result > 0 else { throw SocketError.readFailed() }
        return result
    }
    /// Reads and loads multiple bytes into an UInt8 array
    @inlinable
    func read(length: Int) throws -> [UInt8] {
        return try [UInt8](unsafeUninitializedCapacity: length, initializingWith: { $1 = try read(into: &$0, length: length) })
    }

    @inlinable
    func readLine() throws -> String {
        var line:String = ""
        var index:UInt8 = 0
        while index != 10 {
            index = try self.read()
            if index > 13 {
                line.append(Character(UnicodeScalar(index)))
            }
        }
        return line
    }

    /*
    /// Reads and loads multiple bytes into an UInt8 array
    @inlinable
    func read<T : Decodable>(decoder: Decoder) throws -> T {
        let length:Int = MemoryLayout<T>.size
        var buffer:UnsafeMutableBufferPointer<UInt8> = .allocate(capacity: length)
        try read(into: &buffer, length: length)
        return buffer.withUnsafeBytes {
            $0.withMemoryRebound(to: T.self, { _ in
                T.init(from: decoder)
            })
        }
    }*/

    /// Reads and writes multiple bytes into a buffer
    @inlinable
    func read(into buffer: inout UnsafeMutableBufferPointer<UInt8>, length: Int) throws -> Int {
        var bytes_read:Int = 0
        guard let baseAddress:UnsafeMutablePointer<UInt8> = buffer.baseAddress else { return 0 }
        while bytes_read < length {
            let to_read:Int = min(bytes_read + Self.bufferLength, length)
            let read_bytes:Int = unistd.read(fileDescriptor, baseAddress + bytes_read, to_read)
            guard read_bytes > 0 else {
                throw SocketError.readFailed()
            }
            bytes_read += read_bytes
        }
        return bytes_read
    }
}


// MARK: SocketProtocol writing
public extension SocketProtocol where Self : ~Copyable {
    /*
    func write(_ bytes: ArraySlice<UInt8>) throws {
        try bytes.withUnsafeBufferPointer {
            try write($0.baseAddress!, length: $0.count)
        }
    }*/
    @inlinable
    func write(_ pointer: UnsafeRawPointer, length: Int) throws {
        guard !closed else { return }
        var sent:Int = 0
        while sent < length {
            let result:Int = unistd.write(fileDescriptor, pointer + sent, length - sent)
            if result <= 0 { throw SocketError.writeFailed() }
            sent += result
        }
    }
}

// MARK: SocketError
public enum SocketError : Error {
    case acceptFailed(String = String(cString: strerror(errno)))
    case writeFailed(String = String(cString: strerror(errno)))
    case readFailed(String = String(cString: strerror(errno)))
    case invalidStatus(String = String(cString: strerror(errno)))
}