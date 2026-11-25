import Foundation

/// Incoming mixed-part plain text is displayed alongside HTML. Links are
/// detected locally; escaping precedes paragraph/linebreak formatting.
enum NativeMailTextHTML {
    private static func escape(_ text:String)->String {
        var result=""
        for s in text.unicodeScalars {
            switch s.value {
            case 1...9,11,12,14...31,127:result += "&#x"+String(s.value,radix:16,uppercase:true)+";"
            case 160:result += "&nbsp;"
            case 38:result += "&amp;"
            case 60:result += "&lt;"
            case 62:result += "&gt;"
            case 34:result += "&quot;"
            case 39:result += "&apos;"
            case 96:result += "&#x60;"
            case 128...:result += "&#x"+String(s.value,radix:16,uppercase:true)+";"
            default:result.unicodeScalars.append(s)
            }
        }
        return result
    }
    // The upstream default fuzzy-domain allowlist. Explicit URI schemes do
    // not need a recognized public suffix. No DNS lookup is performed.
    private static let tldPattern="^(?:biz|com|edu|gov|net|org|pro|web|xxx|aero|asia|coop|info|museum|name|shop|рф|xn--[a-z0-9-]+|a[cdefgilmnoqrstuwxz]|b[abdefghijmnorstvwyz]|c[acdfghiklmnoruvwxyz]|d[ejkmoz]|e[cegrstu]|f[ijkmor]|g[abdefghilmnpqrstuwy]|h[kmnrtu]|i[delmnoqrst]|j[emop]|k[eghimnprwyz]|l[abcikrstuvy]|m[acdeghklmnopqrstuvwxyz]|n[acefgilopruz]|om|p[aefghklmnrstwy]|qa|r[eosuw]|s[abcdeghijklmnortuvxyz]|t[cdfghjklmnortvwz]|u[agksyz]|v[aceginu]|w[fs]|y[et]|z[amw])$"
    private static func link(_ raw:String,detected:URL)->String? {
        if raw.range(of:"^(?:https?:|ftp:|mailto:|//)",options:[.regularExpression,.caseInsensitive]) != nil{return raw}
        let isEmail=detected.scheme?.lowercased()=="mailto",host=isEmail ? raw.split(separator:"@").last.map(String.init):detected.host
        guard let suffix=host?.split(separator:".").last,String(suffix).range(of:tldPattern,options:[.regularExpression,.caseInsensitive]) != nil else{return nil}
        return (isEmail ? "mailto:":"http://")+raw
    }
    static func convert(_ text:String)throws->String {
        try Task.checkCancellation()
        let detector=try NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue),input=text as NSString
        var output="",end=0,failure:Error?
        detector.enumerateMatches(in:text,range:NSRange(location:0,length:input.length)){match,_,stop in
            do {
                try Task.checkCancellation();guard let match,let detected=match.url,let url=link(input.substring(with:match.range),detected:detected) else{return}
                output += escape(input.substring(with:NSRange(location:end,length:match.range.location-end)))
                output += "<a href=\""+url.replacingOccurrences(of:"\"",with:"&quot;")+"\">"+escape(input.substring(with:match.range))+"</a>";end=NSMaxRange(match.range)
            } catch {failure=error;stop.pointee=true}
        }
        if let failure{throw failure};output += escape(input.substring(from:end))
        output=output.replacingOccurrences(of:"\r\n",with:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
        let trailing=try NSRegularExpression(pattern:"[ \\t]+$",options:.anchorsMatchLines)
        output=trailing.stringByReplacingMatches(in:output,range:NSRange(location:0,length:(output as NSString).length),withTemplate:"").trimmingCharacters(in:.whitespacesAndNewlines)
        output=output.replacingOccurrences(of:"\n\n+",with:"</p><p>",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        return "<p>"+output.replacingOccurrences(of:"\n",with:"<br/>")+"</p>"
    }
}
