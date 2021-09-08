//
//  CWINet.swift
//  CWSockets
//
//  Created by Colin Wilson on 13/05/2020.
//  Copyright © 2020 Colin Wilson. All rights reserved.
//

import Foundation

final public class CWINet {
    
    public static func getIFAddressesForFamily (_ family : CWSocketFamily?) -> [String] {
        var addresses = [String]()
        
        // Get list of all interfaces on the local machine:
        var ifaddr : UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        guard let firstAddr = ifaddr else { return [] }
        
        // For each interface ...
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // Check for running IPv4. Skip the loopback interface.
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if family == nil || addr.sa_family == family!.value {
                    
                    // Convert interface address to a human readable string:
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if (getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST) == 0) {
                        let address = String(cString: hostname)
                        addresses.append(address)
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return addresses
    }
    
    private enum IFError:Error {
        case IOCTLFailed(Int32)
        case StringIsNotAnASCIIString
    }
    
    private enum AddressRequestType {
        case ipAddress
        case netmask
    }
    
    private static func _interfaceAddressForName (_ name: String, _ requestType: AddressRequestType, _ interfaceAddress: UnsafeMutablePointer<sockaddr>) -> Int {
        
        var ifr = ifreq ()
        ifr.ifr_ifru.ifru_addr.sa_family = sa_family_t(AF_INET)
        
        var b = [CChar] (repeating: 0, count: 16)
        
        strncpy (&b, name, 16)
        
        ifr.ifr_name = (b [0], b [1], b [2], b [3], b [4], b [5], b [6], b [7], b [8], b [9], b [10], b [11], b [12], b [13], b [14], b [15])
               
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        
        let SIOCGIFADDR: UInt = 0x8915
        let SIOCGIFNETMASK: UInt = 0x891B
        
        let ioRequest : UInt = requestType == .ipAddress ? SIOCGIFADDR : SIOCGIFNETMASK;
        
        let ioctl_res = ioctl(fd, ioRequest, &ifr)
        
        if ioctl_res < 0 {
            return Int(ioctl_res)
        }
        
        memcpy (interfaceAddress, &ifr.ifr_ifru.ifru_addr, MemoryLayout<sockaddr>.size)
        return 0
    }
    
    
    private static func interfaceAddress(forInterfaceWithName interfaceName: String, requestType: AddressRequestType) throws -> sockaddr_in {
        
        let addressPtr = UnsafeMutablePointer<sockaddr>.allocate(capacity: 1)
        let ioctl_res = _interfaceAddressForName(interfaceName, requestType, addressPtr)
        let address = addressPtr.move()
        addressPtr.deallocate()
        
        if ioctl_res < 0 {
            throw IFError.IOCTLFailed(errno)
        } else {
            return unsafeBitCast(address, to: sockaddr_in.self)
        }
    }
    
    public static func getInterfaceIPAddress (interfaceName: String) throws -> String {
        let s = try interfaceAddress(forInterfaceWithName: interfaceName, requestType: .ipAddress)
        let rv = String (cString: inet_ntoa (s.sin_addr))
        return rv
    }
    
    public static func getInterfaceNetMask (interfaceName: String) throws -> String {
        let s = try interfaceAddress(forInterfaceWithName: interfaceName, requestType: .netmask)
        let rv = String (cString: inet_ntoa (s.sin_addr))
        return rv
    }
    
    public enum SysctlError:Error {
        case Error(Int32)
    }
    
    private static func getSysctlForMib (_ mib: [Int32]) throws -> [Int8] {
        var l: size_t = 0
        
        var tmib = mib
        let mibCount = UInt32 (tmib.count)
        
        // First call with nil buffer to get the size
        var err = sysctl(&tmib, mibCount, nil, &l, nil, 0)
        if err < 0 || l == 0 {
            throw SysctlError.Error(err)
        }
        
        var buffer = [Int8] (repeating: 0, count: l)
        
        // Second call with buffer to get the data
        err = sysctl(&tmib, mibCount, &buffer, &l, nil, 0)
        if err < 0 {
            throw SysctlError.Error(err)
        }
        return buffer
    }

    #if os(OSX)
    public static func getDefaultGateway (interfaceName: String) throws -> String {
        
        // Round up to nearest multiple of 4 - so 0->4, 1->4, 2->4, 3->4, 4->4, 5->8 etc
        func ROUNDUP (_ a: Int) -> Int {
            let ls = MemoryLayout<Int32>.stride
            let rv = a > 0 ? (1 + ((a - 1) | (ls - 1))) : ls
            return rv
        }
        
        let buffer = try getSysctlForMib ([CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY])
        let hdrLen = MemoryLayout<rt_msghdr>.stride
        let bufLen = buffer.count
        
        let rx = buffer.withUnsafeBytes { ptr -> String? in
            
            var rv: String?
            
            let p = ptr.baseAddress!
            
            var i = 0
            while i < bufLen {
                let rt = (p+i).bindMemory(to: rt_msghdr.self, capacity: 1) [0]
                
                var sa_pos = i + hdrLen
                
                let sa_tab = (0..<RTAX_MAX).map { i -> UnsafePointer<sockaddr>? in
                    
                    if rt.rtm_addrs & Int32 (1 << i) == 0 { return nil }
                    
                    let stp = (p+sa_pos).assumingMemoryBound(to: sockaddr.self)
                    sa_pos += ROUNDUP (Int (stp.pointee.sa_len))
                    return stp
                }
                
                if let saDst = sa_tab [Int (RTAX_DST)], let saGateway = sa_tab [Int (RTAX_GATEWAY)], saDst.pointee.sa_family == AF_INET, saGateway.pointee.sa_family == AF_INET {
                    
                    let saDst_in = UnsafeRawPointer (saDst).assumingMemoryBound(to: sockaddr_in.self).pointee
                    
                    if saDst_in.sin_addr.s_addr == 0 {
                        var ifName = [Int8] (repeating: 0, count: 128)
                        if_indextoname(UInt32 (rt.rtm_index), &ifName)
                        
                        let x = String (cString: ifName)
                        
                        if x == interfaceName {
                            let saGateway_in = UnsafeRawPointer (saGateway).assumingMemoryBound(to: sockaddr_in.self).pointee
                            rv = String (cString: inet_ntoa (saGateway_in.sin_addr))
                            break
                        }
                    }
                }
                
                i += Int (rt.rtm_msglen)
            }
            return rv
        }
        
        return rx ?? "?"
        
        
    }
    #endif
}
