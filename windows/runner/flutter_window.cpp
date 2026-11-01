#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Media keys OAmp registers as system-wide hotkeys while something is
// loaded. Windows' own forwarding of these keys to the media overlay session
// proved unreliable (roughly one press in three arrived), whereas a hotkey
// is delivered to this window every time.
struct MediaKey {
  int id;
  UINT vk;
  const char* name;
};
constexpr MediaKey kMediaKeys[] = {
    {1, VK_MEDIA_PLAY_PAUSE, "playPause"},
    {2, VK_MEDIA_NEXT_TRACK, "next"},
    {3, VK_MEDIA_PREV_TRACK, "previous"},
    {4, VK_MEDIA_STOP, "stop"},
};

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

  media_keys_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "oamp/media_keys",
          &flutter::StandardMethodCodec::GetInstance());
  media_keys_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "register") {
          result->Success(flutter::EncodableValue(RegisterMediaKeys()));
        } else if (call.method_name() == "unregister") {
          UnregisterMediaKeys();
          result->Success();
        } else {
          result->NotImplemented();
        }
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

bool FlutterWindow::RegisterMediaKeys() {
  if (media_keys_registered_) return true;
  HWND hwnd = GetHandle();
  int registered = 0;
  for (const auto& key : kMediaKeys) {
    // Fails only if another app already holds the key; the rest still work
    // and that key keeps going through the media overlay.
    if (RegisterHotKey(hwnd, key.id, MOD_NOREPEAT, key.vk)) registered++;
  }
  media_keys_registered_ = true;
  return registered > 0;
}

void FlutterWindow::UnregisterMediaKeys() {
  if (!media_keys_registered_) return;
  HWND hwnd = GetHandle();
  for (const auto& key : kMediaKeys) {
    UnregisterHotKey(hwnd, key.id);
  }
  media_keys_registered_ = false;
}

void FlutterWindow::OnDestroy() {
  UnregisterMediaKeys();
  media_keys_channel_ = nullptr;
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
    case WM_HOTKEY:
      for (const auto& key : kMediaKeys) {
        if (static_cast<int>(wparam) == key.id && media_keys_channel_) {
          media_keys_channel_->InvokeMethod(
              "pressed", std::make_unique<flutter::EncodableValue>(
                             std::string(key.name)));
          return 0;
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
