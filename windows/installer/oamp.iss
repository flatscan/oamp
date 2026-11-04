; Inno Setup script for the OAmp Windows installer.
;
; Build the app first, then compile this script with Inno Setup 6.3 or later
; (https://jrsoftware.org/isdl.php):
;
;   flutter build windows --release
;   iscc windows\installer\oamp.iss
;
; The installer is written to build\installer\. The version comes from the
; built oamp.exe, which gets it from `version:` in pubspec.yaml.

#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define AppExe "oamp.exe"
#if !FileExists(SourceDir + "\" + AppExe)
  #error "oamp.exe not found. Run `flutter build windows --release` first."
#endif

; ProductVersion is the pubspec version, e.g. "1.0.0+1".
#define AppVersion GetStringFileInfo(SourceDir + "\" + AppExe, "ProductVersion")
#define AppVersionNumbers GetVersionNumbersString(SourceDir + "\" + AppExe)

; Must match the ID the app sets in windows/runner/main.cpp, so the Windows
; media overlay can find the Start menu shortcut and show OAmp's name and icon.
#define AppUserModelID "OAmp.MusicPlayer"

[Setup]
; AppId identifies OAmp to Windows across versions. Never change it, or
; upgrades will install side by side instead of replacing the old version.
AppId={{00A9F65A-5F77-417D-8070-82B1781078D8}
AppName=OAmp
AppVersion={#AppVersion}
AppVerName=OAmp {#AppVersion}
AppPublisher=OAmp contributors
AppPublisherURL=https://github.com/flatscan/oamp
AppSupportURL=https://github.com/flatscan/oamp/issues
VersionInfoVersion={#AppVersionNumbers}
VersionInfoProductName=OAmp
VersionInfoDescription=OAmp installer
; Installs for the current user without admin rights by default. The
; installer offers an "install for all users" choice, which needs admin.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DefaultDirName={autopf}\OAmp
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; Asks to close a running OAmp before replacing its files.
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=OAmp
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=oamp-{#StringChange(AppVersion, "+", "-")}-setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Clear the old app data folder on upgrade so files a newer build no longer
; ships don't linger. Settings, sign-in and caches live elsewhere and are kept.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\OAmp"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelID}"
Name: "{autodesktop}\OAmp"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,OAmp}"; Flags: nowait postinstall skipifsilent
