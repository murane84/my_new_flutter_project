/// Answering a call while Aluta's fingerprint lock is on.
///
/// A phone lets you answer on the lock screen without unlocking. So when the
/// app is opened BY an incoming-call notification, the splash skips the lock
/// screen ([lockBypassedForCall] = true), the call is answered, and as soon as
/// the call is over [relockAfterCall] (wired by home) brings the lock back —
/// the rest of the app is never reachable without the fingerprint.
library;

bool lockBypassedForCall = false;

/// Set by the home screen: returns to the lock screen.
void Function()? relockAfterCall;
