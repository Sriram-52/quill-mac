import SwiftUI

/// Word-level diff between the original and corrected text. The model is only
/// trusted to return corrected prose; changed spans are computed here,
/// deterministically, never by the model.
enum WordDiff {
    enum Segment: Equatable {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    static func diff(from old: String, to new: String) -> [Segment] {
        let a = tokenize(old)
        let b = tokenize(new)
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var segments: [Segment] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                segments.append(.equal(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                segments.append(.delete(a[i])); i += 1
            } else {
                segments.append(.insert(b[j])); j += 1
            }
        }
        while i < n { segments.append(.delete(a[i])); i += 1 }
        while j < m { segments.append(.insert(b[j])); j += 1 }
        return coalesce(segments)
    }

    static func hasChanges(_ segments: [Segment]) -> Bool {
        segments.contains { if case .equal = $0 { return false } else { return true } }
    }

    /// Number of distinct changed spans (adjacent insert/delete runs count
    /// as one issue) — the badge number.
    static func changeCount(_ segments: [Segment]) -> Int {
        var count = 0
        var inChange = false
        for segment in segments {
            if case .equal(let text) = segment {
                // Whitespace between two edits doesn't split one issue in two.
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    inChange = false
                }
            } else if !inChange {
                count += 1
                inChange = true
            }
        }
        return count
    }

    /// Small on-device models "correct" typographic punctuation to ASCII
    /// (— to --, curly quotes to straight, … to ...). Those aren't real
    /// corrections: fold any delete/insert pair that only differs that way
    /// back into unchanged text, keeping the author's original characters.
    static func suppressingPunctuationNormalization(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var i = 0
        while i < segments.count {
            if i + 1 < segments.count {
                switch (segments[i], segments[i + 1]) {
                case (.delete(let old), .insert(let new)), (.insert(let new), .delete(let old)):
                    if normalizePunctuation(old) == normalizePunctuation(new) {
                        out.append(.equal(old))
                        i += 2
                        continue
                    }
                default:
                    break
                }
            }
            out.append(segments[i])
            i += 1
        }
        return coalesce(out)
    }

    /// Rebuild the corrected text from segments (equal + insert).
    static func result(from segments: [Segment]) -> String {
        segments.reduce(into: "") { acc, segment in
            switch segment {
            case .equal(let t), .insert(let t): acc += t
            case .delete: break
            }
        }
    }

    private static func normalizePunctuation(_ s: String) -> String {
        var t = s
        for (from, to) in [("\u{2014}", "-"), ("\u{2013}", "-"), ("--", "-"),
                           ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
                           ("\u{2026}", "..."), (" ", ""), ("\u{00A0}", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
    }

    /// The corrected text with changed spans highlighted, for the card.
    static func highlightedCorrected(_ segments: [Segment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            switch segment {
            case .equal(let t):
                out += AttributedString(t)
            case .insert(let t):
                var a = AttributedString(t)
                a.foregroundColor = Color(nsColor: .systemGreen)
                out += a
            case .delete:
                continue
            }
        }
        return out
    }

    /// Words (incl. apostrophes) stay whole; whitespace and punctuation are
    /// their own tokens so "word," vs "word." diffs at the punctuation mark.
    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" {
                word.append(ch)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(ch))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private static func coalesce(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments {
            switch (out.last, segment) {
            case (.equal(let a), .equal(let b)):
                out[out.count - 1] = .equal(a + b)
            case (.insert(let a), .insert(let b)):
                out[out.count - 1] = .insert(a + b)
            case (.delete(let a), .delete(let b)):
                out[out.count - 1] = .delete(a + b)
            default:
                out.append(segment)
            }
        }
        return out
    }
}
