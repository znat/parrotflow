#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and hands back the Objective-C exception it raised, or nil.
///
/// Swift has no `catch` for an `NSException`. One thrown inside a Swift frame
/// unwinds straight through it and out of whatever run loop callback the frame
/// was called from, so `do`/`catch` around the call never runs and nothing is
/// logged. AppKit catches it at the top of the loop and the app carries on
/// looking healthy, having silently dropped the work.
///
/// AVFoundation raises them for programmer errors, and one of those errors is
/// reachable from a microphone that changes: `installTapOnBus:` raises when the
/// format it is handed no longer matches the hardware format of the node. See
/// #123.
///
/// Catching one is not a way to keep going as if nothing happened — whatever
/// raised it is in whatever state it was in. It is a way to find out, so the
/// caller can throw the object away and say so.
NSException *_Nullable PFRunCatchingObjCExceptions(void (NS_NOESCAPE ^block)(void))
    NS_SWIFT_NAME(runCatchingObjCExceptions(_:));

NS_ASSUME_NONNULL_END
