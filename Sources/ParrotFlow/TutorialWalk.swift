import AppKit
import SwiftUI

/// One screen of the tour.
///
/// The raw values are the names `--panels` and `--tutorial-sheet` take, so
/// there is one spelling of each screen rather than a switch per entry point.
/// `names` is the vocabulary screen: it cannot be called `vocabulary`, which is
/// the correction panel.
enum TourScreen: String, CaseIterable {
    case downloads
    case names
    case slack
    case hack
    /// Not part of what the setup window plays. The walk's own last screen
    /// already says Ready, and it owns Done, eSpeak NG and the retry a failed
    /// download needs. Kept for `--panels ready`. See `TourWalk.screens`.
    case ready

    /// How long this screen is up for.
    var length: TimeInterval {
        switch self {
        case .downloads: return TutorialDownloadsPane.length
        case .names: return Tutorial.total
        case .slack: return TutorialSlack.total
        case .hack: return TutorialHack.total
        case .ready: return TutorialReadyPane.length
        }
    }

    /// The screen, at one moment in its own pass.
    @ViewBuilder func pane(clock: TimeInterval, progress: Double?) -> some View {
        switch self {
        case .downloads:
            TutorialDownloadsPane(
                elapsed: clock, progress: progress ?? 0
            )
        case .names:
            TutorialPane(
                run: TutorialRun(clock), progress: progress
            )
        case .slack:
            TutorialSlackPane(
                run: TutorialSlackRun(clock), progress: progress
            )
        case .hack:
            TutorialHackPane(
                elapsed: clock, progress: progress
            )
        case .ready:
            // No bar: there is nothing left to wait for, which is the whole of
            // what this screen says.
            TutorialReadyPane()
        }
    }

    /// The height the window keeps for this screen, which is its tallest beat.
    ///
    /// Measured rather than declared: the screens are drawn from the pill's own
    /// metrics and a number written here would go stale the first time one of
    /// them changed. A window sized to anything less resizes itself in the
    /// middle of a pass, under somebody who is reading it.
    var height: CGFloat { TourScreen.heights[self] ?? 0 }

    /// The beats each screen is at its tallest on.
    private var tallest: [TimeInterval] {
        switch self {
        case .downloads, .ready:
            return [0]
        case .names:
            // The last dictation, which is spoken into a field that already
            // holds one sentence, the first offer, whose chips are the widest
            // surface, and the finished field, which holds both.
            return [
                Tutorial.fourthAt + Tutorial.leadIn + 0.5,
                Tutorial.firstLands + Tutorial.Beat.offering.rawValue,
                Tutorial.fourthLands + 0.8,
            ]
        case .slack:
            return [TutorialSlack.landsAt + TutorialSlack.Beat.posted.rawValue]
        case .hack:
            // The panel, up under the third card.
            return [TutorialHack.arrives(.scripts) + TutorialHack.step + 0.3]
        }
    }

    private static let heights: [TourScreen: CGFloat] = {
        var out: [TourScreen: CGFloat] = [:]
        for screen in TourScreen.allCases {
            out[screen] = screen.tallest.map { beat in
                NSHostingView(
                    rootView: screen.pane(clock: beat, progress: 0.5)
                ).fittingSize.height
            }.max() ?? 0
        }
        return out
    }()
}

/// The order the tour plays its screens in, and where one moment of the walk's
/// clock falls.
///
/// The walk is one clock and the screens are functions of it, so skipping is
/// moving the clock rather than a state of its own. That is what keeps a
/// dropped frame from leaving a screen a beat behind for the rest of its pass.
enum TourWalk {
    /// What the setup window plays while the models come down.
    static let screens: [TourScreen] = [.downloads, .names, .slack, .hack]

    static func total(of list: [TourScreen]) -> TimeInterval {
        list.reduce(0) { $0 + $1.length }
    }

    /// Which screen is on at `elapsed`, and that screen's own clock.
    ///
    /// The walk loops: it is up for as long as the download takes, and nobody
    /// knows how long that is.
    static func at(
        _ elapsed: TimeInterval, in list: [TourScreen] = screens
    ) -> (index: Int, clock: TimeInterval) {
        let loop = total(of: list)
        guard !list.isEmpty, loop > 0 else { return (0, 0) }
        var into = elapsed.truncatingRemainder(dividingBy: loop)
        if into < 0 { into += loop }
        for (index, screen) in list.enumerated() {
            if into < screen.length { return (index, into) }
            into -= screen.length
        }
        return (list.count - 1, 0)
    }

}

/// The tour at one moment: whichever screen its clock is inside.
///
/// A function of `elapsed` and nothing else, like the screens it draws. There
/// is nothing to press: the tour turns its own pages and the window decides
/// when it is over.
struct SetupTour: View {
    let elapsed: TimeInterval
    /// How far the model downloads have come, for the bar in the corner. See
    /// `TutorialScreen.progress`.
    var progress: Double?
    var screens: [TourScreen] = TourWalk.screens

    var body: some View {
        let (index, clock) = TourWalk.at(elapsed, in: screens)
        screens[index].pane(clock: clock, progress: progress)
        // Each screen keeps the height of its own tallest beat. Fixed inside
        // one screen, so no frame of a pass resizes the window; different
        // between them, so none of them ends in a band of nothing.
        .frame(height: screens[index].height, alignment: .top)
        // On the frame and not inside the screen: the dots belong at the bottom
        // of the window, and a screen at a beat shorter than its tallest one
        // would carry them up the page with it.
        .overlay(alignment: .bottom) { dots(index) }
        // The screens are drawn in whites over dark glass. A light window makes
        // them unreadable, and the window they play in is whatever the Mac is
        // set to.
        .environment(\.colorScheme, .dark)
    }

    /// One circle a screen, the one playing lit.
    ///
    /// The tour has nothing to press, so this is what says the screens are
    /// pages of one walk rather than four unrelated windows, and how many of
    /// them there are.
    @ViewBuilder private func dots(_ index: Int) -> some View {
        if screens.count > 1 {
            HStack(spacing: 7) {
                ForEach(Array(screens.enumerated()), id: \.offset) { at, _ in
                    Circle()
                        .fill(
                            at == index
                                ? Parrot.action.opacity(0.9)
                                : Color.white.opacity(0.18)
                        )
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 22)
        }
    }
}

/// The tour as the setup window plays it.
///
/// The clock is the window's, not this view's: the poll that ends the tour has
/// to be able to read it, and a clock kept in a view that is rebuilt sixty
/// times a second is not one anything else can ask.
struct SetupTourPane: View {
    /// The screen has changed, so the window is a different height now. Called
    /// from the cut rather than left to the poll: a window that catches up a
    /// second later shows one screen in the last one's frame.
    var onScreenChange: () -> Void = {}

    @EnvironmentObject private var model: PermissionsModel
    @EnvironmentObject private var downloads: ModelDownloads

    var body: some View {
        // `.periodic` and not `.animation`. Both hand the view a date, and the
        // tour is a function of that date either way. What depends on which is
        // whether the frames arrive: `.animation` is the display link, and the
        // display link stops when the window is not being drawn — behind
        // another window, on another space, with the app in the background —
        // which is a tour frozen at whatever frame it was on.
        TimelineView(.periodic(from: model.tourStartedAt ?? Date(), by: 1.0 / 60)) { context in
            let elapsed = model.tourElapsed(at: context.date)
            let index = TourWalk.at(elapsed).index
            SetupTour(
                elapsed: elapsed,
                // The downloader's own number, size-weighted across the six
                // models, and the same one the corner's figure is drawn from.
                progress: downloads.fraction,
            )
            .onChange(of: index) { _, _ in onScreenChange() }
        }
        .onAppear { model.startTour() }
    }
}
