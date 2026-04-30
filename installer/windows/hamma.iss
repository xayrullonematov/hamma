; Hamma — Windows Installer Script
; Requires Inno Setup 6.x  (https://jrsoftware.org/isinfo.php)
;
; Run from the repo root:
;   iscc installer\windows\hamma.iss [/DAppVersion=1.2.3]

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName      "Hamma"
#define AppPublisher "Hamma"
#define AppURL       "https://github.com/your-org/hamma"
#define AppExeName   "hamma.exe"
#define BuildDir     "..\..\build\windows\x64\runner\Release"
#define IconFile     "..\..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{8F3A1C2E-9B47-4D6F-B8E1-2C5D7A09F3E6}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..
OutputBaseFilename=Hamma-Setup-Windows-x64
SetupIconFile={#IconFile}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
