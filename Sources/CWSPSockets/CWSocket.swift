//
//  CWSocket.swift
//  CWExSockets
//
//  Created by Colin Wilson on 15/07/2019.
//  Copyright © 2019 Colin Wilson. All rights reserved.
//

import Foundation

//--------------------------------------------------------------
/// CWSocketFamily:  Tries to make sense of AF/PF inet etc(!)
public enum CWSocketFamily {
    case v4
    case v6
    
    
    var int32Value: Int32 {
        switch (self) {
        case .v4: return AF_INET
        case .v6: return AF_INET6
        }
    }
    
    var value: sa_family_t {
        return sa_family_t (int32Value)
    }
}

//--------------------------------------------------------------
/// CWSocketProtocol:  Encapsulates socket protocol
public enum CWSocketProtocol {
    case tcp
    case udp
    case icmp
    case icmpv6
    
    var type: Int32 {
        switch (self) {
        case .tcp: return SOCK_STREAM
        case .udp: return SOCK_DGRAM
        case .icmp: return SOCK_DGRAM
        case .icmpv6: return SOCK_DGRAM
        }
    }
    
    var proto: Int32 {
        switch (self) {
        case .tcp: return IPPROTO_TCP
        case .udp: return IPPROTO_UDP
        case .icmp: return IPPROTO_ICMP
        case .icmpv6: return IPPROTO_ICMPV6
        }
    }
}

//--------------------------------------------------------------
/// POSIXError extension:   provides description for POSIX errors
extension POSIXError: LocalizedError {
    public var errorDescription: String? {
        let rv = String(cString: strerror(self.code.rawValue))
        
        return rv
    }
}

//--------------------------------------------------------------
// Helper extension to initialize a timeval from a TimeInterval
extension timeval {
    init (timeout: TimeInterval) {
        let sec = Int (trunc (timeout))
        let usec = Int32 (Int ((timeout * 1000000)) % 1000000)
        
        self.init (tv_sec: sec, tv_usec: usec)
    }
}

//--------------------------------------------------------------
/// CWSocket:  Swift wrapper for sockets
final public class CWSocket {
    
    // Must clear these in 'close'
    private (set) public var _descriptor : Int32 = -1
    private var address: CWSocketAddress?
    private var currentReadTimeout: timeval?
    
    public let family : CWSocketFamily
    public let proto : CWSocketProtocol
    
    private (set) public var isConnected = false
    
    //---------------------------------------------------------
    /// deinit.  Destructor - close the socket
    deinit {
        close ();
    }
    
    //--------------------------------------------------------
    /// init:  1.  Initialise with family & protocol
    ///
    /// This is typically called by client connections and server listeners
    ///
    /// - Parameters:
    ///   - family: The family - eg. .v4, .v6
    ///   - proto: The protocol - eg. .tcp, .udp
    public init (family: CWSocketFamily, proto: CWSocketProtocol) {
        self.family = family
        self.proto = proto
    }
    
    //---------------------------------------------------------
    /// init:  2.  Initialise from an existing socket descriptor
    ///
    /// This is typically called by our 'accept' - in which case we already knows the address
    /// But it could also be called, eg. to look up details of a random socket descriptor
    ///
    /// - Parameters:
    ///   - descriptor: The existing socket descriptor
    ///   - address: Optional.  We look it up if we don't already know it
    /// - Throws: POSIX errors
    public init (descriptor: Int32, isConnected: Bool = false, address: CWSocketAddress? = nil) throws {
        self._descriptor = descriptor
        self.isConnected = isConnected
        
        let initAddress: CWSocketAddress
        if let addr = address {
            initAddress = addr
        } else {
            initAddress = CWSocketAddress (len: socklen_t (SOCK_MAXADDRLEN))
            var newLen = initAddress.len
            try CWSocket.check(getsockname (descriptor, initAddress.mutableAddress, &newLen))
            initAddress.resize(newSize: newLen)
        }

        self.address = initAddress
        
        self.family = initAddress.family
        
        var s: Int32 = 0 // SOCK_STREAM, SOCK_DGRAM are Int32
        var l: socklen_t = socklen_t (MemoryLayout.size(ofValue: s))
        
        // Get the socket type
        try CWSocket.check (getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &s, &l))
        
        switch s {
        case SOCK_STREAM: self.proto = .tcp
        case SOCK_DGRAM: self.proto = .udp
        default:
            throw POSIXError (.EPROTONOSUPPORT)
        }
    }
    
    //---------------------------------------------------------
    /// The socket descriptor.  Create it if we don't already know it
    private var descriptor: Int32 {
        if _descriptor == -1 {
            _descriptor = socket (family.int32Value, proto.type, proto.proto)
            var noSigPipe = Int32 (1)
            
            // Prevent 'SIGPIPE' kernel exceptions
            setsockopt(_descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t (MemoryLayout.size(ofValue: noSigPipe)))
        }
        return _descriptor
    }
    
    //---------------------------------------------------------
    /// Returns true if the descriptor has been created
    public var hasDescriptor: Bool {
        return _descriptor != -1
    }
    
    
    //---------------------------------------------------------
    /// close the socket and tidy up
    public func close () {
                
        reset ()
        address = nil
    }
    
    //---------------------------------------------------------
    /// Closes the descriptor so hat the next operation will create a new one
    public func reset () {
        if _descriptor != -1 {
            let _ = Foundation.close(_descriptor)
            _descriptor = -1
        }
        currentReadTimeout = nil
        isConnected = false
    }
    
    //---------------------------------------------------------
    /// func remoteIP
    ///
    /// - Returns: The remote IP address
    /// - Throws: POSIX error
    public func remoteIP () throws ->String {
        if let address = address {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var servBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
            
            let rv = getnameinfo(address.address, address.len, &hostBuffer, socklen_t (NI_MAXHOST), &servBuffer, socklen_t (NI_MAXSERV), NI_NUMERICHOST | NI_NUMERICSERV)
            
            if rv != 0 {
                throw GAIError (rawValue:rv)
            }
            
            return String(cString: hostBuffer)
        } else {
            throw GAIError.EAI_NONAME
        }
    }
    
    //---------------------------------------------------------
    /// func bind:  Bind the socket so it can listen
    ///
    /// - Parameters:
    ///   - port: The port to bind
    ///   - ipAddress: The IP address to bind - or nil for any IP
    /// - Throws: POSIX error
    public func bind (_ port: in_port_t, ipAddress: String?) throws {
        if family == .v6 {
            var v6OnlyOn: Int32 = 1
            
            // By setting IPV6_V6ONLY we allow binding separately to the same port with ipv4 & ipv6
            try CWSocket.check(Foundation.setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &v6OnlyOn, socklen_t (MemoryLayout.size(ofValue: v6OnlyOn))))
        }
        
        // nb.  The reason we have to do SO_REUSEADDR is that, even when we close the listener's socket, for some strange reason it may
        //      still think the port is in use - so when we create a new socket it may fail when we bind it.
        //
        //      Weirdly, this doesn't happen if you step through with the debugger (!)
        
        var reuseOn: Int32 = 1
        try CWSocket.check(Foundation.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseOn, socklen_t (MemoryLayout.size(ofValue: reuseOn))))
        
        let address = try CWSocketAddress (host: ipAddress, port: port, family: family, proto: proto)
        if Foundation.bind(_descriptor, address.address, address.len) != 0 {
            throw POSIXError (POSIXErrorCode (rawValue: errno)!)
        }
        self.address = address
    }
    
    //---------------------------------------------------------
    /// func listen : Set the bound socket to listen - so that it
    /// can accept incoming connections
    ///
    /// - Parameter backlog: Number of pending connections
    /// - Throws: POSIX errors
    public func listen (_ backlog: Int32 = SOMAXCONN) throws {
        try CWSocket.check (Foundation.listen(descriptor, backlog))
    }
    
    //---------------------------------------------------------
    /// func connect
    ///
    /// If the connection is non-blocking, you'd typically create a read dispatch source -
    /// with makeReadSource, and optionally a write dispatch source with makrWriteSource
    ///
    /// - Parameters:
    ///   - port: The port to connect to
    ///   - host: Host ip or name
    ///   - nonblocking: Flag indicates non-blocking mode
    /// - Throws: POSIX Errors
    public func connect (_ port: in_port_t, host: String, nonblocking: Bool) throws {
        let sa = try CWSocketAddress (host: host, port: port, family: family, proto: proto)
        try connectToAddress(address: sa, nonblocking: nonblocking)
    }
    
    public func connectToAddress (address: CWSocketAddress, nonblocking: Bool) throws {
        isConnected = false
        try CWSocket.check(Foundation.connect (descriptor, address.address, address.len))
        
        if nonblocking {
            try CWSocket.check(fcntl(descriptor, F_SETFL, O_NONBLOCK))
        }
        self.address = address
        isConnected = true
    }
    
    //---------------------------------------------------------
    /// func resolve - Resolve the given host to an address
    ///
    /// You'd typically use this for connectionless protocols - like ICMP.  First resolve th host
    /// then send data to it with 'sendto'
    ///
    /// - Parameter host: The host name or IP to resolve
    public func resolve (_ host: String) throws -> CWSocketAddress {
        return try CWSocketAddress (host: host, port: nil, family: family, proto: proto)
    }
    
    //---------------------------------------------------------
    /// func sendto - Send data to an address
    ///
    /// You'd typically use this to send data when using connectionless protocols like ICMP
    /// First resolve the host to a sockadrd using resolve, then call sendto to send it data
    ///
    /// It will probably work for connected protocols like IP and UDP - but you'd be better off using
    /// 'write' for those
    ///
    /// - Parameter data: The data to send
    public func sendTo (address: CWSocketAddress, data: Data) throws -> Int32 {
        
        return try data.withUnsafeBytes { body -> Int32 in
            guard let mem = body.baseAddress else {
                throw POSIXError (POSIXErrorCode.EBADMSG)
            }
            
            let rv = try CWSocket.check(Int32 (sendto (descriptor, mem, data.count, 0, address.address, address.len)))
            return rv
        }
    }
    
    //---------------------------------------------------------
    /// recvFrom - Receive data from a connectionless socket
    /// - Parameters:
    ///   - buffer: Buffer for the data
    ///   - len: Buffer size
    ///
    /// - Returns: A tuple containing the number of bytes actually read, and the address it was read from
    /// - Throws:  POSIX errors
    public func recvFrom (_ buffer: UnsafeMutableRawPointer, len: Int) throws ->(bytes:Int32, fromAddress:CWSocketAddress) {
        let addrLen = MemoryLayout<sockaddr_storage>.size
        let address = CWSocketAddress (len: socklen_t (addrLen))
        
        var addrLenRet = address.len
        let rv = try CWSocket.check(Int32 (recvfrom(descriptor, buffer, len, 0, address.mutableAddress, &addrLenRet)))
        address.resize(newSize: addrLenRet)
        
        return (rv, address)
    }
    
    //---------------------------------------------------------
    /// func accept:  Accept incoming connectsions from a bound,listening socket
    ///
    /// - Parameter nonblocking: Make the accepted socket non-blocking
    /// - Returns: A socket for the accepted connection
    /// - Throws: POSIX errors
    public func accept (nonblocking: Bool) throws ->CWSocket {
        let acceptedAdress = CWSocketAddress (len: socklen_t (SOCK_MAXADDRLEN))
        
        var newLen = acceptedAdress.len
        let clientSocket = try CWSocket.check (Foundation.accept(descriptor, acceptedAdress.mutableAddress, &newLen))
        acceptedAdress.resize(newSize: newLen)
        
        if nonblocking {
            try CWSocket.check (fcntl(clientSocket, F_SETFL, O_NONBLOCK))
        }
        
        return try CWSocket (descriptor: clientSocket, isConnected: true, address: acceptedAdress)
    }
    
    //---------------------------------------------------------
    /// func setReadTimeout
    ///
    /// - Parameter timeout: The timeout in seconds - eg. 1.5
    public func setReadTimeout (_ timeout: TimeInterval) throws {
        var tv = timeval (timeout: timeout)
        
        if let currentReadTimeout = currentReadTimeout {
            if tv.tv_sec == currentReadTimeout.tv_sec && tv.tv_usec == currentReadTimeout.tv_usec {
                return
            }
        }
        
        try CWSocket.check(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t (MemoryLayout.size(ofValue: tv))))
        currentReadTimeout = tv
    }
    
    //---------------------------------------------------------
    /// func read (1)
    ///
    /// Note that read can always return fewer than 'len' bytes.
    /// It can only return 0 if the socket is non-blocking, or it timed out
    ///
    /// - Parameters:
    ///   - buffer: The buffer to read into
    ///   - len: The length of the buffer
    /// - Returns: The number of bytes read
    /// - Throws: POSIX erropr
    public func read (_ buffer: UnsafeMutableRawPointer, len: Int) throws ->Int {
        let rv = Foundation.recv(descriptor, buffer, len, 0)
        if rv == -1 {
            if errno == EAGAIN {
                return 0
            }
            throw POSIXError (POSIXErrorCode (rawValue: errno)!)
        } else if rv == 0 {
            throw POSIXError (POSIXError.ECONNRESET)
        }
        return rv
    }
    
    //---------------------------------------------------------
    /// write (1)
    ///
    /// Note that write can always return fewer than 'len' bytes.
    /// It can only return 0 if the socket is non-blocking
    ///
    /// - Parameters:
    ///   - buffer: The buffer of bytes to write
    ///   - len: The number of bytes in the buffer
    /// - Returns: The number of bytes written
    /// - Throws: POSIX error
    public func write (_ buffer:UnsafeRawPointer, len: Int) throws ->Int {
        let rv = Foundation.send (descriptor, buffer, len, 0)
        
        if (rv == -1) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
                return 0
            }
            throw POSIXError (POSIXErrorCode (rawValue: errno)!)
        }
        return rv
    }
    
    //---------------------------------------------------------
    /// setDescriptorInFDSet - Sets our descriptor in an fd_set
    ///
    /// Too horrid to document further
    private func setDescriptorInFDSet (set: inout fd_set) {
        let intOffset = descriptor / 16
        let bitOffset = descriptor % 16
        let mask: Int32 = 1 << bitOffset
        switch intOffset {
        case 0: set.fds_bits.0 = set.fds_bits.0 | mask
        case 1: set.fds_bits.1 = set.fds_bits.1 | mask
        case 2: set.fds_bits.2 = set.fds_bits.2 | mask
        case 3: set.fds_bits.3 = set.fds_bits.3 | mask
        case 4: set.fds_bits.4 = set.fds_bits.4 | mask
        case 5: set.fds_bits.5 = set.fds_bits.5 | mask
        case 6: set.fds_bits.6 = set.fds_bits.6 | mask
        case 7: set.fds_bits.7 = set.fds_bits.7 | mask
        case 8: set.fds_bits.8 = set.fds_bits.8 | mask
        case 9: set.fds_bits.9 = set.fds_bits.9 | mask
        case 10: set.fds_bits.10 = set.fds_bits.10 | mask
        case 11: set.fds_bits.11 = set.fds_bits.11 | mask
        case 12: set.fds_bits.12 = set.fds_bits.12 | mask
        case 13: set.fds_bits.13 = set.fds_bits.13 | mask
        case 14: set.fds_bits.14 = set.fds_bits.14 | mask
        case 15: set.fds_bits.15 = set.fds_bits.15 | mask
        default: break
        }
    }
    
    //---------------------------------------------------------
    /// makeFDSet
    private func makeFDSet () -> (nfds: Int32, fdset: fd_set) {
        let nfds = descriptor + 1
        var fds = fd_set (fds_bits: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        setDescriptorInFDSet(set: &fds)
        return (nfds, fds)
    }
    
    //---------------------------------------------------------
    /// selectWrite - Wait for up to 'timeout' for the socket to become writable
    ///
    /// There's little in the world of computer science that's more disgusting
    /// and arcane as the sockets 'select' function.  Its usually much better to
    /// use read/write sources instead!
    ///
    /// - Parameter timeout: TimeInterval (a 'double' number of seconds)
    /// - Returns: True if the socket is writable
    /// - Throws: POSIX error
    public func selectWrite (timeout: TimeInterval) throws -> Bool {
        var tm = timeval (timeout: timeout)
        var fdSetDetails = makeFDSet()
        var rv = Foundation.select(fdSetDetails.nfds, nil, &fdSetDetails.fdset, nil, &tm)
        if rv == -1 {
            if errno == EAGAIN {
                rv = 0
            } else {
                throw POSIXError (POSIXErrorCode (rawValue: errno)!)
            }
        }
        return rv > 0
    }
    
    //---------------------------------------------------------
    /// selectRead - Wait for up to 'timeout' for some data to arrive
    ///
    /// Please use read source instead!
    ///
    /// - Parameter timeout: TimeInterval (a 'double' number of seconds)
    /// - Returns: True if data arrived at the socket within the time interval
    /// - Throws: POSIXError
    public func selectRead (timeout: TimeInterval) throws -> Bool {
        var tm = timeval (timeout: timeout)
        var fdSetDetails = makeFDSet()
        var rv = Foundation.select(fdSetDetails.nfds, &fdSetDetails.fdset, nil, nil, &tm)
        if rv == -1 {
            if errno == EAGAIN {
                rv = 0
            } else {
                throw POSIXError (POSIXErrorCode (rawValue: errno)!)
            }
        }
        return rv > 0
    }
        
    //---------------------------------------------------------
    /// getReceiveBufferSize
    ///
    /// - Returns: The native receive buffer size supported by the socket
    /// - Throws: POSIX error
    public func getReceiveBufferSize () throws -> UInt {
        var s: Int32 = 0
        var l: socklen_t = socklen_t (MemoryLayout.size(ofValue: s))
        
        try CWSocket.check(getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &s, &l))
        
        return UInt (s)
    }
    
    //---------------------------------------------------------
    /// getSendBufferSize
    ///
    /// - Returns: The native send buffer size supported by the socket
    /// - Throws: POSIX error
    public func getSendBufferSize () throws -> UInt {
        var s: Int32 = 0
        var l: socklen_t = socklen_t (MemoryLayout.size(ofValue: s))
        
        // Get the socket type
        try CWSocket.check(getsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &s, &l))
        
        return UInt (s)
    }
    
    //---------------------------------------------------------
    /// makeReadSource - Makes a read source for event driven IO on non-blocking sockets
    ///
    /// Once you've created your read source, set its event handlers with DispatchSourceRead.setEventHandler
    /// and .setCancelHandler; then call .resume
    ///
    /// - Parameter queue: The queue for the read source to put events on
    /// - Returns: The DispatchSourceRead for the socket
    public func makeReadSource (queue: DispatchQueue) -> DispatchSourceRead {
        return DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    }
    
    //---------------------------------------------------------
    /// makeWriteSource - Makes a write source for event driven IO on non-blocking sockets
    ///
    /// Once you've created your write source, set its event handlers ith DispatchSourceRead.setEventHandler
    /// and .setCancelHandler.  Call .resume only once you've got some data available for the event handler to write
    ///
    /// - Parameter queue: The queue for the write source to put events on
    /// - Returns: The DispatchSourceWrite for the socket
    public func makeWriteSource (queue: DispatchQueue) -> DispatchSourceWrite {
        return DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    }
    
    
    @discardableResult private static func check (_ rv: Int32) throws -> Int32 {
        if rv < 0 {
            throw POSIXError (POSIXErrorCode (rawValue: errno)!)
        }
        return rv
    }
}


