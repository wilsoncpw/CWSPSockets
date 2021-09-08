//
//  CWSocketAddress.swift
//  CWSockets
//
//  Created by Colin Wilson on 29/10/2019.
//  Copyright © 2019 Colin Wilson. All rights reserved.
//

import Foundation

//---------------------------------------------------------------
/// GAIError:  Exception wrapper for getaddrinfo errors
///
/// Note that the actual integer values in Darwin are different
/// from everyone else's
public struct GAIError: LocalizedError {
    let rawValue: Int32
    public static var EAI_AGAIN: GAIError {
        return GAIError(rawValue: Foundation.EAI_AGAIN)
    }
    
    public static var EAI_NONAME: GAIError {
        return GAIError(rawValue: Foundation.EAI_NONAME)
    }
    
    public var errorDescription: String? {
        return String (cString: gai_strerror(rawValue))
    }
}

//---------------------------------------------------------------
/// CWSocketAddress - a Socket Address
final public class CWSocketAddress {
    private (set) public var len: socklen_t
    private (set) public var mutableAddress : UnsafeMutablePointer<sockaddr>!
    
    //---------------------------------------------------------------
    /// init - Constructor
    /// - Parameter len: The length of the address
    public init(len: socklen_t) {
        self.len = len
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int (len), alignment: 8)
        buffer.initializeMemory(as: Int8.self, repeating: 0, count: Int (len))
        mutableAddress = buffer.bindMemory(to: sockaddr.self, capacity: 1)
        mutableAddress.pointee.sa_len = __uint8_t (len)
    }
    
    //---------------------------------------------------------------
    /// init - Create a CWSocketAddressfor the given host/port/family & proto
    /// - Parameters:
    ///   - host: The host - can be nil - eg. in bind
    ///   - port: The port - can be nil - eg. to resolve the host
    ///   - family: The family
    ///   - proto: The protocol
    public convenience init (host: String?, port: in_port_t?, family: CWSocketFamily, proto : CWSocketProtocol) throws {
            
        var gaiResult:UnsafeMutablePointer<addrinfo>? = nil
        
        let portBuffer : [CChar]?
        
        // Create a buffer containing a string reprentation of the port
        if let port = port {
            let ptst = String (port)
            portBuffer = ptst.cString(using: String.Encoding.ascii)
        } else {
            portBuffer = nil
        }
        
        // Set up the call get getaddrinfo
        var hint = addrinfo(
            ai_flags: AI_NUMERICSERV, ai_family: Int32 (family.value), ai_socktype: proto.type, ai_protocol: proto.proto, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        
        if proto == .icmp || proto == .icmpv6 {
            hint.ai_protocol = 0
            hint.ai_socktype = 0
        }
        
        // Get the address info.
        let rv: Int32
        if let portBuffer = portBuffer {
            
            rv = portBuffer.withUnsafeBufferPointer { body in
                
                let p = body.baseAddress!
        
                let rv: Int32
                if let host = host {
                    
                    // Resolves - so may block for a while
                    rv = getaddrinfo(host, p, &hint, &gaiResult)
                } else {
                    hint.ai_flags |= AI_PASSIVE
                    rv = getaddrinfo(nil, p, &hint, &gaiResult)
                }
                return rv
            }
        } else {
            if let host = host {
                
                // Resolves - so may block for a while
                rv = getaddrinfo(host, nil, &hint, &gaiResult)
            } else {
                hint.ai_flags |= AI_PASSIVE
                rv = getaddrinfo(nil, nil, &hint, &gaiResult)
            }
        }
        
        defer {
            freeaddrinfo(gaiResult)
        }
        
        if (rv != 0) {
            throw GAIError (rawValue: rv)
        }
        
        let l = (gaiResult?.pointee.ai_addr.pointee.sa_len)!
        
        self.init (len: socklen_t (l))
    
        memcpy (mutableAddress, gaiResult?.pointee.ai_addr, Int(l))
    }
    
    //---------------------------------------------------------------
    /// The socket family - eg.  .v4, .v6
    public var family: CWSocketFamily {
        return mutableAddress.pointee.sa_family == sa_family_t (AF_INET) ? CWSocketFamily.v4 : CWSocketFamily.v6
    }
    
    //---------------------------------------------------------------
    /// The address
    public var address: UnsafePointer<sockaddr> {
        return UnsafePointer <sockaddr> (mutableAddress)
    }
    
    //---------------------------------------------------------------
    /// deinit - free he address buffer
    deinit {
        if mutableAddress != nil {
            mutableAddress.deallocate()
        }
    }
    
    //---------------------------------------------------------------
    /// resize - resize the address, keepingasmuch as possible of the old one
    ///
    /// Often we create the addrss with MAXADDRLEN, then resize it to its actaul size once we've established it
    ///
    /// - Parameter newSize: The new size of the address
    public func resize (newSize: socklen_t) {
        let newAddr = CWSocketAddress (len: newSize)
        let newLen = min (newSize, len)
        memcpy (newAddr.mutableAddress, mutableAddress, Int (newLen))
        mutableAddress.deallocate()
        mutableAddress = newAddr.mutableAddress
        len = newLen
        newAddr.mutableAddress = nil
    }
}
