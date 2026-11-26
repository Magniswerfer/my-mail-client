#if canImport(Glibc)
import Glibc

/// Charset conversion through glibc's iconv, for MIME charsets on Linux (ADR 0007), where
/// CoreFoundation's IANA charset table isn't available.
enum Iconv {
    /// `bytes` in `charset` (an IANA name) as a String, or nil when iconv doesn't know the
    /// charset or the bytes aren't valid in it.
    static func decode(_ bytes: [UInt8], from charset: String) -> String? {
        let cd = iconv_open("UTF-8", charset)
        guard cd != iconv_t(bitPattern: -1) else { return nil }
        defer { iconv_close(cd) }
        if bytes.isEmpty { return "" }
        var input = bytes.map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: bytes.count * 4 + 16)
        let converted: Int? = input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                var inPtr: UnsafeMutablePointer<CChar>? = inBuf.baseAddress
                var inLeft = inBuf.count
                var outPtr: UnsafeMutablePointer<CChar>? = outBuf.baseAddress
                var outLeft = outBuf.count
                let result = iconv(cd, &inPtr, &inLeft, &outPtr, &outLeft)
                guard result != -1, inLeft == 0 else { return nil }
                return outBuf.count - outLeft
            }
        }
        guard let converted else { return nil }
        return String(decoding: output.prefix(converted).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
