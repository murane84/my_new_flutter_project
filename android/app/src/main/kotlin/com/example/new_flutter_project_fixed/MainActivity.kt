package com.example.new_flutter_project_fixed

import com.ryanheise.audioservice.AudioServiceFragmentActivity

// Extends AudioServiceFragmentActivity (which itself extends
// FlutterFragmentActivity) so BOTH plugins are satisfied at once:
//   • audio_service keeps receiving hardware media-button events
//     (car Bluetooth, steering wheel, headset), and
//   • local_auth can host the androidx BiometricPrompt, which requires the
//     host Activity to be a FragmentActivity.
class MainActivity : AudioServiceFragmentActivity()
