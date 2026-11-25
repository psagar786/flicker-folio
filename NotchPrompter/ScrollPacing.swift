import Foundation

/// Maps the number of words read to scroll position through the wrapped script.
struct ScrollPacing {
    struct Stop {
        let words: Double
        let offset: Double
    }

    let stops: [Stop]

    var endOffset: Double { stops.last?.offset ?? 0 }

    func progress(at offset: Double) -> Double {
        interpolate(offset, from: \.offset, to: \.words)
    }

    func offset(at progress: Double) -> Double {
        interpolate(progress, from: \.words, to: \.offset)
    }

    func advance(from offset: Double, by words: Double) -> Double {
        self.offset(at: progress(at: offset) + words)
    }

    static func sentenceStarts(in text: String, words: [NSRange], readableHeight: CGFloat,
                               lineOffset: (Int) -> CGFloat) -> [Int] {
        let source = text as NSString
        var boundaries: [Int] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            boundaries.append(range.location)
        }
        var result = [0]
        var boundary = 0
        var top = lineOffset(0)
        for (index, word) in words.enumerated() where index > 0 {
            while boundary < boundaries.count, boundaries[boundary] <= words[index - 1].location {
                boundary += 1
            }
            let y = lineOffset(index)
            if (boundary < boundaries.count && boundaries[boundary] <= word.location) ||
                y - top >= readableHeight {
                result.append(index)
                top = y
            }
        }
        return result
    }

    static func sentenceDuration(words: Int, speed: Double) -> Double {
        max(1.1, Double(words) / max(1, speed) * 60)
    }

    private func interpolate(_ value: Double, from input: KeyPath<Stop, Double>,
                             to output: KeyPath<Stop, Double>) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if value <= first[keyPath: input] { return first[keyPath: output] }
        if value >= last[keyPath: input] { return last[keyPath: output] }

        var lower = 0
        var upper = stops.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if stops[middle][keyPath: input] <= value { lower = middle }
            else { upper = middle }
        }
        let start = stops[lower]
        let end = stops[upper]
        let fraction = (value - start[keyPath: input]) / (end[keyPath: input] - start[keyPath: input])
        return start[keyPath: output] + fraction * (end[keyPath: output] - start[keyPath: output])
    }
}


/// Smooths live WPM changes without changing the script's current word position.
struct TimedPacing {
    private var speed = 0.0

    mutating func reset(wpm: Double) { speed = wpm }

    mutating func advance(wpm: Double, dt: Double) -> Double {
        speed += (wpm - speed) * (1 - exp(-dt * 8))
        return speed * dt / 60
    }
}

/// Local volume gate with noise-floor adaptation, hysteresis and a short pause hold.
struct ConversationalPacing {
    private var floor = 0.0
    private var openingTime = 0.0
    private var hold = 0.0
    private(set) var activity = 0.0
    private(set) var isSpeaking = false

    mutating func advance(level: Double, sensitivity: Double, dt: Double) -> Double {
        let base = 0.46 - sensitivity * 0.0042
        // Learn steady low-level noise while closed. Strong peaks never train the floor.
        if !isSpeaking && level < max(0.23, floor + 0.065) {
            let rate = level < floor ? 3.0 : 1.5
            floor += (level - floor) * (1 - exp(-rate * dt))
        }
        let open = max(base, min(0.75, floor + 0.11))
        let close = max(base * 0.70, floor + 0.065)
        if isSpeaking {
            hold = level >= close ? 0.24 : max(0, hold - dt)
            isSpeaking = hold > 0
        } else {
            openingTime = level >= open ? openingTime + dt : 0
            if openingTime >= 0.055 {
                isSpeaking = true
                hold = 0.24
                openingTime = 0
            }
        }
        let target = isSpeaking ? 1.0 : 0.0
        activity += (target - activity) * (1 - exp(-(isSpeaking ? 11 : 17) * dt))
        if activity < 0.015 { activity = 0 }
        return activity
    }
}

/// Limit speed after a sudden recognition jump and settle on the target when close.
enum SpeechFollowMotion {
    static func offset(from current: Double, to target: Double, dt: Double,
                       reduceMotion: Bool) -> Double {
        let delta = target - current
        if reduceMotion || abs(delta) <= 0.6 { return target }
        let step = min(abs(delta) * (1 - exp(-dt * 9)), 430 * dt)
        return current + (delta < 0 ? -step : step)
    }
}
