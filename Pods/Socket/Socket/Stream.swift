import Foundation

public typealias Bytes = [UInt8]

protocol StreamProtocol {
    
    //    Create a connection witin timeout period to host and port specified.
    //    the connection will have Nagle and sigPipe turned off. timeout defaults
    //    to forever (or until the host gives up which is 30 seconds I think)
    //    TODO: make timeout Double
    //
    //    throws: If not successful
    init(connectTo host:String, port: in_port_t, var timeout: Double) throws
    
    //    Listens to a either an ephemeral or fixes port. A listen socket is only
    //    good for accepting connections.
    //
    //    throws: if not successful
    //    init(listenPort: in_port_t) throws
    //
    //    Returns: the port number that is being listened to
    var port:in_port_t { get }
    
    
    //    Blocks until someone sends a connect to a listening instance.
    //
    //    returns: the instance unless the accept has been closed down, and 
    //    in that case returns nil
    //
    //    throws: if not successful (there is no timeout)
    func acceptConnection() throws -> Stream?
    
    //    Writes data to a connect or accpeted session. Cork is an optional parameter
    //    that defalts to false. cork = true delays the write until the stream is written to
    //    again with cork = false.
    //
    //    throws: if all the data is not successfully written
    func writeBytes(inout bytes: Bytes, cork: Bool) throws
    
    //    Reads data until the size is satisfied, EoF or there is more than timeout
    //    witout reading additional bytes. If timeout is not specified it is "forever".
    //
    //    returns: the bytes read up size, EoF or timeout. To differentiate from EoF and
    //    timeout use atEoF
    //
    //    throws if there is any other reason why size bytes are not read
    func readBytes(size:Int, timeout: Double) throws -> Bytes
    
    //    Reads Bytes preserving natural boundries.
    //
    //    Returns: Bytes up to size or lrngth of 0 if there is
    //    an EoF or timeout. default timeout is "forever".
    //
    //    throws: for any other reason
    func readNextBytes(size: Int, timeout: Double) throws -> Bytes
    
    //    Returns true if the stream is at EoF
    var atEoF:Bool { get }
    
    //    Graceful sutdown of the write channel. Data can still be read
    //
    //    throws: if there is a problem.
    func shutdownSocket() throws
    
    //    Shuts down the complete connection regardless of state. Does not
    //    throw so it can be used in "catch".
    func releaseSock()
}

extension sockaddr {
    
    // TODO, Fix this hack
    init(host: String, port: in_port_t) {
        self.init()
        var addr = sockaddr_in(
            sin_len: __uint8_t(sizeof(sockaddr_in)),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr(host)),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let data = NSData(bytes: &addr, length: sizeof(sockaddr_in))
        data.getBytes(&self, length: sizeof(sockaddr))
    }
}

extension sockaddr_in {
    
    // TODO, Fix this hack
    init(var fromSockaddr s: sockaddr) {
        self.init()
        let data = NSData(bytes: &s, length: sizeof(sockaddr))
        data.getBytes(&self, length: sizeof(sockaddr_in))
    }
}

extension timeval {
    
    // initializes  a timeval from a double of seconds
    init(t: Double) {
        let sec = __darwin_time_t(t)
        let usec = __darwin_suseconds_t((t - Double(sec)) * 1e6)
        self.init(tv_sec: sec, tv_usec: usec)
    }
}

public class Stream: StreamProtocol {
    
    private var s:Int32
    private var eof = false
    private var shuttingDown = false
    
    public var atEoF:Bool {
        return eof
    }
    
    public private(set) var port:in_port_t  = 0;
    
    public required init(connectTo host:String, port: in_port_t, timeout: Double) throws {
        s = socket(AF_INET, SOCK_STREAM, 0)
        guard ( s != -1 ) else {
            throw PosixError(comment: "socket(....) failed")
        }
        
        // don't want signals...
        try nosigpipe()
        
        // disable Nagle
        var value: Int32 = 1;
        guard ( setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(sizeof(Int32))) != -1 ) else {
            throw PosixError(comment: "setsockopt(TCP_NODELAY...) failed.")
        }
        
        // set the connect timeout.
        var t = Int32(timeout + 0.999999) // round up to second.
        guard ( setsockopt(s, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &t, socklen_t(sizeof(Int32))) != -1 ) else {
            throw PosixError(comment: "setsockopt(TCP_CONNECTIONTIMEOUT...) failed.")
        }
        
        // do the connection
        var sockAddr = sockaddr(host: host, port: port)
        guard connect(s, &sockAddr, socklen_t(sockAddr.sa_len)) != -1 else {
            throw PosixError(comment: "connect(...) failed.")
        }
    }
    
    
    public required init(listenPort: in_port_t = 0) throws {
        s = socket(AF_INET, SOCK_STREAM, 0)
        guard ( s != -1 ) else {
            throw PosixError(comment: "socket(....) failed")
        }
        try nosigpipe()
        
        // Set Reuse Socket
        var value: Int32 = 1;
        guard ( setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(strideof(Int32))) != -1 ) else {
            throw PosixError(comment: "setsockopt(...) failed.")
        }
        
        var sock_addr = sockaddr(host: "0.0.0.0", port: listenPort)
        
        guard ( bind(s, &sock_addr, socklen_t(strideof(sockaddr_in))) != -1 ) else {
            throw PosixError(comment: "bind(...) failed.")
        }
        
        guard ( listen(s, 20 /* max pending connection */ ) != -1 ) else {
            throw PosixError(comment: "listen(...) failed.")
        }

        var sa = sockaddr()
        var salen = socklen_t(strideof(sockaddr))
        guard getsockname(s, &sa, &salen) == 0 else {
            throw PosixError(comment: "getsockname(...) failed.")
        }
        let sin = sockaddr_in(fromSockaddr: sa)
        guard sin.sin_family == sa_family_t(AF_INET) else {
            fatalError("wrone networking family")
        }

        port = sin.sin_port.byteSwapped
    }
    
    
    // writes bytes, and if cork is true, then leaves them in the buffer.
    // if cork if false, the data is added to the buffer and then uncorked.
    // The correct sequence to send 2 buffers in a single tcp go, you would:
    //     writeBytes(data1, cork: true)
    //     writeBytes(data2)
    //
    public func writeBytes(inout bytes: Bytes, cork: Bool = false) throws {
        if cork {
            try setCork(true)
        }
        switch write(s, &bytes, bytes.count) {
        case let x where x < 0:
            throw PosixError(comment: "write(...) failed.")
        case bytes.count:
            return // happy
        case let x:     // x > 0 then
            fatalError("partial write len \(x) should have been \(bytes.count)")
        }
        if !cork {
            try setCork(false)
        }
    }
    
    func setCork(b:Bool) throws {
        var x:Int32 = b ? 1 : 0
        guard ( setsockopt(s, IPPROTO_TCP, TCP_NOPUSH, &x, socklen_t(sizeof(Int32))) != -1 ) else {
            throw PosixError(comment: "setsockopt(...) failed.")
        }
    }
    
    
    // Used only by the accept to create a new socket.
    private init(clientSock: Int32) {
        s = clientSock
    }
    
    // TODO: In the future, return nil when a normal close happens on Socket
    func acceptConnection() throws -> Stream? {
        var addr = sockaddr()
        var len: socklen_t = 0
        switch accept(s, &addr, &len) {
        case let a where a > 0: // normal good result
            let clientSocket = Stream(clientSock: a)
            try clientSocket.nosigpipe()
            return clientSocket
        case -1 where errno == 53 && shuttingDown:
            return nil
        case -1:
            throw PosixError(comment: "accept(...) failed.")
        default:
            fatalError("unknown reason")
        }
    }
    
    // this is a half shutdown indicating that we are no longer
    // sending data.
    public func shutdownSocket() throws {
        switch shutdown(s, SHUT_WR) {
        case 0, -1 where errno == 57:
            break // shutdown
        default:
            print(PosixError(comment: "shutdown(...) failed").description)
        }
    }
    
    // this release socket function does not throw so it can be used in
    // or after a catch
    public func releaseSock() {

        shuttingDown = true
        
        // shutdown the socket first
        switch shutdown(s, SHUT_RDWR) {
        case 0, -1 where errno == 57:
            break // shutdown
        default:
            print(PosixError(comment: "shutdown(...) failed").description)
        }
        // close the file descriptor
        switch close(s) {
        case 0: break
        default:
            print(PosixError(comment: "close(...) failed").description)
        }
        eof = true
    }
    
    
    private func setRdTimeout(timeout: Double) throws {
        var tv = timeval(t: timeout)
        let tvSize = socklen_t(strideof(timeval))
        
        switch setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize) {
        case 0: break                    // success
        case -1 where errno == 22: break // bug. If the stream is at EoF, SO_RCVTIMEO will fail.
        default:
            throw PosixError(comment: "setsockopt(SO_RCVTIMEO...) failed.")
        }
    }
    
    // reads preserving natural breaks in the stream.
    public func readNextBytes(size: Int, timeout: Double = 0) throws -> Bytes {
        
        try setRdTimeout(timeout)
        
        var buffer = Bytes(count: size, repeatedValue: 0)
        switch read(s, &buffer, size) {
        case let x where x > 0: // success
            buffer.removeRange(x ..< size)
            return buffer
        case 0: // EoF
            eof = true
            fallthrough
        case -1 where errno == 35: //  timedout
            return []
        case -1: // other error
            throw PosixError(comment: "read(....) failed in read next bytes routine")
        default:
            fatalError("Should not fall through")
        }
    }
    
    
    // this function returns the number of bytes specified or truncated
    // if there is an eof. Truncated to 0 bytes is ok.
    // throws on anything else.
    public func readBytes(size:Int, timeout: Double = 0) throws -> Bytes  {
        
        try setRdTimeout(timeout)
        
        var buffer = Bytes(count: size, repeatedValue: 0)
        var offset = 0
        while offset < size {
            switch read(s, &buffer[offset], size - offset) {
            case let len where len > 0: // len > 0, productive.
                offset += len
            case 0: // EoF
                eof = true
                fallthrough
            case -1 where errno == 35: // timeout
                buffer.removeRange(offset ..< size)
                return buffer
            case -1: // other error
                throw PosixError(comment: "read(....) failed in read bytes routine")
            default:
                fatalError("Should not fall through")
            }
        }
        return buffer
    }
    
    private func nosigpipe() throws {
        // prevents crashes when blocking calls are pending and the app is paused ( via Home button )
        // or if the socket in unexpectedly closed.
        var no_sig_pipe: Int32 = 1;
        guard setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(sizeof(Int32))) >= 0 else {
            throw PosixError(comment: "setsockopt(NoSigPipe...) failed.")
        }
    }
}