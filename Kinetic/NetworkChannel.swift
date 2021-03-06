// Copyright (c) 2015 Seagate Technology

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// @author: Ignacio Corderi

import Socket

public let connect = NetworkChannel.connect
public func connect(host: String, port: Int = NetworkChannel.DEFAULT_PORT,
                    timeout: Double = NetworkChannel.DEFAULT_CONNECT_TIMEOUT) throws ->  KineticSession {
    return try NetworkChannel.connect(host, port: port, timeout: timeout)
}

public class NetworkChannel: CustomStringConvertible, KineticChannel {

    public static let DEFAULT_CONNECT_TIMEOUT = 1.0
    public static let DEFAULT_PORT = 8123
    
    public let host: String
    public let port: Int
    
    var stream:Stream? = nil
    
    // CustomStringConvertible (a.k.a toString)
    public var description: String {
        return "Channel \(self.host):\(self.port)"
    }
    
    // KineticChannel
    weak public private(set) var session: KineticSession? = nil
    public var connected: Bool {
        if self.stream!.eof     {return false}
        if self.stream!.closing {return false}
        return true
    }
    
    internal init(host:String, port:Int, timeout: Double = NetworkChannel.DEFAULT_CONNECT_TIMEOUT) throws {
        self.port = port
        self.host = host
        self.stream = try Stream(connectTo: host, port: String(port), timeout: timeout)
    }
    
    public static func connect(host: String, port: Int, timeout: Double = NetworkChannel.DEFAULT_CONNECT_TIMEOUT) throws -> KineticSession {
        let c = try NetworkChannel(host: host, port: port, timeout: timeout)

        let s = KineticSession(channel: c)
        c.session = s
            
        return s
    }
    
    public func clone() throws -> KineticSession {
        return try NetworkChannel.connect(host, port: port)
    }
    
    public func close() {
        self.stream!.releaseSock()
    }
    
    public func send(builder: Builder) throws {
        let encoded = try builder.encode()
        try stream!.writeBytes(encoded.header.bytes, cork: true)
        try stream!.writeBytes(encoded.proto)
        if encoded.value.count > 0 {
            try stream!.writeBytes(encoded.value)
        }
    }
    
    public func receive() throws -> RawResponse {
        
        let header = try KineticEncoding.Header(bytes: stream!.readBytes(9))
        let proto = try stream!.readBytes(header.protoLength)
        var value: Bytes = []
        if header.valueLength > 0 {
            value = try stream!.readBytes(header.valueLength)
        }
        
        let encoding = KineticEncoding(header, proto, value)
        
        return try encoding.decode()
    }
}
