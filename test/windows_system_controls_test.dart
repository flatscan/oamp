import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/system_controls.dart';
import 'package:oamp/platform/windows_system_controls.dart';
import 'package:smtc_windows/smtc_windows.dart';

void main() {
  test('the play/pause key toggles, whichever button Windows reports', () {
    // Windows picks Play or Pause from the last status OAmp sent, which can
    // lag the player; either must still flip the real state.
    expect(
      WindowsSystemControls.commandFor(PressedButton.play),
      isA<TogglePlayCommand>(),
    );
    expect(
      WindowsSystemControls.commandFor(PressedButton.pause),
      isA<TogglePlayCommand>(),
    );
    expect(
      WindowsSystemControls.commandFor(PressedButton.next),
      isA<NextCommand>(),
    );
    expect(
      WindowsSystemControls.commandFor(PressedButton.previous),
      isA<PreviousCommand>(),
    );
    expect(WindowsSystemControls.commandFor(PressedButton.record), isNull);
  });
}
