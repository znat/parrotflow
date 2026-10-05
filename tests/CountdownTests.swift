import Foundation

@main
enum CountdownTests {
    static func main() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        var countdown = Countdown(duration: 30, start: start)
        precondition(countdown.fraction(at: at(0)) == 1, "full at the start")
        precondition(countdown.fraction(at: at(15)) == 0.5, "half after 15 s")
        precondition(countdown.deadline == at(30), "runs out 30 s after the start")

        countdown.pause(at: at(12))
        precondition(countdown.state == .paused(remaining: 18), "pause keeps what was left")
        precondition(countdown.fraction(at: at(100)) == 0.6, "nothing drains while paused")
        precondition(countdown.deadline == nil, "no deadline while paused")
        precondition(countdown.isPaused, "paused reads as paused")

        countdown.pause(at: at(40))
        precondition(countdown.state == .paused(remaining: 18), "a second pause changes nothing")

        countdown.resume(at: at(50))
        precondition(countdown.state == .running(remaining: 18, since: at(50)), "resume from what was left")
        precondition(!countdown.isPaused, "running reads as not paused")
        precondition(countdown.deadline == at(68), "deadline moves by the time spent paused")
        precondition(countdown.fraction(at: at(59)) == 0.3, "drains again after resume")

        countdown.resume(at: at(60))
        precondition(countdown.state == .running(remaining: 18, since: at(50)), "a second resume changes nothing")

        precondition(countdown.fraction(at: at(68)) == 0, "empty at the deadline")
        precondition(countdown.fraction(at: at(80)) == 0, "never below empty")

        countdown.pause(at: at(70))
        precondition(countdown.state == .expired, "a pause past the deadline has run out")
        precondition(countdown.deadline == nil, "no deadline once run out")
        countdown.resume(at: at(71))
        precondition(countdown.state == .expired, "nothing resumes what has run out")
        precondition(countdown.fraction(at: at(71)) == 0, "run out is empty")

        print("Countdown: all cases pass")
    }
}
