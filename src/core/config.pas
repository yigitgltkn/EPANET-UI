{====================================================================
 Project:      EPANET-UI
 Version:      1.0.3
 Module:       config
 Description:  reads, saves and edits program preferences
 License:      see LICENSE
 Last Updated: 06/19/2026
=====================================================================}

unit config;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, Graphics, SysUtils, Controls, Forms, IniFiles, ExtCtrls, LCLIntf,
  ImgList;

const
  WinFontSize = 10;
  NixFontSize = 9;

  GrayTheme: Integer       = $00F3F3F3;
  BlueTheme: Integer       = $00FDEEE3;
  CreamTheme: Integer      = $00F0FBFF;
  GrayMenuColor: Integer   = $007E7969;
  GrayHeaderColor: Integer = $007E7969;
  BlueMenuColor: Integer   = $00BE6E10;
  BlueHeaderColor: Integer = $00BE6E10;

  // Colors of the dark theme
  DarkTheme: Integer       = $002B231E;
  DarkMenuColor: Integer   = $001E1814;
  DarkHeaderColor: Integer = $0040332B;
  DarkAlternateColor       = $00352C26;
  DarkInfoColor            = $004A3A2D;
  DarkSelectColor          = $006B4A2F;

  // Color themes
  thGray = 0;
  thBlue = 1;
  thDark = 2;
  ThemeNames: array[thGray..thDark] of string = ('Gray', 'Blue', 'Dark');

  MonoFonts: array[1..3] of string =
    ('Noto Mono', 'Liberation Mono', 'DejaVu Sans Mono');

var
  MapHiliter:        Boolean;
  MapHinting:        Boolean;
  ShowNotifiers:     Boolean;
  ConfirmDeletions:  Boolean;
  ShowWelcomePage:   Boolean;
  OpenLastFile:      Boolean;
  BackupFile:        Boolean;
  Theme:             Integer;  // color theme in use
  NextTheme:         Integer;  // color theme to use from the next start
  DarkStyle:         Boolean;  // Windows controls are drawn dark
  ThemeColor:        TColor;
  FormColor:         TColor;
  MenuColor:         TColor;
  HeaderColor:       TColor;
  AlternateColor:    TColor;
  InfoColor:         TColor;   // background of notes and highlighted cells
  GoodColor:         TColor;   // status bar when results are current
  WarnColor:         TColor;   // status bar when results need updating
  SelectColor:       TColor;   // background of selected list items
  DecimalPlaces:     Integer;
  FontSize:          Integer;
  MonoFont:          string;
  IconFamily:        string;

  procedure InitAppearance;
  procedure InitFont;
  procedure ReadPreferences(FileName: string);
  procedure SavePreferences(FileName: string);
  procedure EditPreferences(var ClearFileList: Boolean);
  procedure SetThemeColors;
  procedure SetHeaderColor(aHeader: TPanel);
  procedure LightenImageList(ImageList: TCustomImageList);
  procedure DarkenControls(AControl: TControl);
  function  IsDefaultBrowserChromium: Boolean;

implementation

uses
  {$IFDEF LCLWIN32}
  LCLType, uDarkStyleParams, uMetaDarkStyle, uDarkStyleSchemes,
  {$ENDIF}
  Math, TypInfo, ComCtrls, IntfGraphics, FPImage, Dialogs, TAGraph,
  TACustomSeries,
  main, project, reportframe, configeditor, resourcestrings;

function GetSysMonoFont: string;
var
  I: Integer;
begin
  Result := 'Monospace';
  for I := Low(MonoFonts) to High(MonoFonts) do
  begin
    if Screen.Fonts.IndexOf(MonoFonts[I]) >= 0 then
    begin
      Result := MonoFonts[I];
      exit;
    end;
  end;
end;

function GetWinMonoFont: string;
//
//  The most modern fixed-width font that is installed.
//
const
  Fonts: array[1..2] of string = ('Cascadia Mono', 'Consolas');
var
  I: Integer;
begin
  Result := 'Courier New';
  for I := Low(Fonts) to High(Fonts) do
    if Screen.Fonts.IndexOf(Fonts[I]) >= 0 then
    begin
      Result := Fonts[I];
      exit;
    end;
end;

function ThemeIndex(const Name: string): Integer;
begin
  for Result := thGray to thDark do
    if SameText(Name, ThemeNames[Result]) then exit;
  Result := thDark;
end;

function ReadTheme(Ini: TIniFile): Integer;
//
//  The program starts with the dark theme unless another one was chosen.
//
begin
  Result := ThemeIndex(Ini.ReadString('Preferences', 'Theme',
    ThemeNames[thDark]));
end;

{$IFDEF LCLWIN32}
function DarkColors: TDSColors;
//
//  The colors that Windows controls are given in the dark theme. They
//  match the program's own dark colors.
//
const
  Back:   TColor = $002B231E;
  Field:  TColor = $00312923;
  Text:   TColor = $00F0EAE6;
  Accent: TColor = $00F7812F;
  Hover:  TColor = $00463A2D;
begin
  Result := DefaultDark;
  with Result do
  begin
    SysColor[COLOR_SCROLLBAR]          := Back;
    SysColor[COLOR_BACKGROUND]         := Back;
    SysColor[COLOR_INACTIVECAPTION]    := Back;
    SysColor[COLOR_MENU]               := Back;
    SysColor[COLOR_MENUBAR]            := Back;
    SysColor[COLOR_FORM]               := Back;
    SysColor[COLOR_BTNFACE]            := Back;
    SysColor[COLOR_APPWORKSPACE]       := Back;
    SysColor[COLOR_ACTIVEBORDER]       := Back;
    SysColor[COLOR_INACTIVEBORDER]     := Back;
    SysColor[COLOR_WINDOW]             := Field;
    SysColor[COLOR_WINDOWFRAME]        := $00151109;
    SysColor[COLOR_3DDKSHADOW]         := $00151109;
    SysColor[COLOR_BTNSHADOW]          := $001E1814;
    SysColor[COLOR_3DLIGHT]            := $003D332C;
    SysColor[COLOR_BTNHIGHLIGHT]       := $004E423A;
    SysColor[COLOR_WINDOWTEXT]         := Text;
    SysColor[COLOR_BTNTEXT]            := Text;
    SysColor[COLOR_MENUTEXT]           := Text;
    SysColor[COLOR_CAPTIONTEXT]        := Text;
    SysColor[COLOR_INACTIVECAPTIONTEXT]:= Text;
    SysColor[COLOR_HIGHLIGHTTEXT]      := $00FFFFFF;
    SysColor[COLOR_GRAYTEXT]           := $00A0948C;
    SysColor[COLOR_HIGHLIGHT]          := Accent;
    SysColor[COLOR_ACTIVECAPTION]      := Accent;
    SysColor[COLOR_HOTLIGHT]           := Hover;
    SysColor[COLOR_MENUHILIGHT]        := Hover;
    SysColor[COLOR_INFOBK]             := DarkInfoColor;
    SysColor[COLOR_INFOTEXT]           := Text;
  end;
end;
{$ENDIF}

procedure InitAppearance;
//
//  Called by the program file before the application is initialized,
//  since Windows controls can only be made dark before any of them exist.
//
var
  Ini: TIniFile;
  FileName: string;
  Chosen: Integer;
begin
  Chosen := thDark;
  FileName := GetAppConfigDir(false) + ApplicationName + '.ini';
  if FileExists(FileName) then
  begin
    Ini := TIniFile.Create(FileName);
    try
      Chosen := ReadTheme(Ini);
    finally
      Ini.Free;
    end;
  end;

  DarkStyle := false;
  {$IFDEF LCLWIN32}
  if Chosen = thDark then
  begin
    PreferredAppMode := pamForceDark;
    ApplyMetaDarkStyle(DarkColors);

    // Older versions of Windows cannot draw their controls dark
    DarkStyle := IsDarkModeEnabled;
  end;
  {$ENDIF}
end;

procedure InitFont;
//
//  Called by the program file before any form is created: forms then use
//  Windows 11's own interface font where it is installed.
//
begin
  {$IFDEF WINDOWS}
  if Screen.Fonts.IndexOf('Segoe UI Variable Text') >= 0 then
    DefFontData.Name := 'Segoe UI Variable Text';
  {$ENDIF}
end;

procedure ReadPreferences(FileName: string);
var
  Ini: TIniFile;
begin
  MapHiliter := true;
  MapHinting := true;
  ShowNotifiers := true;
  ConfirmDeletions := true;
  ShowWelcomePage := true;
  IconFamily := 'Material';
  OpenLastFile := true;
  BackupFile := false;
  Theme := thDark;
  DecimalPlaces := 2;

{$ifdef UNIX}
  MonoFont := GetSysMonoFont;
  FontSize := NixFontSize;
{$else}
  MonoFont := GetWinMonoFont;
  FontSize := WinFontSize;
{$endif}

  if FileExists(FileName) then
  begin
    Ini := TIniFile.Create(FileName);
    try
      MapHiliter := Ini.ReadBool('Preferences', 'Map Hiliting', true);
      MapHinting := Ini.ReadBool('Preferences', 'Map Hinting', true);
      ConfirmDeletions := Ini.ReadBool('Preferences', 'Confirm Deletions', true);
      ShowWelcomePage := Ini.ReadBool('Preferences', 'Show Welcome Page', true);
      OpenLastFile := Ini.ReadBool('Preferences', 'Open Last File', true);
      BackupFile := Ini.ReadBool('Preferences', 'Backup File', false);
      DecimalPlaces := Ini.ReadInteger('Preferences', 'Decimal Places', 2);
      Theme := ReadTheme(Ini);
    finally
      Ini.Free;
    end;
  end;

  // The dark theme needs dark Windows controls (see InitAppearance)
  NextTheme := Theme;
  if (Theme = thDark) and not DarkStyle then Theme := thGray;
  SetThemeColors;
end;

procedure SavePreferences(FileName: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FileName);
  try
    Ini.WriteBool('Preferences', 'Map Hiliting', MapHiliter);
    Ini.WriteBool('Preferences', 'Map Hinting', MapHinting);
    Ini.WriteBool('Preferences', 'Confirm Deletions', ConfirmDeletions);
    Ini.WriteBool('Preferences', 'Show Welcome Page', ShowWelcomePage);
    Ini.WriteBool('Preferences', 'Open Last File', OpenLastFile);
    Ini.WriteBool('Preferences', 'Backup File', BackupFile);
    Ini.WriteInteger('Preferences', 'Decimal Places', DecimalPlaces);
    Ini.WriteString('Preferences', 'Theme', ThemeNames[NextTheme]);
  finally
    Ini.Free;
  end;
end;

procedure EditPreferences(var ClearFileList: Boolean);
//
//  Called by MainForm.FileConfigure which is called when
//  'Preferences' is selected from the FileMenuForm.
//
var
  NewTheme: Integer;
begin
  with TConfigForm.Create(MainForm) do
  try
    SetPreferences;
    ShowModal;
    if ModalResult = mrOK then
    begin
      GetPreferences(ClearFileList, NewTheme);
      if NewTheme = NextTheme then exit;
      NextTheme := NewTheme;

      // Windows controls can only change between dark and light when the
      // program starts again
      if (NewTheme = thDark) or (Theme = thDark) then
        MessageDlg(rsColorTheme, rsThemeAfterRestart, mtInformation, [mbOK], 0)
      else
      begin
        Theme := NewTheme;
        SetThemeColors;
        MainForm.SetColorTheme;
      end;
    end;
  finally
    Free;
  end;
end;

procedure SetThemeColors;
begin
  FormColor := clWindow;
  AlternateColor := $00F6F6F3;
  InfoColor := $00E1FFFF;
  SelectColor := $00FFE8CC;
  GoodColor := $001DE6B5;
  WarnColor := $000EC9FF;
  case Theme of
    thBlue:
      begin
        ThemeColor := BlueTheme;
        MenuColor := BlueMenuColor;
        HeaderColor := BlueHeaderColor;
      end;
    thDark:
      begin
        ThemeColor := DarkTheme;
        MenuColor := DarkMenuColor;
        HeaderColor := DarkHeaderColor;
        AlternateColor := DarkAlternateColor;
        InfoColor := DarkInfoColor;
        SelectColor := DarkSelectColor;
        GoodColor := $004F7D2E;
        WarnColor := $00126AA8;
      end;
    else
      begin
        ThemeColor := GrayTheme;
        MenuColor := GrayMenuColor;
        HeaderColor := GrayHeaderColor;
      end;
  end;
end;

procedure SetHeaderColor(aHeader: TPanel);
begin
  aHeader.Color := HeaderColor;
  aHeader.BorderStyle := bsNone;
  aHeader.Font.Color := clWhite;
end;

procedure LightenImageList(ImageList: TCustomImageList);
//
//  Make the dark gray icons of an image list light so they show up on a
//  dark background. Colored parts of an icon are left alone; gray parts
//  have their brightness reversed.
//
var
  I, R, X, Y: Integer;
  Res: array of TCustomImageListResolution;
  Bmps: array of array of TBitmap;
  Images: array of TCustomBitmap;
  Img: TLazIntfImage;
  C: TFPColor;
  Lo, Hi, V: Word;
  Tmp: TCustomImageListResolution;
begin
  if ImageList.Count = 0 then exit;

  // Resolutions from the smallest to the biggest
  SetLength(Res, ImageList.ResolutionCount);
  for R := 0 to High(Res) do
    Res[R] := ImageList.ResolutionByIndex[R];
  for R := 1 to High(Res) do
    for I := R downto 1 do
      if Res[I].Width < Res[I-1].Width then
      begin
        Tmp := Res[I];
        Res[I] := Res[I-1];
        Res[I-1] := Tmp;
      end;

  SetLength(Bmps, ImageList.Count, Length(Res));
  try
    for I := 0 to ImageList.Count - 1 do
      for R := 0 to High(Res) do
      begin
        Bmps[I, R] := TBitmap.Create;
        Res[R].GetBitmap(I, Bmps[I, R]);
        Img := Bmps[I, R].CreateIntfImage;
        try
          for Y := 0 to Img.Height - 1 do
            for X := 0 to Img.Width - 1 do
            begin
              C := Img.Colors[X, Y];
              if C.Alpha = 0 then continue;
              Lo := Min(C.Red, Min(C.Green, C.Blue));
              Hi := Max(C.Red, Max(C.Green, C.Blue));
              if Hi - Lo > $3000 then continue;   // a colored pixel
              V := $FFFF - (C.Red + C.Green + C.Blue) div 3;
              V := $3800 + Round(V * 0.78);
              C.Red := V;
              C.Green := V;
              C.Blue := V;
              Img.Colors[X, Y] := C;
            end;
          Bmps[I, R].LoadFromIntfImage(Img);
        finally
          Img.Free;
        end;
      end;

    ImageList.BeginUpdate;
    try
      ImageList.Clear;
      SetLength(Images, Length(Res));
      for I := 0 to High(Bmps) do
      begin
        for R := 0 to High(Res) do
          Images[R] := Bmps[I, R];
        ImageList.AddMultipleResolutions(Images);
      end;
    finally
      ImageList.EndUpdate;
    end;
  finally
    for I := 0 to High(Bmps) do
      for R := 0 to High(Bmps[I]) do
        Bmps[I, R].Free;
  end;
end;

procedure DarkenChart(Chart: TChart);
//
//  Dark backgrounds and light text for a chart; its series keep their colors.
//
const
  Text = $00F0EAE6;
  Lines = $00706259;
  GridLines = $00443A33;
var
  I: Integer;
begin
  Chart.Color := ThemeColor;
  Chart.BackColor := $00312923;
  Chart.Frame.Color := Lines;
  Chart.Title.Font.Color := Text;
  Chart.Foot.Font.Color := Text;
  Chart.Legend.BackgroundBrush.Color := $00312923;
  Chart.Legend.Font.Color := Text;
  Chart.Legend.Frame.Color := Lines;
  for I := 0 to Chart.SeriesCount - 1 do
    if Chart.Series[I] is TChartSeries then
      with TChartSeries(Chart.Series[I]).Marks do
      begin
        LabelFont.Color := Text;
        LabelBrush.Color := $00312923;
        LinkPen.Color := Lines;
        Frame.Color := Lines;
      end;
  for I := 0 to Chart.AxisList.Count - 1 do
    with Chart.AxisList[I] do
    begin
      Marks.LabelFont.Color := Text;
      Title.LabelFont.Color := Text;
      AxisPen.Color := Lines;
      Grid.Color := GridLines;
    end;
end;

procedure DarkenControls(AControl: TControl);
//
//  Replace the light colors that a control and the controls on it were
//  designed with by dark theme ones. Only colors known to be used in this
//  program's forms are replaced, so that colors that carry a meaning, such
//  as those of legends, are left alone. The map, its legend, the 3D view
//  and charts draw themselves with their own colors.
//
const
  Skipped: array[0..2] of string =
    ('TMapFrame', 'TMapLegendFrame', 'TView3DFrame');
  LinkColor = $00FFB66B;
var
  I: Integer;
begin
  for I := 0 to High(Skipped) do
    if AControl.ClassName = Skipped[I] then exit;
  if AControl is TChart then
  begin
    DarkenChart(TChart(AControl));
    exit;
  end;

  case AControl.Color of
    clWhite:
      AControl.Color := clWindow;
    $00E0FFFF, $00E1FFFF:
      AControl.Color := InfoColor;
    $00FCF8F4, $00F0FBFF, $00F8F8F8, $00F3F3F3, $00FDEEE3, $00F6F6F3,
    $00F2E4D7:
      AControl.Color := ThemeColor;
  end;
  case AControl.Font.Color of
    clBlack:
      AControl.Font.Color := clWindowText;
    clNavy, clBlue:
      AControl.Font.Color := LinkColor;
    clMaroon:
      AControl.Font.Color := $008080FF;
    clGray, $006D6D6D:
      AControl.Font.Color := clGrayText;
  end;

  // Rows of tables that were left white
  if IsPublishedProp(AControl, 'AlternateColor') then
    case TColor(GetOrdProp(AControl, 'AlternateColor')) of
      clNone, clDefault, clWhite, $00F6F6F3:
        SetOrdProp(AControl, 'AlternateColor', AlternateColor);
    end;

  // Windows draws tabs dark, but not tabs that look like buttons
  if AControl is TPageControl then
    with TPageControl(AControl) do
      if Style <> tsTabs then Style := tsTabs;

  if AControl is TWinControl then
    with TWinControl(AControl) do
      for I := 0 to ControlCount - 1 do
        DarkenControls(Controls[I]);
end;

function IsDefaultBrowserChromium: Boolean;
//
//  Determine if Windows default web browser is Chromium-based (Edge or Chrome)
//
var
  Path:   string;
  Params: string;
begin
  Result := false;
  FindDefaultBrowser(Path, Params);
  if (Pos('Edge', Path) > 0)
  or (Pos('MicrosoftEdge', Path) > 0)
  or (Pos('MSEdge', Path) > 0)
  or (Pos('Chrome', Path) > 0) then
    Result := True;
end;

end.
