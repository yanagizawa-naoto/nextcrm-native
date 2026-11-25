import Foundation
import Darwin

/// The receive transport has finished writing before this reader is exposed.
/// IMAP control rows are read incrementally. Literal payloads remain file
/// ranges until the selected header/message is consumed.
final class NativeMailIMAPFile {
    private indirect enum Token {
        case atom(String),quoted(Data),literal(Range<Int>),list([Token])
        var string:String?{switch self{case .atom(let s):return s;case .quoted(let d):return String(data:d,encoding:.utf8);default:return nil}}
    }
    private enum Segment {case literal(Range<Int>),quoted(Data)}
    private struct Payload {let uid:UInt32,seen:Bool,section:String,segment:Segment}
    private final class Input {
        let fd:Int32,size:Int
        var position=0,bufferStart=0,bufferEnd=0,buffer=[UInt8](repeating:0,count:16_384),tokens=0
        init(fd:Int32,size:Int){self.fd=fd;self.size=size}
        func peek()throws->UInt8? {
            guard position<size else{return nil}
            if position<bufferStart || position>=bufferEnd {
                try Task.checkCancellation();var n:Int
                repeat{n=buffer.withUnsafeMutableBytes{pread(fd,$0.baseAddress,min($0.count,size-position),off_t(position))}}while n<0 && errno==EINTR
                guard n>0 else{throw NativeMailResponseFile.fileError};bufferStart=position;bufferEnd=position+n
            }
            return buffer[position-bufferStart]
        }
        func take()throws->UInt8 {guard let b=try peek() else{throw NativeMailFailure.malformed};position += 1;return b}
        func token(depth:Int)throws->Token {
            tokens += 1;guard depth<=16,tokens<=100_000 else{throw NativeMailFailure.malformed}
            let first=try take()
            if first==40 {
                var values:[Token]=[]
                while let b=try peek(){if b==32 || b==9{position += 1;continue};if b==41{position += 1;return .list(values)};values.append(try token(depth:depth+1))}
                throw NativeMailFailure.malformed
            }
            if first==34 {
                var value=Data()
                while let b=try peek(){position += 1;if b==34{return .quoted(value)};if b==92{let next=try take();guard next==92 || next==34 else{throw NativeMailFailure.malformed};value.append(next)}else{guard b != 0,b != 10,b != 13 else{throw NativeMailFailure.malformed};value.append(b)};guard value.count<=65_536 else{throw NativeMailFailure.tooLarge}}
                throw NativeMailFailure.malformed
            }
            if first==123 {
                var length=0,digits=0
                while let b=try peek(),(48...57).contains(b){guard length<=(Int.max-Int(b-48))/10 else{throw NativeMailFailure.malformed};length=length*10+Int(b-48);digits += 1;position += 1}
                guard digits>0 else{throw NativeMailFailure.malformed};if try peek()==43{position += 1}
                guard try take()==125,try take()==13,try take()==10,length<=size-position else{throw NativeMailFailure.malformed}
                let range=position..<position+length;position += length;return .literal(range)
            }
            guard ![0,10,13,41].contains(first) else{throw NativeMailFailure.malformed}
            var value=[first]
            while let b=try peek(),![0,9,10,13,32,40,41,34,123].contains(b){position += 1;value.append(b);guard value.count<=65_536 else{throw NativeMailFailure.tooLarge}}
            return .atom(String(decoding:value,as:UTF8.self))
        }
        func row()throws->[Token]? {
            while try peek() != nil {
                try Task.checkCancellation();tokens=0;var row:[Token]=[]
                while let b=try peek(),b != 13,b != 10 {if b==32 || b==9{position += 1}else{row.append(try token(depth:0))}}
                if try peek()==13{position += 1;guard try take()==10 else{throw NativeMailFailure.malformed}}else if try peek()==10{position += 1}
                if !row.isEmpty{return row}
            }
            return nil
        }
    }
    let file:NativeMailResponseFile
    init(file:NativeMailResponseFile){self.file=file}
    private func eachPayload(expected:Set<UInt32>,_ body:(Payload,Int32)throws->Void)throws {
        try file.withDescriptor { fd in
            var info=stat();guard fstat(fd,&info)==0,info.st_size>=0,let size=Int(exactly:info.st_size) else{throw NativeMailResponseFile.fileError}
            let input=Input(fd:fd,size:size);var observed:Set<UInt32>=[]
            while let row=try input.row() {
                guard row.count>=4,row[0].string=="*",row[2].string?.uppercased()=="FETCH" else{continue}
                guard case .list(let fields)=row[3] else{throw NativeMailFailure.malformed}
                var uid:UInt32?,seen=false,section:String?,segment:Segment?
                for i in fields.indices {
                    let key:String;if case .atom(let s)=fields[i]{key=s.uppercased()}else{key=""}
                    if key=="UID"{guard uid==nil,i+1<fields.count,let value=fields[i+1].string.flatMap(UInt32.init),value>0 else{throw NativeMailFailure.malformed};uid=value}
                    if key=="FLAGS"{guard i+1<fields.count,case .list(let flags)=fields[i+1] else{throw NativeMailFailure.malformed};seen=flags.contains{$0.string?.lowercased()=="\\seen"}}
                    if key.hasPrefix("BODY["){guard section==nil else{throw NativeMailFailure.malformed};section=key}
                    switch fields[i] {
                    case .literal(let range):guard section != nil,segment==nil else{throw NativeMailFailure.malformed};segment = .literal(range)
                    case .quoted(let data):guard section != nil,segment==nil else{throw NativeMailFailure.malformed};segment = .quoted(data)
                    default:break
                    }
                }
                guard let segment else{continue}
                guard let uid,expected.contains(uid),observed.insert(uid).inserted,let section else{throw NativeMailFailure.malformed}
                try body(.init(uid:uid,seen:seen,section:section,segment:segment),fd)
            }
        }
    }
    private func mapped(_ segment:Segment,fd:Int32)throws->Data {
        switch segment {
        case .quoted(let data):return data
        case .literal(let range):
            guard !range.isEmpty else{return Data()}
            let page=Int(getpagesize()),offset=range.lowerBound/page*page,delta=range.lowerBound-offset,length=range.upperBound-offset
            guard let start=mmap(nil,length,PROT_READ|PROT_WRITE,MAP_PRIVATE,fd,off_t(offset)),start != MAP_FAILED else{throw NativeMailResponseFile.fileError}
            // Data is a mutable value type. Private writable mapping preserves
            // its contract without ever modifying the owned receive file.
            return Data(bytesNoCopy:start.advanced(by:delta),count:range.count,deallocator:.custom{_,_ in munmap(start,length)})
        }
    }
    func body(expected:UInt32)throws->Data? {
        var found:Segment?
        try eachPayload(expected:[expected]){item,_ in guard found==nil,item.section=="BODY[]" else{throw NativeMailFailure.malformed};found=item.segment}
        guard let found else{return nil};return try file.withDescriptor{try mapped(found,fd:$0)}
    }
    func headers(expected:Set<UInt32>,_ consume:(NativeMailIMAPHeader)throws->Void)throws {
        guard !expected.isEmpty,expected.count<=50 else{throw NativeMailFailure.malformed}
        // At most50 small offsets/flags, never50 materialized literal bodies.
        var index:[Payload]=[];try eachPayload(expected:expected){item,_ in
            guard item.section.hasPrefix("BODY[HEADER") else{throw NativeMailFailure.malformed};index.append(item)
        }
        try file.withDescriptor{fd in
            for item in index.sorted(by:{$0.uid<$1.uid}) {
                try Task.checkCancellation()
                let length:Int;switch item.segment{case .literal(let range):length=range.count;case .quoted(let data):length=data.count}
                guard length<=NativeMailMIME.maximumIncomingHeaderBytes else{throw NativeMailFailure.tooLarge}
                try autoreleasepool{let data=try mapped(item.segment,fd:fd);try consume(.init(uid:item.uid,seen:item.seen,headers:NativeMailMIME.headers(data,allowLargeIncoming:true)))}
            }
        }
    }

}

/// Fake receivers retain their existing small-array implementation. The real
/// client provides a file-backed batch; the worker consumes each header inside
/// its existing transaction and publishes the cursor only after the full batch.
enum NativeMailHeaderBatch {
    case memory([NativeMailIMAPHeader])
    case file(NativeMailIMAPFile,expected:Set<UInt32>)
    func forEach(_ consume:(NativeMailIMAPHeader)throws->Void)throws {
        switch self {case .memory(let rows):for row in rows{try Task.checkCancellation();try consume(row)};case .file(let file,let expected):try file.headers(expected:expected,consume)}
    }
}
