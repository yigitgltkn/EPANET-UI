{====================================================================
 Project:      EPANET-UI
 Module:       view3dframe
 Description:  a frame that displays the pipe network and its
               hydraulic results as a three dimensional scene
 License:      see LICENSE
=====================================================================}

unit view3dframe;

{
 The frame fills the third page of the main form's Notebook1. It has two
 displays that share one OpenGL control:

 Network view - links are drawn at their elevations with the hydraulic
 grade line above them. The space in between, which is the pressure head,
 is filled with a translucent surface colored by pressure, so the head
 removed by a valve or added by a pump shows up as a vertical step.

 Valve view - a schematic of one valve driven by its simulation results:
 flow, upstream and downstream pressure, status and setting. EPANET does
 not model the flow inside a valve, so the position of the closure
 element is only an estimate made from the valve's head loss (except for
 a PCV, whose setting is its opening).
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls,
  Graphics, LCLType, Math, OpenGLContext, GL;

type
  TViewMode = (vmNetwork, vmValve);

  TCamera = record
    Yaw, Pitch, Dist: Single;
    X, Y, Z:          Single;   // point the camera looks at
  end;

  TNode3D = record
    X, Y:         Single;       // position in scene coordinates
    Elev:         Single;       // elevation (water surface of a reservoir)
    MaxLevel:     Single;       // highest water level of a tank
    NodeType:     Integer;
    ResIndex:     Integer;      // position in the results file (0 if none)
    OnMap:        Boolean;
    Head, Pres:   Single;       // values on display
    Head0, Pres0: Single;       // values being changed from ...
    Head1, Pres1: Single;       // ... and changed to
  end;
  PNode3D = ^TNode3D;

  TLink3D = record
    N1, N2:       Integer;
    LinkType:     Integer;      // EPANET link type code
    ResIndex:     Integer;
    OnMap:        Boolean;
    First:        Integer;      // first of the link's points in FPts
    Count:        Integer;      // number of points
    Len:          Single;       // length in scene units
    MidX, MidY:   Single;       // point half way along the link
    DirX, DirY:   Single;       // direction of the link at that point
    Flow, Vel:    Single;       // values on display
    Flow0, Vel0:  Single;
    Flow1, Vel1:  Single;
    Status:       Integer;
    Setting:      Single;
    Phase:        Single;       // position of the flow markers (0 to 1)
  end;
  PLink3D = ^TLink3D;

  TLinkPt = record
    X, Y: Single;
    T:    Single;               // distance from start as fraction of length
  end;

  // A point on a link's profile: the pipe below, the grade line above
  TProfilePt = record
    X, Y:   Single;
    ZB, ZT: Single;
    P:      Single;             // pressure
  end;

  TTextTex = record
    Key:  string;
    Tex:  GLuint;
    W, H: Integer;              // size of the text in pixels
    U, V: Single;               // texture coordinates of its far corner
    Used: Boolean;
  end;

  TIcon = record
    Link: Integer;
    X, Y: Single;
  end;

  TParticle = record
    U:    Single;               // position along the pipe (0 to 1)
    A, B: Single;               // position across the pipe (-1 to 1)
    Seed: Single;
  end;

  // What the valve view shows for a valve
  TValveInfo = record
    ID:          string;
    TypeStr:     string;
    StatusStr:   string;
    HasResults:  Boolean;
    Status:      Integer;
    Setting:     Double;
    Diameter:    Double;
    Flow:        Double;
    Velocity:    Double;
    PresIn:      Double;
    PresOut:     Double;
    HeadIn:      Double;
    HeadOut:     Double;
    HeadDrop:    Double;
    PowerKW:     Double;
    LossCoeff:   Double;        // head loss / velocity head (< 0 if no flow)
    Opening:     Double;        // 0 (closed) to 1 (fully open)
    OpeningKnown:     Boolean;  // false if there is no flow to estimate from
    OpeningEstimated: Boolean;  // true unless given by status or setting
  end;

  { TView3DFrame }

  TView3DFrame = class(TFrame)
    AnimTimer:    TTimer;
    BackBtn:      TButton;
    FlowBox:      TCheckBox;
    GLPanel:      TPanel;
    LabelsBox:    TCheckBox;
    ResetBtn:     TButton;
    SurfaceBox:   TCheckBox;
    TopPanel:     TPanel;
    ValveCombo:   TComboBox;
    VertLabel:    TLabel;
    VertTrackBar: TTrackBar;

    procedure AnimTimerTimer(Sender: TObject);
    procedure BackBtnClick(Sender: TObject);
    procedure OptionChange(Sender: TObject);
    procedure ResetBtnClick(Sender: TObject);
    procedure ValveComboChange(Sender: TObject);
    procedure VertTrackBarChange(Sender: TObject);

  private
    GLBox:        TOpenGLControl;
    FActive:      Boolean;
    FGLReady:     Boolean;
    FDirty:       Boolean;      // scene must be drawn again
    FFailed:      Boolean;      // drawing stopped because it raised an error
    FNeedReset:   Boolean;      // camera must be set for a new project
    FMode:        TViewMode;
    FCam:         array[TViewMode] of TCamera;
    FGoal:        array[TViewMode] of TCamera;
    FSavedCam:    TCamera;      // network camera before zooming to a valve
    FLastTick:    QWord;
    FClock:       Double;       // seconds of animation
    FWatchTime:   Double;
    FW, FH:       Integer;      // size of the display in pixels
    FPixScale:    Single;       // screen pixels per pixel at 96 dpi
    FMV, FPR:     array[0..15] of GLdouble;

    // Network
    FNodes:       array of TNode3D;
    FLinks:       array of TLink3D;
    FPts:         array of TLinkPt;
    FProf:        array of TProfilePt;
    FNodeCount:   Integer;
    FLinkCount:   Integer;
    FPtCount:     Integer;
    FExtX, FExtY: Single;       // half the scene's extent
    FZBase:       Single;       // lowest elevation
    FZTop:        Single;       // highest elevation or head
    FZScale:      Single;
    FZExag:       Single;       // vertical scale chosen by the user

    // Results
    FHasResults:  Boolean;
    FPeriods:     Integer;
    FPeriod:      Integer;
    FTween:       Single;       // progress to the period on display (0 to 1)
    FPresLo:      Single;       // pressure range of the color ramp
    FPresHi:      Single;
    FVelMax:      Single;
    FRamp:        array[0..4, 0..2] of Single;
    FBufA, FBufB: TSingleDynArray;

    // Valve view
    FValve:       Integer;      // link index of the valve on display
    FPendingValve: Integer;     // valve the network view is zooming to
    FPendingTime: Single;
    FSerIn:       array of Single;  // upstream pressure in each period
    FSerOut:      array of Single;  // downstream pressure in each period
    FGaugeMax:    Single;
    FValveVelMax: Single;
    FEnergy:      Double;       // kWh dissipated over the simulation
    FParticles:   array of TParticle;

    // Mouse
    FMouseDown:   Boolean;
    FDragged:     Boolean;
    FMouseBtn:    TMouseButton;
    FMouseX:      Integer;
    FMouseY:      Integer;
    FDownX:       Integer;
    FDownY:       Integer;
    FIcons:       array of TIcon;
    FIconCount:   Integer;
    FHotLink:     Integer;      // valve under the mouse pointer

    // Text
    FTexts:       array of TTextTex;
    FTextCount:   Integer;

    // Dots
    FDotTex:      GLuint;
    FDotRadius:   Single;       // scene units per unit of depth
    FDotRight:    array[0..2] of Single;
    FDotUp:       array[0..2] of Single;

    procedure GLPaint(Sender: TObject);
    procedure GLResize(Sender: TObject);
    procedure GLMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure GLMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure GLMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure GLMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure GLMouseLeave(Sender: TObject);
    procedure GLKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure BuildNetwork;
    procedure ScanResults;
    procedure LoadPeriod(Period: Integer; Instant: Boolean);
    procedure ApplyTween;
    procedure LoadValveSeries;
    procedure FillValveCombo;
    procedure CheckProject;
    function  Advance(DT: Double): Boolean;
    procedure EnterValve(LinkIndex: Integer);
    function  IconAt(X, Y: Integer): Integer;
    function  DefaultCamera(AMode: TViewMode): TCamera;

    function  CanRender: Boolean;
    procedure Render;
    procedure DrawFrame;
    procedure InitGL;
    procedure SetupCamera(const Cam: TCamera);
    procedure BeginOverlay;
    function  ToScreen(X, Y, Z: Single; out SX, SY: Single): Boolean;
    function  ZOf(Value: Single): Single;
    procedure RampColor(Pressure: Single; out R, G, B: Single);
    function  LinkProfile(I: Integer): Integer;
    procedure LinkPoint(L: PLink3D; F: Single; out X, Y: Single);
    procedure BeginDots(Size: Single);
    procedure Dot(X, Y, Z: Single);
    procedure EndDots;

    procedure DrawBackground;
    procedure DrawNetworkScene;
    procedure DrawGround;
    procedure DrawPipes;
    procedure DrawStorage;
    procedure DrawGradeLine;
    procedure DrawSurface;
    procedure DrawSteps;
    procedure DrawFlow;
    procedure DrawNetworkOverlay;
    procedure DrawNoResults;
    procedure DrawValveScene;
    procedure DrawValveOverlay;
    procedure DrawGauge(CX, CY, R, Value, MaxValue: Single;
      const Title, Units: string);
    procedure DrawChart(X0, Y0, X1, Y1: Single; const Info: TValveInfo);

    function  TextTexture(const S: string; Size: Integer; Bold: Boolean): Integer;
    procedure PurgeTexts;
    function  TextWidth(const S: string; Size: Integer; Bold: Boolean): Integer;
    function  TextHeight(Size: Integer; Bold: Boolean): Integer;
    procedure PutText(X, Y: Single; const S: string; Size: Integer; Bold: Boolean;
      R, G, B: Single; Just: TAlignment = taLeftJustify);

  public
    procedure Init;
    procedure Clear;
    procedure SetActive(Value: Boolean);
    procedure RefreshScene;
    procedure ResetView;
    procedure ShowNetwork;
    function  ShowValve(LinkIndex: Integer; Animate: Boolean): Boolean;
    function  GetValveInfo(LinkIndex: Integer; out Info: TValveInfo): Boolean;
    procedure SetVerticalScale(Value: Single);
    procedure TurnTo(Yaw, Pitch: Single);
    procedure ZoomBy(Factor: Single);
    function  SaveImage(const FileName: string): Boolean;

    function  GetCamera: TCamera;

    property  Active: Boolean read FActive;
    property  Mode: TViewMode read FMode;
    property  Valve: Integer read FValve;
    property  VerticalScale: Single read FZExag;
  end;

implementation

{$R *.lfm}

uses
  IntfGraphics, FPImage, FPWritePNG,
  main, project, results, mapthemes, config, utils, epanet2, resourcestrings;

const
  // Positions of variables in the results file
  NODE_HEAD     = 1;
  NODE_PRESSURE = 2;
  LINK_FLOW     = 0;
  LINK_VELOCITY = 1;
  LINK_STATUS   = 4;
  LINK_SETTING  = 5;

  // Link status codes in the results file
  STATUS_CLOSED = 2;            // this and anything lower is closed
  STATUS_ACTIVE = 4;

  FieldOfView   = 35.0;         // degrees
  SceneHeight   = 0.6;          // height of the scene at a vertical scale of 1
  TweenTime     = 0.45;         // seconds taken to move to a new time period
  FastTick      = 16;           // timer intervals (msec)
  SlowTick      = 120;
  PickRadius    = 14;           // pixels
  MaxLabels     = 60;

  // Valve schematic
  BoreRadius    = 0.5;
  HalfLength    = 3.2;
  ParticleCount = 340;

  // Loss coefficient assumed for a fully open valve that has none of its own
  OpenLossCoeff = 5.0;

  GL_MULTISAMPLE = $809D;

  ValveNames: array[0..6] of string =
    ('Pressure Reducing Valve', 'Pressure Sustaining Valve',
     'Pressure Breaker Valve', 'Flow Control Valve', 'Throttle Control Valve',
     'General Purpose Valve', 'Positional Control Valve');

function Lerp(A, B, T: Single): Single; inline;
begin
  Result := A + (B - A) * T;
end;

function SmoothStep(T: Single): Single;
begin
  if T <= 0 then Result := 0
  else if T >= 1 then Result := 1
  else Result := T * T * (3 - 2 * T);
end;

function NiceCeiling(Value: Double): Double;
//
//  The smallest round number that is not below Value.
//
const
  Steps: array[0..9] of Double = (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10);
var
  P: Double;
  I: Integer;
begin
  Result := 1;
  if Value <= 0 then exit;
  P := Power(10, Floor(Log10(Value)));
  for I := 0 to High(Steps) do
  begin
    Result := Steps[I] * P;
    if Result >= Value * 0.9999 then exit;
  end;
end;

function Fmt(Value: Double; Decimals: Integer = 1): string;
begin
  Result := utils.Float2Str(Value, Decimals);
end;

function LengthUnits: string;
begin
  if project.GetUnitsSystem = usUS then
    Result := rsFoot
  else
    Result := rsMeter;
end;

function PresUnitsStr: string;
begin
  Result := LowerCase(project.PressureUnitsStr[project.PressureUnits]);
  if Result = LowerCase(rsMeters) then Result := rsMeter;
end;

{------------------------------------------------------------------------------
  Solid shapes of the valve schematic (the X axis runs along the pipe)
------------------------------------------------------------------------------}

procedure TubeX(X0, X1, R: Single; CZ: Single = 0; Segs: Integer = 40);
var
  I: Integer;
  A, C, S: Single;
begin
  glBegin(GL_QUAD_STRIP);
  for I := 0 to Segs do
  begin
    A := 2 * Pi * I / Segs;
    C := Cos(A);
    S := Sin(A);
    glNormal3f(0, C, S);
    glVertex3f(X0, R * C, CZ + R * S);
    glVertex3f(X1, R * C, CZ + R * S);
  end;
  glEnd;
end;

procedure RingX(X, R0, R1, NX: Single; CZ: Single = 0; Segs: Integer = 40);
var
  I: Integer;
  A, C, S: Single;
begin
  glBegin(GL_QUAD_STRIP);
  glNormal3f(NX, 0, 0);
  for I := 0 to Segs do
  begin
    A := 2 * Pi * I / Segs;
    C := Cos(A);
    S := Sin(A);
    glVertex3f(X, R0 * C, CZ + R0 * S);
    glVertex3f(X, R1 * C, CZ + R1 * S);
  end;
  glEnd;
end;

procedure TubeZ(Z0, Z1, R: Single; Segs: Integer = 40);
var
  I: Integer;
  A, C, S: Single;
begin
  glBegin(GL_QUAD_STRIP);
  for I := 0 to Segs do
  begin
    A := 2 * Pi * I / Segs;
    C := Cos(A);
    S := Sin(A);
    glNormal3f(C, S, 0);
    glVertex3f(R * C, R * S, Z0);
    glVertex3f(R * C, R * S, Z1);
  end;
  glEnd;
end;

procedure RingZ(Z, R0, R1, NZ: Single; Segs: Integer = 40);
var
  I: Integer;
  A, C, S: Single;
begin
  glBegin(GL_QUAD_STRIP);
  glNormal3f(0, 0, NZ);
  for I := 0 to Segs do
  begin
    A := 2 * Pi * I / Segs;
    C := Cos(A);
    S := Sin(A);
    glVertex3f(R0 * C, R0 * S, Z);
    glVertex3f(R1 * C, R1 * S, Z);
  end;
  glEnd;
end;

procedure Ellipsoid(CZ, RX, RY, RZ: Single; UpperHalf: Boolean);
const
  Stacks = 18;
  Slices = 36;
var
  I, J, I0: Integer;
  A0, A1, B, C, S: Single;
begin
  if UpperHalf then I0 := Stacks div 2 else I0 := 0;
  for I := I0 to Stacks - 1 do
  begin
    A0 := -Pi / 2 + Pi * I / Stacks;
    A1 := -Pi / 2 + Pi * (I + 1) / Stacks;
    glBegin(GL_QUAD_STRIP);
    for J := 0 to Slices do
    begin
      B := 2 * Pi * J / Slices;
      C := Cos(B);
      S := Sin(B);
      glNormal3f(Cos(A1) * C / RX, Cos(A1) * S / RY, Sin(A1) / RZ);
      glVertex3f(RX * Cos(A1) * C, RY * Cos(A1) * S, CZ + RZ * Sin(A1));
      glNormal3f(Cos(A0) * C / RX, Cos(A0) * S / RY, Sin(A0) / RZ);
      glVertex3f(RX * Cos(A0) * C, RY * Cos(A0) * S, CZ + RZ * Sin(A0));
    end;
    glEnd;
  end;
end;

{------------------------------------------------------------------------------
  Flat shapes of the overlay (pixel coordinates, Y pointing down)
------------------------------------------------------------------------------}

procedure FillRect2D(X0, Y0, X1, Y1, R, G, B, A: Single);
begin
  glColor4f(R, G, B, A);
  glBegin(GL_QUADS);
    glVertex2f(X0, Y0);
    glVertex2f(X1, Y0);
    glVertex2f(X1, Y1);
    glVertex2f(X0, Y1);
  glEnd;
end;

procedure FrameRect2D(X0, Y0, X1, Y1, R, G, B, A: Single);
begin
  glColor4f(R, G, B, A);
  glBegin(GL_LINE_LOOP);
    glVertex2f(X0, Y0);
    glVertex2f(X1, Y0);
    glVertex2f(X1, Y1);
    glVertex2f(X0, Y1);
  glEnd;
end;

procedure Disc2D(CX, CY, Radius: Single);
const
  Segs = 40;
var
  I: Integer;
  A: Single;
begin
  glBegin(GL_TRIANGLE_FAN);
  glVertex2f(CX, CY);
  for I := 0 to Segs do
  begin
    A := 2 * Pi * I / Segs;
    glVertex2f(CX + Radius * Cos(A), CY + Radius * Sin(A));
  end;
  glEnd;
end;

procedure Circle2D(CX, CY, Radius: Single);
const
  Segs = 48;
var
  I: Integer;
  A: Single;
begin
  glBegin(GL_LINE_LOOP);
  for I := 0 to Segs - 1 do
  begin
    A := 2 * Pi * I / Segs;
    glVertex2f(CX + Radius * Cos(A), CY + Radius * Sin(A));
  end;
  glEnd;
end;

{ TView3DFrame }

{------------------------------------------------------------------------------
  Setup
------------------------------------------------------------------------------}

procedure TView3DFrame.Init;
var
  I: Integer;
begin
  GLBox := TOpenGLControl.Create(Self);
  GLBox.Parent := GLPanel;
  GLBox.Align := alClient;
  GLBox.MultiSampling := 4;
  GLBox.OnPaint := @GLPaint;
  GLBox.OnResize := @GLResize;
  GLBox.OnMouseDown := @GLMouseDown;
  GLBox.OnMouseMove := @GLMouseMove;
  GLBox.OnMouseUp := @GLMouseUp;
  GLBox.OnMouseWheel := @GLMouseWheel;
  GLBox.OnMouseLeave := @GLMouseLeave;
  GLBox.OnKeyDown := @GLKeyDown;

  FZExag := 1;
  FPixScale := 1;
  FNeedReset := true;
  FMode := vmNetwork;
  FCam[vmNetwork] := DefaultCamera(vmNetwork);
  FCam[vmValve] := DefaultCamera(vmValve);
  FGoal := FCam;

  SetLength(FParticles, ParticleCount);
  for I := 0 to ParticleCount - 1 do
  begin
    FParticles[I].U := Random;
    FParticles[I].A := Random * 2 * Pi;
    FParticles[I].B := Sqrt(Random);
    FParticles[I].Seed := Random * 100;
  end;
  Clear;
end;

procedure TView3DFrame.Clear;
//
//  Forget the network on display (a new project is being started).
//
begin
  FNodeCount := 0;
  FLinkCount := 0;
  FPtCount := 0;
  FHasResults := false;
  FPeriods := 0;
  FPeriod := 0;
  FValve := 0;
  FPendingValve := 0;
  FHotLink := 0;
  FIconCount := 0;
  FMode := vmNetwork;
  FNeedReset := true;
  BackBtn.Visible := false;
  ValveCombo.Items.Clear;
  FDirty := true;
end;

procedure TView3DFrame.SetActive(Value: Boolean);
//
//  Called when the frame's page is brought into or taken out of view.
//
begin
  if Value = FActive then exit;
  FActive := Value;
  if FActive then
  begin
    FFailed := false;
    RefreshScene;
    FLastTick := GetTickCount64;
    AnimTimer.Interval := FastTick;

    // Keys and the mouse wheel should go to the scene, not to the tool bar
    if GLBox.CanFocus then GLBox.SetFocus;
  end;
  AnimTimer.Enabled := FActive;
end;

procedure TView3DFrame.RefreshScene;
//
//  Read the network and its results again.
//
var
  OldValve: Integer;
begin
  if not FActive then exit;
  OldValve := FValve;
  BuildNetwork;
  ScanResults;
  LoadPeriod(mapthemes.TimePeriod, true);
  FillValveCombo;

  if FNeedReset then
  begin
    FNeedReset := false;
    FMode := vmNetwork;
    FValve := 0;
    FCam[vmNetwork] := DefaultCamera(vmNetwork);
    FGoal[vmNetwork] := FCam[vmNetwork];
  end

  // Stay on the valve that was on display if it still exists
  else if (FMode = vmValve) and ((OldValve > FLinkCount)
  or (FLinks[OldValve].LinkType < EN_PRV)) then
  begin
    FMode := vmNetwork;
    FValve := 0;
  end;
  if FMode = vmValve then LoadValveSeries;
  BackBtn.Visible := (FMode = vmValve);
  FPendingValve := 0;
  FDirty := true;
end;

function TView3DFrame.DefaultCamera(AMode: TViewMode): TCamera;
begin
  if AMode = vmNetwork then
  begin
    Result.Yaw := 24;
    Result.Pitch := 26;
    Result.Dist := 3.0;
    Result.X := 0;
    Result.Y := 0;
    Result.Z := SceneHeight * FZExag * 0.5;
  end
  else
  begin
    Result.Yaw := 22;
    Result.Pitch := 16;
    Result.Dist := 10.5;
    Result.X := 0;
    Result.Y := 0;
    Result.Z := 0.75;
  end;
end;

procedure TView3DFrame.ResetView;
begin
  FGoal[FMode] := DefaultCamera(FMode);
  if FMode = vmNetwork then FSavedCam := FGoal[vmNetwork];
  FDirty := true;
end;

procedure TView3DFrame.SetVerticalScale(Value: Single);
begin
  VertTrackBar.Position := EnsureRange(Round(Value * 4), VertTrackBar.Min,
    VertTrackBar.Max);
  VertTrackBarChange(nil);
end;

procedure TView3DFrame.TurnTo(Yaw, Pitch: Single);
begin
  FGoal[FMode].Yaw := Yaw;
  FGoal[FMode].Pitch := EnsureRange(Pitch, 3, 89);
  FCam[FMode].Yaw := FGoal[FMode].Yaw;
  FCam[FMode].Pitch := FGoal[FMode].Pitch;
  FDirty := true;
end;

function TView3DFrame.GetCamera: TCamera;
begin
  Result := FGoal[FMode];
end;

procedure TView3DFrame.ZoomBy(Factor: Single);
begin
  if Factor <= 0 then exit;
  FGoal[FMode].Dist := EnsureRange(DefaultCamera(FMode).Dist / Factor, 0.15, 40);
  FCam[FMode].Dist := FGoal[FMode].Dist;
  FDirty := true;
end;

{------------------------------------------------------------------------------
  Network and results
------------------------------------------------------------------------------}

procedure TView3DFrame.BuildNetwork;
//
//  Place the project's nodes and links in a scene whose larger map
//  dimension runs from -1 to 1.
//
var
  I, K, N1, N2, LT: Integer;
  X: Double = 0;
  Y: Double = 0;
  Xmin, Xmax, Ymin, Ymax, Cx, Cy, Kx, Span, S: Double;
  Acc, Seg, Half: Single;
  Node: PNode3D;
  Link: PLink3D;
  RawX, RawY: array of Double;

  procedure Extend(AX, AY: Double);
  begin
    Xmin := Min(Xmin, AX);
    Xmax := Max(Xmax, AX);
    Ymin := Min(Ymin, AY);
    Ymax := Max(Ymax, AY);
  end;

  procedure AddPt(AX, AY: Single);
  begin
    if FPtCount >= Length(FPts) then
      SetLength(FPts, FPtCount + 1024);
    FPts[FPtCount].X := AX;
    FPts[FPtCount].Y := AY;
    FPts[FPtCount].T := 0;
    Inc(FPtCount);
  end;

begin
  FNodeCount := project.GetItemCount(ctNodes);
  FLinkCount := project.GetItemCount(ctLinks);
  SetLength(FNodes, 0);
  SetLength(FLinks, 0);
  SetLength(FNodes, FNodeCount + 1);
  SetLength(FLinks, FLinkCount + 1);
  SetLength(RawX, FNodeCount + 1);
  SetLength(RawY, FNodeCount + 1);
  FPtCount := 0;

  // The map's extent
  Xmin := 1e300;
  Xmax := -1e300;
  Ymin := 1e300;
  Ymax := -1e300;
  for I := 1 to FNodeCount do
  begin
    Node := @FNodes[I];
    Node^.NodeType := project.GetNodeType(I);
    Node^.Elev := project.GetNodeParam(I, EN_ELEVATION);
    if Node^.NodeType = ntTank then
      Node^.MaxLevel := project.GetNodeParam(I, EN_MAXLEVEL);
    Node^.OnMap := project.GetNodeCoord(I, X, Y) and (X <> EN_MISSING)
      and (Y <> EN_MISSING);
    if Node^.OnMap then
    begin
      RawX[I] := X;
      RawY[I] := Y;
      Extend(X, Y);
    end;
  end;
  for I := 1 to FLinkCount do
    for K := 1 to project.GetVertexCount(I) do
      if project.GetVertexCoord(I, K, X, Y) then Extend(X, Y);
  if Xmax < Xmin then
  begin
    Xmin := 0;
    Xmax := 0;
    Ymin := 0;
    Ymax := 0;
  end;

  // A degree of longitude is shorter than a degree of latitude
  Kx := 1;
  if project.MapUnits = muDegrees then
    Kx := Max(Cos(DegToRad((Ymin + Ymax) / 2)), 0.05);
  Cx := (Xmin + Xmax) / 2;
  Cy := (Ymin + Ymax) / 2;
  Span := Max((Xmax - Xmin) * Kx, Ymax - Ymin);
  if Span <= 0 then Span := 1;
  S := 2 / Span;
  FExtX := (Xmax - Xmin) * Kx * S / 2;
  FExtY := (Ymax - Ymin) * S / 2;

  FZBase := 1e30;
  FZTop := -1e30;
  for I := 1 to FNodeCount do
  begin
    Node := @FNodes[I];
    if not Node^.OnMap then continue;
    Node^.X := (RawX[I] - Cx) * Kx * S;
    Node^.Y := (RawY[I] - Cy) * S;
    FZBase := Min(FZBase, Node^.Elev);
    FZTop := Max(FZTop, Node^.Elev + Node^.MaxLevel);
  end;
  if FZTop < FZBase then
  begin
    FZBase := 0;
    FZTop := 0;
  end;

  // Each link runs from its start node through its vertices to its end node
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    LT := 0;
    N1 := 0;
    N2 := 0;
    epanet2.ENgetlinktype(I, LT);
    Link^.LinkType := LT;
    Link^.First := FPtCount;
    if not project.GetLinkNodes(I, N1, N2) then continue;
    if (N1 < 1) or (N1 > FNodeCount) or (N2 < 1) or (N2 > FNodeCount) then
      continue;
    Link^.N1 := N1;
    Link^.N2 := N2;
    Link^.OnMap := FNodes[N1].OnMap and FNodes[N2].OnMap;
    if not Link^.OnMap then continue;

    AddPt(FNodes[N1].X, FNodes[N1].Y);
    for K := 1 to project.GetVertexCount(I) do
      if project.GetVertexCoord(I, K, X, Y) then
        AddPt((X - Cx) * Kx * S, (Y - Cy) * S);
    AddPt(FNodes[N2].X, FNodes[N2].Y);
    Link^.Count := FPtCount - Link^.First;

    // Distance of each point along the link
    Acc := 0;
    for K := Link^.First + 1 to FPtCount - 1 do
    begin
      Acc := Acc + Hypot(FPts[K].X - FPts[K-1].X, FPts[K].Y - FPts[K-1].Y);
      FPts[K].T := Acc;
    end;
    Link^.Len := Acc;
    for K := Link^.First + 1 to FPtCount - 1 do
      if Acc > 0 then
        FPts[K].T := FPts[K].T / Acc
      else
        FPts[K].T := (K - Link^.First) / (Link^.Count - 1);

    // The point half way along and the link's direction there
    Link^.MidX := (FNodes[N1].X + FNodes[N2].X) / 2;
    Link^.MidY := (FNodes[N1].Y + FNodes[N2].Y) / 2;
    Link^.DirX := 1;
    Link^.DirY := 0;
    for K := Link^.First to FPtCount - 2 do
      if (FPts[K].T <= 0.5) and (FPts[K+1].T >= 0.5) then
      begin
        Seg := FPts[K+1].T - FPts[K].T;
        if Seg > 0 then Half := (0.5 - FPts[K].T) / Seg else Half := 0.5;
        Link^.MidX := Lerp(FPts[K].X, FPts[K+1].X, Half);
        Link^.MidY := Lerp(FPts[K].Y, FPts[K+1].Y, Half);
        Seg := Hypot(FPts[K+1].X - FPts[K].X, FPts[K+1].Y - FPts[K].Y);
        if Seg > 0 then
        begin
          Link^.DirX := (FPts[K+1].X - FPts[K].X) / Seg;
          Link^.DirY := (FPts[K+1].Y - FPts[K].Y) / Seg;
        end;
        break;
      end;
  end;
end;

procedure TView3DFrame.ScanResults;
//
//  Find where each object's results are and the ranges that pressure,
//  head and velocity take over the simulation.
//
var
  I, T, Step, R: Integer;
  HeadMax: Single;
  C: TColor;
begin
  FHasResults := project.HasResults and project.OutFileOpened;
  if FHasResults then FPeriods := results.Nperiods else FPeriods := 0;
  FPresLo := 1e30;
  FPresHi := -1e30;
  FVelMax := 0;
  HeadMax := -1e30;

  for I := 1 to FNodeCount do
    if FHasResults then
      FNodes[I].ResIndex := project.GetResultIndex(ctNodes, I)
    else
      FNodes[I].ResIndex := 0;
  for I := 1 to FLinkCount do
    if FHasResults then
      FLinks[I].ResIndex := project.GetResultIndex(ctLinks, I)
    else
      FLinks[I].ResIndex := 0;

  // Long simulations are sampled
  if FHasResults then
  begin
    Step := Max(1, FPeriods div 200);
    T := 0;
    while T < FPeriods do
    begin
      results.GetNodeValues(NODE_HEAD, T, FBufA);
      results.GetNodeValues(NODE_PRESSURE, T, FBufB);
      for I := 1 to FNodeCount do
      begin
        R := FNodes[I].ResIndex;
        if (R < 1) or (R > Length(FBufA)) then
        begin
          FNodes[I].ResIndex := 0;
          continue;
        end;
        if not FNodes[I].OnMap then continue;
        HeadMax := Max(HeadMax, FBufA[R-1]);
        if FNodes[I].NodeType = ntJunction then
        begin
          FPresLo := Min(FPresLo, FBufB[R-1]);
          FPresHi := Max(FPresHi, FBufB[R-1]);
        end;
      end;
      results.GetLinkValues(LINK_VELOCITY, T, FBufA);
      for I := 1 to FLinkCount do
      begin
        R := FLinks[I].ResIndex;
        if (R < 1) or (R > Length(FBufA)) then
        begin
          FLinks[I].ResIndex := 0;
          continue;
        end;
        if FLinks[I].LinkType <= EN_PIPE then
          FVelMax := Max(FVelMax, Abs(FBufA[R-1]));
      end;
      Inc(T, Step);
    end;
  end;

  if FPresHi < FPresLo then
  begin
    FPresLo := 0;
    FPresHi := 1;
  end;
  FPresLo := Max(FPresLo, 0);
  if FPresHi - FPresLo < 1e-3 then FPresHi := FPresLo + 1;
  if FVelMax < 1e-4 then FVelMax := 1;
  FZTop := Max(FZTop, HeadMax);
  FZScale := SceneHeight / Max(FZTop - FZBase, 1e-6);

  // Pressures use the colors of the map's node legend
  for I := 0 to 4 do
  begin
    C := ColorToRGB(mapthemes.NodeColors[I]);
    FRamp[I, 0] := Red(C) / 255;
    FRamp[I, 1] := Green(C) / 255;
    FRamp[I, 2] := Blue(C) / 255;
  end;
end;

procedure TView3DFrame.LoadPeriod(Period: Integer; Instant: Boolean);
//
//  Display the results of a time period, either at once or by moving
//  to them from the values now on display.
//
var
  I, R: Integer;
  Node: PNode3D;
  Link: PLink3D;
  HasLinks: Boolean;
  Status, Setting: TSingleDynArray;
begin
  if FHasResults then
    FPeriod := EnsureRange(Period, 0, FPeriods - 1)
  else
    FPeriod := 0;

  if FHasResults then
  begin
    results.GetNodeValues(NODE_HEAD, FPeriod, FBufA);
    results.GetNodeValues(NODE_PRESSURE, FPeriod, FBufB);
  end;
  for I := 1 to FNodeCount do
  begin
    Node := @FNodes[I];
    Node^.Head0 := Node^.Head;
    Node^.Pres0 := Node^.Pres;
    R := Node^.ResIndex;
    if FHasResults and (R >= 1) and (R <= Length(FBufA)) then
    begin
      Node^.Head1 := FBufA[R-1];
      Node^.Pres1 := FBufB[R-1];
    end
    else
    begin
      Node^.Head1 := Node^.Elev;
      Node^.Pres1 := 0;
    end;
  end;

  Status := nil;
  Setting := nil;
  HasLinks := FHasResults and (FLinkCount > 0);
  if HasLinks then
  begin
    results.GetLinkValues(LINK_FLOW, FPeriod, FBufA);
    results.GetLinkValues(LINK_VELOCITY, FPeriod, FBufB);
    results.GetLinkValues(LINK_STATUS, FPeriod, Status);
    results.GetLinkValues(LINK_SETTING, FPeriod, Setting);
  end;
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    Link^.Flow0 := Link^.Flow;
    Link^.Vel0 := Link^.Vel;
    R := Link^.ResIndex;
    if HasLinks and (R >= 1) and (R <= Length(FBufA)) then
    begin
      Link^.Flow1 := FBufA[R-1];
      Link^.Vel1 := FBufB[R-1];
      Link^.Status := Round(Status[R-1]);
      Link^.Setting := Setting[R-1];
    end
    else
    begin
      Link^.Flow1 := 0;
      Link^.Vel1 := 0;
      Link^.Status := 3;
      Link^.Setting := 0;
    end;
  end;

  if Instant then FTween := 1 else FTween := 0;
  ApplyTween;
  FDirty := true;
end;

procedure TView3DFrame.ApplyTween;
var
  I: Integer;
  S: Single;
begin
  S := SmoothStep(FTween);
  for I := 1 to FNodeCount do
  begin
    FNodes[I].Head := Lerp(FNodes[I].Head0, FNodes[I].Head1, S);
    FNodes[I].Pres := Lerp(FNodes[I].Pres0, FNodes[I].Pres1, S);
  end;
  for I := 1 to FLinkCount do
  begin
    FLinks[I].Flow := Lerp(FLinks[I].Flow0, FLinks[I].Flow1, S);
    FLinks[I].Vel := Lerp(FLinks[I].Vel0, FLinks[I].Vel1, S);
  end;
end;

procedure TView3DFrame.FillValveCombo;
var
  I: Integer;
begin
  ValveCombo.Items.BeginUpdate;
  try
    ValveCombo.Items.Clear;
    ValveCombo.Items.Add(rs3dSelectValve);
    for I := 1 to FLinkCount do
      if FLinks[I].LinkType >= EN_PRV then
        ValveCombo.Items.AddObject(project.ValveTypeStr[
          EnsureRange(FLinks[I].LinkType - EN_PRV, 0, High(ValveTypeStr))] +
          ' ' + project.GetID(ctLinks, I), TObject(PtrInt(I)));
  finally
    ValveCombo.Items.EndUpdate;
  end;
  ValveCombo.Enabled := ValveCombo.Items.Count > 1;
  ValveCombo.ItemIndex := 0;
  if FMode = vmValve then
    for I := 1 to ValveCombo.Items.Count - 1 do
      if PtrInt(ValveCombo.Items.Objects[I]) = FValve then
        ValveCombo.ItemIndex := I;
end;

function TView3DFrame.GetValveInfo(LinkIndex: Integer;
  out Info: TValveInfo): Boolean;
//
//  The quantities the valve view displays, taken from the results now on
//  display.
//
const
  CfsToCms = 0.028316847;
  FootToMeter = 0.3048;
var
  Link: PLink3D;
  SpGr: Single = 1;
  G, VelHead, HeadM, Flow, OpenK: Double;
begin
  Result := false;
  Info := Default(TValveInfo);
  if (LinkIndex < 1) or (LinkIndex > FLinkCount) then exit;
  Link := @FLinks[LinkIndex];
  if (Link^.LinkType < EN_PRV) or (Link^.N1 < 1) or (Link^.N2 < 1) then exit;
  Result := true;

  Info.ID := project.GetID(ctLinks, LinkIndex);
  Info.TypeStr := project.ValveTypeStr[EnsureRange(Link^.LinkType - EN_PRV, 0,
    High(ValveTypeStr))];
  Info.Diameter := project.GetLinkParam(LinkIndex, EN_DIAMETER);
  Info.Setting := project.GetLinkParam(LinkIndex, EN_INITSETTING);
  Info.LossCoeff := -1;
  Info.HasResults := FHasResults and (Link^.ResIndex > 0)
    and (FNodes[Link^.N1].ResIndex > 0) and (FNodes[Link^.N2].ResIndex > 0);
  if not Info.HasResults then exit;

  Info.Status := Link^.Status;
  if Link^.Status <= STATUS_CLOSED then
    Info.StatusStr := rsClosed
  else if Link^.Status = STATUS_ACTIVE then
    Info.StatusStr := rs3dActive
  else
    Info.StatusStr := rsOpen;
  Info.Setting := Link^.Setting;
  Info.Flow := Link^.Flow;
  Info.Velocity := Abs(Link^.Vel);
  Info.PresIn := FNodes[Link^.N1].Pres;
  Info.PresOut := FNodes[Link^.N2].Pres;
  Info.HeadIn := FNodes[Link^.N1].Head;
  Info.HeadOut := FNodes[Link^.N2].Head;
  Info.HeadDrop := Info.HeadIn - Info.HeadOut;

  // Hydraulic power lost across the valve
  epanet2.ENgetoption(EN_SP_GRAVITY, SpGr);
  if SpGr <= 0 then SpGr := 1;
  Flow := Abs(Info.Flow) / project.FlowUcf[project.FlowUnits] * CfsToCms;
  HeadM := Abs(Info.HeadDrop);
  if project.GetUnitsSystem = usUS then HeadM := HeadM * FootToMeter;
  Info.PowerKW := 9.80665 * SpGr * Flow * HeadM;

  // Head loss as a multiple of the velocity head
  if project.GetUnitsSystem = usUS then G := 32.174 else G := 9.80665;
  VelHead := Sqr(Info.Velocity) / (2 * G);
  if VelHead > 1e-9 then
    Info.LossCoeff := Abs(Info.HeadDrop) / VelHead;

  // How far open the valve is
  OpenK := project.GetLinkParam(LinkIndex, EN_MINORLOSS);
  if OpenK <= 0 then OpenK := OpenLossCoeff;
  Info.OpeningKnown := true;
  if Link^.Status <= STATUS_CLOSED then
    Info.Opening := 0
  else if Link^.LinkType = EN_PCV then
    Info.Opening := EnsureRange(Info.Setting / 100, 0, 1)
  else if Info.LossCoeff < 0 then
    Info.OpeningKnown := false
  else
  begin
    Info.OpeningEstimated := true;
    if Info.LossCoeff <= OpenK then
      Info.Opening := 1
    else
      Info.Opening := Sqrt(OpenK / Info.LossCoeff);
  end;
end;

procedure TView3DFrame.LoadValveSeries;
//
//  Read what the valve on display does over the whole simulation.
//
var
  T, R1, R2, RL: Integer;
  PMax: Single;
  Link: PLink3D;
  Saved: TLink3D;
  Node1, Node2: TNode3D;
  Info: TValveInfo;
begin
  SetLength(FSerIn, 0);
  SetLength(FSerOut, 0);
  FGaugeMax := 1;
  FValveVelMax := 0;
  FEnergy := 0;
  if (FValve < 1) or (FValve > FLinkCount) or not FHasResults then exit;
  if not (project.HasResults and project.OutFileOpened) then exit;
  Link := @FLinks[FValve];
  if (Link^.N1 < 1) or (Link^.N2 < 1) then exit;
  R1 := FNodes[Link^.N1].ResIndex;
  R2 := FNodes[Link^.N2].ResIndex;
  RL := Link^.ResIndex;
  if (R1 < 1) or (R2 < 1) or (RL < 1) then exit;

  // The power lost in each period is found by GetValveInfo, which works
  // on the values on display, so those are replaced for the time being
  Saved := Link^;
  Node1 := FNodes[Link^.N1];
  Node2 := FNodes[Link^.N2];
  SetLength(FSerIn, FPeriods);
  SetLength(FSerOut, FPeriods);
  PMax := 0;
  for T := 0 to FPeriods - 1 do
  begin
    FSerIn[T] := results.GetNodeValue(R1, NODE_PRESSURE, T);
    FSerOut[T] := results.GetNodeValue(R2, NODE_PRESSURE, T);
    PMax := Max(PMax, Max(FSerIn[T], FSerOut[T]));

    Link^.Flow := results.GetLinkValue(RL, LINK_FLOW, T);
    Link^.Vel := results.GetLinkValue(RL, LINK_VELOCITY, T);
    FNodes[Link^.N1].Head := results.GetNodeValue(R1, NODE_HEAD, T);
    FNodes[Link^.N2].Head := results.GetNodeValue(R2, NODE_HEAD, T);
    FValveVelMax := Max(FValveVelMax, Abs(Link^.Vel));
    if (T < FPeriods - 1) and GetValveInfo(FValve, Info) then
      FEnergy := FEnergy + Info.PowerKW * results.Rstep / 3600;
  end;
  Link^ := Saved;
  FNodes[Link^.N1] := Node1;
  FNodes[Link^.N2] := Node2;
  FGaugeMax := NiceCeiling(Max(PMax, 1e-3));
end;

procedure TView3DFrame.CheckProject;
//
//  Follow changes made to the project and to the time period on view
//  while this frame is on display.
//
begin
  if (project.GetItemCount(ctNodes) <> FNodeCount)
  or (project.GetItemCount(ctLinks) <> FLinkCount)
  or ((project.HasResults and project.OutFileOpened) <> FHasResults)
  or (FHasResults and (results.Nperiods <> FPeriods)) then
    RefreshScene
  else if FHasResults and (mapthemes.TimePeriod <> FPeriod)
  and (mapthemes.TimePeriod >= 0) and (mapthemes.TimePeriod < FPeriods) then
    LoadPeriod(mapthemes.TimePeriod, false);
end;

{------------------------------------------------------------------------------
  Animation
------------------------------------------------------------------------------}

procedure TView3DFrame.AnimTimerTimer(Sender: TObject);
var
  Tick: QWord;
  DT: Double;
  Moving: Boolean;
begin
  if not FActive then exit;
  Tick := GetTickCount64;
  DT := Min((Tick - FLastTick) / 1000, 0.1);
  FLastTick := Tick;
  FClock := FClock + DT;

  FWatchTime := FWatchTime + DT;
  if FWatchTime >= 0.1 then
  begin
    FWatchTime := 0;
    CheckProject;
  end;

  Moving := Advance(DT);
  if Moving or FDirty then Render;
  if Moving then
    AnimTimer.Interval := FastTick
  else
    AnimTimer.Interval := SlowTick;
end;

function TView3DFrame.Advance(DT: Double): Boolean;
//
//  Move everything that is animated on by DT seconds. Returns false if
//  nothing moved.
//
var
  I: Integer;
  K, Speed, Gate: Single;
  Cam, Goal: ^TCamera;
  Link: PLink3D;
  Info: TValveInfo;

  function Approach(var Value: Single; Target: Single; Tolerance: Single): Boolean;
  begin
    Result := Abs(Target - Value) > Tolerance;
    if Result then
      Value := Value + (Target - Value) * K
    else
      Value := Target;
  end;

begin
  Result := false;

  // Results on display move to those of the current time period
  if FTween < 1 then
  begin
    FTween := Min(1, FTween + DT / TweenTime);
    ApplyTween;
    Result := true;
  end;

  // The camera moves to where it was sent
  K := 1 - Exp(-DT * 9);
  Cam := @FCam[FMode];
  Goal := @FGoal[FMode];
  if Approach(Cam^.Yaw, Goal^.Yaw, 0.02) then Result := true;
  if Approach(Cam^.Pitch, Goal^.Pitch, 0.02) then Result := true;
  if Approach(Cam^.Dist, Goal^.Dist, Goal^.Dist * 0.0005) then Result := true;
  if Approach(Cam^.X, Goal^.X, 0.0005) then Result := true;
  if Approach(Cam^.Y, Goal^.Y, 0.0005) then Result := true;
  if Approach(Cam^.Z, Goal^.Z, 0.0005) then Result := true;

  // The network view has zoomed in on a valve that was picked
  if FPendingValve > 0 then
  begin
    FPendingTime := FPendingTime - DT;
    if FPendingTime <= 0 then EnterValve(FPendingValve);
    Result := true;
  end;

  if not FHasResults then exit;

  // Flow markers travel along the links
  if (FMode = vmNetwork) and FlowBox.Checked then
  begin
    for I := 1 to FLinkCount do
    begin
      Link := @FLinks[I];
      if (Link^.Len <= 1e-6) or (Link^.ResIndex < 1) then continue;
      Speed := Min(Abs(Link^.Vel) / FVelMax, 1.5) * 0.3 / Link^.Len;
      if Link^.Flow < 0 then Speed := -Speed;
      Link^.Phase := Link^.Phase + Speed * DT;
      Link^.Phase := Link^.Phase - Floor(Link^.Phase);
    end;
    Result := true;
  end

  // Water moves through the valve, faster where the passage narrows
  else if FMode = vmValve then
  begin
    if not GetValveInfo(FValve, Info) then exit;
    if not Info.HasResults then exit;
    if FValveVelMax > 1e-6 then
      Speed := Info.Velocity / FValveVelMax
    else
      Speed := 0;
    if Info.Status <= STATUS_CLOSED then Speed := 0;
    if Info.Flow < 0 then Speed := -Speed;
    Gate := Max(Info.Opening, 0.2);
    for I := 0 to High(FParticles) do
    begin
      K := (FParticles[I].U - 0.5) * 2 * HalfLength;
      K := 1 + (1 / Gate - 1) * Exp(-Sqr(K / 0.4));
      FParticles[I].U := FParticles[I].U + Speed * 0.16 * K * DT;
      FParticles[I].U := FParticles[I].U - Floor(FParticles[I].U);
    end;
    Result := true;
  end;
end;

{------------------------------------------------------------------------------
  Choice of what is on display
------------------------------------------------------------------------------}

function TView3DFrame.ShowValve(LinkIndex: Integer; Animate: Boolean): Boolean;
//
//  Display the schematic of a valve. With Animate the network view first
//  zooms in on where the valve is.
//
var
  Link: PLink3D;
begin
  Result := false;
  if (LinkIndex < 1) or (LinkIndex > FLinkCount) then exit;
  Link := @FLinks[LinkIndex];
  if Link^.LinkType < EN_PRV then exit;
  Result := true;

  if Animate and (FMode = vmNetwork) and Link^.OnMap then
  begin
    if FPendingValve = 0 then FSavedCam := FGoal[vmNetwork];
    FPendingValve := LinkIndex;
    FPendingTime := 0.5;
    FGoal[vmNetwork].X := Link^.MidX;
    FGoal[vmNetwork].Y := Link^.MidY;
    FGoal[vmNetwork].Z := ZOf((FNodes[Link^.N1].Head + FNodes[Link^.N2].Head) / 2);
    FGoal[vmNetwork].Dist := Max(FCam[vmNetwork].Dist * 0.3, 0.3);
    FDirty := true;
  end
  else
  begin
    if FMode = vmNetwork then FSavedCam := FGoal[vmNetwork];
    EnterValve(LinkIndex);
    if not Animate then FCam[vmValve] := FGoal[vmValve];
  end;
end;

procedure TView3DFrame.EnterValve(LinkIndex: Integer);
var
  I: Integer;
begin
  FPendingValve := 0;
  FValve := LinkIndex;
  FMode := vmValve;
  LoadValveSeries;

  // The camera closes in from further away
  FGoal[vmValve] := DefaultCamera(vmValve);
  FCam[vmValve] := FGoal[vmValve];
  FCam[vmValve].Dist := FGoal[vmValve].Dist * 1.7;
  FCam[vmValve].Yaw := FGoal[vmValve].Yaw + 30;

  BackBtn.Visible := true;
  for I := 1 to ValveCombo.Items.Count - 1 do
    if PtrInt(ValveCombo.Items.Objects[I]) = FValve then
      ValveCombo.ItemIndex := I;
  GLBox.Cursor := crDefault;
  FHotLink := 0;
  FDirty := true;
end;

procedure TView3DFrame.ShowNetwork;
begin
  if (FMode = vmNetwork) and (FPendingValve = 0) then exit;
  FPendingValve := 0;
  FMode := vmNetwork;
  FGoal[vmNetwork] := FSavedCam;
  BackBtn.Visible := false;
  ValveCombo.ItemIndex := 0;
  FDirty := true;
end;

procedure TView3DFrame.BackBtnClick(Sender: TObject);
begin
  ShowNetwork;
end;

procedure TView3DFrame.ValveComboChange(Sender: TObject);
begin
  if ValveCombo.ItemIndex > 0 then
    ShowValve(PtrInt(ValveCombo.Items.Objects[ValveCombo.ItemIndex]),
      FMode = vmNetwork)
  else
    ShowNetwork;
end;

procedure TView3DFrame.ResetBtnClick(Sender: TObject);
begin
  ResetView;
end;

procedure TView3DFrame.OptionChange(Sender: TObject);
begin
  FDirty := true;
end;

procedure TView3DFrame.VertTrackBarChange(Sender: TObject);
var
  OldExag: Single;
begin
  OldExag := FZExag;
  FZExag := VertTrackBar.Position / 4;
  VertLabel.Caption := Format('Vertical scale x%s', [Fmt(FZExag, 2)]);

  // Keep looking at the same height of the network
  if OldExag > 0 then
  begin
    FGoal[vmNetwork].Z := FGoal[vmNetwork].Z * FZExag / OldExag;
    FCam[vmNetwork].Z := FGoal[vmNetwork].Z;
    FSavedCam.Z := FSavedCam.Z * FZExag / OldExag;
  end;
  FDirty := true;
end;

{------------------------------------------------------------------------------
  Mouse and keyboard
------------------------------------------------------------------------------}

function TView3DFrame.IconAt(X, Y: Integer): Integer;
var
  I: Integer;
  D, Best: Single;
begin
  Result := 0;
  Best := Sqr(PickRadius * FPixScale);
  for I := 0 to FIconCount - 1 do
  begin
    D := Sqr(FIcons[I].X - X) + Sqr(FIcons[I].Y - Y);
    if D <= Best then
    begin
      Best := D;
      Result := FIcons[I].Link;
    end;
  end;
end;

procedure TView3DFrame.GLMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if GLBox.CanFocus then GLBox.SetFocus;
  FMouseDown := true;
  FDragged := false;
  FMouseBtn := Button;
  if (Button = mbLeft) and (ssShift in Shift) then FMouseBtn := mbRight;
  FDownX := X;
  FDownY := Y;
  FMouseX := X;
  FMouseY := Y;
end;

procedure TView3DFrame.GLMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  DX, DY, Hot: Integer;
  K, C, S: Single;
  Cam: ^TCamera;
begin
  if not FMouseDown then
  begin
    // Valves that can be picked are pointed out
    Hot := 0;
    if (FMode = vmNetwork) and (FPendingValve = 0) then Hot := IconAt(X, Y);
    if Hot <> FHotLink then
    begin
      FHotLink := Hot;
      if Hot > 0 then
        GLBox.Cursor := crHandPoint
      else
        GLBox.Cursor := crDefault;
      FDirty := true;
    end;
    exit;
  end;

  DX := X - FMouseX;
  DY := Y - FMouseY;
  FMouseX := X;
  FMouseY := Y;
  if (Abs(X - FDownX) > 3) or (Abs(Y - FDownY) > 3) then FDragged := true;
  if not FDragged or (FPendingValve > 0) then exit;

  Cam := @FGoal[FMode];
  if FMouseBtn = mbLeft then
  begin
    Cam^.Yaw := Cam^.Yaw - DX * 0.4;
    Cam^.Pitch := EnsureRange(Cam^.Pitch + DY * 0.4, 3, 89);
  end
  else if FMode = vmNetwork then
  begin
    // The point under the mouse pointer follows it over the ground
    K := Cam^.Dist * 2 * Tan(DegToRad(FieldOfView) / 2) / Max(FH, 1);
    C := Cos(DegToRad(Cam^.Yaw));
    S := Sin(DegToRad(Cam^.Yaw));
    Cam^.X := Cam^.X - C * DX * K;
    Cam^.Y := Cam^.Y - S * DX * K;
    K := K / Max(Sin(DegToRad(Cam^.Pitch)), 0.3);
    Cam^.X := Cam^.X - S * DY * K;
    Cam^.Y := Cam^.Y + C * DY * K;
  end;
  FCam[FMode] := Cam^;
  FDirty := true;
end;

procedure TView3DFrame.GLMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Link: Integer;
begin
  if not FMouseDown then exit;
  FMouseDown := false;
  if FDragged or (Button <> mbLeft) or (FMode <> vmNetwork) then exit;
  Link := IconAt(X, Y);
  if Link > 0 then
  begin
    MainForm.ProjectFrame.SelectItem(ctLinks, Link - 1);
    ShowValve(Link, true);
  end;
end;

procedure TView3DFrame.GLMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  Handled := true;
  if FPendingValve > 0 then exit;
  FGoal[FMode].Dist := EnsureRange(
    FGoal[FMode].Dist * Power(0.88, WheelDelta / 120), 0.15, 40);
  FDirty := true;
end;

procedure TView3DFrame.GLMouseLeave(Sender: TObject);
begin
  if FHotLink > 0 then
  begin
    FHotLink := 0;
    GLBox.Cursor := crDefault;
    FDirty := true;
  end;
end;

procedure TView3DFrame.GLKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) and (FMode = vmValve) then
  begin
    ShowNetwork;
    Key := 0;
  end;
end;

{------------------------------------------------------------------------------
  Drawing
------------------------------------------------------------------------------}

function TView3DFrame.CanRender: Boolean;
begin
  Result := Assigned(GLBox) and GLBox.HandleAllocated and GLBox.IsVisible
    and (GLBox.Width > 1) and (GLBox.Height > 1);
end;

procedure TView3DFrame.GLPaint(Sender: TObject);
begin
  Render;
end;

procedure TView3DFrame.GLResize(Sender: TObject);
begin
  FDirty := true;
end;

procedure TView3DFrame.Render;
begin
  if FFailed or not CanRender then exit;
  if not GLBox.MakeCurrent then exit;
  try
    DrawFrame;
  except
    // The failure is reported once, not again on every tick of the timer
    FFailed := true;
    raise;
  end;
  GLBox.SwapBuffers;
  FDirty := false;
end;

function TView3DFrame.SaveImage(const FileName: string): Boolean;
//
//  Save what is on display to a PNG file.
//
var
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  Buf: array of Byte;
  X, Y: Integer;
  P: PByte;
  C: TFPColor;
begin
  Result := false;
  if not CanRender then exit;
  if not GLBox.MakeCurrent then exit;
  DrawFrame;
  glFinish;
  SetLength(Buf, FW * FH * 4);
  glReadBuffer(GL_BACK);
  glReadPixels(0, 0, FW, FH, GL_RGBA, GL_UNSIGNED_BYTE, @Buf[0]);
  GLBox.SwapBuffers;

  Img := TFPMemoryImage.Create(FW, FH);
  Writer := TFPWriterPNG.Create;
  try
    Writer.UseAlpha := false;
    Writer.WordSized := false;
    C.Alpha := $FFFF;
    for Y := 0 to FH - 1 do
    begin
      P := @Buf[(FH - 1 - Y) * FW * 4];   // OpenGL rows run bottom to top
      for X := 0 to FW - 1 do
      begin
        C.Red := P[0] * 257;
        C.Green := P[1] * 257;
        C.Blue := P[2] * 257;
        Img.Colors[X, Y] := C;
        Inc(P, 4);
      end;
    end;
    Img.SaveToFile(FileName, Writer);
    Result := true;
  finally
    Writer.Free;
    Img.Free;
  end;
end;

procedure TView3DFrame.InitGL;
begin
  glShadeModel(GL_SMOOTH);
  glDisable(GL_CULL_FACE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glEnable(GL_MULTISAMPLE);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glEnable(GL_LINE_SMOOTH);
  glEnable(GL_POINT_SMOOTH);
  glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
  glHint(GL_POINT_SMOOTH_HINT, GL_NICEST);
  glDepthFunc(GL_LEQUAL);
  FGLReady := true;
end;

procedure TView3DFrame.DrawFrame;
var
  I: Integer;
begin
  if not FGLReady then InitGL;
  FW := GLBox.Width;
  FH := GLBox.Height;
  FPixScale := Screen.PixelsPerInch / 96;
  for I := 0 to FTextCount - 1 do
    FTexts[I].Used := false;

  glViewport(0, 0, FW, FH);
  glDepthMask(GL_TRUE);
  glClearColor(0.05, 0.07, 0.11, 1);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
  DrawBackground;
  if not FActive then exit;

  if FMode = vmValve then
  begin
    DrawValveScene;
    BeginOverlay;
    DrawValveOverlay;
  end
  else
  begin
    DrawNetworkScene;
    BeginOverlay;
    DrawNetworkOverlay;
  end;
  PurgeTexts;
end;

procedure TView3DFrame.DrawBackground;
begin
  BeginOverlay;
  glBegin(GL_QUADS);
    glColor3f(0.10, 0.14, 0.21);
    glVertex2f(0, 0);
    glVertex2f(FW, 0);
    glColor3f(0.03, 0.04, 0.07);
    glVertex2f(FW, FH);
    glVertex2f(0, FH);
  glEnd;
end;

procedure TView3DFrame.SetupCamera(const Cam: TCamera);
var
  Aspect, ZNear, ZFar, HalfH: Double;
begin
  Aspect := FW / Max(FH, 1);
  ZNear := Max(Cam.Dist * 0.05, 0.01);
  ZFar := Cam.Dist * 6 + 20;
  HalfH := ZNear * Tan(DegToRad(FieldOfView) / 2);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glFrustum(-HalfH * Aspect, HalfH * Aspect, -HalfH, HalfH, ZNear, ZFar);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
  glTranslatef(0, 0, -Cam.Dist);
  glRotatef(Cam.Pitch - 90, 1, 0, 0);
  glRotatef(-Cam.Yaw, 0, 0, 1);
  glTranslatef(-Cam.X, -Cam.Y, -Cam.Z);
  glGetDoublev(GL_MODELVIEW_MATRIX, @FMV[0]);
  glGetDoublev(GL_PROJECTION_MATRIX, @FPR[0]);
  glEnable(GL_DEPTH_TEST);
  glDepthMask(GL_TRUE);
end;

procedure TView3DFrame.BeginOverlay;
//
//  Draw in pixels from the top left corner, on top of everything.
//
begin
  glDisable(GL_LIGHTING);
  glDisable(GL_DEPTH_TEST);
  glDepthMask(GL_FALSE);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glOrtho(0, FW, FH, 0, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
end;

function TView3DFrame.ToScreen(X, Y, Z: Single; out SX, SY: Single): Boolean;
//
//  Find where a point of the scene is on the display.
//
var
  E, C: array[0..3] of Double;
  I: Integer;
begin
  for I := 0 to 3 do
    E[I] := FMV[I] * X + FMV[4+I] * Y + FMV[8+I] * Z + FMV[12+I];
  for I := 0 to 3 do
    C[I] := FPR[I] * E[0] + FPR[4+I] * E[1] + FPR[8+I] * E[2] + FPR[12+I] * E[3];
  Result := C[3] > 1e-6;
  if Result then
  begin
    SX := (C[0] / C[3] * 0.5 + 0.5) * FW;
    SY := (0.5 - C[1] / C[3] * 0.5) * FH;
  end
  else
  begin
    SX := 0;
    SY := 0;
  end;
end;

function TView3DFrame.ZOf(Value: Single): Single;
begin
  Result := (Value - FZBase) * FZScale * FZExag;
end;

procedure TView3DFrame.RampColor(Pressure: Single; out R, G, B: Single);
var
  T, F: Single;
  I: Integer;
begin
  T := EnsureRange((Pressure - FPresLo) / (FPresHi - FPresLo), 0, 1) * 4;
  I := Min(Trunc(T), 3);
  F := T - I;
  R := Lerp(FRamp[I, 0], FRamp[I+1, 0], F);
  G := Lerp(FRamp[I, 1], FRamp[I+1, 1], F);
  B := Lerp(FRamp[I, 2], FRamp[I+1, 2], F);
end;

function TView3DFrame.LinkProfile(I: Integer): Integer;
//
//  Fill FProf with the points of a link's profile and return how many
//  there are. Head changes evenly along a pipe, but all at once half way
//  along a valve or a pump.
//
var
  K, N: Integer;
  E1, E2, H1, H2, P1, P2, T: Single;
  Link: PLink3D;
  Stepped, MidDone: Boolean;

  procedure Add(AX, AY, AT, AHead, APres: Single);
  begin
    if N >= Length(FProf) then SetLength(FProf, N + 64);
    FProf[N].X := AX;
    FProf[N].Y := AY;
    FProf[N].ZB := ZOf(Lerp(E1, E2, AT));
    FProf[N].ZT := ZOf(AHead);
    FProf[N].P := APres;
    Inc(N);
  end;

begin
  N := 0;
  Link := @FLinks[I];
  E1 := FNodes[Link^.N1].Elev;
  E2 := FNodes[Link^.N2].Elev;
  H1 := FNodes[Link^.N1].Head;
  H2 := FNodes[Link^.N2].Head;
  P1 := FNodes[Link^.N1].Pres;
  P2 := FNodes[Link^.N2].Pres;
  Stepped := Link^.LinkType >= EN_PUMP;
  MidDone := false;
  for K := Link^.First to Link^.First + Link^.Count - 1 do
  begin
    T := FPts[K].T;
    if not Stepped then
      Add(FPts[K].X, FPts[K].Y, T, Lerp(H1, H2, T), Lerp(P1, P2, T))
    else
    begin
      if (T > 0.5) and not MidDone then
      begin
        Add(Link^.MidX, Link^.MidY, 0.5, H1, P1);
        Add(Link^.MidX, Link^.MidY, 0.5, H2, P2);
        MidDone := true;
      end;
      if T <= 0.5 then
        Add(FPts[K].X, FPts[K].Y, T, H1, P1)
      else
        Add(FPts[K].X, FPts[K].Y, T, H2, P2);
    end;
  end;
  Result := N;
end;

procedure TView3DFrame.LinkPoint(L: PLink3D; F: Single; out X, Y: Single);
//
//  The point that lies fraction F of the way along a link.
//
var
  K: Integer;
  Seg: Single;
begin
  X := FPts[L^.First].X;
  Y := FPts[L^.First].Y;
  for K := L^.First to L^.First + L^.Count - 2 do
    if F <= FPts[K+1].T then
    begin
      Seg := FPts[K+1].T - FPts[K].T;
      if Seg > 0 then Seg := (F - FPts[K].T) / Seg;
      X := Lerp(FPts[K].X, FPts[K+1].X, Seg);
      Y := Lerp(FPts[K].Y, FPts[K+1].Y, Seg);
      exit;
    end;
end;

procedure TView3DFrame.BeginDots(Size: Single);
//
//  Start drawing round dots that are Size pixels across wherever they are
//  in the scene. (Points drawn by OpenGL itself come out square on a
//  multisampled display.)
//
const
  N = 32;
var
  X, Y: Integer;
  D: Single;
  Buf: array[0..N * N - 1] of Byte;
begin
  if (FDotTex = 0) or (glIsTexture(FDotTex) = GL_FALSE) then
  begin
    for Y := 0 to N - 1 do
      for X := 0 to N - 1 do
      begin
        D := Hypot(X - (N - 1) / 2, Y - (N - 1) / 2);
        Buf[Y * N + X] := Round(EnsureRange((N / 2 - 1 - D) / 2.5, 0, 1) * 255);
      end;
    glGenTextures(1, @FDotTex);
    glBindTexture(GL_TEXTURE_2D, FDotTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, N, N, 0, GL_ALPHA,
      GL_UNSIGNED_BYTE, @Buf[0]);
  end;

  // Dots face the camera, whose right and up directions are the first two
  // rows of the model view matrix
  FDotRadius := Size / 2 * 2 * Tan(DegToRad(FieldOfView) / 2) / Max(FH, 1);
  FDotRight[0] := FMV[0];
  FDotRight[1] := FMV[4];
  FDotRight[2] := FMV[8];
  FDotUp[0] := FMV[1];
  FDotUp[1] := FMV[5];
  FDotUp[2] := FMV[9];
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, FDotTex);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
  glBegin(GL_QUADS);
end;

procedure TView3DFrame.Dot(X, Y, Z: Single);
var
  R: Single;
begin
  // The further away a dot is, the larger it must be to look the same size
  R := -(FMV[2] * X + FMV[6] * Y + FMV[10] * Z + FMV[14]) * FDotRadius;
  if R <= 0 then exit;
  glTexCoord2f(0, 0);
  glVertex3f(X - (FDotRight[0] + FDotUp[0]) * R, Y - (FDotRight[1] + FDotUp[1]) * R,
    Z - (FDotRight[2] + FDotUp[2]) * R);
  glTexCoord2f(1, 0);
  glVertex3f(X + (FDotRight[0] - FDotUp[0]) * R, Y + (FDotRight[1] - FDotUp[1]) * R,
    Z + (FDotRight[2] - FDotUp[2]) * R);
  glTexCoord2f(1, 1);
  glVertex3f(X + (FDotRight[0] + FDotUp[0]) * R, Y + (FDotRight[1] + FDotUp[1]) * R,
    Z + (FDotRight[2] + FDotUp[2]) * R);
  glTexCoord2f(0, 1);
  glVertex3f(X - (FDotRight[0] - FDotUp[0]) * R, Y - (FDotRight[1] - FDotUp[1]) * R,
    Z - (FDotRight[2] - FDotUp[2]) * R);
end;

procedure TView3DFrame.EndDots;
begin
  glEnd;
  glDisable(GL_TEXTURE_2D);
end;

{------------------------------------------------------------------------------
  Network view
------------------------------------------------------------------------------}

procedure TView3DFrame.DrawNetworkScene;
begin
  SetupCamera(FCam[vmNetwork]);
  DrawGround;
  DrawPipes;
  DrawStorage;
  if not FHasResults then exit;
  DrawGradeLine;
  glDepthMask(GL_FALSE);
  if SurfaceBox.Checked then DrawSurface;
  DrawSteps;
  if FlowBox.Checked then DrawFlow;
  glDepthMask(GL_TRUE);
end;

procedure TView3DFrame.DrawGround;
const
  Margin = 0.12;
  Spacing = 0.25;
  Z = -0.03;
var
  EX, EY, V: Single;
  I, K: Integer;
  E1, E2: Single;
  Link: PLink3D;
begin
  EX := Ceil((FExtX + Margin) / Spacing) * Spacing;
  EY := Ceil((FExtY + Margin) / Spacing) * Spacing;

  glDepthMask(GL_FALSE);
  glColor4f(0.16, 0.21, 0.30, 0.35);
  glBegin(GL_QUADS);
    glVertex3f(-EX, -EY, Z);
    glVertex3f(EX, -EY, Z);
    glVertex3f(EX, EY, Z);
    glVertex3f(-EX, EY, Z);
  glEnd;

  glLineWidth(1);
  glColor4f(1, 1, 1, 0.08);
  glBegin(GL_LINES);
  V := -EX;
  while V <= EX + 1e-4 do
  begin
    glVertex3f(V, -EY, Z);
    glVertex3f(V, EY, Z);
    V := V + Spacing;
  end;
  V := -EY;
  while V <= EY + 1e-4 do
  begin
    glVertex3f(-EX, V, Z);
    glVertex3f(EX, V, Z);
    V := V + Spacing;
  end;
  glEnd;

  // The network's plan and, at each node, how far above it the pipes are
  glLineWidth(1.2 * FPixScale);
  glBegin(GL_LINES);
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if not Link^.OnMap then continue;
    glColor4f(0.45, 0.58, 0.78, 0.30);
    for K := Link^.First to Link^.First + Link^.Count - 2 do
    begin
      glVertex3f(FPts[K].X, FPts[K].Y, Z);
      glVertex3f(FPts[K+1].X, FPts[K+1].Y, Z);
    end;
    if FLinkCount > 400 then continue;
    E1 := ZOf(FNodes[Link^.N1].Elev);
    E2 := ZOf(FNodes[Link^.N2].Elev);
    glColor4f(0.45, 0.58, 0.78, 0.10);
    glVertex3f(FNodes[Link^.N1].X, FNodes[Link^.N1].Y, Z);
    glVertex3f(FNodes[Link^.N1].X, FNodes[Link^.N1].Y, E1);
    glVertex3f(FNodes[Link^.N2].X, FNodes[Link^.N2].Y, Z);
    glVertex3f(FNodes[Link^.N2].X, FNodes[Link^.N2].Y, E2);
  end;
  glEnd;
  glDepthMask(GL_TRUE);
end;

procedure TView3DFrame.DrawPipes;
var
  I, K: Integer;
  E1, E2, R, G, B: Single;
  Link: PLink3D;
  Node: PNode3D;
begin
  glLineWidth(1.8 * FPixScale);
  glBegin(GL_LINES);
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if not Link^.OnMap then continue;
    if Link^.LinkType >= EN_PRV then
      glColor3f(1.0, 0.55, 0.25)
    else if Link^.LinkType = EN_PUMP then
      glColor3f(0.40, 0.90, 0.50)
    else
      glColor3f(0.74, 0.79, 0.86);
    E1 := FNodes[Link^.N1].Elev;
    E2 := FNodes[Link^.N2].Elev;
    for K := Link^.First to Link^.First + Link^.Count - 2 do
    begin
      glVertex3f(FPts[K].X, FPts[K].Y, ZOf(Lerp(E1, E2, FPts[K].T)));
      glVertex3f(FPts[K+1].X, FPts[K+1].Y, ZOf(Lerp(E1, E2, FPts[K+1].T)));
    end;
  end;
  glEnd;

  // Junctions, colored by pressure
  if FNodeCount > 6000 then exit;
  glDepthMask(GL_FALSE);
  BeginDots(6.5 * FPixScale);
  for I := 1 to FNodeCount do
  begin
    Node := @FNodes[I];
    if not Node^.OnMap or (Node^.NodeType <> ntJunction) then continue;
    if FHasResults and (Node^.ResIndex > 0) then
    begin
      RampColor(Node^.Pres, R, G, B);
      glColor3f(R, G, B);
    end
    else
      glColor3f(0.74, 0.79, 0.86);
    Dot(Node^.X, Node^.Y, ZOf(Node^.Elev));
  end;
  EndDots;
  glDepthMask(GL_TRUE);
end;

procedure TView3DFrame.DrawStorage;
//
//  Tanks are drawn as cylinders filled to their water level and reservoirs
//  as slabs at their water surface.
//
const
  Segs = 20;
  TankRadius = 0.035;
  PoolSize = 0.055;
var
  I, K: Integer;
  A, Z0, Z1, ZW, Shade: Single;
  Node: PNode3D;
begin
  for I := 1 to FNodeCount do
  begin
    Node := @FNodes[I];
    if not Node^.OnMap or (Node^.NodeType = ntJunction) then continue;

    if Node^.NodeType = ntReservoir then
    begin
      Z1 := ZOf(Node^.Elev);
      Z0 := Z1 - 0.025;
      glBegin(GL_QUADS);
      glColor3f(0.30, 0.62, 0.98);
      glVertex3f(Node^.X - PoolSize, Node^.Y - PoolSize, Z1);
      glVertex3f(Node^.X + PoolSize, Node^.Y - PoolSize, Z1);
      glVertex3f(Node^.X + PoolSize, Node^.Y + PoolSize, Z1);
      glVertex3f(Node^.X - PoolSize, Node^.Y + PoolSize, Z1);
      for K := 0 to 3 do
      begin
        A := Pi / 4 + K * Pi / 2;
        Shade := 0.55 + 0.25 * Cos(A - 0.6);
        glColor3f(0.20 * Shade, 0.42 * Shade, 0.80 * Shade);
        glVertex3f(Node^.X + PoolSize * Sqrt(2) * Cos(A),
                   Node^.Y + PoolSize * Sqrt(2) * Sin(A), Z0);
        glVertex3f(Node^.X + PoolSize * Sqrt(2) * Cos(A + Pi / 2),
                   Node^.Y + PoolSize * Sqrt(2) * Sin(A + Pi / 2), Z0);
        glVertex3f(Node^.X + PoolSize * Sqrt(2) * Cos(A + Pi / 2),
                   Node^.Y + PoolSize * Sqrt(2) * Sin(A + Pi / 2), Z1);
        glVertex3f(Node^.X + PoolSize * Sqrt(2) * Cos(A),
                   Node^.Y + PoolSize * Sqrt(2) * Sin(A), Z1);
      end;
      glEnd;
      continue;
    end;

    // The water in a tank ...
    Z0 := ZOf(Node^.Elev);
    Z1 := ZOf(Node^.Elev + Node^.MaxLevel);
    if FHasResults and (Node^.ResIndex > 0) then
    begin
      ZW := ZOf(Node^.Head);
      glBegin(GL_QUAD_STRIP);
      for K := 0 to Segs do
      begin
        A := 2 * Pi * K / Segs;
        Shade := 0.6 + 0.4 * Cos(A - 0.6);
        glColor3f(0.20 * Shade, 0.50 * Shade, 0.95 * Shade);
        glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), Z0);
        glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), ZW);
      end;
      glEnd;
      glColor3f(0.40, 0.70, 1.0);
      glBegin(GL_TRIANGLE_FAN);
      glVertex3f(Node^.X, Node^.Y, ZW);
      for K := 0 to Segs do
      begin
        A := 2 * Pi * K / Segs;
        glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), ZW);
      end;
      glEnd;
    end;

    // ... and the outline of the tank itself
    glLineWidth(1.2 * FPixScale);
    glColor4f(0.85, 0.90, 0.96, 0.8);
    glBegin(GL_LINE_LOOP);
    for K := 0 to Segs - 1 do
    begin
      A := 2 * Pi * K / Segs;
      glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), Z1);
    end;
    glEnd;
    glBegin(GL_LINES);
    for K := 0 to 3 do
    begin
      A := Pi / 2 * K;
      glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), Z0);
      glVertex3f(Node^.X + TankRadius * Cos(A), Node^.Y + TankRadius * Sin(A), Z1);
    end;
    glEnd;
  end;
end;

procedure TView3DFrame.DrawGradeLine;
var
  I, K, N: Integer;
  R, G, B: Single;
  Link: PLink3D;
begin
  glLineWidth(2.4 * FPixScale);
  glBegin(GL_LINES);
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if not Link^.OnMap or (FNodes[Link^.N1].ResIndex < 1)
    or (FNodes[Link^.N2].ResIndex < 1) then continue;
    N := LinkProfile(I);
    for K := 0 to N - 2 do
    begin
      RampColor(FProf[K].P, R, G, B);
      glColor3f(R, G, B);
      glVertex3f(FProf[K].X, FProf[K].Y, FProf[K].ZT);
      RampColor(FProf[K+1].P, R, G, B);
      glColor3f(R, G, B);
      glVertex3f(FProf[K+1].X, FProf[K+1].Y, FProf[K+1].ZT);
    end;
  end;
  glEnd;
end;

procedure TView3DFrame.DrawSurface;
//
//  Fill the space between each link and its grade line.
//
const
  TopAlpha = 0.50;
  BaseAlpha = 0.10;
var
  I, K, N: Integer;
  R, G, B: Single;
  Link: PLink3D;
begin
  glBegin(GL_QUADS);
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if not Link^.OnMap or (FNodes[Link^.N1].ResIndex < 1)
    or (FNodes[Link^.N2].ResIndex < 1) then continue;
    N := LinkProfile(I);
    for K := 0 to N - 2 do
    begin
      RampColor(FProf[K].P, R, G, B);
      glColor4f(R, G, B, BaseAlpha);
      glVertex3f(FProf[K].X, FProf[K].Y, FProf[K].ZB);
      glColor4f(R, G, B, TopAlpha);
      glVertex3f(FProf[K].X, FProf[K].Y, FProf[K].ZT);
      RampColor(FProf[K+1].P, R, G, B);
      glColor4f(R, G, B, TopAlpha);
      glVertex3f(FProf[K+1].X, FProf[K+1].Y, FProf[K+1].ZT);
      glColor4f(R, G, B, BaseAlpha);
      glVertex3f(FProf[K+1].X, FProf[K+1].Y, FProf[K+1].ZB);
    end;
  end;
  glEnd;
end;

procedure TView3DFrame.DrawSteps;
//
//  Mark the head removed by each valve and added by each pump with a
//  panel that stands across the link.
//
const
  HalfWidth = 0.05;
var
  I: Integer;
  Z1, Z2, ZP, PX, PY, R, G, B: Single;
  Link: PLink3D;
begin
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if (Link^.LinkType < EN_PUMP) or not Link^.OnMap
    or (FNodes[Link^.N1].ResIndex < 1) or (FNodes[Link^.N2].ResIndex < 1) then
      continue;
    Z1 := ZOf(FNodes[Link^.N1].Head);
    Z2 := ZOf(FNodes[Link^.N2].Head);
    ZP := ZOf((FNodes[Link^.N1].Elev + FNodes[Link^.N2].Elev) / 2);
    PX := -Link^.DirY * HalfWidth;
    PY := Link^.DirX * HalfWidth;
    if Link^.LinkType = EN_PUMP then
    begin
      R := 0.35;
      G := 0.92;
      B := 0.50;
    end
    else
    begin
      R := 1.0;
      G := 0.42;
      B := 0.20;
    end;

    // A post from the link up to the higher of the two heads
    glLineWidth(1.2 * FPixScale);
    glColor4f(1, 1, 1, 0.45);
    glBegin(GL_LINES);
      glVertex3f(Link^.MidX, Link^.MidY, ZP);
      glVertex3f(Link^.MidX, Link^.MidY, Max(Z1, Z2));
    glEnd;
    if Abs(Z1 - Z2) < 1e-4 then continue;

    glColor4f(R, G, B, 0.62);
    glBegin(GL_QUADS);
      glVertex3f(Link^.MidX - PX, Link^.MidY - PY, Z1);
      glVertex3f(Link^.MidX + PX, Link^.MidY + PY, Z1);
      glVertex3f(Link^.MidX + PX, Link^.MidY + PY, Z2);
      glVertex3f(Link^.MidX - PX, Link^.MidY - PY, Z2);
    glEnd;
    glLineWidth(1.6 * FPixScale);
    glColor4f(R, G, B, 1);
    glBegin(GL_LINE_LOOP);
      glVertex3f(Link^.MidX - PX, Link^.MidY - PY, Z1);
      glVertex3f(Link^.MidX + PX, Link^.MidY + PY, Z1);
      glVertex3f(Link^.MidX + PX, Link^.MidY + PY, Z2);
      glVertex3f(Link^.MidX - PX, Link^.MidY - PY, Z2);
    glEnd;
  end;
end;

procedure TView3DFrame.DrawFlow;
//
//  Markers that travel along each pipe at a speed in proportion to its
//  flow velocity.
//
const
  Spacing = 0.07;
var
  I, K, N: Integer;
  F, X, Y, E1, E2: Single;
  Link: PLink3D;
begin
  glColor4f(1, 1, 1, 0.9);
  if FLinkCount > 2000 then
    BeginDots(3.5 * FPixScale)
  else
    BeginDots(5 * FPixScale);
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if not Link^.OnMap or (Link^.ResIndex < 1) or (Link^.Len <= 1e-6)
    or (Abs(Link^.Vel) < FVelMax * 1e-3) or (Link^.Status <= STATUS_CLOSED) then
      continue;
    E1 := FNodes[Link^.N1].Elev;
    E2 := FNodes[Link^.N2].Elev;

    // Only some of the links shorter than the spacing carry a marker, so
    // that a network of many short pipes is not buried under markers
    N := Min(Round(Link^.Len / Spacing), 40);
    if N = 0 then
    begin
      if (I * 7919) mod 1000 >= Link^.Len / Spacing * 1000 then continue;
      N := 1;
    end;
    for K := 0 to N - 1 do
    begin
      F := Link^.Phase + K / N;
      F := F - Floor(F);
      LinkPoint(Link, F, X, Y);
      Dot(X, Y, ZOf(Lerp(E1, E2, F)) + 0.003);
    end;
  end;
  EndDots;
end;

procedure TView3DFrame.DrawNetworkOverlay;
var
  I, N, Labels: Integer;
  S, M, SX, SY, TX, TY, DX, DY, D, W, H, R, G, B, X, Y, Z: Single;
  Link: PLink3D;
  Node: PNode3D;
  Txt: string;
  Marked: Boolean;
begin
  S := FPixScale;
  M := 14 * S;
  FIconCount := 0;
  Labels := 0;

  // Valves and pumps: a symbol on the link and a label above its step
  for I := 1 to FLinkCount do
  begin
    Link := @FLinks[I];
    if (Link^.LinkType < EN_PUMP) or not Link^.OnMap then continue;
    Z := ZOf((FNodes[Link^.N1].Elev + FNodes[Link^.N2].Elev) / 2);
    if not ToScreen(Link^.MidX, Link^.MidY, Z, SX, SY) then continue;
    if not ToScreen(Link^.MidX + Link^.DirX * 0.01, Link^.MidY + Link^.DirY * 0.01,
      Z, TX, TY) then continue;
    DX := TX - SX;
    DY := TY - SY;
    D := Hypot(DX, DY);
    if D < 1e-6 then
    begin
      DX := 1;
      DY := 0;
    end
    else
    begin
      DX := DX / D;
      DY := DY / D;
    end;
    Marked := (I = FHotLink) or (I = FPendingValve);

    if Link^.LinkType = EN_PUMP then
    begin
      glColor4f(0.05, 0.07, 0.10, 1);
      Disc2D(SX, SY, 7.5 * S);
      glColor4f(0.40, 0.92, 0.52, 1);
      Disc2D(SX, SY, 6 * S);
    end
    else
    begin
      // Two triangles that meet point to point
      if Marked then D := 11 * S else D := 8.5 * S;
      glColor4f(0.05, 0.07, 0.10, 1);
      Disc2D(SX, SY, D + 2.5 * S);
      if Marked then glColor4f(1, 0.95, 0.4, 1) else glColor4f(1.0, 0.55, 0.22, 1);
      glBegin(GL_TRIANGLES);
        glVertex2f(SX, SY);
        glVertex2f(SX - DX * D - DY * D * 0.7, SY - DY * D + DX * D * 0.7);
        glVertex2f(SX - DX * D + DY * D * 0.7, SY - DY * D - DX * D * 0.7);
        glVertex2f(SX, SY);
        glVertex2f(SX + DX * D - DY * D * 0.7, SY + DY * D + DX * D * 0.7);
        glVertex2f(SX + DX * D + DY * D * 0.7, SY + DY * D - DX * D * 0.7);
      glEnd;
      if FIconCount >= Length(FIcons) then SetLength(FIcons, FIconCount + 32);
      FIcons[FIconCount].Link := I;
      FIcons[FIconCount].X := SX;
      FIcons[FIconCount].Y := SY;
      Inc(FIconCount);
    end;

    if not LabelsBox.Checked or (Labels >= MaxLabels) then continue;
    Inc(Labels);
    if Link^.LinkType = EN_PUMP then
      Txt := rsPump + ' ' + project.GetID(ctLinks, I)
    else
      Txt := project.ValveTypeStr[EnsureRange(Link^.LinkType - EN_PRV, 0,
        High(ValveTypeStr))] + ' ' + project.GetID(ctLinks, I);
    if FHasResults and (FNodes[Link^.N1].ResIndex > 0)
    and (FNodes[Link^.N2].ResIndex > 0) then
    begin
      Z := ZOf(Max(FNodes[Link^.N1].Head, FNodes[Link^.N2].Head));
      if Link^.LinkType = EN_PUMP then
        Txt := Txt + Format('   +%s %s', [Fmt(FNodes[Link^.N2].Head -
          FNodes[Link^.N1].Head), LengthUnits])
      else
        Txt := Txt + Format('   %s → %s %s', [Fmt(FNodes[Link^.N1].Pres),
          Fmt(FNodes[Link^.N2].Pres), PresUnitsStr]);
    end;
    if not ToScreen(Link^.MidX, Link^.MidY, Z, TX, TY) then continue;
    W := TextWidth(Txt, 9, true);
    H := TextHeight(9, true);
    X := Round(TX - W / 2);
    Y := Round(TY - 12 * S - H);
    if Link^.LinkType = EN_PUMP then
    begin
      R := 0.40; G := 0.92; B := 0.52;
    end
    else
    begin
      R := 1.0; G := 0.55; B := 0.22;
    end;
    FillRect2D(X - 6 * S, Y - 3 * S, X + W + 6 * S, Y + H + 3 * S,
      0.04, 0.06, 0.09, 0.80);
    glLineWidth(1);
    FrameRect2D(X - 6 * S, Y - 3 * S, X + W + 6 * S, Y + H + 3 * S, R, G, B, 0.9);
    PutText(X, Y, Txt, 9, true, 1, 1, 1);
  end;

  // Tanks and reservoirs
  N := 0;
  if LabelsBox.Checked then
    for I := 1 to FNodeCount do
    begin
      Node := @FNodes[I];
      if not Node^.OnMap or (Node^.NodeType = ntJunction) then continue;
      if N >= MaxLabels then break;
      Inc(N);
      if Node^.NodeType = ntTank then
        Z := ZOf(Node^.Elev + Node^.MaxLevel)
      else
        Z := ZOf(Node^.Elev);
      if not ToScreen(Node^.X, Node^.Y, Z, SX, SY) then continue;
      Txt := project.GetID(ctNodes, I);
      if FHasResults and (Node^.ResIndex > 0) then
        Txt := Txt + Format('   %s %s', [Fmt(Node^.Head), LengthUnits]);
      PutText(SX, SY - 10 * S - TextHeight(9, false), Txt, 9, false,
        0.75, 0.88, 1.0, taCenter);
    end;

  // Title and time
  PutText(M, M, rs3dTitle, 13, true, 1, 1, 1);
  Y := M + TextHeight(13, true) + 3 * S;
  if not FHasResults then
    DrawNoResults
  else
  begin
    I := project.GetStatisticsType;
    if I <> 0 then
      Txt := project.StatisticStr[I]
    else if FPeriods > 1 then
      Txt := results.GetTimeStr(FPeriod) + '   (' + utils.TimeOfDayStr(
        project.StartTime + FPeriod * results.Rstep + results.Rstart) + ')'
    else
      Txt := '';
    PutText(M, Y, Txt, 10, false, 0.80, 0.86, 0.94);

    // Pressure legend
    W := 190 * S;
    H := 10 * S;
    X := M;
    Y := FH - M - H - TextHeight(8, false) - 4 * S;
    PutText(X, Y - TextHeight(9, true) - 4 * S,
      rsPressure + ' (' + PresUnitsStr + ')', 9, true, 1, 1, 1);
    glBegin(GL_QUAD_STRIP);
    for I := 0 to 32 do
    begin
      RampColor(Lerp(FPresLo, FPresHi, I / 32), R, G, B);
      glColor4f(R, G, B, 1);
      glVertex2f(X + W * I / 32, Y);
      glVertex2f(X + W * I / 32, Y + H);
    end;
    glEnd;
    PutText(X, Y + H + 3 * S, Fmt(FPresLo), 8, false, 0.80, 0.86, 0.94);
    PutText(X + W / 2, Y + H + 3 * S, Fmt((FPresLo + FPresHi) / 2), 8, false,
      0.80, 0.86, 0.94, taCenter);
    PutText(X + W, Y + H + 3 * S, Fmt(FPresHi), 8, false, 0.80, 0.86, 0.94,
      taRightJustify);
  end;

  PutText(FW - M, FH - M - TextHeight(8, false), rs3dNetworkHelp, 8, false,
    0.60, 0.67, 0.76, taRightJustify);
end;

procedure TView3DFrame.DrawNoResults;
//
//  Say why there are no pressures or flows on display and how to get them.
//  (Results are removed when, for instance, the project's units are changed.)
//
var
  S, W, H, X0, Y0: Single;
begin
  S := FPixScale;
  H := TextHeight(14, true);
  W := Max(TextWidth(rs3dNoResults, 14, true),
    TextWidth(rs3dRunAnalysis, 10, false)) + 44 * S;
  X0 := Round((FW - W) / 2);
  Y0 := Round(FH * 0.11);
  FillRect2D(X0, Y0, X0 + W, Y0 + H + TextHeight(10, false) + 30 * S,
    0.04, 0.06, 0.09, 0.90);
  glLineWidth(1.5 * S);
  FrameRect2D(X0, Y0, X0 + W, Y0 + H + TextHeight(10, false) + 30 * S,
    1.0, 0.72, 0.35, 1);
  PutText(FW / 2, Y0 + 12 * S, rs3dNoResults, 14, true, 1.0, 0.80, 0.45,
    taCenter);
  PutText(FW / 2, Y0 + 16 * S + H, rs3dRunAnalysis, 10, false,
    0.90, 0.93, 0.97, taCenter);
end;

{------------------------------------------------------------------------------
  Valve view
------------------------------------------------------------------------------}

procedure TView3DFrame.DrawValveScene;
const
  LightDir: array[0..3] of GLfloat = (-0.35, -0.75, 0.6, 0);
  Ambient:  array[0..3] of GLfloat = (0.38, 0.38, 0.40, 1);
  Diffuse:  array[0..3] of GLfloat = (0.80, 0.80, 0.78, 1);
  R0 = BoreRadius;
var
  Info: TValveInfo;
  Cam: TCamera;
  I, Pass: Integer;
  Lift, Gate, X, Y, Z, W, ZFree, YFree, ZGap, YGap, A, Mix: Single;
  R1, G1, B1, R2, G2, B2: Single;
begin
  if not GetValveInfo(FValve, Info) then exit;

  // Stand further back in a narrow window so the whole valve is seen
  Cam := FCam[vmValve];
  Cam.Dist := Cam.Dist * Max(1, 1.45 / (FW / Max(FH, 1)));
  SetupCamera(Cam);

  // Colors of the water on each side
  if Info.HasResults then
  begin
    RampColor(Info.PresIn, R1, G1, B1);
    RampColor(Info.PresOut, R2, G2, B2);
  end
  else
  begin
    R1 := 0.45; G1 := 0.65; B1 := 0.90;
    R2 := R1; G2 := G1; B2 := B1;
  end;
  if Info.OpeningKnown then Lift := Info.Opening else Lift := 0;
  Lift := Lift * 2 * R0;

  glEnable(GL_LIGHTING);
  glEnable(GL_LIGHT0);
  glEnable(GL_NORMALIZE);
  glEnable(GL_COLOR_MATERIAL);
  glColorMaterial(GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE);
  glLightModeli(GL_LIGHT_MODEL_TWO_SIDE, 1);
  glLightfv(GL_LIGHT0, GL_POSITION, @LightDir[0]);
  glLightfv(GL_LIGHT0, GL_AMBIENT, @Ambient[0]);
  glLightfv(GL_LIGHT0, GL_DIFFUSE, @Diffuse[0]);

  // Flanges
  glColor3f(0.55, 0.59, 0.64);
  for I := 0 to 1 do
  begin
    X := 1.08 - 2.36 * I;       // 1.08 and -1.28
    TubeX(X, X + 0.2, 0.74);
    RingX(X, R0, 0.74, -1);
    RingX(X + 0.2, R0, 0.74, 1);
    X := (HalfLength - 0.12) * (1 - 2 * I) - 0.06;
    TubeX(X, X + 0.12, 0.62);
    RingX(X, R0, 0.62, -1);
    RingX(X + 0.12, R0, 0.62, 1);
  end;

  // The closure element and its stem
  glColor3f(0.90, 0.58, 0.20);
  TubeX(-0.08, 0.08, R0 * 0.97, Lift);
  RingX(-0.08, 0, R0 * 0.97, -1, Lift);
  RingX(0.08, 0, R0 * 0.97, 1, Lift);
  glColor3f(0.70, 0.73, 0.78);
  TubeZ(Lift + R0 * 0.9, 1.75, 0.055, 16);

  // The actuator on top
  glColor3f(0.16, 0.42, 0.78);
  TubeZ(1.60, 1.80, 0.82);
  RingZ(1.60, 0, 0.82, -1);
  RingZ(1.80, 0, 0.82, 1);
  Ellipsoid(1.80, 0.80, 0.80, 0.30, true);
  glColor3f(0.70, 0.73, 0.78);
  TubeZ(2.08, 2.38, 0.07, 16);
  RingZ(2.38, 0, 0.07, 1, 16);

  // The line that brings the downstream pressure to the actuator
  glDisable(GL_LIGHTING);
  glLineWidth(3 * FPixScale);
  glColor3f(0.85, 0.55, 0.32);
  glBegin(GL_LINE_STRIP);
    glVertex3f(2.0, 0, R0);
    glVertex3f(2.0, 0, 1.25);
    glVertex3f(1.1, 0, 1.70);
    glVertex3f(0.82, 0, 1.70);
  glEnd;

  // Everything from here on is seen through, so it leaves no trace in the
  // depth buffer: first, water moving through the bore and under the
  // closure element
  glDepthMask(GL_FALSE);
  if Info.HasResults then
  begin
    Gate := Max(Lift / (2 * R0), 0.05);
    BeginDots(6.5 * FPixScale);
    for I := 0 to High(FParticles) do
    begin
      X := (FParticles[I].U - 0.5) * 2 * HalfLength;
      YFree := Cos(FParticles[I].A) * FParticles[I].B * R0 * 0.88;
      ZFree := Sin(FParticles[I].A) * FParticles[I].B * R0 * 0.88;

      // Where the particle would pass through the gap
      ZGap := -R0 + (ZFree / (R0 * 0.88) * 0.5 + 0.5) * Gate * 2 * R0 * 0.9
        + 0.02;
      YGap := YFree / (R0 * 0.88) * Sqrt(Max(Sqr(R0) - Sqr(ZGap), 0)) * 0.85;
      W := Exp(-Sqr(X / 0.42));
      Y := Lerp(YFree, YGap, W);
      Z := Lerp(ZFree, ZGap, W);

      // The jet breaks up downstream of a throttled valve
      if X > 0 then
      begin
        A := 0.11 * (1 - Gate) * Exp(-X / 1.3);
        Y := Y + A * Sin(FParticles[I].Seed * 37 + FClock * 9 + X * 7);
        Z := Z + A * Cos(FParticles[I].Seed * 51 + FClock * 8 + X * 6);
        A := Hypot(Y, Z);
        if A > R0 * 0.92 then
        begin
          Y := Y * R0 * 0.92 / A;
          Z := Z * R0 * 0.92 / A;
        end;
      end;
      Mix := SmoothStep((X + 0.2) / 0.5);
      glColor4f(Lerp(R1, R2, Mix), Lerp(G1, G2, Mix), Lerp(B1, B2, Mix), 0.95);
      Dot(X, Y, Z);
    end;
    EndDots;
  end;

  // Then the body of water on each side and the shells around it
  if Info.HasResults then
  begin
    glColor4f(R1, G1, B1, 0.20);
    TubeX(-HalfLength, -0.08, R0 * 0.96);
    glColor4f(R2, G2, B2, 0.20);
    TubeX(0.08, HalfLength, R0 * 0.96);
  end;
  glEnable(GL_LIGHTING);
  glEnable(GL_CULL_FACE);
  for Pass := 0 to 1 do
  begin
    // Far sides first, then near sides
    if Pass = 0 then glCullFace(GL_FRONT) else glCullFace(GL_BACK);
    glColor4f(0.78, 0.86, 0.95, 0.16);
    TubeX(-HalfLength, -1.08, R0);
    TubeX(1.08, HalfLength, R0);
    TubeZ(0.62, 1.60, 0.52);
    glColor4f(0.78, 0.86, 0.95, 0.20);
    Ellipsoid(0.05, 1.10, 0.74, 0.80, false);
  end;
  glDisable(GL_CULL_FACE);
  glDisable(GL_LIGHTING);
  glDisable(GL_COLOR_MATERIAL);
  glDepthMask(GL_TRUE);
end;

procedure TView3DFrame.DrawGauge(CX, CY, R, Value, MaxValue: Single;
  const Title, Units: string);
const
  StartAngle = 225;
  Sweep = 270;
  Segs = 54;
var
  I: Integer;
  A, C, S, F, CR, CG, CB: Single;
begin
  glColor4f(0.05, 0.07, 0.10, 0.92);
  Disc2D(CX, CY, R);

  // Scale, in the colors that pressures have everywhere else
  glBegin(GL_QUAD_STRIP);
  for I := 0 to Segs do
  begin
    F := I / Segs;
    A := DegToRad(StartAngle - Sweep * F);
    C := Cos(A);
    S := Sin(A);
    RampColor(F * MaxValue, CR, CG, CB);
    glColor4f(CR, CG, CB, 1);
    glVertex2f(CX + R * 0.80 * C, CY - R * 0.80 * S);
    glVertex2f(CX + R * 0.93 * C, CY - R * 0.93 * S);
  end;
  glEnd;
  glLineWidth(1.5 * FPixScale);
  glColor4f(0.80, 0.86, 0.94, 1);
  Circle2D(CX, CY, R);
  glBegin(GL_LINES);
  for I := 0 to 10 do
  begin
    A := DegToRad(StartAngle - Sweep * I / 10);
    if Odd(I) then F := 0.74 else F := 0.68;
    glVertex2f(CX + R * F * Cos(A), CY - R * F * Sin(A));
    glVertex2f(CX + R * 0.80 * Cos(A), CY - R * 0.80 * Sin(A));
  end;
  glEnd;

  // Needle
  F := EnsureRange(Value / MaxValue, 0, 1.04);
  A := DegToRad(StartAngle - Sweep * F);
  glLineWidth(2.6 * FPixScale);
  glColor4f(1, 1, 1, 1);
  glBegin(GL_LINES);
    glVertex2f(CX - R * 0.14 * Cos(A), CY + R * 0.14 * Sin(A));
    glVertex2f(CX + R * 0.74 * Cos(A), CY - R * 0.74 * Sin(A));
  glEnd;
  Disc2D(CX, CY, R * 0.07);

  PutText(CX, CY - R - TextHeight(10, true) - 5 * FPixScale, Title, 10, true,
    1, 1, 1, taCenter);
  PutText(CX, CY + R * 0.28, Fmt(Value), 12, true, 1, 1, 1, taCenter);
  PutText(CX, CY + R * 0.28 + TextHeight(12, true) - 2 * FPixScale, Units, 8,
    false, 0.75, 0.82, 0.90, taCenter);
  PutText(CX - R * 0.84, CY + R * 0.80, '0', 8, false, 0.75, 0.82, 0.90, taCenter);
  PutText(CX + R * 0.84, CY + R * 0.80, Fmt(MaxValue, 0), 8, false,
    0.75, 0.82, 0.90, taCenter);
end;

procedure TView3DFrame.DrawChart(X0, Y0, X1, Y1: Single; const Info: TValveInfo);
//
//  Upstream and downstream pressure over the whole simulation, with a
//  marker at the time period on display.
//
var
  T, N: Integer;
  S, X, PX0, PX1, PY0, PY1, H: Single;

  function XOf(Period: Single): Single;
  begin
    Result := PX0 + (PX1 - PX0) * Period / Max(N - 1, 1);
  end;

  function YOf(Pressure: Single): Single;
  begin
    Result := PY1 - (PY1 - PY0) * EnsureRange(Pressure / FGaugeMax, 0, 1);
  end;

begin
  N := Length(FSerIn);
  if N < 2 then exit;
  S := FPixScale;
  H := TextHeight(8, false);
  PX0 := X0 + 38 * S;
  PX1 := X1 - 12 * S;
  PY0 := Y0 + H + 10 * S;
  PY1 := Y1 - H - 8 * S;

  FillRect2D(X0, Y0, X1, Y1, 0.04, 0.06, 0.09, 0.72);
  glLineWidth(1);
  FrameRect2D(X0, Y0, X1, Y1, 1, 1, 1, 0.12);
  glColor4f(1, 1, 1, 0.14);
  glBegin(GL_LINES);
    glVertex2f(PX0, PY0);
    glVertex2f(PX1, PY0);
    glVertex2f(PX0, (PY0 + PY1) / 2);
    glVertex2f(PX1, (PY0 + PY1) / 2);
    glVertex2f(PX0, PY1);
    glVertex2f(PX1, PY1);
  glEnd;

  glLineWidth(2 * S);
  glColor4f(1.0, 0.72, 0.35, 1);
  glBegin(GL_LINE_STRIP);
  for T := 0 to N - 1 do
    glVertex2f(XOf(T), YOf(FSerIn[T]));
  glEnd;
  glColor4f(0.45, 0.85, 1.0, 1);
  glBegin(GL_LINE_STRIP);
  for T := 0 to N - 1 do
    glVertex2f(XOf(T), YOf(FSerOut[T]));
  glEnd;

  // The time on display
  X := XOf(EnsureRange(FPeriod, 0, N - 1));
  glLineWidth(1.4 * S);
  glColor4f(1, 1, 1, 0.75);
  glBegin(GL_LINES);
    glVertex2f(X, PY0);
    glVertex2f(X, PY1);
  glEnd;
  glColor4f(1.0, 0.72, 0.35, 1);
  Disc2D(X, YOf(Info.PresIn), 4 * S);
  glColor4f(0.45, 0.85, 1.0, 1);
  Disc2D(X, YOf(Info.PresOut), 4 * S);

  PutText(PX0, Y0 + 5 * S, rs3dUpstream + ' ' + LowerCase(rsPressure), 8, true,
    1.0, 0.72, 0.35);
  PutText(PX0 + TextWidth(rs3dUpstream + ' ' + LowerCase(rsPressure), 8, true)
    + 18 * S, Y0 + 5 * S, rs3dDownstream + ' ' + LowerCase(rsPressure), 8, true,
    0.45, 0.85, 1.0);
  PutText(PX0 - 5 * S, PY0 - H / 2, Fmt(FGaugeMax, 0), 8, false, 0.75, 0.82, 0.90,
    taRightJustify);
  PutText(PX0 - 5 * S, PY1 - H / 2, '0', 8, false, 0.75, 0.82, 0.90,
    taRightJustify);
  PutText(PX0, PY1 + 3 * S, results.GetTimeStr(0), 8, false, 0.75, 0.82, 0.90);
  PutText(PX1, PY1 + 3 * S, results.GetTimeStr(N - 1), 8, false, 0.75, 0.82, 0.90,
    taRightJustify);
end;

procedure TView3DFrame.DrawValveOverlay;
var
  Info: TValveInfo;
  S, M, X, Y, H, SX, SY, R, ChartTop: Single;
  Txt, Units: string;
  D: Integer;

  procedure Line(const AName, AValue: string);
  begin
    PutText(X, Y, AName, 9, false, 0.72, 0.79, 0.88);
    PutText(X + 132 * S, Y, AValue, 9, true, 1, 1, 1);
    Y := Y + H + 3 * S;
  end;

begin
  if not GetValveInfo(FValve, Info) then exit;
  S := FPixScale;
  M := 14 * S;
  D := config.DecimalPlaces;
  H := TextHeight(9, false);

  PutText(M, M, Info.TypeStr + ' ' + Info.ID, 13, true, 1, 1, 1);
  Y := M + TextHeight(13, true) + 2 * S;
  Txt := ValveNames[EnsureRange(FLinks[FValve].LinkType - EN_PRV, 0,
    High(ValveNames))];
  if Info.HasResults and (FPeriods > 1) and (project.GetStatisticsType = 0) then
    Txt := Txt + '   -   ' + results.GetTimeStr(FPeriod) + '   (' +
      utils.TimeOfDayStr(project.StartTime + FPeriod * results.Rstep +
      results.Rstart) + ')';
  PutText(M, Y, Txt, 10, false, 0.80, 0.86, 0.94);
  Y := Y + TextHeight(10, false) + 12 * S;
  X := M;

  if not Info.HasResults then
    DrawNoResults
  else
  begin
    // What the setting is measured in depends on the kind of valve
    case FLinks[FValve].LinkType of
      EN_PRV, EN_PSV, EN_PBV: Units := ' ' + PresUnitsStr;
      EN_FCV: Units := ' ' + project.FlowUnitsStr[project.FlowUnits];
      EN_PCV: Units := ' %';
      else Units := '';
    end;
    Line(rsStatus, Info.StatusStr);
    if FLinks[FValve].LinkType <> EN_GPV then
      Line(rsSetting, Fmt(Info.Setting, D) + Units);
    Line(rsFlow, Fmt(Info.Flow, D) + ' ' +
      project.FlowUnitsStr[project.FlowUnits]);
    if project.GetUnitsSystem = usUS then
      Line(rsVelocity, Fmt(Info.Velocity, D) + ' ' + rsFeetPerSec)
    else
      Line(rsVelocity, Fmt(Info.Velocity, D) + ' ' + rsMetersPerSec);
    Line(rs3dHeadDrop, Fmt(Info.HeadDrop, D) + ' ' + LengthUnits);
    Line(rs3dPower, Fmt(Info.PowerKW, D) + ' kW');
    if (FPeriods > 1) and (project.GetStatisticsType = 0) then
      Line(rs3dEnergy, Format('%s kWh / %s %s', [Fmt(FEnergy, 0),
        utils.Time2Str((FPeriods - 1) * results.Rstep), rsHrs]));
    if Info.LossCoeff >= 0 then
      Line(rs3dLossCoeff, Fmt(Info.LossCoeff, 1));
    if not Info.OpeningKnown then
      Line(rs3dOpening, '-')
    else if Info.OpeningEstimated then
      Line(rs3dOpening, Format('%s %%  (%s)', [Fmt(Info.Opening * 100, 0),
        rs3dEstimated]))
    else
      Line(rs3dOpening, Fmt(Info.Opening * 100, 0) + ' %');
  end;

  // Notes and the chart along the bottom
  Y := FH - M - TextHeight(8, false);
  PutText(FW - M, Y, rs3dValveHelp, 8, false, 0.60, 0.67, 0.76, taRightJustify);
  Txt := rs3dSchematic;
  if Info.OpeningEstimated then Txt := Txt + ' ' + rs3dOpeningNote;
  PutText(M, Y, Txt, 8, false, 0.60, 0.67, 0.76);
  ChartTop := Y - 8 * S;
  if Info.HasResults and (Length(FSerIn) > 1) then
  begin
    ChartTop := Y - 8 * S - 118 * S;
    DrawChart(M, ChartTop, FW - M, Y - 8 * S, Info);
  end;

  // A pressure gauge over each side of the valve
  if not Info.HasResults then exit;
  R := 54 * S;
  if ToScreen(-2.15, 0, BoreRadius, SX, SY) then
  begin
    SY := EnsureRange(SY - R - 46 * S, R + 40 * S, ChartTop - R - 24 * S);
    DrawGauge(SX, SY, R, Info.PresIn, FGaugeMax, rs3dUpstream, PresUnitsStr);
  end;
  if ToScreen(2.15, 0, BoreRadius, SX, SY) then
  begin
    SY := EnsureRange(SY - R - 46 * S, R + 40 * S, ChartTop - R - 24 * S);
    DrawGauge(SX, SY, R, Info.PresOut, FGaugeMax, rs3dDownstream, PresUnitsStr);
  end;

  // The difference between them, below the valve
  if ToScreen(0, 0, -0.85, SX, SY) then
  begin
    H := TextHeight(16, true);
    SY := Min(SY + 14 * S, ChartTop - H - TextHeight(9, false) - 6 * S);
    PutText(SX, SY, Fmt(Info.PresIn - Info.PresOut) + ' ' + PresUnitsStr, 16,
      true, 1.0, 0.62, 0.30, taCenter);
    PutText(SX, SY + H, rs3dPresDrop, 9, false, 0.80, 0.86, 0.94, taCenter);
  end;
end;

{------------------------------------------------------------------------------
  Text, drawn from textures made with the LCL
------------------------------------------------------------------------------}

function TView3DFrame.TextTexture(const S: string; Size: Integer;
  Bold: Boolean): Integer;
var
  Key: string;
  I, X, Y, W, H, TW, TH: Integer;
  Bmp: TBitmap;
  Img: TLazIntfImage;
  Buf: array of Byte;
begin
  Key := IntToStr(Size) + BoolToStr(Bold, 'b', 'n') + S;
  for I := 0 to FTextCount - 1 do
    if FTexts[I].Key = Key then
    begin
      // The texture is lost if the display had to be created again
      if glIsTexture(FTexts[I].Tex) = GL_FALSE then break;
      FTexts[I].Used := true;
      exit(I);
    end;

  // Reuse the entry of a lost texture, otherwise add one
  Result := -1;
  for I := 0 to FTextCount - 1 do
    if FTexts[I].Key = Key then Result := I;
  if Result < 0 then
  begin
    if FTextCount >= Length(FTexts) then SetLength(FTexts, FTextCount + 64);
    Result := FTextCount;
    Inc(FTextCount);
  end;

  // White text on black, whose brightness becomes the texture's opacity
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.Canvas.Font.Size := Size;
    Bmp.Canvas.Font.Quality := fqAntialiased;
    if Bold then Bmp.Canvas.Font.Style := [fsBold];
    W := Max(Bmp.Canvas.TextWidth(S), 1) + 2;
    H := Max(Bmp.Canvas.TextHeight('Mg'), 1) + 2;
    Bmp.SetSize(W, H);
    Bmp.Canvas.Brush.Color := clBlack;
    Bmp.Canvas.FillRect(0, 0, W, H);
    Bmp.Canvas.Font.Color := clWhite;
    Bmp.Canvas.Brush.Style := bsClear;
    Bmp.Canvas.TextOut(1, 1, S);

    TW := 1;
    while TW < W do TW := TW * 2;
    TH := 1;
    while TH < H do TH := TH * 2;
    SetLength(Buf, TW * TH);
    Img := Bmp.CreateIntfImage;
    try
      for Y := 0 to H - 1 do
        for X := 0 to W - 1 do
          Buf[Y * TW + X] := Img.Colors[X, Y].Green shr 8;
    finally
      Img.Free;
    end;
  finally
    Bmp.Free;
  end;

  FTexts[Result].Key := Key;
  FTexts[Result].W := W;
  FTexts[Result].H := H;
  FTexts[Result].U := W / TW;
  FTexts[Result].V := H / TH;
  FTexts[Result].Used := true;
  glGenTextures(1, @FTexts[Result].Tex);
  glBindTexture(GL_TEXTURE_2D, FTexts[Result].Tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, TW, TH, 0, GL_ALPHA,
    GL_UNSIGNED_BYTE, @Buf[0]);
end;

procedure TView3DFrame.PurgeTexts;
//
//  Values change all the time, so texts that are no longer shown are
//  dropped once there are many of them.
//
var
  I, N: Integer;
begin
  if FTextCount < 240 then exit;
  N := 0;
  for I := 0 to FTextCount - 1 do
    if FTexts[I].Used then
    begin
      FTexts[N] := FTexts[I];
      Inc(N);
    end
    else
      glDeleteTextures(1, @FTexts[I].Tex);
  for I := N to FTextCount - 1 do
    FTexts[I].Key := '';
  FTextCount := N;
end;

function TView3DFrame.TextWidth(const S: string; Size: Integer;
  Bold: Boolean): Integer;
var
  I: Integer;
begin
  // TextTexture can move FTexts in memory, so it has to return before
  // FTexts is indexed
  I := TextTexture(S, Size, Bold);
  Result := FTexts[I].W - 2;
end;

function TView3DFrame.TextHeight(Size: Integer; Bold: Boolean): Integer;
var
  I: Integer;
begin
  I := TextTexture('0', Size, Bold);
  Result := FTexts[I].H - 2;
end;

procedure TView3DFrame.PutText(X, Y: Single; const S: string; Size: Integer;
  Bold: Boolean; R, G, B: Single; Just: TAlignment);
//
//  Draw a line of text whose top is at Y and whose left side, middle or
//  right side is at X.
//
var
  T: TTextTex;
  X0, Y0: Single;
  I, Pass: Integer;
begin
  if S = '' then exit;
  I := TextTexture(S, Size, Bold);
  T := FTexts[I];
  case Just of
    taCenter:       X := X - (T.W - 2) / 2;
    taRightJustify: X := X - (T.W - 2);
  end;
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, T.Tex);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
  glBegin(GL_QUADS);
  for Pass := 0 to 1 do
  begin
    // A shadow first keeps the text readable over anything
    if Pass = 0 then
    begin
      glColor4f(0, 0, 0, 0.75);
      X0 := Round(X);
      Y0 := Round(Y);
    end
    else
    begin
      glColor4f(R, G, B, 1);
      X0 := Round(X) - 1;
      Y0 := Round(Y) - 1;
    end;
    glTexCoord2f(0, 0);
    glVertex2f(X0, Y0);
    glTexCoord2f(T.U, 0);
    glVertex2f(X0 + T.W, Y0);
    glTexCoord2f(T.U, T.V);
    glVertex2f(X0 + T.W, Y0 + T.H);
    glTexCoord2f(0, T.V);
    glVertex2f(X0, Y0 + T.H);
  end;
  glEnd;
  glDisable(GL_TEXTURE_2D);
end;

end.
