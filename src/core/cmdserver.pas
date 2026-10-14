{====================================================================
 Project:      EPANET-UI
 Module:       cmdserver
 Description:  a local TCP server that lets external programs send
               JSON commands to the application
 License:      see LICENSE
=====================================================================}

unit cmdserver;

//
// The server listens on the loopback interface only and is polled from a
// TTimer, so every command runs on the application's main thread in the
// same way a user action would.
//
// A request is a single JSON object:
//   {"type": "<command>", "params": {...}}
// The reply is a single JSON object followed by a line feed:
//   {"status": "success", "result": {...}}
//   {"status": "error", "message": "..."}
//

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

const
  DefaultPort = 9877;

type
  // Executes a command and returns its result (or raises an exception)
  TCommandFunc = function(const CmdType: string; Params: TJSONObject): TJSONData;

function  Start(Port: Integer; Handler: TCommandFunc): Boolean;
procedure Stop;
function  IsRunning: Boolean;
function  GetPort: Integer;

implementation

uses
  ExtCtrls, jsonparser, sockets
  {$IFDEF WINDOWS}, winsock2{$ELSE}, BaseUnix{$ENDIF};

const
  InvalidSock   = -1;
  PollInterval  = 50;            // msec between socket polls
  MaxClients    = 8;
  MaxRequest    = 4 * 1024 * 1024; // largest request accepted (bytes)
  SendTimeout   = 10000;         // msec allowed for sending a reply

type
  TClient = class
    Sock:   LongInt;
    Buffer: RawByteString;
  end;

  TServer = class
  private
    FListenSock: LongInt;
    FPort:       Integer;
    FClients:    TFPList;
    FTimer:      TTimer;
    FHandler:    TCommandFunc;
    FBusy:       Boolean;
    procedure TimerTick(Sender: TObject);
    procedure AcceptClients;
    procedure ServiceClient(Client: TClient);
    procedure DropClient(Client: TClient);
    function  Execute(const Request: RawByteString): RawByteString;
    function  SendAll(Sock: LongInt; const Data: RawByteString): Boolean;
  public
    constructor Create(Port: Integer; Handler: TCommandFunc);
    destructor Destroy; override;
    function Listen: Boolean;
  end;

var
  Server: TServer = nil;

function SetNonBlocking(Sock: LongInt): Boolean;
{$IFDEF WINDOWS}
var
  Mode: u_long;
begin
  Mode := 1;
  Result := ioctlsocket(Sock, LongInt(FIONBIO), Mode) = 0;
end;
{$ELSE}
var
  Flags: LongInt;
begin
  Flags := FpFcntl(Sock, F_GETFL, 0);
  Result := (Flags >= 0) and (FpFcntl(Sock, F_SETFL, Flags or O_NONBLOCK) >= 0);
end;
{$ENDIF}

function WouldBlock: Boolean;
begin
  Result := (socketerror = EsockEWOULDBLOCK)
  {$IFNDEF WINDOWS} or (socketerror = ESysEAGAIN){$ENDIF};
end;

function IsCompleteJson(const S: RawByteString): Boolean;
//
//  True once S holds a whole JSON object (its braces balance outside of
//  string literals).
//
var
  I, Depth: Integer;
  InString, Escaped, Started: Boolean;
begin
  Depth := 0;
  InString := false;
  Escaped := false;
  Started := false;
  for I := 1 to Length(S) do
  begin
    if InString then
    begin
      if Escaped then Escaped := false
      else if S[I] = '\' then Escaped := true
      else if S[I] = '"' then InString := false;
    end
    else case S[I] of
      '"': InString := true;
      '{': begin Inc(Depth); Started := true; end;
      '}': Dec(Depth);
    end;
  end;
  Result := Started and (Depth <= 0) and not InString;
end;

{ TServer }

constructor TServer.Create(Port: Integer; Handler: TCommandFunc);
begin
  inherited Create;
  FListenSock := InvalidSock;
  FPort := Port;
  FHandler := Handler;
  FClients := TFPList.Create;
  FBusy := false;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := false;
  FTimer.Interval := PollInterval;
  FTimer.OnTimer := @TimerTick;
end;

destructor TServer.Destroy;
begin
  FTimer.Enabled := false;
  FTimer.Free;
  while FClients.Count > 0 do
    DropClient(TClient(FClients[0]));
  FClients.Free;
  if FListenSock <> InvalidSock then
    CloseSocket(FListenSock);
  inherited Destroy;
end;

function TServer.Listen: Boolean;
var
  Addr: TInetSockAddr;
  {$IFNDEF WINDOWS}
  Opt: LongInt;
  {$ENDIF}
begin
  Result := false;
  FListenSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenSock = InvalidSock then exit;

  {$IFNDEF WINDOWS}
  Opt := 1;
  fpSetSockOpt(FListenSock, SOL_SOCKET, SO_REUSEADDR, @Opt, SizeOf(Opt));
  {$ENDIF}

  // Accept connections from this computer only
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(FPort);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');

  if (fpBind(FListenSock, @Addr, SizeOf(Addr)) <> 0)
  or (fpListen(FListenSock, MaxClients) <> 0)
  or not SetNonBlocking(FListenSock) then
  begin
    CloseSocket(FListenSock);
    FListenSock := InvalidSock;
    exit;
  end;
  FTimer.Enabled := true;
  Result := true;
end;

procedure TServer.TimerTick(Sender: TObject);
//
//  A command can open a modal form, whose message loop lets this timer
//  fire again, so polling is skipped while a command is being executed.
//
var
  I: Integer;
begin
  if FBusy then exit;
  FBusy := true;
  try
    AcceptClients;
    for I := FClients.Count - 1 downto 0 do
      ServiceClient(TClient(FClients[I]));
  finally
    FBusy := false;
  end;
end;

procedure TServer.AcceptClients;
var
  Sock: LongInt;
  Client: TClient;
begin
  while FClients.Count < MaxClients do
  begin
    Sock := fpAccept(FListenSock, nil, nil);
    if Sock = InvalidSock then break;
    if not SetNonBlocking(Sock) then
    begin
      CloseSocket(Sock);
      continue;
    end;
    Client := TClient.Create;
    Client.Sock := Sock;
    Client.Buffer := '';
    FClients.Add(Client);
  end;
end;

procedure TServer.DropClient(Client: TClient);
begin
  FClients.Remove(Client);
  CloseSocket(Client.Sock);
  Client.Free;
end;

procedure TServer.ServiceClient(Client: TClient);
var
  Chunk: array[0..8191] of Byte;
  N: PtrInt;
  OldLen: Integer;
  Request: RawByteString;
begin
  // Read whatever has arrived
  repeat
    N := fpRecv(Client.Sock, @Chunk[0], SizeOf(Chunk), 0);
    if N > 0 then
    begin
      OldLen := Length(Client.Buffer);
      SetLength(Client.Buffer, OldLen + N);
      Move(Chunk[0], Client.Buffer[OldLen + 1], N);
    end;
  until N <= 0;

  // Connection was closed or failed
  if (N = 0) or ((N < 0) and not WouldBlock) then
  begin
    DropClient(Client);
    exit;
  end;

  if Length(Client.Buffer) > MaxRequest then
  begin
    SendAll(Client.Sock,
      '{"status": "error", "message": "request is too large"}' + #10);
    DropClient(Client);
    exit;
  end;

  // Execute a complete request
  if IsCompleteJson(Client.Buffer) then
  begin
    Request := Client.Buffer;
    Client.Buffer := '';
    if not SendAll(Client.Sock, Execute(Request) + #10) then
      DropClient(Client);
  end;
end;

function TServer.Execute(const Request: RawByteString): RawByteString;
var
  Data: TJSONData;
  Params: TJSONObject;
  OwnsParams: Boolean;
  CmdType: string;
  Reply: TJSONObject;
  CmdResult: TJSONData;
begin
  Reply := TJSONObject.Create;
  try
    try
      Data := GetJSON(Request);
      try
        if not (Data is TJSONObject) then
          raise Exception.Create('request must be a JSON object');
        CmdType := TJSONObject(Data).Get('type', '');
        if CmdType = '' then
          raise Exception.Create('request has no "type"');

        OwnsParams := not (TJSONObject(Data).Find('params') is TJSONObject);
        if OwnsParams then
          Params := TJSONObject.Create
        else
          Params := TJSONObject(Data).Objects['params'];
        try
          CmdResult := FHandler(CmdType, Params);
        finally
          if OwnsParams then Params.Free;
        end;

        if CmdResult = nil then CmdResult := TJSONObject.Create;
        Reply.Add('status', 'success');
        Reply.Add('result', CmdResult);
      finally
        Data.Free;
      end;
    except
      on E: Exception do
      begin
        Reply.Clear;
        Reply.Add('status', 'error');
        Reply.Add('message', E.Message);
      end;
    end;
    Result := Reply.AsJSON;
  finally
    Reply.Free;
  end;
end;

function TServer.SendAll(Sock: LongInt; const Data: RawByteString): Boolean;
var
  Sent, N: PtrInt;
  Waited: Integer;
begin
  Result := false;
  Sent := 0;
  Waited := 0;
  while Sent < Length(Data) do
  begin
    N := fpSend(Sock, @Data[Sent + 1], Length(Data) - Sent, 0);
    if N > 0 then
      Inc(Sent, N)
    else if (N < 0) and WouldBlock and (Waited < SendTimeout) then
    begin
      Sleep(1);
      Inc(Waited);
    end
    else
      exit;
  end;
  Result := true;
end;

{ Unit interface }

function Start(Port: Integer; Handler: TCommandFunc): Boolean;
begin
  Stop;
  Server := TServer.Create(Port, Handler);
  Result := Server.Listen;
  if not Result then FreeAndNil(Server);
end;

procedure Stop;
begin
  FreeAndNil(Server);
end;

function IsRunning: Boolean;
begin
  Result := Server <> nil;
end;

function GetPort: Integer;
begin
  if Server <> nil then Result := Server.FPort else Result := 0;
end;

finalization
  Stop;

end.
