#include "vocal_profile.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <cmath>
#include <cstdint>

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Biquad {
  double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  double Run(double x) {
    const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  }
  // RBJ cookbook, Q = 0.707.
  static Biquad HighPass(double fc, double sr) {
    const double w = 2 * kPi * fc / sr, a = std::sin(w) / (2 * 0.707);
    const double c = std::cos(w), a0 = 1 + a;
    return {(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0,
            (1 - a) / a0};
  }
  static Biquad LowPass(double fc, double sr) {
    const double w = 2 * kPi * fc / sr, a = std::sin(w) / (2 * 0.707);
    const double c = std::cos(w), a0 = 1 + a;
    return {(1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0,
            (1 - a) / a0};
  }
};

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

}  // namespace

std::vector<double> AnalyzeVocalProfile(const std::wstring& path) {
  std::vector<double> out;
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(MFStartup(MF_VERSION))) {
    if (SUCCEEDED(co)) CoUninitialize();
    return out;
  }
  IMFSourceReader* reader = nullptr;
  IMFMediaType* want = nullptr;
  IMFMediaType* got = nullptr;
  do {
    if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader)))
      break;
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                               TRUE);
    if (FAILED(MFCreateMediaType(&want))) break;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    want->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (FAILED(reader->SetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, want)))
      break;
    if (FAILED(reader->GetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &got)))
      break;
    UINT32 sr = 44100, ch = 2;
    got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
    got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
    if (sr == 0) sr = 44100;
    if (ch == 0) ch = 1;

    Biquad hp = Biquad::HighPass(300.0, sr), lp = Biquad::LowPass(3400.0, sr);
    const UINT32 frame = sr / 10;
    double sum_all = 0, sum_voice = 0;
    UINT32 n = 0;
    const size_t max_values = 12 * 60 * 10 * 2;  // 12 minutes is plenty
    while (out.size() < max_values) {
      DWORD flags = 0;
      IMFSample* sample = nullptr;
      if (FAILED(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                    0, nullptr, &flags, nullptr, &sample)))
        break;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        SafeRelease(&sample);
        break;
      }
      if (!sample) continue;
      IMFMediaBuffer* buf = nullptr;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
        BYTE* data = nullptr;
        DWORD len = 0;
        if (SUCCEEDED(buf->Lock(&data, nullptr, &len))) {
          const int16_t* s = reinterpret_cast<const int16_t*>(data);
          const size_t count = len / sizeof(int16_t) / ch;
          for (size_t i = 0; i < count; ++i) {
            double m = 0;
            for (UINT32 c = 0; c < ch; ++c) m += s[i * ch + c];
            const double x = m / ch / 32768.0;
            const double v = lp.Run(hp.Run(x));
            sum_all += x * x;
            sum_voice += v * v;
            if (++n >= frame) {
              out.push_back(std::sqrt(sum_all / n));
              out.push_back(std::sqrt(sum_voice / n));
              sum_all = sum_voice = 0;
              n = 0;
            }
          }
          buf->Unlock();
        }
        SafeRelease(&buf);
      }
      SafeRelease(&sample);
    }
  } while (false);
  SafeRelease(&got);
  SafeRelease(&want);
  SafeRelease(&reader);
  MFShutdown();
  if (SUCCEEDED(co)) CoUninitialize();
  return out;
}
