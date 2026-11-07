#include "taskbar_buttons.h"

#include <cstdint>
#include <vector>

namespace {

constexpr UINT kPreviousId = 1;
constexpr UINT kPlayPauseId = 2;
constexpr UINT kNextId = 3;

// Glyphs in Windows' own icon fonts, so the buttons match the system's.
// Both fonts use the same code points.
constexpr wchar_t kPreviousGlyph = 0xE892;
constexpr wchar_t kPlayGlyph = 0xE768;
constexpr wchar_t kPauseGlyph = 0xE769;
constexpr wchar_t kNextGlyph = 0xE893;

bool FontExists(HDC dc, const wchar_t* face) {
  LOGFONTW query = {};
  query.lfCharSet = DEFAULT_CHARSET;
  wcscpy_s(query.lfFaceName, face);
  bool found = false;
  EnumFontFamiliesExW(
      dc, &query,
      [](const LOGFONTW*, const TEXTMETRICW*, DWORD, LPARAM found) -> int {
        *reinterpret_cast<bool*>(found) = true;
        return 0;
      },
      reinterpret_cast<LPARAM>(&found), 0);
  return found;
}

void CopyTip(wchar_t (&tip)[260], const wchar_t* text) {
  wcscpy_s(tip, text);
}

}  // namespace

TaskbarButtons::TaskbarButtons() = default;

TaskbarButtons::~TaskbarButtons() { Detach(); }

void TaskbarButtons::Attach(HWND hwnd, PressHandler handler, void* context) {
  hwnd_ = hwnd;
  handler_ = handler;
  context_ = context;
  button_created_message_ = RegisterWindowMessageW(L"TaskbarButtonCreated");
}

void TaskbarButtons::Detach() {
  if (taskbar_) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  added_ = false;
  DestroyIcons();
  hwnd_ = nullptr;
  handler_ = nullptr;
}

void TaskbarButtons::Show(bool playing, bool can_previous, bool can_next) {
  visible_ = true;
  playing_ = playing;
  can_previous_ = can_previous;
  can_next_ = can_next;
  Apply();
}

void TaskbarButtons::Hide() {
  visible_ = false;
  Apply();
}

bool TaskbarButtons::HandleMessage(UINT message, WPARAM wparam, LPARAM) {
  if (hwnd_ == nullptr) return false;
  if (button_created_message_ != 0 && message == button_created_message_) {
    // A new taskbar (first start, or Explorer restarted) has none of our
    // buttons yet.
    if (taskbar_) {
      taskbar_->Release();
      taskbar_ = nullptr;
    }
    added_ = false;
    AddButtons();
    return false;
  }
  if (message == WM_DPICHANGED) {
    // Redrawn at the new size on the next update; do it now so the buttons
    // are sharp straight away.
    if (added_) Apply();
    return false;
  }
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED && handler_) {
    switch (LOWORD(wparam)) {
      case kPreviousId:
        handler_(context_, "previous");
        return true;
      case kPlayPauseId:
        handler_(context_, "playPause");
        return true;
      case kNextId:
        handler_(context_, "next");
        return true;
    }
  }
  return false;
}

void TaskbarButtons::AddButtons() {
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&taskbar_)))) {
    taskbar_ = nullptr;
    return;
  }
  if (FAILED(taskbar_->HrInit())) {
    taskbar_->Release();
    taskbar_ = nullptr;
    return;
  }
  RecreateIcons();
  THUMBBUTTON buttons[3] = {};
  const UINT ids[3] = {kPreviousId, kPlayPauseId, kNextId};
  for (int i = 0; i < 3; i++) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    // Hidden until Apply() says otherwise.
    buttons[i].dwFlags = THBF_HIDDEN;
  }
  buttons[0].hIcon = previous_icon_;
  CopyTip(buttons[0].szTip, L"Previous");
  buttons[1].hIcon = play_icon_;
  CopyTip(buttons[1].szTip, L"Play");
  buttons[2].hIcon = next_icon_;
  CopyTip(buttons[2].szTip, L"Next");
  added_ = SUCCEEDED(taskbar_->ThumbBarAddButtons(hwnd_, 3, buttons));
  if (added_) Apply();
}

void TaskbarButtons::Apply() {
  if (!added_ || taskbar_ == nullptr) return;
  // Icons drawn for another DPI are kept until the taskbar has the new ones,
  // since it may still be showing them.
  HICON old_icons[4] = {};
  const bool redraw = GetDpiForWindow(hwnd_) != icon_dpi_;
  if (redraw) {
    old_icons[0] = previous_icon_;
    old_icons[1] = play_icon_;
    old_icons[2] = pause_icon_;
    old_icons[3] = next_icon_;
    previous_icon_ = play_icon_ = pause_icon_ = next_icon_ = nullptr;
    RecreateIcons();
  }
  THUMBBUTTON buttons[3] = {};
  const UINT ids[3] = {kPreviousId, kPlayPauseId, kNextId};
  const bool enabled[3] = {can_previous_, true, can_next_};
  for (int i = 0; i < 3; i++) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    if (!visible_) {
      buttons[i].dwFlags = THBF_HIDDEN;
    } else {
      buttons[i].dwFlags = enabled[i] ? THBF_ENABLED : THBF_DISABLED;
    }
  }
  buttons[0].hIcon = previous_icon_;
  CopyTip(buttons[0].szTip, L"Previous");
  buttons[1].hIcon = playing_ ? pause_icon_ : play_icon_;
  CopyTip(buttons[1].szTip, playing_ ? L"Pause" : L"Play");
  buttons[2].hIcon = next_icon_;
  CopyTip(buttons[2].szTip, L"Next");
  taskbar_->ThumbBarUpdateButtons(hwnd_, 3, buttons);
  for (HICON icon : old_icons) {
    if (icon) DestroyIcon(icon);
  }
}

void TaskbarButtons::RecreateIcons() {
  DestroyIcons();
  icon_dpi_ = GetDpiForWindow(hwnd_);
  if (icon_dpi_ == 0) icon_dpi_ = 96;
  const int size = GetSystemMetricsForDpi(SM_CXSMICON, icon_dpi_);
  previous_icon_ = MakeIcon(kPreviousGlyph, size);
  play_icon_ = MakeIcon(kPlayGlyph, size);
  pause_icon_ = MakeIcon(kPauseGlyph, size);
  next_icon_ = MakeIcon(kNextGlyph, size);
}

void TaskbarButtons::DestroyIcons() {
  for (HICON* icon :
       {&previous_icon_, &play_icon_, &pause_icon_, &next_icon_}) {
    if (*icon) DestroyIcon(*icon);
    *icon = nullptr;
  }
  icon_dpi_ = 0;
}

// Draws |glyph| white on a transparent square |size| pixels wide.
//
// GDI text leaves the alpha channel alone, so the glyph is drawn white on
// black with grey-scale smoothing, and each pixel's brightness becomes its
// opacity.
HICON TaskbarButtons::MakeIcon(wchar_t glyph, int size) {
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  const wchar_t* face =
      FontExists(dc, L"Segoe Fluent Icons") ? L"Segoe Fluent Icons"
                                            : L"Segoe MDL2 Assets";

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;  // Top-down rows.
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP color =
      CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color == nullptr || bits == nullptr) {
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return nullptr;
  }
  HGDIOBJ old_bitmap = SelectObject(dc, color);
  RECT rect = {0, 0, size, size};
  FillRect(dc, &rect, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));

  // The glyphs are designed on a square em, so an em of |size| fills the
  // icon the way the system's own icons do.
  HFONT font = CreateFontW(-size, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                           DEFAULT_PITCH, face);
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  wchar_t text[2] = {glyph, 0};
  DrawTextW(dc, text, 1, &rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  GdiFlush();

  auto* pixels = static_cast<uint32_t*>(bits);
  for (int i = 0; i < size * size; i++) {
    const uint32_t p = pixels[i];
    const uint32_t r = (p >> 16) & 0xFF;
    const uint32_t g = (p >> 8) & 0xFF;
    const uint32_t b = p & 0xFF;
    const uint32_t a = (r > g ? (r > b ? r : b) : (g > b ? g : b));
    // White at opacity |a| (icons use straight, not premultiplied, alpha).
    pixels[i] = (a << 24) | 0x00FFFFFF;
  }

  SelectObject(dc, old_font);
  DeleteObject(font);
  SelectObject(dc, old_bitmap);

  // An all-zero mask: the colour bitmap's alpha decides what shows.
  std::vector<uint8_t> mask_bits(((size + 15) / 16) * 2 * size, 0);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, mask_bits.data());
  ICONINFO icon_info = {};
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color;
  icon_info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&icon_info);

  DeleteObject(mask);
  DeleteObject(color);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return icon;
}
