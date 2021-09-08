//
//  CWExSocketServer.swift
//  CWExSockets
//
//  Created by Colin Wilson on 30/09/2019.
//  Copyright © 2019 Colin Wilson. All rights reserved.
//

import Foundation

//======================================================================
/// CWSocketServerError enum
///
/// - cantStartListener: Can's start listener - eg. maybe the port is already listening
/// - cantCreateAcceptSource: Can't creat accept source
/// - noDelegateToReceiveData: No delegate to receive data
public enum CWSocketServerError: Error {
    case cantStartListener (posixError: POSIXError)
    case cantCreateAcceptSource
    case cantCreateReadSource
    case noDelegateToReceiveData
    case notUTF8
    case writeBufferFull
}

extension CWSocketServerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cantStartListener (let posixError): return "Can't start listener: errno=" + String (posixError.code.rawValue) + ":" + posixError.localizedDescription
        case .cantCreateAcceptSource: return "Can't create accept source"
        case .cantCreateReadSource: return "Can''t create read source"
        case .noDelegateToReceiveData: return "No delegate to receive data"
        case .notUTF8: return "Not UTF8"
        case .writeBufferFull: return "Write Buffer Full"
        }
    }
}

//---------------------------------------------------------------
/// Delegate for CWSocketServer.
///
/// Note that all the functions are called on the async queue - which is why they all start
/// async...!
public protocol CWSocketServerDelegate: AnyObject {
    func asyncConnected (_ server: CWSocketServer, _ connection: CWSocketConnection)
    func asyncDisconnected (_ server: CWSocketServer, _ connection: CWSocketConnection)
    func asyncHasData (_ server: CWSocketServer, _ connection: CWSocketConnection)
    func asyncStopped (_ server: CWSocketServer)
}

//---------------------------------------------------------------
/// CWSocketServer
final public class CWSocketServer: CWSocketConnectionDelegate {
    
    
    public let port: UInt16
    public let socketFamily: CWSocketFamily
    
    private var connections = [CWSocketConnection] ()
    private var asyncQueue: DispatchQueue?
    private var listenerSocket: CWSocket?
    private var acceptSource: DispatchSourceRead?
    public var userObject: AnyObject?
    public weak var delegate : CWSocketServerDelegate?
    public var started: Bool { listenerSocket != nil }
    
    //---------------------------------------------------------------
    /// init - CWSocketServer constructor
    ///
    /// - Parameters:
    ///   - port: The port to listen on
    ///   - socketFamily: The family - v4 or v6
    public init (port: UInt16, socketFamily: CWSocketFamily) {
        self.port = port
        self.socketFamily = socketFamily
        debugInitPrint ("CWSocket Server init for port \(port)")
    }
    
    //---------------------------------------------------------------
    /// deinit
    deinit {
        debugInitPrint ("CWSocket Server deinit for port \(port)")

        stop ()
    }
    
    //---------------------------------------------------------------
    /// disconnect - Disconnect and close an individual client connection
    ///
    /// - Parameter connection: The connection to disconnect
    public func disconnect (_ connection: CWSocketConnection) {
        asyncQueue?.async {
            connection.asyncDisconnect()
            
            /// Note that the connection will  be removed from our array of connections
            /// by it calling our asyncDisconnected function - below
        }
    }
    
    //---------------------------------------------------------------
    /// stop - Cancels all client connections, and stops listening for more
    public func stop () {
        
        if !started { return }
        
        asyncQueue?.async {
            for connection in self.connections {
                connection.asyncDisconnect ()
            }
        }
        
        acceptSource?.cancel()
        acceptSource = nil
        asyncQueue = nil
    }
    
    //---------------------------------------------------------------
    /// start - Starts the server
    /// - Throws: CWSocketServerError
    public func start () throws {
        
        if started { return }
        
        let listenerSocket = CWSocket (family: socketFamily, proto: .tcp)
        
        do {
            try listenerSocket.bind(port, ipAddress: nil)
            try listenerSocket.listen()
            
            let asyncQueue = DispatchQueue (label: "serverAsyncQueue")
            let acceptSource = listenerSocket.makeReadSource(queue: asyncQueue)
            
            acceptSource.setEventHandler(handler: asyncAcceptPendingConnections)
            acceptSource.setCancelHandler(handler: asyncCancelAccept)
            
            self.listenerSocket = listenerSocket
            self.asyncQueue = asyncQueue
            self.acceptSource = acceptSource
            
            acceptSource.resume()
        } catch let e as POSIXError {
            asyncQueue = nil
            throw CWSocketServerError.cantStartListener (posixError: e)
        }
    }
    
    //---------------------------------------------------------------
    /// connectionWithContext - Find a connection by its context string.
    ///
    /// - Parameter context: The context to find
    /// - Returns: The first connection with a match contet - or nil
    public func connectionWithContext (context: String) -> CWSocketConnection? {
        return connections.first(where: ) { connection in
            connection.context == context
        }
    }
    
    //---------------------------------------------------------------
    /// asyncCancelAccept - called by the accept source's cancel handler
    private func asyncCancelAccept () {
        listenerSocket = nil
        delegate?.asyncStopped(self)
    }
    
    //---------------------------------------------------------------
    /// asyncAcceptPendingConnection - called by the accept source's event handler
   private func asyncAcceptPendingConnections() {
         guard let listenerSocket = listenerSocket, let acceptSource = acceptSource, let asyncQueue = asyncQueue else {
             return
         }
         let numPendingConnections = acceptSource.data
         for _ in 0..<numPendingConnections {
             
             do {
                let clientSocket = try listenerSocket.accept (nonblocking:true)
                let connection = try CWSocketConnection (socket: clientSocket, host: clientSocket.remoteIP(), asyncQueue: asyncQueue)
                connection.delegate = self
                connections.append(connection)
                connection.start()
                delegate?.asyncConnected(self, connection)
             }
             catch let e as POSIXError {
                 debugInitPrint ("Error in accept:" + String(e.code.rawValue) + ":" + e.localizedDescription)
             }
             catch {
                 debugInitPrint ("Unknown error in accept")
             }
         }
     }
    
    //===============================================================
    // CWSocketConnectionDelegate implementation
    
    //---------------------------------------------------------------
    /// asyncDisconnected - Called by a connection when it disconnects
    ///
    /// This will be called either if the client closed the connection, or we did.  In either case,
    /// /// remove the conection from our array of connections
    ///
    /// - Parameter connection: The connection that disconnected
    func asyncDisconnected(connection: CWSocketConnection) {
        delegate?.asyncDisconnected(self, connection)
        
        if let idx = (connections.firstIndex(where: ) { conn in conn === connection }) {
            connections.remove(at: idx)
        }
        
    }
    
    //---------------------------------------------------------------
    /// hadData - called by the connection when it has read some new data
    ///
    /// Typically your delegate would use the connection's read... functions to retrieve the data
    /// from the connection's read buffer until the read buffer is empty.
    ///
    /// - Parameter connection: <#connection description#>
    func hasData(connection: CWSocketConnection) {
        delegate?.asyncHasData(self, connection)
    }
    

}

