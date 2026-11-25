import Foundation
import Darwin

private final class NativeCalendarNoRedirects: NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}

/// Disposable provider response, using the existing inode-bound private lease.
/// The transport owns writes until return; callers then read with pread.
/// No URL, token or body bytes are written to diagnostics.
struct NativeCalendarResponse {
    typealias Request = (URLRequest) async throws -> NativeCalendarResponse
    let file:NativeMailResponseFile,response:HTTPURLResponse
    init(data:Data,response:HTTPURLResponse,temporaryRoot:URL=FileManager.default.temporaryDirectory)throws {
        file=try NativeMailResponseFile(temporaryRoot:temporaryRoot);self.response=response
        try file.withDescriptor { fd in try Self.write(data,fd:fd) }
    }
    init(file:NativeMailResponseFile,response:HTTPURLResponse){self.file=file;self.response=response}
    static var invalid:NativeDBError{.message("カレンダーの応答形式または作業ファイルが不正です。")}
    private static func write(_ data:Data,fd:Int32)throws {
        try data.withUnsafeBytes { raw in
            var done=0
            while done<raw.count {
                try Task.checkCancellation();let count=Darwin.write(fd,raw.baseAddress!.advanced(by:done),raw.count-done)
                if count<0 && errno==EINTR{continue};guard count>0 else{throw invalid};done += count
            }
        }
    }
    static func network(_ request:URLRequest,temporaryRoot:URL=FileManager.default.temporaryDirectory)async throws->Self {
        let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil;config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=90
        let session=URLSession(configuration:config,delegate:NativeCalendarNoRedirects(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        let file=try NativeMailResponseFile(temporaryRoot:temporaryRoot)
        let (bytes,response)=try await session.bytes(for:request)
        guard let response=response as? HTTPURLResponse else{throw invalid}
        var buffer=Data();buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation();buffer.append(byte)
            if buffer.count==65_536 {try file.withDescriptor{try write(buffer,fd:$0)};buffer.removeAll(keepingCapacity:true)}
        }
        if !buffer.isEmpty{try file.withDescriptor{try write(buffer,fd:$0)}}
        try Task.checkCancellation();return .init(file:file,response:response)
    }
    func forEachChunk(_ consume:(Data)throws->Void)throws {
        try file.withDescriptor { fd in
            var offset:off_t=0,buffer=[UInt8](repeating:0,count:65_536)
            while true {
                try Task.checkCancellation();let count=pread(fd,&buffer,buffer.count,offset)
                if count<0 && errno==EINTR{continue};guard count>=0 else{throw Self.invalid};if count==0{return}
                try consume(Data(buffer.prefix(count)));offset += off_t(count)
            }
        }
    }
    func data(maximumBytes:Int)throws->Data {
        var result=Data()
        try forEachChunk{chunk in guard chunk.count<=maximumBytes-result.count else{throw Self.invalid};result.append(chunk)}
        return result
    }
    /// Locates only JSON envelope/array boundaries. Foundation parses every
    /// key and value. The first pass validates syntax and records the LAST array
    /// range; the second projects that range. Duplicate keys cannot publish
    /// discarded events or impose schema checks on an overwritten value.
    func project(array name:String,metadata:Set<String>,maximumItems:Int,requireArray:Bool=false,begin:()throws->Void,element:(Data)throws->Void)throws->[String:Any] {
        try file.withDescriptor { fd in
            let cursor=try Cursor(fd);var values:[String:Any]=[:],selected:Range<Int>?
            try cursor.expect(123);try cursor.spaces()
            if !(try cursor.take(125)) {
                while true {
                    try cursor.spaces();let keyRange=try cursor.valueRange()
                    let key=try JSONDecoder().decode(String.self,from:cursor.data(keyRange));try cursor.expect(58);try cursor.spaces()
                    if key==name {
                        let start=cursor.position
                        if try cursor.take(91) {
                            try cursor.arrayElements { range in
                                _ = try JSONSerialization.jsonObject(with:cursor.data(range),options:.fragmentsAllowed)
                            }
                        } else {
                            let range=try cursor.valueRange();_ = try JSONSerialization.jsonObject(with:cursor.data(range),options:.fragmentsAllowed)
                        }
                        selected=start..<cursor.position
                    } else {
                        let range=try cursor.valueRange()
                        try autoreleasepool {
                            let value=try JSONSerialization.jsonObject(with:cursor.data(range),options:.fragmentsAllowed)
                            if metadata.contains(key){values[key]=value}
                        }
                    }
                    try cursor.spaces();if try cursor.take(125){break};try cursor.expect(44)
                }
            }
            try cursor.end()
            if let selected {
                cursor.position=selected.lowerBound;try begin()
                if try cursor.take(91) {
                    var count=0
                    try cursor.arrayElements {range in count += 1;guard count<=maximumItems else{throw Self.invalid};try element(cursor.data(range))}
                } else {
                    guard !requireArray,try JSONSerialization.jsonObject(with:cursor.data(selected),options:.fragmentsAllowed) is NSNull else{throw Self.invalid}
                }
            } else if requireArray {throw Self.invalid}
            return values
        }
    }
    private final class Cursor {
        let fd:Int32,size:Int
        var position=0,start=0,endOffset=0,buffer=[UInt8](repeating:0,count:65_536)
        init(_ fd:Int32)throws{self.fd=fd;var s=stat();guard fstat(fd,&s)==0,s.st_size>=0,let n=Int(exactly:s.st_size) else{throw invalid};size=n}
        func peek()throws->UInt8? {
            guard position<size else{return nil}
            if position<start || position>=endOffset {
                try Task.checkCancellation();var n:Int
                repeat{n=buffer.withUnsafeMutableBytes{pread(fd,$0.baseAddress,min($0.count,size-position),off_t(position))}}while n<0 && errno==EINTR
                guard n>0 else{throw invalid};start=position;endOffset=position+n
            }
            return buffer[position-start]
        }
        func spaces()throws{while let b=try peek(),[9,10,13,32].contains(b){position += 1}}
        func take(_ byte:UInt8)throws->Bool{if try peek()==byte{position += 1;return true};return false}
        func expect(_ byte:UInt8)throws{try spaces();guard try take(byte) else{throw invalid}}
        func end()throws{try spaces();guard try peek()==nil else{throw invalid}}
        func arrayElements(_ body:(Range<Int>)throws->Void)throws {
            try spaces();if try take(93){return}
            while true {
                let range=try valueRange();try autoreleasepool{try body(range)}
                try spaces();if try take(93){return};try expect(44)
            }
        }
        func valueRange()throws->Range<Int> {
            try spaces();let start=position;guard let first=try peek() else{throw invalid}
            var containers:[UInt8]=[],quoted=false,escaped=false
            if first==123 || first==91 {containers.append(first);position += 1}
            else if first==34 {quoted=true;position += 1}
            else {
                while let b=try peek(),![9,10,13,32,44,93,125].contains(b){position += 1}
                guard position>start else{throw invalid};return start..<position
            }
            while let b=try peek() {
                position += 1
                if quoted {
                    if escaped{escaped=false;continue}
                    if b==92{escaped=true}else if b==34{quoted=false;if containers.isEmpty{return start..<position}}
                    continue
                }
                if b==34{quoted=true;continue}
                if b==123 || b==91{containers.append(b)}
                if b==125 || b==93 {
                    guard let open=containers.popLast(),(open==123 && b==125)||(open==91 && b==93) else{throw invalid}
                    if containers.isEmpty{return start..<position}
                }
            }
            throw invalid
        }
        func data(_ range:Range<Int>)throws->Data {
            guard range.lowerBound>=0,range.upperBound<=size else{throw invalid}
            var data=Data(count:range.count)
            try data.withUnsafeMutableBytes { raw in
                var done=0
                while done<raw.count {
                    try Task.checkCancellation();let n=pread(fd,raw.baseAddress!.advanced(by:done),min(65_536,raw.count-done),off_t(range.lowerBound+done))
                    if n<0 && errno==EINTR{continue};guard n>0 else{throw invalid};done += n
                }
            }
            return data
        }
    }
}
