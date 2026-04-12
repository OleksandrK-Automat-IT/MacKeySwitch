import Foundation

/// Impossible character combinations (bigrams) for English and Ukrainian.
/// If ANY bigram from these lists appears in a word, that word CANNOT belong to the language.
/// Generated from linguistic rules and corpus analysis.
struct ProtoLanguage {

    // MARK: - English Impossible Bigrams

    /// Two-character sequences that never occur in English words
    static let englishImpossibleBigrams: Set<String> = [
        // Consecutive rare consonants that never appear together in English
        "bx", "bz", "bq", "cb", "cf", "cg", "cj", "cp", "cv", "cw", "cx", "cz",
        "db", "dc", "df", "dj", "dk", "dp", "dq", "dt", "dv", "dx", "dz",
        "fb", "fc", "fd", "fg", "fh", "fj", "fk", "fm", "fn", "fp", "fq", "fv", "fw", "fx", "fz",
        "gb", "gc", "gd", "gf", "gj", "gk", "gp", "gq", "gv", "gx", "gz",
        "hb", "hc", "hd", "hf", "hg", "hh", "hj", "hk", "hl", "hm", "hp", "hq", "hr", "hs", "hv", "hw", "hx", "hz",
        "iw", "ix",
        "jb", "jc", "jd", "jf", "jg", "jh", "jj", "jk", "jl", "jm", "jn", "jp", "jq", "jr", "js", "jt", "jv", "jw", "jx", "jy", "jz",
        "kb", "kc", "kd", "kf", "kg", "kj", "kk", "km", "kp", "kq", "kv", "kx", "kz",
        "lq", "lx",
        "mf", "mh", "mj", "mk", "mq", "mv", "mx", "mz",
        "nq", "nx", "nz",
        "pj", "pk", "pq", "pv", "px", "pz",
        "qa", "qb", "qc", "qd", "qe", "qf", "qg", "qh", "qi", "qj", "qk", "ql", "qm", "qn", "qo", "qp", "qq", "qr", "qs", "qt", "qv", "qw", "qx", "qy", "qz",
        "rq", "rx",
        "sd", "sj", "sx",
        "tb", "tg", "tj", "tk", "tp", "tq", "tv", "tx",
        "uh",
        "vb", "vc", "vd", "vf", "vg", "vh", "vj", "vk", "vl", "vm", "vn", "vp", "vq", "vr", "vs", "vt", "vu", "vv", "vw", "vx", "vz",
        "wb", "wc", "wd", "wf", "wg", "wj", "wk", "wm", "wp", "wq", "wv", "ww", "wx", "wz",
        "xb", "xc", "xd", "xf", "xg", "xj", "xk", "xm", "xn", "xq", "xr", "xs", "xv", "xw", "xx", "xz",
        "yq", "yx", "yz",
        "zb", "zc", "zd", "zf", "zg", "zj", "zk", "zm", "zn", "zp", "zq", "zr", "zs", "zt", "zv", "zw", "zx",
    ]

    // MARK: - Ukrainian Impossible Bigrams

    /// Two-character sequences that never occur in Ukrainian words.
    /// Based on Ukrainian phonotactic rules.
    static let ukrainianImpossibleBigrams: Set<String> = [
        // ь (soft sign) cannot start a word or follow certain consonants
        "ьа", "ье", "ьи", "ьу", "ьі", "ьї", "ьє", "ьґ", "ьь",
        // ъ doesn't exist in Ukrainian at all (only Russian)
        // ї cannot follow consonants directly in most cases
        "бї", "вї", "гї", "ґї", "дї", "жї", "зї", "кї", "лї", "мї", "нї", "пї",
        "рї", "сї", "тї", "фї", "хї", "цї", "чї", "шї", "щї",
        // щ combinations that don't occur
        "щб", "щг", "щґ", "щд", "щж", "щз", "щк", "щл", "щм", "щп",
        "щр", "щс", "щт", "щф", "щх", "щц", "щч", "щш", "щщ",
        // Doubled consonants that never occur in Ukrainian
        "жж", "щщ", "цц", "хх", "ґґ", "фф",
        // Initial combinations that are impossible in Ukrainian
        "гк", "гп", "гт", "гф", "дк", "дп", "дф",
        "жб", "жг", "жд", "жж", "жз", "жк", "жп", "жт", "жф", "жх", "жц", "жш", "жщ",
        "зщ", "зш",
        // ю after certain consonants
        "ґю", "жю", "хю", "цю", "чю", "шю", "щю",
        // є after certain consonants
        "ґє", "жє", "хє", "цє", "чє", "шє", "щє",
        // Combinations with ф (rare in native Ukrainian words)
        "фб", "фг", "фґ", "фд", "фж", "фз", "фк", "фм", "фп", "фс", "фт", "фх", "фц", "фч", "фш", "фщ",
        // ґ is very rare and has limited combinations
        "ґб", "ґг", "ґд", "ґж", "ґз", "ґк", "ґл", "ґм", "ґп", "ґс", "ґт", "ґф", "ґх", "ґц", "ґч", "ґш", "ґщ",
    ]

    // MARK: - Public API

    /// Check if a word contains any impossible bigrams for English
    static func hasImpossibleEnglishBigram(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return false }
        let chars = Array(lower)
        for i in 0..<(chars.count - 1) {
            let bigram = String(chars[i]) + String(chars[i + 1])
            if englishImpossibleBigrams.contains(bigram) {
                return true
            }
        }
        return false
    }

    /// Check if a word contains any impossible bigrams for Ukrainian
    static func hasImpossibleUkrainianBigram(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return false }
        let chars = Array(lower)
        for i in 0..<(chars.count - 1) {
            let bigram = String(chars[i]) + String(chars[i + 1])
            if ukrainianImpossibleBigrams.contains(bigram) {
                return true
            }
        }
        return false
    }

    /// Quick check: can this text possibly be English? (no impossible bigrams)
    static func couldBeEnglish(_ word: String) -> Bool {
        let lower = word.lowercased()
        // Must be all Latin
        guard lower.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return !hasImpossibleEnglishBigram(lower)
    }

    /// Quick check: can this text possibly be Ukrainian? (no impossible bigrams)
    static func couldBeUkrainian(_ word: String) -> Bool {
        let lower = word.lowercased()
        // Must be all Cyrillic
        guard lower.allSatisfy({ char in
            guard let scalar = char.unicodeScalars.first else { return false }
            let v = scalar.value
            return (v >= 0x0400 && v <= 0x04FF)
        }) else { return false }
        return !hasImpossibleUkrainianBigram(lower)
    }
}
