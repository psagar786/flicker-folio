import Foundation

let pacing = ScrollPacing(stops: [
    .init(words: 0, offset: 0),
    .init(words: 5, offset: 20),
    .init(words: 15, offset: 64),
    .init(words: 20, offset: 92),
])

func expect(_ actual: Double, _ expected: Double) {
    precondition(abs(actual - expected) < 0.001, "Expected \(expected), got \(actual)")
}

expect(pacing.advance(from: 0, by: 5), 20)
expect(pacing.advance(from: 20, by: 10), 64)
expect(pacing.advance(from: 42, by: 5), 64)
expect(pacing.advance(from: 64, by: 50), 92)
expect(pacing.advance(from: 0, by: 140 / 60.0 * (20 / 140.0 * 60)), 92)
expect(ScrollPacing(stops: []).advance(from: 100, by: 12), 0)
let prose = "Hi Sagar. This is one sentence."
let words = [0, 3, 10, 15, 18, 22].map { NSRange(location: $0, length: 1) }
precondition(ScrollPacing.sentenceStarts(in: prose, words: words, readableHeight: 100, lineOffset: { _ in 0 }) == [0, 2])
precondition(ScrollPacing.sentenceStarts(in: prose, words: words, readableHeight: 50, lineOffset: { $0 < 4 ? 0 : 60 }) == [0, 2, 4])
expect(ScrollPacing.sentenceDuration(words: 7, speed: 140), 3)
expect(ScrollPacing.sentenceDuration(words: 1, speed: 140), 1.1)
// Live WPM changes continue from the current offset with no jump or pixel-rounding stall.
var liveOffset = 0.0
for _ in 0..<120 {
    liveOffset = pacing.advance(from: liveOffset, by: 120 / 60.0 / 60.0)
}
expect(liveOffset, pacing.advance(from: 0, by: 4))
let beforeSpeedChange = liveOffset
for _ in 0..<120 {
    liveOffset = pacing.advance(from: liveOffset, by: 180 / 60.0 / 60.0)
}
expect(liveOffset, pacing.advance(from: beforeSpeedChange, by: 6))
precondition(liveOffset > beforeSpeedChange)
let reflowed = ScrollPacing(stops: [.init(words: 0, offset: 0), .init(words: 10, offset: 80),
                                    .init(words: 20, offset: 124)])
let progressBeforeResize = pacing.progress(at: 24)
let restoredOffset = reflowed.offset(at: progressBeforeResize)
expect(reflowed.progress(at: restoredOffset), progressBeforeResize)
precondition(restoredOffset != 24)
print("Pacing checks passed")

var timed = TimedPacing()
timed.reset(wpm: 150)
let frame = 1.0 / 60
var wordsAdvanced = 0.0
for _ in 0..<60 { wordsAdvanced += timed.advance(wpm: 150, dt: frame) }
expect(wordsAdvanced, 2.5)
let firstFasterFrame = timed.advance(wpm: 210, dt: frame)
precondition(firstFasterFrame > 150 * frame / 60 && firstFasterFrame < 210 * frame / 60)
for _ in 0..<90 { _ = timed.advance(wpm: 210, dt: frame) }
expect(timed.advance(wpm: 210, dt: frame), 210 * frame / 60)

var conversation = ConversationalPacing()
expect(conversation.advance(level: 0.8, sensitivity: 50, dt: frame), 0)
for _ in 0..<60 {
    expect(conversation.advance(level: 0.12, sensitivity: 50, dt: frame), 0)
}
for _ in 0..<12 { _ = conversation.advance(level: 0.6, sensitivity: 50, dt: frame) }
precondition(conversation.isSpeaking && conversation.activity > 0.7)
for _ in 0..<8 { _ = conversation.advance(level: 0, sensitivity: 50, dt: frame) }
precondition(conversation.isSpeaking)
for _ in 0..<40 { _ = conversation.advance(level: 0, sensitivity: 50, dt: frame) }
precondition(!conversation.isSpeaking)
expect(conversation.activity, 0)

var speechOffset = 0.0
for _ in 0..<180 {
    let next = SpeechFollowMotion.offset(from: speechOffset, to: 220,
                                         dt: frame, reduceMotion: false)
    precondition(next >= speechOffset && next - speechOffset <= 430 * frame + 0.001)
    speechOffset = next
}
expect(speechOffset, 220)
expect(SpeechFollowMotion.offset(from: 0, to: 220, dt: frame, reduceMotion: true), 220)
print("Timed, conversational, and speech motion checks passed")
