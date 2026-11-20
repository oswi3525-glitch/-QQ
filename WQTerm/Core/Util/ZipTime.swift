import Foundation

/// Chuyển đổi thời gian sang định dạng DOS (dùng trong header ZIP).
enum ZipTime {
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16((parts.hour ?? 0) << 11)
            | UInt16((parts.minute ?? 0) << 5)
            | UInt16((parts.second ?? 0) / 2)
        let day = UInt16(min(127, year - 1980) << 9)
            | UInt16((parts.month ?? 1) << 5)
            | UInt16(parts.day ?? 1)
        return (time, day)
    }

    static func date(dosTime time: UInt16, dosDate: UInt16) -> Date {
        var parts = DateComponents()
        parts.year = 1980 + Int((dosDate >> 9) & 0x7F)
        parts.month = Int((dosDate >> 5) & 0x0F)
        parts.day = Int(dosDate & 0x1F)
        parts.hour = Int((time >> 11) & 0x1F)
        parts.minute = Int((time >> 5) & 0x3F)
        parts.second = Int(time & 0x1F) * 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }
}
