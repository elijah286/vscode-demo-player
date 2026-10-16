#ifndef AppVersion
  #error AppVersion must be supplied by Build-Windows.ps1
#endif
#ifndef PayloadDir
  #error PayloadDir must be supplied by Build-Windows.ps1
#endif
#ifndef ArtifactDir
  #error ArtifactDir must be supplied by Build-Windows.ps1
#endif

[Setup]
AppId={{58C5EB37-BA1A-48B3-BE25-EC530DC65462}
AppName=VS Code Demo Player
AppVersion={#AppVersion}
AppPublisher=VS Code Demo Player contributors
AppPublisherURL=https://github.com/elijah286/vscode-demo-player
AppSupportURL=https://github.com/elijah286/vscode-demo-player/issues
AppUpdatesURL=https://github.com/elijah286/vscode-demo-player/releases
DefaultDirName={localappdata}\Programs\VSCodeDemoPlayer
DefaultGroupName=VS Code Demo Player
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#ArtifactDir}
OutputBaseFilename=VSCodeDemoPlayer-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\VSCodeDemoPlayer.exe
AppMutex=Local\VSCodeDemoPlayer.Installed
CloseApplications=no
RestartApplications=no
SetupLogging=yes
DisableProgramGroupPage=yes
InfoBeforeFile=install-notes.txt

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\VS Code Demo Player"; Filename: "{app}\VSCodeDemoPlayer.exe"; WorkingDir: "{app}"
Name: "{group}\Uninstall VS Code Demo Player"; Filename: "{uninstallexe}"
Name: "{autodesktop}\VS Code Demo Player"; Filename: "{app}\VSCodeDemoPlayer.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\VSCodeDemoPlayer.exe"; Description: "Launch VS Code Demo Player"; Flags: nowait postinstall skipifsilent
