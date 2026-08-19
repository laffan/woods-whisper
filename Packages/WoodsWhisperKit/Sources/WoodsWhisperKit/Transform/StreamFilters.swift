import Foundation

// The two pure filters a streamed transform runs through, on their way from the model to the text
// that gets saved. They live here — in the kit, rather than beside the MLX service that drives
// them — because they carry the one guarantee the whole feature rests on: a model's *reasoning*
// never reaches your words. Nothing in either type knows about MLX, so both can be tested.

/// Streaming guard that suppresses everything from the first occurrence of any stop sequence
/// onward, and holds back a trailing fragment that could be the *start* of one — so a chat model's
/// turn-end marker (LFM2.5's `<|im_end|>`, say) halts generation cleanly
/// instead of being echoed and repeated. Pure value type, unit-testable, no MLX dependency.
public struct StopSequenceFilter {
    public let stops: [String]
    public private(set) var isStopped = false
    private var pending = ""

    public init(stops: [String]) { self.stops = stops.filter { !$0.isEmpty } }

    /// Append a streamed chunk; returns the text that is now safe to emit.
    public mutating func consume(_ chunk: String) -> String {
        guard !isStopped else { return "" }
        guard !stops.isEmpty else { return chunk }      // nothing to filter
        pending += chunk
        if let cut = earliestStop(in: pending) {       // a full marker is present → emit up to it and stop
            let head = String(pending[..<cut])
            pending = ""
            isStopped = true
            return head
        }
        // Hold back the longest suffix that could be the beginning of a stop sequence.
        let hold = maxTrailingPartial(in: pending)
        let safeEnd = pending.index(pending.endIndex, offsetBy: -hold)
        let emit = String(pending[..<safeEnd])
        pending = String(pending[safeEnd...])
        return emit
    }

    /// Flush any held-back text once the stream ends without hitting a stop sequence.
    public mutating func flush() -> String {
        guard !isStopped else { return "" }
        defer { pending = "" }
        return pending
    }

    private func earliestStop(in text: String) -> String.Index? {
        var earliest: String.Index?
        for stop in stops {
            if let r = text.range(of: stop), earliest == nil || r.lowerBound < earliest! {
                earliest = r.lowerBound
            }
        }
        return earliest
    }

    /// Length of the longest suffix of `text` that is a (strict) prefix of some stop sequence.
    private func maxTrailingPartial(in text: String) -> Int {
        var maxLen = 0
        for stop in stops {
            var k = min(stop.count - 1, text.count)
            while k > maxLen {
                if text.hasSuffix(String(stop.prefix(k))) { maxLen = k; break }
                k -= 1
            }
        }
        return maxLen
    }
}

/// Incrementally separates a `<think>…</think>` reasoning block from the answer in a streamed
/// response. "Thinking" models emit their reasoning first, wrapped in those tags, then the answer;
/// we want the reasoning shown separately and kept out of the saved output. Tags may be split across
/// streamed chunks, so each `consume` holds back a trailing fragment that could be the start of a
/// tag (like `StopSequenceFilter`). When `enabled` is false everything is the answer.
///
/// Some models are handed the opening tag by their own chat template (LFM2.5-2.6B: the prompt ends
/// with `<think>`, since the model is expected to think rather than announce that it will), so
/// generation starts *inside* the block and only the closing tag ever arrives. `startsInside` says
/// so, and the splitter begins in the reasoning phase.
public struct ThinkSplitter {
    private static let open = "<think>"
    private static let close = "</think>"

    private enum Phase { case beforeThink, inThink, afterThink }
    private let enabled: Bool
    private var phase: Phase
    private var buffer = ""

    public init(enabled: Bool, startsInside: Bool = false) {
        self.enabled = enabled
        // Disabled ⇒ straight to "all answer"; started inside ⇒ straight into the reasoning.
        self.phase = enabled ? (startsInside ? .inThink : .beforeThink) : .afterThink
    }

    /// Append streamed text; return the deltas to add to the reasoning and the answer.
    public mutating func consume(_ text: String) -> (reasoning: String, answer: String) {
        buffer += text
        var reasoning = ""
        var answer = ""
        loop: while !buffer.isEmpty {
            switch phase {
            case .beforeThink:
                if let r = buffer.range(of: Self.open) {
                    answer += String(buffer[..<r.lowerBound])      // stray text before the tag (rare)
                    buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                    phase = .inThink
                } else {
                    let hold = trailingPartial(of: Self.open, in: buffer)
                    answer += String(buffer.dropLast(hold))
                    buffer = String(buffer.suffix(hold))
                    break loop
                }
            case .inThink:
                if let r = buffer.range(of: Self.close) {
                    reasoning += String(buffer[..<r.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                    phase = .afterThink
                } else {
                    let hold = trailingPartial(of: Self.close, in: buffer)
                    reasoning += String(buffer.dropLast(hold))
                    buffer = String(buffer.suffix(hold))
                    break loop
                }
            case .afterThink:
                answer += buffer
                buffer = ""
                break loop
            }
        }
        return (reasoning, answer)
    }

    /// Emit whatever is still buffered once the stream ends. An unterminated `<think>` is
    /// reasoning: the model was still thinking when it ran out of room, so there is no answer —
    /// which is a *better* outcome than calling half a thought the answer, since the caller then
    /// leaves the text it was rewriting alone (see `AppModel`'s transforms) instead of replacing it
    /// with one. Reasoning never becomes your words, in any case, which is the whole point of this
    /// type.
    public mutating func flush() -> (reasoning: String, answer: String) {
        defer { buffer = "" }
        switch phase {
        case .inThink:                  return (buffer, "")
        case .beforeThink, .afterThink: return ("", buffer)
        }
    }

    /// Length of the longest suffix of `text` that is a strict prefix of `needle`.
    private func trailingPartial(of needle: String, in text: String) -> Int {
        var k = min(needle.count - 1, text.count)
        while k > 0 {
            if text.hasSuffix(String(needle.prefix(k))) { return k }
            k -= 1
        }
        return 0
    }
}
