{====================================================================
 Project:      EPANET-UI
 Module:       qgislink
 Description:  sends the network and its results to QGIS
 License:      see LICENSE
=====================================================================}

unit qgislink;

{
 QGIS is reached through the QGIS MCP plugin's server, which listens on
 port 9876 of this computer and runs the Python code sent to it. The
 network is written with the export_geojson command and shown in QGIS by
 bridge/qgis_load_results.py. Values edited there come back through the
 command channel (bridge/qgis_update_epanet.py and apply_edits).
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls;

const
  QgisPort = 9876;

function  AddQgisIcon(ImageList: TImageList): Integer;
function  SendToQgis(out Msg: string): Boolean;
procedure ComeToFront;

implementation

uses
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  Forms, Graphics, fpjson, jsonparser, ssockets, main, project, cmdhandlers;

const
  ConnectTimeout = 3000;      // ms
  ReplyTimeout = 60000;       // ms
  {$IFDEF WINDOWS}
  ASFW_ANY = DWORD(-1);
  {$ENDIF}

{$IFDEF WINDOWS}
function AllowSetForegroundWindow(dwProcessId: DWORD): BOOL; stdcall;
  external 'user32.dll';
{$ENDIF}

const
  // 48 x 48 PNG
  IconPng: array[0..804] of Byte = (
    $89, $50, $4E, $47, $0D, $0A, $1A, $0A, $00, $00, $00, $0D, $49, $48, $44, $52,
    $00, $00, $00, $30, $00, $00, $00, $30, $08, $06, $00, $00, $00, $57, $02, $F9,
    $87, $00, $00, $00, $01, $73, $52, $47, $42, $00, $AE, $CE, $1C, $E9, $00, $00,
    $00, $04, $67, $41, $4D, $41, $00, $00, $B1, $8F, $0B, $FC, $61, $05, $00, $00,
    $00, $09, $70, $48, $59, $73, $00, $00, $0E, $C3, $00, $00, $0E, $C3, $01, $C7,
    $6F, $A8, $64, $00, $00, $02, $BA, $49, $44, $41, $54, $68, $43, $ED, $56, $21,
    $73, $DB, $30, $14, $2E, $2C, $2C, $0C, $1C, $1C, $2C, $DB, $22, $01, $17, $EE,
    $EC, $A7, $73, $D9, $1A, $19, $A4, $B0, $30, $70, $30, $6C, $B0, $70, $D0, $17,
    $3B, $77, $85, $81, $85, $81, $83, $F9, $09, $85, $85, $85, $85, $DD, $7D, $39,
    $39, $E7, $BC, $C9, $8E, $E5, $C8, $8E, $B7, $CB, $77, $F7, $9D, $EF, $64, $3D,
    $E9, $BD, $27, $E9, $7D, $EF, $E2, $E2, $8C, $33, $CE, $38, $A3, $0E, $49, $2E,
    $BF, $F2, $B1, $7F, $02, $93, $6C, $7C, $9B, $64, $72, $93, $E4, $F2, $23, $C9,
    $E5, $8B, $CE, $C4, $3D, $9F, $33, $48, $24, $B9, $BC, $D1, $99, $58, $1B, $C7,
    $F7, $99, $C9, $0D, $02, $E3, $36, $83, $80, $5E, $8A, $6B, $9D, $8B, $E7, $BF,
    $9C, $B6, $50, $67, $E2, $37, $02, $E5, $6B, $9C, $04, $DF, $D3, $2F, $9F, $92,
    $5C, $AE, $B8, $93, $4D, $88, $93, $42, $E0, $7C, $CD, $5E, $60, $1C, $4F, $B9,
    $53, $2D, $B9, $9A, $A4, $E3, $CF, $7C, $8F, $4E, $30, $4D, $83, $91, $5E, $8A,
    $47, $9D, $8B, $77, $8B, $23, $C7, $32, $45, $62, $F8, $9E, $5E, $30, $4D, $83,
    $AB, $24, $97, $F3, $8E, $1C, $DF, $23, $12, $84, $44, $71, $1F, $5A, $61, $9A,
    $06, $97, $C9, $42, $FE, $D0, $B9, $78, $E3, $1B, $75, $49, $24, $4A, $2F, $C5,
    $4F, $24, $8E, $FB, $D4, $18, $C9, $42, $CE, $74, $2E, $5E, $F9, $E2, $7D, $D2,
    $24, $6E, $8E, $44, $72, $FF, $2A, $01, $D1, $81, $F8, $F0, $C5, $4E, $C9, $6D,
    $22, $17, $72, $76, $30, $10, $CF, $D5, $C5, $37, $9B, $57, $AB, $63, $EA, $BB,
    $6F, $1E, $A5, $17, $2E, $0A, $EB, $9B, $5E, $15, $BB, $B6, $C7, $F1, $CD, $2E,
    $7B, $26, $D6, $65, $FA, $66, $7F, $5D, $EB, $24, $1B, $DF, $F9, $AA, $54, $A8,
    $30, $7A, $21, $1E, $F8, $1E, $BD, $00, $19, $6B, $AB, $15, $DB, $1A, $DF, $A4,
    $34, $BA, $20, $08, $82, $CB, $28, $8A, $6E, $E2, $38, $6E, $DC, $93, $18, $B5,
    $6E, $2C, $7A, $25, $71, $6A, $AC, $B2, $61, $18, $8E, $E0, $17, $BE, $FC, $DF,
    $0E, $71, $1C, $5F, $29, $A5, $36, $4A, $A9, $0F, $C3, $5F, $B5, $06, $0C, $A5,
    $7E, $C9, $DA, $76, $98, $F6, $C0, $A9, $CF, $31, $3E, $CD, $89, $E8, $0D, $3E,
    $11, $D1, $0B, $11, $D9, $B5, $00, $11, $96, $9C, $2F, $F8, $4E, $44, $8F, $58,
    $88, $CF, $AF, $02, $02, $B1, $74, $AC, $A9, $8B, $E3, $B8, $09, $4A, $A9, $59,
    $E1, $38, $E3, $8C, $CF, $DF, $02, $D7, $A6, $C2, $00, $91, $63, $7C, $EE, $18,
    $C8, $08, $8D, $A0, $6B, $8B, $4C, $44, $0F, $4A, $A9, $57, $EE, $43, $41, $24,
    $9A, $DB, $EC, $80, $9F, $38, $26, $6E, $54, $22, $16, $9E, $21, $43, $DC, $F6,
    $58, $44, $51, $74, $77, $68, $6F, $CC, $E1, $76, $56, $28, $A5, $EE, $EB, $B2,
    $60, $FE, $79, $A9, $D9, $44, $74, $CB, $DE, $DE, $1E, $DB, $9C, $FE, $16, $C5,
    $3D, $AC, $0B, $C4, $3C, $AA, $56, $AA, $69, $DE, $DC, $9A, $AF, $59, $A2, $F3,
    $FB, $B3, $82, $57, $82, $0A, $22, $83, $DF, $B8, $AD, $0D, $61, $18, $5E, $13,
    $D1, $B3, $65, $8D, $32, $9D, $2A, $E0, $0E, $75, $3A, $80, $40, $90, $11, $64,
    $C6, $B2, $61, $C1, $75, $D5, $23, $C3, $9A, $4A, $A9, $95, $C5, $A6, $CC, $27,
    $DB, $DE, $5E, $75, $00, $63, $F8, $67, $D9, $BC, $CC, $15, $32, $5D, $CC, $27,
    $A2, $D4, $32, $C7, $3A, $BF, $0C, $7E, $FA, $5E, $75, $C0, $64, $F4, $C9, $62,
    $53, $26, $EE, $B8, $F3, $89, $F5, $AA, $03, $C8, $5C, $83, $AB, $C1, $59, $F9,
    $66, $4E, $A6, $03, $0D, $AA, $4A, $6D, $D5, $1A, $8C, $0E, $20, $B3, $96, $BA,
    $5E, $39, $7F, $B0, $3A, $80, $71, $3C, $5E, $5C, $89, $96, $27, $56, $F9, $FE,
    $9C, $C0, $2B, $41, $05, $2B, $EF, $34, $47, $A7, $3A, $50, $87, $53, $EA, $80,
    $57, $F4, $A9, $03, $9D, $A2, $4B, $1D, $E8, $15, $BE, $75, $E0, $64, $68, $50,
    $55, $6A, $AB, $D6, $60, $E0, $AA, $03, $83, $C5, $21, $1D, $38, $E3, $7F, $C0,
    $1F, $61, $14, $F8, $B1, $C1, $A0, $89, $5C, $00, $00, $00, $00, $49, $45, $4E,
    $44, $AE, $42, $60, $82);

function AddQgisIcon(ImageList: TImageList): Integer;
//
//  Adds the QGIS button's icon (a stack of map layers) to an image list.
//
var
  Stream: TMemoryStream;
  Png: TPortableNetworkGraphic;
begin
  Result := -1;
  Stream := TMemoryStream.Create;
  Png := TPortableNetworkGraphic.Create;
  try
    Stream.WriteBuffer(IconPng[0], Length(IconPng));
    Stream.Position := 0;
    Png.LoadFromStream(Stream);
    Result := ImageList.Add(Png, nil);
  finally
    Png.Free;
    Stream.Free;
  end;
end;

function PyStr(const S: string): string;
//
//  A Python raw string literal (Windows paths hold no double quotes).
//
begin
  Result := 'r"' + S + '"';
end;

function LoaderScript: string;
//
//  The QGIS loader script, in the bridge folder of the source tree
//  (bin/<platform>/ is two levels below it).
//
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim + 'bridge' + PathDelim + 'qgis_load_results.py');
end;

function AskQgis(const Code: string; out Reply: TJSONObject; out Msg: string): Boolean;
//
//  Sends Python code to the QGIS MCP plugin and waits for its reply.
//
var
  Request: TJSONObject;
  Text, Buffer: RawByteString;
  Sock: TInetSocket;
  Chunk: array[0..8191] of Byte;
  N, OldLen: Integer;
  Data: TJSONData;
begin
  Result := false;
  Reply := nil;
  Request := TJSONObject.Create(['type', 'execute_code',
    'params', TJSONObject.Create(['code', Code])]);
  try
    Text := Request.AsJSON;
  finally
    Request.Free;
  end;

  try
    Sock := TInetSocket.Create('127.0.0.1', QgisPort, ConnectTimeout);
  except
    Msg := Format('QGIS does not answer on port %d.' + LineEnding +
      'Start QGIS and the server of its QGIS MCP plugin.', [QgisPort]);
    exit;
  end;
  try
    Sock.IOTimeout := ReplyTimeout;
    Sock.WriteBuffer(Text[1], Length(Text));
    Buffer := '';
    repeat
      N := Sock.Read(Chunk[0], SizeOf(Chunk));
      if N <= 0 then break;
      OldLen := Length(Buffer);
      SetLength(Buffer, OldLen + N);
      Move(Chunk[0], Buffer[OldLen + 1], N);
      try
        Data := GetJSON(Buffer);
      except
        Data := nil;          // the reply is not complete yet
      end;
    until Data <> nil;
  finally
    Sock.Free;
  end;

  if (Data = nil) or (Data.JSONType <> jtObject) then
  begin
    Data.Free;
    Msg := 'QGIS did not reply.';
    exit;
  end;
  Reply := TJSONObject(Data);
  Result := true;
end;

function SendToQgis(out Msg: string): Boolean;
//
//  Exports the network with its current results and shows it in QGIS,
//  then brings the QGIS window to the front.
//
var
  Params, Result1, Info: TJSONObject;
  Reply: TJSONObject;
  Loader, NodesFile, LinksFile, Breaks, Code, Err: string;
  US: Boolean;
begin
  Result := false;
  Msg := '';
  if project.GetItemCount(ctNodes) = 0 then
  begin
    Msg := 'There is no network to send.';
    exit;
  end;
  Loader := LoaderScript;
  if not FileExists(Loader) then
  begin
    Msg := 'The QGIS loader script was not found:' + LineEnding + Loader;
    exit;
  end;

  // Write the GeoJSON files
  Params := TJSONObject.Create;
  Result1 := nil;
  try
    try
      Result1 := cmdhandlers.ExecuteCommand('export_geojson', Params) as TJSONObject;
      NodesFile := Result1.Get('nodes_file', '');
      LinksFile := Result1.Get('links_file', '');
    except
      on E: Exception do
      begin
        Msg := 'The network could not be exported: ' + E.Message;
        exit;
      end;
    end;
  finally
    Params.Free;
    Result1.Free;
  end;

  // Pressure and velocity classes suited to the project's units
  US := SameText(project.PressureUnitsStr[project.PressureUnits], 'psi');
  if US then
    Breaks := '"pressure_breaks": [40, 60, 80, 100], "velocity_breaks": [0.25, 1, 2]'
  else
    Breaks := '"pressure_breaks": [20, 40, 60, 80], "velocity_breaks": [0.05, 0.2, 0.5]';

  Code :=
    'path = ' + PyStr(Loader) + LineEnding +
    'exec(compile(open(path, encoding="utf-8").read(), path, "exec"), {"CONFIG": {' +
    '"nodes_file": ' + PyStr(NodesFile) + ', "links_file": ' + PyStr(LinksFile) +
    ', ' + Breaks + '}})' + LineEnding +
    'from qgis.PyQt.QtCore import Qt' + LineEnding +
    'from qgis.utils import iface' + LineEnding +
    'w = iface.mainWindow()' + LineEnding +
    'w.setWindowState(w.windowState() & ~Qt.WindowMinimized)' + LineEnding +
    'w.show(); w.raise_(); w.activateWindow()';

  // Let QGIS take the foreground when it has loaded the layers
  {$IFDEF WINDOWS}
  AllowSetForegroundWindow(ASFW_ANY);
  {$ENDIF}
  if not AskQgis(Code, Reply, Msg) then exit;
  try
    Info := Reply.Find('result', jtObject) as TJSONObject;
    if (Reply.Get('status', '') <> 'success') or (Info = nil)
    or not Info.Get('executed', true) then
    begin
      Err := Reply.Get('message', '');
      if (Info <> nil) and (Info.Find('error') <> nil) then
        Err := Info.Get('error', '');
      Msg := 'QGIS could not load the network: ' + Err;
      exit;
    end;
  finally
    Reply.Free;
  end;
  Msg := 'The network was sent to QGIS.';
  Result := true;
end;

procedure ComeToFront;
//
//  Shows the main window in front of other programs (QGIS allows this
//  after its "Update EPANET" button has sent edits here).
//
begin
  if MainForm.WindowState = wsMinimized then
    MainForm.WindowState := wsNormal;
  Application.Restore;
  MainForm.Show;
  {$IFDEF WINDOWS}
  SetForegroundWindow(MainForm.Handle);
  {$ENDIF}
  MainForm.BringToFront;
end;

end.
