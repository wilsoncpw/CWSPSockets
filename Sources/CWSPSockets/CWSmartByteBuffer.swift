///////////////////////////////////////////////////////////////////////////////
//  CWSmartBuffer.swift
//  CWEXSockets
//
//  Circular buffer implemntation using mirroring to ensure that it always
//  provides a contiguous chunk of memory
//
//  Created by Colin Wilson on 17/11/2015.
//  Copyright © 2015 Colin Wilson. All rights reserved.
//

import Foundation

public enum CWSmartByteBufferError : Error {
    case kernError(kr: kern_return_t, fn: String)
}

extension CWSmartByteBufferError: LocalizedError {
    var localizedDescription: String {
        switch self {
        case .kernError (let kr, let fn) :
            let description: String
            if let cStr = mach_error_string(kr) {
                description = String (cString: cStr)
            } else {
                description = "unknown kernel error \(kr)"
            }
            return "Kernel error:\(description) in \(fn)"
        }
    }
}


//==============================================================
/// CWSmartByteBuffer class
///
/// Circular byte buffer that uses vm techniques to perform wrapping
///
final public class CWSmartByteBuffer {
    
    let VM_INHERIT_DEFAULT: vm_inherit_t = 1
    
    static let vm_page_size_m1: vm_size_t = vm_page_size - 1
    static let TruncPage = { (x: vm_size_t) -> vm_size_t in x & ~(vm_page_size_m1) }
    static let RoundPage = { (x: vm_size_t) -> vm_size_t in TruncPage(x + vm_page_size_m1) }
    
    private var bufPtr: vm_address_t = 0
    private (set) public var bufSize: UInt
    
    private var readPointer: vm_address_t = 0
    private var writePointer: vm_address_t = 0
    
    private var bytesWritten: UInt = 0
    private var bytesRead: UInt = 0
    
    //--------------------------------------------------------------
    /// init
    /// - Parameter initialSize: The initial buffer size
    public init (initialSize: UInt) {
        self.bufSize = CWSmartByteBuffer.RoundPage (initialSize)
    }
    
    //--------------------------------------------------------------
    /// deinit
    deinit {
        deallocBuffer ()
    }
    
    //--------------------------------------------------------------
    /// availableBytes
    public var availableBytes: UInt {
        if bytesWritten >= bytesRead {
            return bytesWritten - bytesRead
        } else {
            return UInt.max - bytesRead + bytesWritten
        }
    }
    
    //--------------------------------------------------------------
    /// freeSpace
    public var freeSpace: UInt {
        return bufSize - availableBytes
    }
    
    
    //--------------------------------------------------------------
    /// reset - Empty the buffer - but don't deallocate it
    public func reset () {
        readPointer = bufPtr
        writePointer = bufPtr
        
        bytesWritten = 0
        bytesRead = 0
    }
    
    //--------------------------------------------------------------
    /// deallocBuffer - Deallocate and reset the buffer
    private func deallocBuffer () {
        if bufPtr != 0 {
            vm_deallocate(mach_task_self_, bufPtr, bufSize)
            bufPtr = 0
            bufSize = 0
        }
        reset ();
    }
    
    //--------------------------------------------------------------
    /// krCheck - check a kernel result for errors
    /// - Parameters:
    ///   - kr: Kernel error code - 0 for no error
    ///   - fn: Function name where the error happened
    ///   - file: Filename where the error hppened
    private func krCheck (_ kr: kern_return_t, fn: String = #function, file: String = #file) throws {
        if kr != KERN_SUCCESS {
            let cls = (file as NSString).lastPathComponent.split(separator: ".") [0]
            throw CWSmartByteBufferError.kernError (kr: kr, fn: cls + "." + fn)
        }
    }
    
    //--------------------------------------------------------------
    /// createBuffer - Create the mirored buffer
    ///
    /// nb.  bufSize must have been rounded when this is called
    private func createBuffer () throws {
        
        // Make sure there's space for the buffer and its mirror
        try krCheck (vm_allocate(mach_task_self_, &bufPtr, bufSize * 2, VM_FLAGS_ANYWHERE))
        
        // Deallocate the top, 'mirror' half
        var mirror = bufPtr + bufSize
        try krCheck (vm_deallocate(mach_task_self_, mirror, bufSize))
                
        do {
            
            // Now map the mirror half onto the lower, non-mirror half.  We end up with a chunk of address space, twice as large as the buffer.  If you write anywhere in the lower half
            // the data appears in the upper half too - and vice versa.  And if you read from either half the results will be the same.
            
            var cp: vm_prot_t = 0
            var mp: vm_prot_t = 0
            try krCheck (vm_remap(mach_task_self_, &mirror, bufSize, 0, 0, mach_task_self_, bufPtr, 0, &cp, &mp, VM_INHERIT_DEFAULT))
        } catch let e {
            vm_deallocate (mach_task_self_, bufPtr, bufSize)
            throw e
        }

        // Set the read & write pointers to the start of the buffer.
        readPointer = bufPtr
        writePointer = bufPtr
    }
    
    
    //--------------------------------------------------------------
    /// getWritePointer - Returns the current write pointer.
    ///
    /// After you've written data to this pointer, call 'finalizeWrite' to update the pointers.
    ///
    /// If size is greater than the amonunt of free space in the buffer,
    /// the buffer will automatically resize itself - as long as it's
    /// empty.  If it's not empty, the function wil return nil.
    ///
    /// - Parameter size: Size of the data you want to write
    public func getWritePointer (_ size: UInt) throws -> UnsafeMutablePointer<UInt8>? {
        if (bufPtr == 0) {
            // First time buffer used - so create it
            
            bufSize = size > bufSize ? CWSmartByteBuffer.RoundPage (size) : bufSize
            try createBuffer()
        } else if freeSpace < size {
            // The buffer isn't big enoug to return a chunk with the required size
            
            if availableBytes == 0 {
                // Buffer is currently empty, so can be resized

                deallocBuffer()
                bufSize = CWSmartByteBuffer.RoundPage (size)
                try createBuffer()
            } else {
                return nil
            }
        }
        
        return UnsafeMutablePointer<UInt8>(bitPattern: writePointer)
    }
    
    //--------------------------------------------------------------
    /// getReadPointer - Return a pointer that you can read 'availeBytes' of data from.
    ///
    /// After you've read the data, call finalizeRead to update the pointers
    public func getReadPointer ()->UnsafePointer<UInt8>? {
        return UnsafePointer<UInt8>(bitPattern: readPointer)
    }
    
    //--------------------------------------------------------------
    /// finalizeRead
    public func finalizeRead (_ size: UInt) {
        readPointer += size
        
        if readPointer - bufPtr >= bufSize {
            readPointer -= bufSize
        }
        
        bytesRead = bytesRead &+ size  // Note overflow + operator
    }
    
    //--------------------------------------------------------------
    /// finalizeWrite
    public func finalizeWrite (_ size: UInt) {
        writePointer += size
        
        if writePointer - bufPtr >= bufSize {
            writePointer -= bufSize
        }
        
        bytesWritten = bytesWritten &+ size
    }
}

extension CWSmartByteBuffer {
    
    //--------------------------------------------------------------
    /// readln - read a line terminated with <LF> or <CR/LF>
    public func readln () -> String? {
        
        guard let p = getReadPointer(), availableBytes > 0 else { return nil }
        
        var i = 0
        
        while i < availableBytes && p [i] != 10 {
            i += 1
        }
        
        guard i < availableBytes && p [i] == 10 else {
            return nil
        }
        
        let bytesUsed = i+1
        if i > 0 && p [i-1] == 13 {
            i -= 1
        }
        let ptr = UnsafeMutableRawPointer (mutating: p)
        
        let rv = String (bytesNoCopy: ptr, length: i, encoding: .ascii, freeWhenDone: false)
        finalizeRead(UInt (bytesUsed))

        return rv
    }
}

extension CWSmartByteBuffer {

    //--------------------------------------------------------------
    /// peek - peek at the first 'len' bytes in the buffer.
    ///
    /// Return nil if the buffer doesn't  containlen bytes
    ///
    /// - Parameter len: Number of bytes to peek at
    public func peek (len: Int) -> String? {
        guard let p = getReadPointer(), availableBytes >= len else {
            return nil
        }
        
        let ptr = UnsafeMutableRawPointer (mutating: p)
        let rv = String (bytesNoCopy: ptr, length: len, encoding: .ascii, freeWhenDone: false)
        return rv
    }
    
    //--------------------------------------------------------------
    /// readToken - read bytes in the buffer up to the separator
    ///
    /// Returns nil if the separator doesn't exist in the buffer
    ///
    /// - Parameter separator: The separator byte
    public func readToken (separator: UInt8) -> String? {
        guard let p = getReadPointer(), availableBytes >= 0 else {
            return nil
        }
        
        var i = 0
        while i < availableBytes && p[i] != separator {
            i += 1
        }
        
        guard i < availableBytes else {
            return nil
        }
        
        var bytesUsed = i+1
        while bytesUsed < availableBytes && p[bytesUsed] == separator {
            bytesUsed += 1
        }
        
        let ptr = UnsafeMutableRawPointer (mutating: p)
        let rv = String (bytesNoCopy: ptr, length: i, encoding: .ascii, freeWhenDone: false)
        finalizeRead(UInt (bytesUsed))
        return rv
    }
    
    //--------------------------------------------------------------
    /// Read 'some bytes from the buffer
    ///
    /// If the bufer doesn't contain the specified number of bytes, just return what's available
    ///
    /// - Parameter bytes: The number of bytes to read
    public func read (bytes: Int) -> [UInt8]? {
        let avail = Int (availableBytes)
        let n = min (bytes, avail)

        guard n >= 0, let p = getReadPointer() else {
            return nil
        }
        
        var rv = [UInt8] (repeating: 0, count: n)
        memcpy(&rv, p, n)
        finalizeRead(UInt (n))
        return rv
    }
    
    func copyFrom (buffer: CWSmartByteBuffer) throws -> UInt {
        let bytesToTransfer = buffer.availableBytes
        
        if bytesToTransfer > 0 {
            let writePointer = try getWritePointer(bytesToTransfer)
            let readPointer = buffer.getReadPointer()
            memcpy (writePointer, readPointer, Int (bytesToTransfer))
            buffer.finalizeRead(bytesToTransfer)
            finalizeWrite(bytesToTransfer)
        }
        return bytesToTransfer
    }
    
    func allData () -> Data {
        if let rp = getReadPointer() {
            let bytes = availableBytes
            defer {
                finalizeRead(bytes)
            }
            return Data(bytes: rp, count: Int (bytes))
        }
        return Data ()
    }
}
