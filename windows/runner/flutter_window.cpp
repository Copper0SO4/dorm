#include "flutter_window.h"

#include <cstdint>
#include <optional>
#include <variant>
#include <vector>
#include <mmsystem.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::vector<uint8_t> card_sound;

void RegisterCardAudio(flutter::FlutterEngine* engine) {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      engine->messenger(), "dorm/cards/audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "play" || call.arguments() == nullptr) {
      result->NotImplemented();
      return;
    }
    const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
    if (bytes == nullptr || bytes->size() < 44 || bytes->size() > 100000) {
      result->Error("invalid-audio", "Invalid sound sample");
      return;
    }
    PlaySoundW(nullptr, nullptr, 0);
    card_sound = *bytes;
    const auto* wave = reinterpret_cast<const wchar_t*>(card_sound.data());
    PlaySoundW(wave, nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    result->Success();
  });
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
  RegisterCardAudio(flutter_controller_->engine());
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
  PlaySoundW(nullptr, nullptr, 0);
  card_sound.clear();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
