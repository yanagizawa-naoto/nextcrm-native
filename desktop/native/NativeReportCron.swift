import Foundation

struct NativeReportCronError: LocalizedError {
    let errorDescription: String?
    init(_ message:String) { errorDescription=message }
}

/// Five-field calendar schedules. Storage keeps the expression and a named
/// timezone, so travel does not silently move an existing schedule. A missing
/// DST wall time is skipped; a repeated wall time runs at its first occurrence.
struct NativeReportCron {
    private struct Field {
        let values:Set<Int>,startsWithStar:Bool
        init(_ text:String,_ bounds:ClosedRange<Int>,names:[String:Int]=[:],sunday:Bool=false)throws {
            startsWithStar=text.first=="*"
            var selected=Set<Int>()
            func number(_ raw:Substring)throws->Int {
                if let named=names[String(raw).uppercased()] {return named}
                guard !raw.isEmpty,raw.utf8.allSatisfy({$0>=48 && $0<=57}),let value=Int(raw),bounds.contains(value) else {
                    throw NativeReportCronError("曜日・時刻の指定が範囲外です。")
                };return value
            }
            for part in text.split(separator:",",omittingEmptySubsequences:false) {
                let pieces=part.split(separator:"/",omittingEmptySubsequences:false)
                guard (1...2).contains(pieces.count),!pieces[0].isEmpty else {throw NativeReportCronError("繰り返し間隔の指定を確認してください。")}
                var step=1
                if pieces.count==2 {
                    guard !pieces[1].isEmpty,pieces[1].utf8.allSatisfy({$0>=48 && $0<=57}),let value=Int(pieces[1]),value>0 else {
                        throw NativeReportCronError("繰り返し間隔は1以上の整数で指定してください。")
                    };step=min(value,bounds.upperBound-bounds.lowerBound+1)
                }
                let lower:Int,upper:Int
                if pieces[0]=="*" {lower=bounds.lowerBound;upper=bounds.upperBound}
                else {
                    let range=pieces[0].split(separator:"-",omittingEmptySubsequences:false)
                    guard (1...2).contains(range.count) else {throw NativeReportCronError("曜日・時刻の範囲指定を確認してください。")}
                    lower=try number(range[0]);upper=range.count==2 ? try number(range[1]) : pieces.count==2 ? bounds.upperBound : lower
                    guard lower<=upper else {throw NativeReportCronError("範囲の開始は終了以下にしてください。")}
                }
                for value in stride(from:lower,through:upper,by:step) {selected.insert(sunday && value==7 ? 0 : value)}
            }
            guard !selected.isEmpty else {throw NativeReportCronError("繰り返し日時が指定されていません。")};values=selected
        }
    }
    let expression:String
    private let minute:Field,hour:Field,day:Field,month:Field,weekday:Field
    init(_ expression:String)throws {
        guard expression.utf8.count<=512 else {throw NativeReportCronError("繰り返し日時の指定が長すぎます。")}
        let fields=expression.split(whereSeparator:{$0==" " || $0=="\t"}).map(String.init)
        guard fields.count==5 else {throw NativeReportCronError("分・時・日・月・曜日の5項目で指定してください。例：0 9 * * 1")}
        self.expression=fields.joined(separator:" ")
        minute=try Field(fields[0],0...59);hour=try Field(fields[1],0...23);day=try Field(fields[2],1...31)
        month=try Field(fields[3],1...12,names:Dictionary(uniqueKeysWithValues:["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"].enumerated().map{($0.element,$0.offset+1)}))
        weekday=try Field(fields[4],0...7,names:Dictionary(uniqueKeysWithValues:["SUN","MON","TUE","WED","THU","FRI","SAT"].enumerated().map{($0.element,$0.offset)}),sunday:true)
    }
    /// Day-of-month and weekday use traditional cron OR semantics when both
    /// fields are restricted. A field beginning with '*' keeps AND semantics.
    private func matchesDay(_ date:Date,calendar:Calendar)->Bool {
        let c=calendar.dateComponents([.day,.month,.weekday],from:date)
        guard month.values.contains(c.month!) else{return false}
        let a=day.values.contains(c.day!),b=weekday.values.contains(c.weekday!-1)
        return day.startsWithStar || weekday.startsWithStar ? a && b : a || b
    }
    func next(after date:Date,timeZone:TimeZone)throws->Date? {
        guard date.timeIntervalSince1970.isFinite else {throw NativeReportCronError("基準日時が不正です。")}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        guard let limit=calendar.date(byAdding:.year,value:8,to:date) else {throw NativeReportCronError("基準日時が範囲外です。")}
        var current=calendar.startOfDay(for:date)
        let hours=hour.values.sorted(),minutes=minute.values.sorted()
        let startingClock=calendar.dateComponents([.hour,.minute],from:date)
        while current<=limit {
            try Task.checkCancellation()
            if matchesDay(current,calendar:calendar) {
                for h in hours {
                    try Task.checkCancellation()
                    for m in minutes {
                        if calendar.isDate(current,inSameDayAs:date),h<startingClock.hour! || (h==startingClock.hour! && m<=startingClock.minute!) {continue}
                        guard let candidate=calendar.nextDate(after:current.addingTimeInterval(-1),matching:DateComponents(hour:h,minute:m,second:0),matchingPolicy:.strict,repeatedTimePolicy:.first,direction:.forward),
                              calendar.isDate(candidate,inSameDayAs:current),candidate>date,candidate<=limit else {continue}
                        return candidate
                    }
                }
            }
            guard let tomorrow=calendar.date(byAdding:.day,value:1,to:current),tomorrow>current else {return nil}
            // A midnight DST gap can make startOfDay 01:00. Normalize the next
            // day again so subsequent midnight occurrences are not skipped.
            current=calendar.startOfDay(for:tomorrow)
        }
        return nil
    }
}
