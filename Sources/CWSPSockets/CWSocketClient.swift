//
//  CWSocketClient.swift
//  CWSockets
//
//  Created by Colin Wilson on 01/11/2019.
//  Copyright © 2019 Colin Wilson. All rights reserved.
//

import Foundation

//---------------------------------------------------------------
/// CWSocketClientDelegate
///
///Note that these are all called on the main dispatch queue.  Question - shouldn;'t these all be async - like in CWSocketServer
public protocol CWSocketClientDelegate: AnyObject {
    
    func connectionFailed (client: CWSocketClient, host: String, port: in_port_t, family : CWSocketFamily, proto: CWSocketProtocol, error: Error)
    func connected (client: CWSocketClient, connection: CWSocketConnection)
    func disconnected (client: CWSocketClient, connection: CWSocketConnection)
    func hasData (client: CWSocketClient, connection: CWSocketConnection)
}

public extension DispatchSource {
    class func singleTimer(interval: TimeInterval, handler: @escaping () -> Void) ->
    DispatchSourceTimer {
        let result = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        result.setEventHandler(handler: handler)
        result.schedule(deadline: DispatchTime.now() + interval, leeway: .nanoseconds(0))
        result.resume()
        return result
    }
}

//---------------------------------------------------------------
/// CWSocketClient class
///
/// Note that this can handle multiple connections to the same client, though typically
/// you'd only have one.
final public class CWSocketClient: CWSocketConnectionDelegate {
    
    let asyncQueue = DispatchQueue (label: "CWSocketClient")
    var connections = [CWSocketConnection] ()
    public weak var delegate: CWSocketClientDelegate?
    
    //---------------------------------------------------------------
    /// Constructor
    public init () {
    }
    
    //---------------------------------------------------------------
    /// Destructor.  Closeall the connections
    deinit {
        // Call disconnect on each connection.  Because we're in deinit, our
        // asyncDisconnect won't get called by the connection
        connections.forEach {connection in connection.asyncDisconnect()}
        debugInitPrint ("CWSocketServer deinit")
    }
    
    //---------------------------------------------------------------
    /// connect
    ///
    ///Connect to a host/port endpoint
    ///
    /// - Parameters:
    ///   - host: The host
    ///   - port: Portto connect to
    ///   - family: The address family - eg .v4
    ///   - proto: The protociol
    public func connect (host: String, port: in_port_t, family: CWSocketFamily, proto: CWSocketProtocol, timeout: TimeInterval? = nil) throws {
        guard proto == .tcp || proto == .udp else {
            throw POSIXError (POSIXErrorCode.EPROTONOSUPPORT)
        }
        
        let socket = CWSocket (family: family, proto: proto)
        
        asyncQueue.async {
            var timedOut = false
            do {
                var timer : DispatchSourceTimer?
                
                if let timeout = timeout {
                    timer = DispatchSource.singleTimer(interval: timeout) {
                        timedOut = true
                        socket.close()
                    }
                }
                
                let connection = try self.asyncConnect(socket: socket, host: host, port: port)
                timer?.cancel()
                self.connections.append(connection)
                
                if let delegate = self.delegate {
                    DispatchQueue.main.async {
                        delegate.connected(client: self, connection: connection)
                    }
                }
                connection.start()
            } catch let e {
                if let delegate = self.delegate {
                    let error = timedOut ? POSIXError (POSIXError.ETIMEDOUT) : e
                    DispatchQueue.main.async {
                        delegate.connectionFailed(client: self, host: host, port: port, family: family, proto: proto, error: error)
                    }
                }
            }
        }
    }
    
    public func disconnect (connection: CWSocketConnection) {
        asyncQueue.async {
            connection.asyncDisconnect()
        }
    }
    
    //---------------------------------------------------------------
    /// disconnectAll - Disconnect all connections
    public func disconnectAll () {
        // Our asyncDisconnect will get called by each connection as it disconnects - which will remove
        // it from our connections array.  And because its called async on our asyncQueue we can guarantee that
        // no asyncDisconnect will get called until we've finished this foreach loop.
        asyncQueue.async {
            self.connections.forEach { connection in connection.asyncDisconnect()
            }
        }
    }
    
    //---------------------------------------------------------------
    /// asyncConnect - Connect the socket to the hostr/port
    /// - Parameters:
    ///   - socket: The socket to connect
    ///   - host: The host
    ///   - port: The port
    private func asyncConnect (socket: CWSocket, host: String, port: in_port_t) throws -> CWSocketConnection {
        try socket.connect(port, host: host, nonblocking: true)
        let connection = try CWSocketConnection (socket: socket, host: host, asyncQueue: asyncQueue)
        connection.delegate = self
        return connection
    }
    
    // === Implement CWSocketConnectionDelegate
    
    func asyncDisconnected (connection: CWSocketConnection) {
        if let idx = (connections.firstIndex (where: ) { conn in conn === connection }) {
            connections.remove(at: idx)
        }
        
        if let delegate = delegate {
            DispatchQueue.main.async {
                delegate.disconnected(client: self, connection: connection)
            }
        }
    }
    
    func hasData(connection: CWSocketConnection) {
        if let delegate = delegate {
            DispatchQueue.main.async {
                delegate.hasData (client: self, connection: connection)
            }
        }
    }
}
