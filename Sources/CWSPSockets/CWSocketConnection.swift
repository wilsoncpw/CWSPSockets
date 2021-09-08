//
//  CWSocketConnection.swift
//  CWSockets
//
//  Created by Colin Wilson on 31/10/2019.
//  Copyright © 2019 Colin Wilson. All rights reserved.
//

import Foundation

internal protocol CWSocketConnectionDelegate: AnyObject {
    func asyncDisconnected (connection: CWSocketConnection)
    func hasData (connection: CWSocketConnection)
}

public struct Variables {
    public static var debugInit = true
}

internal func debugInitPrint (_ st: Any...) {
    
    if Variables.debugInit {
        print (st)
    }
}

//-----------------------------------------------------------------------------
/// CWSocketConnection class used for bothe client and server connections
final public class CWSocketConnection {
    public let host: String

    private let socket: CWSocket
    private let asyncQueue: DispatchQueue
    internal weak var delegate: CWSocketConnectionDelegate?
    
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let readBuffer = CWSmartByteBuffer (initialSize: 1024*1024)
    private let writeBuffer = CWSmartByteBuffer (initialSize: 1024*1024)
    
    private var socketRefCount = 0
    private var writeSourceResumed = false
    private let sendBufferSize: Int
    
    public var context: String?
    public var error: Error?
    
    //-----------------------------------------------------------------------------
    /// init - Constructor
    /// - Parameter socket: The connected socket
    /// - Parameter host: The remote host name or IP
    /// - Parameter asyncQueue: An asyn queue to use
    /// - Parameter delegate: The delegate
    internal init (socket: CWSocket, host: String, asyncQueue: DispatchQueue) throws {
        self.socket = socket
        self.asyncQueue = asyncQueue
        self.host = host
        self.sendBufferSize = Int (try socket.getSendBufferSize())
        
        self.readSource = socket.makeReadSource(queue: asyncQueue)
        self.writeSource = socket.makeWriteSource(queue: asyncQueue)
        self.socketRefCount = 2

        readSource.setCancelHandler(handler: cancelHandler)
        readSource.setEventHandler(handler: readHandler)
        
        writeSource.setCancelHandler(handler: cancelHandler)
        writeSource.setEventHandler(handler: writeHandler)
        
        debugInitPrint ("CWSocketConnection init")
    }
    
    //-----------------------------------------------------------------------------
    /// Start monitoring the connection for received data
    internal func start () {
        readSource.resume()
    }
    
    deinit {
        debugInitPrint ("CWSocketConnection deinit")
    }
    
    //-----------------------------------------------------------------------------
    /// Called by the readSource on the asyncQueue when data arrives.  Read it onto the readBuffer
    /// then let the delegate know we've got some data
    private func readHandler () {
        let bytesAvailable = readSource.data
        do {
            
            guard bytesAvailable > 0, let buf = try readBuffer.getWritePointer(bytesAvailable) else {
                throw POSIXError (POSIXErrorCode.ECONNRESET)
            }
                    
            let bytesRead = try socket.read(buf, len: Int (bytesAvailable))
            readBuffer.finalizeWrite(UInt (bytesRead))
            delegate?.hasData(connection: self)
        }
        catch let e {
            debugInitPrint ("Read handler for \(host) caused disconnect because \(e.localizedDescription)")
            asyncDisconnect(error: e)
        }
    }
    
    //-----------------------------------------------------------------------------
    /// Called by the write source on the asyncQueue any time we're allowed to write.  Because this is 'always'
    /// we suspend the write source until we have data in our writeBuffer
    private func writeHandler () {
        
        do {
            while true {
                let l = min (writeBuffer.availableBytes, UInt (sendBufferSize))
                
                if l == 0 { // Nothing to write.  Suspend the writeSource
                    asyncSuspendWriteSource()
                    return
                }
                
                guard let p = writeBuffer.getReadPointer() else { throw POSIXError (POSIXErrorCode.EFAULT) }
                                    
                let written = try socket.write(p, len: Int (l))
                if written == 0 { break }
                writeBuffer.finalizeRead(UInt (written))
            }
        } catch let e {
            asyncDisconnect(error: e)
        }
    }
    
    //-----------------------------------------------------------------------------
    /// Called by the readSource and writeSource on the asyncQueue when they are cancelled.  Close the
    /// socket only when both sources are canceld
    private func cancelHandler () {
        socketRefCount = max (socketRefCount-1, 0)
        if socketRefCount == 0 {
            socket.close()
            delegate?.asyncDisconnected(connection: self)
        }
    }
    
    //-----------------------------------------------------------------------------
    /// Called on the asyncQueue, both by ourself and by the SocketClient and SocketServer when they
    /// want to forcably close the connection, or when it has become invalid
    internal func asyncDisconnect (error: Error? = nil) {
        self.error = error
        readSource.cancel()
        writeSource.cancel()
        asyncResumeWriteSource()
    }
    
    //-----------------------------------------------------------------------------
    /// Resume the write source if its already resumed.  Run on the async queue only
    private func asyncResumeWriteSource () {
        if !writeSourceResumed {
            writeSourceResumed = true
            writeSource.resume()
        }
    }
    
    //-----------------------------------------------------------------------------
    /// Suspend the write source if its not already suspended.
    private func asyncSuspendWriteSource () {
        if writeSourceResumed {
            writeSourceResumed = false
            writeSource.suspend()
        }
    }
    
    //-----------------------------------------------------------------------------
    /// Write some data by adding it to the writeBuffer then resuming the write source
    /// - Parameter data: The data to write
    public func write (_ data: Data) throws {
        guard let p = try writeBuffer.getWritePointer(UInt (data.count)) else {
            throw CWSocketServerError.writeBufferFull
            // I'm thinking that if this becomes an issue I could implement this instead as a
            // list of buffers.  But i'd have to be careful with synhro between this
            // main thread and the async one that powers the write handler.
        }
         
        data.copyBytes(to: p, count: data.count)
         
        writeBuffer.finalizeWrite(UInt (data.count))
         
        asyncQueue.async {  self.asyncResumeWriteSource() }
    }
    
    //-----------------------------------------------------------------------------
    /// Write a string of data
    /// - Parameter st: The string of data
    public func write (_ st: String) throws {
        
        guard let data = st.data(using: .utf8) else {
            throw CWSocketServerError.notUTF8
        }
        
        try write (data)
    }
    
    //---------------------------------------------------------------
    // Helpers...

    public func writeln (_ st: String) throws {
        try write (st + "\r\n")
    }
    
    public func readln () -> String? {
        return readBuffer.readln ()
    }
    
    public func peek (len: Int) -> String? {
        return readBuffer.peek(len: len)
    }
    
    public func readToken (separator: UInt8) -> String? {
        return readBuffer.readToken(separator: separator)
    }
    
    public func read (bytes: Int) -> [UInt8]? {
        return readBuffer.read (bytes: bytes)
    }
    
    @discardableResult public func copyAllFrom (connection: CWSocketConnection) throws -> Int {
        let bytes = try writeBuffer.copyFrom (buffer: connection.readBuffer)
        if bytes > 0 {
            asyncQueue.async { self.asyncResumeWriteSource() }
        }
        return Int(bytes)
    }
    
    public func readAllData () -> Data {
        return readBuffer.allData()
    }
}
