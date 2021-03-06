//
//  HTTPServer.swift
//  SlimaneHTTPServer
//
//  Created by Yuki Takei on 4/10/16.
//  Copyright © 2016 MikeTOKYO. All rights reserved.
//

#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

@_exported import Suv
@_exported import S4
@_exported import C7
@_exported import HTTP
@_exported import HTTPParser

/**
 Result enum for on HTTP Connection
 
 - Success: For getting request and response objects
 - Error: For getting Error
 */
public typealias HTTPConnectionResult = (() throws -> (Request, HTTPStream)) -> ()

public final class HTTPServer {
    
    /**
     Event loop
     */
    public let loop: Loop
    
    /**
     The maximum number of tcp established connection that server can handle
     */
    public var backlog: UInt = 1024
    
    /**
     Seconds for keep alive timeout, if zero keep alive is disabled. Default is 15 (Same as Nginx)
     */
    public var keepAliveTimeout: UInt = 15
    
    public var shouldKeepAlive: Bool {
        return keepAliveTimeout > 0
    }
    
    /**
     Sets the maximum number of requests that can be served through one keep-alive connection. After the maximum number of requests are made, the connection is closed.
     */
    public var keepaliveRequests: UInt = 100
    
    /**
     Flag for Enable / disable Nagle’s algorithm.
     */
    public var setNoDelay = false
    
    private var roundRobinCounter = 0
    
    private let userOnConnection: HTTPConnectionResult
    
    private let server: TCPServer
    
    // Current connected clients count.
    public var clientsConnected: Int = 0
    
    /**
     - parameter loop: Event loop
     - parameter ipcEnable: if true TCP is initilized as ipcMode and it can't bind, false it is initialized as basic TCP handle instance
     - parameter onConnection: Connection handler
     */
    public init(loop: Loop = Loop.defaultLoop, ipcEnable: Bool = false, onConnection: HTTPConnectionResult = {_ in}) {
        self.loop = loop
        self.userOnConnection = onConnection
        self.server = TCPServer(loop: loop, ipcEnable: ipcEnable)
        
        // Ignore SIGPIPE
        signal(SIGPIPE, SIG_IGN)
    }
    
    /**
     Bind address
     
     - parameter addr: Bind Address
     - throws: SuvError.UVError
     */
    public func bind(_ addr: Address) throws {
        try server.bind(addr)
    }
    
    /**
     Listen HTTP Server
     */
    public func listen() throws {
        if server.socket.typeIsTcp && self.setNoDelay {
            try (server.socket as! TCP).setNoDelay(true)
        }
        
        try server.listen(backlog) { [unowned self] result in
            if case .Success(let queue) = result {
                self.onConnection(queue)
            }
            else if case .Error(let err) = result {
                self.userOnConnection { throw err }
            }
        }
        
        Loop.defaultLoop.run()
    }
    
    private func onConnection(_ queue: Pipe?) {
        // TODO need to fix more ARC friendly
        let client = HTTPStream(stream: TCP())
        self.clientsConnected += 1
        
        let unmanaged = Unmanaged.passRetained(client)
        
        client.stream.onClose { [unowned self] in
            self.clientsConnected -= 1
            unmanaged.release()
        }
        
        do {
            // accept connection
            try server.accept(client.stream, queue: queue)
        }  catch {
            do {
                try client.close()
                self.userOnConnection { throw error }
            } catch {
                self.userOnConnection { throw error }
            }
        }
        
        // send handle to worker via ipc socket
        if Cluster.isMaster && hasWorker {
            return sendHandleToWorker(client)
        }
        
        let parser = RequestParser()
        
        client.receive { [unowned self, unowned client] result in
            do {
                let data = try result()
                if let request = try parser.parse(data) {
                    self.userOnConnection { return (request, client) }
                }
            } catch HTTPStream.Error.EOF {
                do {
                    try client.close()
                    self.userOnConnection { throw HTTPStream.Error.EOF }
                } catch {
                    self.userOnConnection { throw error }
                }
            } catch {
                if !self.shouldKeepAlive {
                    do {
                        try client.close()
                        self.userOnConnection { throw error }
                    } catch {
                        self.userOnConnection { throw error }
                    }
                }
            }
        }
    }
    
    private var hasWorker: Bool {
        return Cluster.workers.count > 0
    }
    
    // sending handles over a pipe
    private func sendHandleToWorker(_ client: HTTPStream){
        let worker = Cluster.workers[self.roundRobinCounter]
        
        // send stream to worker with ipc
        client.stream.write2(ipcPipe: worker.ipcPipe!)
        client.stream.close()
        
        roundRobinCounter = (roundRobinCounter + 1) % Cluster.workers.count
    }
    
    /**
     Close server handle
     */
    public func close(){
        self.server.close()
    }
}
