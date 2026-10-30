#ifndef RUNNER_VOCAL_PROFILE_H_
#define RUNNER_VOCAL_PROFILE_H_

#include <string>
#include <vector>

// Where the singing is in a song (lyrics that follow it without hand timing).
// Decodes the file with Media Foundation and returns, every 100 ms, the
// loudness of the whole signal and of the voice band (~300-3400 Hz):
// [all0, voice0, all1, voice1, ...]. Empty on failure. Same output as
// VocalProfile.kt on Android. Call from a worker thread.
std::vector<double> AnalyzeVocalProfile(const std::wstring& path);

#endif  // RUNNER_VOCAL_PROFILE_H_
