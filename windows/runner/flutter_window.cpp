#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "vocal_profile.h"

namespace {

// A finished song analysis, posted from the worker thread back to the
// window's thread (Flutter replies must be sent on the platform thread).
constexpr UINT kVocalDoneMessage = WM_APP + 0x51;

struct VocalJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::vector<double> data;
};

std::wstring WideFromUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      w.data(), n);
  return w;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  vocal_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "aluta/vocal",
          &flutter::StandardMethodCodec::GetInstance());
  HWND hwnd = GetHandle();
  vocal_channel_->SetMethodCallHandler(
      [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "vocalProfile") {
          result->NotImplemented();
          return;
        }
        std::string path;
        if (const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto it = args->find(flutter::EncodableValue("path"));
          if (it != args->end()) {
            if (const auto* s = std::get_if<std::string>(&it->second)) {
              path = *s;
            }
          }
        }
        if (path.empty()) {
          result->Success();
          return;
        }
        auto* job = new VocalJob{std::move(result), {}};
        std::thread([hwnd, job, path]() {
          job->data = AnalyzeVocalProfile(WideFromUtf8(path));
          if (!PostMessage(hwnd, kVocalDoneMessage, 0,
                           reinterpret_cast<LPARAM>(job))) {
            delete job;
          }
        }).detach();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kVocalDoneMessage) {
    auto* job = reinterpret_cast<VocalJob*>(lparam);
    if (job) {
      if (job->data.empty()) {
        job->result->Success();
      } else {
        job->result->Success(flutter::EncodableValue(job->data));
      }
      delete job;
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
