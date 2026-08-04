package com.example.new_flutter_project_fixed

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity (not FlutterActivity) so audio_service can
// receive hardware media-button events (car Bluetooth, steering wheel, headset).
class MainActivity : AudioServiceActivity()
