#ifndef ReleaseDir
  #error Pass /DReleaseDir to the compiler.
#endif
#ifndef RuntimeDir
  #error Pass /DRuntimeDir to the compiler.
#endif
#ifndef DormVersion
  #error Pass /DDormVersion to the compiler.
#endif
#ifndef DormFileVersion
  #error Pass /DDormFileVersion to the compiler.
#endif

[Setup]
AppId={{ECB6AE66-F0B9-47A4-8D64-03B4E78C9B51}
AppName=Dorm
AppVersion={#DormVersion}
AppPublisher=Dorm
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Dorm
DefaultGroupName=Dorm
DisableProgramGroupPage=yes
UninstallDisplayName=Dorm
UninstallDisplayIcon={app}\Dorm.exe
SetupIconFile=..\runner\resources\app_icon.ico
OutputDir=.
OutputBaseFilename=Dorm-Windows-x64-Setup-v{#DormVersion}
VersionInfoVersion={#DormFileVersion}
VersionInfoDescription=Dorm Windows x64 Setup
UsePreviousAppDir=yes
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "zhcn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RuntimeDir}\msvcp140.dll"; DestDir: "{app}"
Source: "{#RuntimeDir}\vcruntime140.dll"; DestDir: "{app}"
Source: "{#RuntimeDir}\vcruntime140_1.dll"; DestDir: "{app}"

[Icons]
Name: "{autoprograms}\Dorm"; Filename: "{app}\Dorm.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Dorm"; Filename: "{app}\Dorm.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Dorm.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,Dorm}"; Flags: nowait postinstall skipifsilent
