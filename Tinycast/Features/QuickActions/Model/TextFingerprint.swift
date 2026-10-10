/// FNV-1a, because saved history is matched by these values and `Hasher` reseeds every launch.
enum TextFingerprint {
    static func of(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
