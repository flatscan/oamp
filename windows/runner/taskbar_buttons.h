#ifndef RUNNER_TASKBAR_BUTTONS_H_
#define RUNNER_TASKBAR_BUTTONS_H_

#include <windows.h>
// After windows.h, which it relies on.
#include <shobjidl.h>

#include <string>

// Previous, play/pause and next buttons on the window's taskbar thumbnail
// (the preview shown when hovering the taskbar icon).
//
// Windows only accepts the buttons once the taskbar has created the app's
// taskbar button, which it announces with the registered
// "TaskbarButtonCreated" message. That message comes again if Explorer
// restarts, and the buttons are added again then.
//
// Buttons can't be removed once added, so with nothing loaded they are
// hidden rather than removed.
class TaskbarButtons {
 public:
  // What a button press asks for: "previous", "playPause" or "next".
  using PressHandler = void (*)(void* context, const char* name);

  TaskbarButtons();
  ~TaskbarButtons();

  void Attach(HWND hwnd, PressHandler handler, void* context);
  void Detach();

  // Shows the buttons for the player's state.
  void Show(bool playing, bool can_previous, bool can_next);
  // Nothing is loaded: hides the buttons.
  void Hide();

  // Handles taskbar messages. Returns true when |message| was a button press
  // and needs no further handling.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void AddButtons();
  void Apply();
  void RecreateIcons();
  void DestroyIcons();
  HICON MakeIcon(wchar_t glyph, int size);

  HWND hwnd_ = nullptr;
  PressHandler handler_ = nullptr;
  void* context_ = nullptr;
  UINT button_created_message_ = 0;
  ITaskbarList3* taskbar_ = nullptr;
  bool added_ = false;

  bool visible_ = false;
  bool playing_ = false;
  bool can_previous_ = true;
  bool can_next_ = true;

  UINT icon_dpi_ = 0;
  HICON previous_icon_ = nullptr;
  HICON play_icon_ = nullptr;
  HICON pause_icon_ = nullptr;
  HICON next_icon_ = nullptr;
};

#endif  // RUNNER_TASKBAR_BUTTONS_H_
