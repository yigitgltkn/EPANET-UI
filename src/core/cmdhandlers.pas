{====================================================================
 Project:      EPANET-UI
 Module:       cmdhandlers
 Description:  implements the commands that external programs can
               send to the application through the cmdserver unit
 License:      see LICENSE
=====================================================================}

unit cmdhandlers;

{
 Each command acts through the same forms and frames a user would use,
 so the display always reflects what a command has done.

 Commands:
   ping              - identifies the application
   get_project_info  - describes the project that is open
   open_project      - opens an EPANET input file
   run_analysis      - runs a simulation
   set_map_view      - selects map themes, time period, legends, animation
   get_results       - returns node or link values for a theme
   export_geojson    - writes the network and its results to GeoJSON files
   set_3d_view       - shows the 3D view of the network or of one valve
   show_report       - shows one of the program's reports
   apply_edits       - changes junction and pipe properties, e.g. ones
                       edited in QGIS
   send_to_qgis      - shows the network and its results in QGIS, as the
                       QGIS button does
   activate          - brings the EPANET-UI window to the front
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

function ExecuteCommand(const CmdType: string; Params: TJSONObject): TJSONData;

implementation

uses
  Forms, Math, StrUtils, StdCtrls, ComCtrls,
  main, mainmenu, mapviewerframe, view3dframe, reportframe, project, results,
  mapthemes, simulator, epanet2, cmdserver, qgislink, resourcestrings;

const
  DefRowLimit = 50;
  MaxRowLimit = 5000;
  MaxReportChars = 4000;

  NodeTypeStr: array[ntJunction..ntTank] of string =
    ('Junction', 'Reservoir', 'Tank');
  LinkTypeStr: array[ltCVPipe..ltValve] of string =
    ('Pipe', 'Pipe', 'Pump', 'Valve');
  SimStatusStr: array[TSimStatus] of string =
    ('success', 'warning', 'error', 'wrong_version', 'failed', 'shutdown',
     'cancelled', 'none');
  ResultsStatusStr: array[rsNotAvailable..rsNeedsUpdating] of string =
    ('none', 'current', 'needs_update');

type
  // A floating point value written with a few significant digits
  TCompactFloat = class(TJSONFloatNumber)
  protected
    function GetAsJSON: TJSONStringType; override;
  end;

  TRow = record
    Index: Integer;
    Value: Double;
  end;
  TRows = array of TRow;

  // One property change requested through apply_edits
  TPropEdit = record
    Category: Integer;        // ctNodes or ctLinks
    Index: Integer;
    Param: Integer;           // EN_ code, or -1 for a pipe's status
    ID, Field: string;
    OldValue, NewValue: Single;
    OldStatus, NewStatus: string;
  end;

var
  JsonFormat: TFormatSettings;

function TCompactFloat.GetAsJSON: TJSONStringType;
begin
  if IsNan(AsFloat) or IsInfinite(AsFloat) then
    Result := 'null'
  else
    Result := FloatToStrF(AsFloat, ffGeneral, 6, 0, JsonFormat);
end;

function Num(Value: Double): TJSONData;
begin
  Result := TCompactFloat.Create(Value);
end;

procedure CheckReady;
//
//  State-changing commands are refused while the user is in the middle
//  of an operation that disables the main menu.
//
begin
  if not MainForm.MainMenuFrame.Enabled then
    raise Exception.Create(
      'EPANET-UI is busy with another operation; finish or cancel it first');
end;

function ThemeNames(Items: TStrings): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 1 to Items.Count - 1 do   // item 0 is the 'None' theme
    Result.Add(Items[I]);
end;

function FindTheme(Items: TStrings; Value: TJSONData; const What: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if Value.JSONType = jtNumber then
    Result := Value.AsInteger
  else for I := 0 to Items.Count - 1 do
    if SameText(Trim(Items[I]), Trim(Value.AsString)) then
    begin
      Result := I;
      break;
    end;
  if (Result < 0) or (Result >= Items.Count) then
    raise Exception.CreateFmt('unknown %s theme "%s"; available themes: %s',
      [What, Value.AsString, Items.CommaText]);
end;

function ItemText(Combo: TComboBox): string;
begin
  if Combo.ItemIndex >= 0 then
    Result := Combo.Items[Combo.ItemIndex]
  else
    Result := '';
end;

function ViewInfo: TJSONObject;
var
  Viewer: TMapViewerFrame;
begin
  Viewer := MainForm.MapViewerFrame;
  Result := TJSONObject.Create;
  Result.Add('node_theme', ItemText(Viewer.ViewNodeCombo));
  Result.Add('link_theme', ItemText(Viewer.ViewLinkCombo));
  Result.Add('period', mapthemes.TimePeriod);
  if project.HasResults then
    Result.Add('time', results.GetTimeStr(mapthemes.TimePeriod));
  Result.Add('animating', Viewer.AnimateBtn.Checked);
end;

function Ping: TJSONObject;
var
  Version: Integer = 0;
begin
  epanet2.ENgetversion(Version);
  Result := TJSONObject.Create;
  Result.Add('app', Copy(rsVersions, 1, Pos(LineEnding, rsVersions) - 1));
  Result.Add('engine_version', Version);
  Result.Add('port', cmdserver.GetPort);
  Result.Add('project', project.InpFile);
  Result.Add('dialog_open', Application.ModalLevel > 0);
end;

function GetProjectInfo: TJSONObject;
var
  I: Integer;
  NodeCounts: array[ntJunction..ntTank] of Integer = (0, 0, 0);
  LinkCounts: array[ltCVPipe..ltValve] of Integer = (0, 0, 0, 0);
  Counts, Sim: TJSONObject;
  Viewer: TMapViewerFrame;
begin
  for I := 1 to project.GetItemCount(ctNodes) do
    Inc(NodeCounts[EnsureRange(project.GetNodeType(I), ntJunction, ntTank)]);
  for I := 1 to project.GetItemCount(ctLinks) do
    Inc(LinkCounts[EnsureRange(project.GetLinkType(I), ltCVPipe, ltValve)]);

  Counts := TJSONObject.Create;
  Counts.Add('junctions', NodeCounts[ntJunction]);
  Counts.Add('reservoirs', NodeCounts[ntReservoir]);
  Counts.Add('tanks', NodeCounts[ntTank]);
  Counts.Add('pipes', LinkCounts[ltCVPipe] + LinkCounts[ltPipe]);
  Counts.Add('pumps', LinkCounts[ltPump]);
  Counts.Add('valves', LinkCounts[ltValve]);

  Sim := TJSONObject.Create;
  Sim.Add('has_results', project.HasResults);
  Sim.Add('results_status', ResultsStatusStr[EnsureRange(project.ResultsStatus,
    rsNotAvailable, rsNeedsUpdating)]);
  if project.HasResults then
  begin
    Sim.Add('periods', results.Nperiods);
    Sim.Add('first_time', results.GetTimeStr(0));
    Sim.Add('last_time', results.GetTimeStr(results.Nperiods - 1));
  end;

  Viewer := MainForm.MapViewerFrame;
  Result := TJSONObject.Create;
  Result.Add('file', project.InpFile);
  Result.Add('title', Trim(project.GetTitle(0)));
  Result.Add('has_unsaved_changes', project.HasChanged);
  Result.Add('counts', Counts);
  Result.Add('flow_units', project.FlowUnitsStr[project.FlowUnits]);
  Result.Add('pressure_units', project.PressureUnitsStr[project.PressureUnits]);
  Result.Add('head_loss_model', project.GetHlossModelStr);
  Result.Add('demand_model', project.GetDemandModelStr);
  Result.Add('quality_model', project.GetQualModelStr);
  Result.Add('map_units', project.MapUnitsStr[project.MapUnits]);
  Result.Add('map_epsg', project.MapEPSG);
  Result.Add('has_web_basemap', MainForm.MapFrame.HasWebBasemap);
  Result.Add('simulation', Sim);
  Result.Add('node_themes', ThemeNames(Viewer.ViewNodeCombo.Items));
  Result.Add('link_themes', ThemeNames(Viewer.ViewLinkCombo.Items));
  Result.Add('view', ViewInfo);
end;

function OpenProject(Params: TJSONObject): TJSONObject;
var
  Path: string;
begin
  CheckReady;
  Path := Params.Get('path', '');
  if Path = '' then
    raise Exception.Create('missing "path" parameter');
  if not FileExists(Path) then
    raise Exception.CreateFmt('file not found: %s', [Path]);
  if project.HasChanged and not Params.Get('discard_changes', false) then
    raise Exception.Create('the open project has unsaved changes; save it ' +
      'in EPANET-UI or send "discard_changes": true');

  MainForm.OpenFile(Path);
  if project.InpFile = '' then
    raise Exception.CreateFmt('EPANET-UI could not load %s', [Path]);
  Result := GetProjectInfo;
end;

function ReadReport: string;
//
//  The status report that the engine wrote for the last run.
//
var
  Lines: TStringList;
begin
  Result := '';
  if not FileExists(project.AuxFile) then exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(project.AuxFile);
    Result := Trim(Lines.Text);
    if Length(Result) > MaxReportChars then
      Result := Copy(Result, 1, MaxReportChars) + LineEnding + '...';
  finally
    Lines.Free;
  end;
end;

function RunAnalysis: TJSONObject;
begin
  CheckReady;
  if project.GetItemCount(ctNodes) = 0 then
    raise Exception.Create('no network is loaded');

  // Run through the Analyze button so the display is updated as usual
  simulator.CloseWhenDone := true;
  try
    MainForm.MainMenuFrame.ProjectAnalyzeBtnClick(nil);
  finally
    simulator.CloseWhenDone := false;
  end;

  Result := TJSONObject.Create;
  Result.Add('status', SimStatusStr[project.SimStatus]);
  Result.Add('has_results', project.HasResults);
  if project.HasResults then
  begin
    Result.Add('periods', results.Nperiods);
    Result.Add('first_time', results.GetTimeStr(0));
    Result.Add('last_time', results.GetTimeStr(results.Nperiods - 1));
  end;
  if project.SimStatus <> ssSuccess then
    Result.Add('status_report', ReadReport);
end;

procedure SetPeriod(Period: Integer);
var
  Viewer: TMapViewerFrame;
begin
  if not project.HasResults then
    raise Exception.Create('no simulation results are available');
  if (Period < 0) or (Period >= results.Nperiods) then
    raise Exception.CreateFmt('period must be between 0 and %d',
      [results.Nperiods - 1]);
  Viewer := MainForm.MapViewerFrame;
  Viewer.TimeTrackBar.Position := Period;
  Viewer.TimeTrackBar.Tag := 1;      // as if the slider had been released
  Viewer.TimeTrackBarChange(nil);
end;

function SetMapView(Params: TJSONObject): TJSONObject;
var
  Viewer: TMapViewerFrame;
  V: TJSONData;
begin
  Viewer := MainForm.MapViewerFrame;
  MainForm.ShowPage(MainForm.MapPage);

  V := Params.Find('node_theme');
  if V <> nil then
  begin
    Viewer.ViewNodeCombo.ItemIndex :=
      FindTheme(Viewer.ViewNodeCombo.Items, V, 'node');
    Viewer.ViewNodeComboChange(nil);
  end;

  V := Params.Find('link_theme');
  if V <> nil then
  begin
    Viewer.ViewLinkCombo.ItemIndex :=
      FindTheme(Viewer.ViewLinkCombo.Items, V, 'link');
    Viewer.ViewLinkComboChange(nil);
  end;

  V := Params.Find('period');
  if V <> nil then SetPeriod(V.AsInteger);

  V := Params.Find('node_legend');
  if (V <> nil) and Viewer.NodeLegendBox.Enabled then
  begin
    Viewer.NodeLegendBox.Checked := V.AsBoolean;
    Viewer.NodeLegendBoxChange(nil);
  end;

  V := Params.Find('link_legend');
  if (V <> nil) and Viewer.LinkLegendBox.Enabled then
  begin
    Viewer.LinkLegendBox.Checked := V.AsBoolean;
    Viewer.LinkLegendBoxChange(nil);
  end;

  V := Params.Find('animate');
  if (V <> nil) and Viewer.AnimateBtn.Enabled then
  begin
    Viewer.AnimateBtn.Checked := V.AsBoolean;
    Viewer.AnimateBtnChange(nil);
  end;

  Result := ViewInfo;
end;

procedure SortRows(var Rows: TRows; L, R: Integer; Descending: Boolean);
var
  I, J: Integer;
  Pivot: Double;
  Tmp: TRow;
begin
  if L >= R then exit;
  I := L;
  J := R;
  Pivot := Rows[(L + R) div 2].Value;
  repeat
    if Descending then
    begin
      while Rows[I].Value > Pivot do Inc(I);
      while Rows[J].Value < Pivot do Dec(J);
    end
    else
    begin
      while Rows[I].Value < Pivot do Inc(I);
      while Rows[J].Value > Pivot do Dec(J);
    end;
    if I <= J then
    begin
      Tmp := Rows[I];
      Rows[I] := Rows[J];
      Rows[J] := Tmp;
      Inc(I);
      Dec(J);
    end;
  until I > J;
  SortRows(Rows, L, J, Descending);
  SortRows(Rows, I, R, Descending);
end;

function GetResults(Params: TJSONObject): TJSONObject;
//
//  Parameters:
//    category  "nodes" or "links"
//    theme     a theme name listed by get_project_info
//    period    time period (default is the one shown on the map)
//    types     optional list of object types to consider, e.g. ["Junction"]
//    ids       optional list of object IDs to report
//    below, above   optional limits a value must be under / over
//    sort      "asc" or "desc" (default is network order)
//    limit     most rows to return (default 50)
//
var
  Category, Theme, Period, Count, I, N, Limit: Integer;
  CategoryStr, SortStr, ID: string;
  Combo: TComboBox;
  V, Ids: TJSONData;
  Value, Sum, Below, Above: Double;
  HasBelow, HasAbove: Boolean;
  All, Rows: TRows;
  MinRow, MaxRow: Integer;
  Wanted, Types: TStringList;
  Stats, Row: TJSONObject;
  RowArray, NotFound: TJSONArray;

  function ValueOf(Index: Integer): Double;
  begin
    if Category = ctNodes then
      Result := mapthemes.GetNodeValue(Index, Theme, Period)
    else
      Result := mapthemes.GetLinkValue(Index, Theme, Period);
  end;

  function TypeOf(Index: Integer): string;
  begin
    if Category = ctNodes then
      Result := NodeTypeStr[EnsureRange(project.GetNodeType(Index),
        ntJunction, ntTank)]
    else
      Result := LinkTypeStr[EnsureRange(project.GetLinkType(Index),
        ltCVPipe, ltValve)];
  end;

begin
  CategoryStr := Params.Get('category', 'nodes');
  if SameText(CategoryStr, 'nodes') then
  begin
    Category := ctNodes;
    Combo := MainForm.MapViewerFrame.ViewNodeCombo;
  end
  else if SameText(CategoryStr, 'links') then
  begin
    Category := ctLinks;
    Combo := MainForm.MapViewerFrame.ViewLinkCombo;
  end
  else
    raise Exception.Create('"category" must be "nodes" or "links"');

  V := Params.Find('theme');
  if V = nil then
    raise Exception.Create('missing "theme" parameter');
  Theme := FindTheme(Combo.Items, V, CategoryStr);
  if Theme = 0 then
    raise Exception.Create('choose a theme other than None');

  Period := Params.Get('period', mapthemes.TimePeriod);
  if project.HasResults
  and ((Period < 0) or (Period >= results.Nperiods)) then
    raise Exception.CreateFmt('period must be between 0 and %d',
      [results.Nperiods - 1]);

  HasBelow := Params.Find('below') <> nil;
  HasAbove := Params.Find('above') <> nil;
  Below := Params.Get('below', 0.0);
  Above := Params.Get('above', 0.0);
  SortStr := Params.Get('sort', '');
  Limit := EnsureRange(Params.Get('limit', DefRowLimit), 1, MaxRowLimit);

  // Collect every object of the wanted types that has a value for the theme
  Types := nil;
  V := Params.Find('types');
  if V is TJSONArray then
  begin
    Types := TStringList.Create;
    for I := 0 to TJSONArray(V).Count - 1 do
      Types.Add(TJSONArray(V).Items[I].AsString);
  end;
  Count := project.GetItemCount(Category);
  SetLength(All, Count);
  N := 0;
  Sum := 0;
  MinRow := -1;
  MaxRow := -1;
  try
    for I := 1 to Count do
    begin
      if (Types <> nil) and (Types.IndexOf(TypeOf(I)) < 0) then continue;
      Value := ValueOf(I);
      if Value = MISSING then continue;
      All[N].Index := I;
      All[N].Value := Value;
      Sum := Sum + Value;
      if (MinRow < 0) or (Value < All[MinRow].Value) then MinRow := N;
      if (MaxRow < 0) or (Value > All[MaxRow].Value) then MaxRow := N;
      Inc(N);
    end;
  finally
    Types.Free;
  end;
  SetLength(All, N);
  if N = 0 then
  begin
    if (Category = ctNodes) and (Theme >= FirstNodeResultTheme)
    or (Category = ctLinks) and (Theme >= FirstLinkResultTheme) then
      raise Exception.Create('no values found; if the theme is a ' +
        'simulation result, run an analysis first')
    else
      raise Exception.Create('no ' + CategoryStr + ' of the requested ' +
        'types were found');
  end;

  Stats := TJSONObject.Create;
  Stats.Add('min', Num(All[MinRow].Value));
  Stats.Add('min_id', project.GetID(Category, All[MinRow].Index));
  Stats.Add('max', Num(All[MaxRow].Value));
  Stats.Add('max_id', project.GetID(Category, All[MaxRow].Index));
  Stats.Add('mean', Num(Sum / N));

  // Keep only the objects that were asked for
  NotFound := TJSONArray.Create;
  Wanted := nil;
  Ids := Params.Find('ids');
  if Ids is TJSONArray then
  begin
    Wanted := TStringList.Create;
    Wanted.Sorted := true;
    Wanted.Duplicates := dupIgnore;
    for I := 0 to TJSONArray(Ids).Count - 1 do
    begin
      ID := TJSONArray(Ids).Items[I].AsString;
      if project.GetItemIndex(Category, ID) > 0 then
        Wanted.Add(ID)
      else
        NotFound.Add(ID);
    end;
  end;
  try
    SetLength(Rows, N);
    Count := 0;
    for I := 0 to N - 1 do
    begin
      if HasBelow and not (All[I].Value < Below) then continue;
      if HasAbove and not (All[I].Value > Above) then continue;
      if (Wanted <> nil)
      and (Wanted.IndexOf(project.GetID(Category, All[I].Index)) < 0) then
        continue;
      Rows[Count] := All[I];
      Inc(Count);
    end;
    SetLength(Rows, Count);
  finally
    Wanted.Free;
  end;

  if SameText(SortStr, 'asc') then
    SortRows(Rows, 0, Count - 1, false)
  else if SameText(SortStr, 'desc') then
    SortRows(Rows, 0, Count - 1, true);

  RowArray := TJSONArray.Create;
  for I := 0 to Min(Count, Limit) - 1 do
  begin
    Row := TJSONObject.Create;
    Row.Add('id', project.GetID(Category, Rows[I].Index));
    Row.Add('type', TypeOf(Rows[I].Index));
    Row.Add('value', Num(Rows[I].Value));
    RowArray.Add(Row);
  end;

  Result := TJSONObject.Create;
  Result.Add('category', LowerCase(CategoryStr));
  Result.Add('theme', Combo.Items[Theme]);
  Result.Add('units', mapthemes.GetThemeUnits(Category, Theme));
  Result.Add('period', Period);
  if project.HasResults then
    Result.Add('time', results.GetTimeStr(Period));
  Result.Add('total', N);
  Result.Add('stats', Stats);
  Result.Add('matched', Count);
  Result.Add('returned', RowArray.Count);
  Result.Add('rows', RowArray);
  if NotFound.Count > 0 then
    Result.Add('ids_not_found', NotFound)
  else
    NotFound.Free;
end;

function FieldName(const ThemeName: string): string;
//
//  Attribute name for a theme, e.g. 'Base Demand' becomes 'base_demand'.
//
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(ThemeName) do
  begin
    C := ThemeName[I];
    if C in ['A'..'Z'] then
      Result := Result + Chr(Ord(C) + 32)
    else if C in ['a'..'z', '0'..'9'] then
      Result := Result + C
    else if (Result <> '') and (Result[Length(Result)] <> '_') then
      Result := Result + '_';
  end;
  while (Result <> '') and (Result[Length(Result)] = '_') do
    SetLength(Result, Length(Result) - 1);
end;

function JsonValue(Value: Double): string;
begin
  if (Value = MISSING) or IsNan(Value) or IsInfinite(Value) then
    Result := 'null'
  else
    Result := FloatToStrF(Value, ffGeneral, 6, 0, JsonFormat);
end;

function JsonText(const S: string): string;
begin
  Result := '"' + StringToJSONString(S) + '"';
end;

function JsonCoord(X, Y: Double): string;
begin
  Result := '[' + FloatToStr(X, JsonFormat) + ',' +
    FloatToStr(Y, JsonFormat) + ']';
end;

function PipeStatus(Index: Integer): string;
//
//  A pipe's initial status: 'Open', 'Closed' or 'CV' (has a check valve).
//
var
  X: Single = 0;
begin
  if project.GetLinkType(Index) = ltCVPipe then
    exit('CV');
  epanet2.ENgetlinkvalue(Index, EN_INITSTATUS, X);
  if Round(X) = EN_CLOSED then
    Result := 'Closed'
  else
    Result := 'Open';
end;

function ExportGeoJson(Params: TJSONObject): TJSONObject;
//
//  Writes <name>_nodes.geojson and <name>_links.geojson, in the map's
//  coordinate system, with one attribute per map theme.
//
//  Parameters:
//    folder   where to write the files (default is a 'qgis' folder
//             beside the project's input file)
//    period   time period the result values are taken from (default is
//             the one shown on the map)
//
var
  Folder, BaseName, Header, Props, Coords, NodesFile, LinksFile: string;
  Period, Epsg, I, K, N1, N2, NodeCount, LinkCount, Skipped: Integer;
  X, Y: Double;
  NodeItems, LinkItems: TStrings;
  Lines: TStringList;
  Fields, Units: TJSONObject;
  FieldList: TJSONArray;

  function FileHeader(const LayerName: string): string;
  begin
    Result := '{"type":"FeatureCollection","name":' + JsonText(LayerName);
    if Epsg > 0 then
      Result := Result + ',"crs":{"type":"name","properties":{"name":' +
        '"urn:ogc:def:crs:EPSG::' + IntToStr(Epsg) + '"}}';
    Result := Result + ',"features":[';
  end;

  procedure AddFeature(const Properties, Geometry: string);
  var
    S: string;
  begin
    S := '{"type":"Feature","properties":{' + Properties + '},"geometry":' +
      Geometry + '}';
    if Lines.Count > 1 then S := ',' + S;
    Lines.Add(S);
  end;

  procedure DescribeFields(Category: Integer; Items: TStrings;
    const Key: string);
  var
    T: Integer;
    CategoryUnits: TJSONObject;
  begin
    // Node and link themes can share a name, so units are listed per layer
    FieldList := TJSONArray.Create;
    CategoryUnits := TJSONObject.Create;
    for T := 1 to Items.Count - 1 do
    begin
      FieldList.Add(FieldName(Items[T]));
      if CategoryUnits.Find(FieldName(Items[T])) = nil then
        CategoryUnits.Add(FieldName(Items[T]),
          mapthemes.GetThemeUnits(Category, T));
    end;
    Fields.Add(Key, FieldList);
    Units.Add(Key, CategoryUnits);
  end;

begin
  if project.GetItemCount(ctNodes) = 0 then
    raise Exception.Create('no network is loaded');

  Folder := Params.Get('folder', '');
  if Folder = '' then
  begin
    if project.InpFile = '' then
      raise Exception.Create('the project has not been saved; ' +
        'send a "folder" to write the files to');
    Folder := ExtractFilePath(ExpandFileName(project.InpFile)) + 'qgis';
  end;
  Folder := ExcludeTrailingPathDelimiter(ExpandFileName(Folder));
  if not ForceDirectories(Folder) then
    raise Exception.CreateFmt('could not create folder %s', [Folder]);

  if project.InpFile <> '' then
    BaseName := ChangeFileExt(ExtractFileName(project.InpFile), '')
  else
    BaseName := 'network';
  NodesFile := Folder + PathDelim + BaseName + '_nodes.geojson';
  LinksFile := Folder + PathDelim + BaseName + '_links.geojson';

  Period := Params.Get('period', mapthemes.TimePeriod);
  if project.HasResults
  and ((Period < 0) or (Period >= results.Nperiods)) then
    raise Exception.CreateFmt('period must be between 0 and %d',
      [results.Nperiods - 1]);

  Epsg := project.MapEPSG;
  if (Epsg = 0) and (project.MapUnits = muDegrees) then Epsg := 4326;
  NodeItems := MainForm.MapViewerFrame.ViewNodeCombo.Items;
  LinkItems := MainForm.MapViewerFrame.ViewLinkCombo.Items;
  Skipped := 0;

  Lines := TStringList.Create;
  try
    // Nodes
    Lines.Add(FileHeader(BaseName + '_nodes'));
    for I := 1 to project.GetItemCount(ctNodes) do
    begin
      if not project.GetNodeCoord(I, X, Y) or (X = EN_MISSING) then
      begin
        Inc(Skipped);
        continue;
      end;
      Props := '"id":' + JsonText(project.GetID(ctNodes, I)) + ',"type":' +
        JsonText(NodeTypeStr[EnsureRange(project.GetNodeType(I),
          ntJunction, ntTank)]);
      for K := 1 to NodeItems.Count - 1 do
        Props := Props + ',"' + FieldName(NodeItems[K]) + '":' +
          JsonValue(mapthemes.GetNodeValue(I, K, Period));
      AddFeature(Props, '{"type":"Point","coordinates":' +
        JsonCoord(X, Y) + '}');
    end;
    Lines.Add(']}');
    Lines.SaveToFile(NodesFile);
    NodeCount := Lines.Count - 2;

    // Links, drawn from start node through any vertices to end node
    Lines.Clear;
    Lines.Add(FileHeader(BaseName + '_links'));
    for I := 1 to project.GetItemCount(ctLinks) do
    begin
      if not project.GetLinkNodes(I, N1, N2)
      or not project.GetNodeCoord(N1, X, Y) or (X = EN_MISSING) then
      begin
        Inc(Skipped);
        continue;
      end;
      Coords := JsonCoord(X, Y);
      for K := 1 to project.GetVertexCount(I) do
        if project.GetVertexCoord(I, K, X, Y) then
          Coords := Coords + ',' + JsonCoord(X, Y);
      if not project.GetNodeCoord(N2, X, Y) or (X = EN_MISSING) then
      begin
        Inc(Skipped);
        continue;
      end;
      Coords := Coords + ',' + JsonCoord(X, Y);

      Props := '"id":' + JsonText(project.GetID(ctLinks, I)) + ',"type":' +
        JsonText(LinkTypeStr[EnsureRange(project.GetLinkType(I),
          ltCVPipe, ltValve)]) +
        ',"node1":' + JsonText(project.GetID(ctNodes, N1)) +
        ',"node2":' + JsonText(project.GetID(ctNodes, N2));
      if project.GetLinkType(I) <= ltPipe then
        Props := Props + ',"status":' + JsonText(PipeStatus(I))
      else
        Props := Props + ',"status":null';
      for K := 1 to LinkItems.Count - 1 do
        Props := Props + ',"' + FieldName(LinkItems[K]) + '":' +
          JsonValue(mapthemes.GetLinkValue(I, K, Period));
      AddFeature(Props, '{"type":"LineString","coordinates":[' +
        Coords + ']}');
    end;
    Lines.Add(']}');
    Lines.SaveToFile(LinksFile);
    LinkCount := Lines.Count - 2;
  finally
    Lines.Free;
  end;

  Fields := TJSONObject.Create;
  Units := TJSONObject.Create;
  DescribeFields(ctNodes, NodeItems, 'nodes');
  DescribeFields(ctLinks, LinkItems, 'links');
  Fields.Arrays['links'].Insert(0, TJSONString.Create('status'));

  Result := TJSONObject.Create;
  Result.Add('nodes_file', NodesFile);
  Result.Add('links_file', LinksFile);
  Result.Add('node_count', NodeCount);
  Result.Add('link_count', LinkCount);
  Result.Add('skipped_without_coordinates', Skipped);
  Result.Add('epsg', Epsg);
  Result.Add('has_results', project.HasResults);
  Result.Add('period', Period);
  if project.HasResults then
    Result.Add('time', results.GetTimeStr(Period));
  Result.Add('fields', Fields);
  Result.Add('units', Units);
end;

function ApplyEdits(Params: TJSONObject): TJSONObject;
//
//  Changes junction and pipe properties, for example ones edited in QGIS
//  on the layers that export_geojson wrote.
//
//  Parameters:
//    nodes    [{"id": "J1", "elevation": 12.5, "base_demand": 0.2}, ...]
//    links    [{"id": "P1", "diameter": 150, "length": 80.5,
//               "roughness": 130, "status": "Open|Closed|CV"}, ...]
//    dry_run  true reports what would change without changing anything
//
//  Each item needs an "id"; its other fields are optional. Values are in
//  the project's units, as export_geojson writes them. Values equal to the
//  current ones are left alone. Everything is checked first: if anything
//  is refused, nothing is changed and the reply lists the problems.
//
const
  NodeFields: array[0..1] of string = ('elevation', 'base_demand');
  NodeParams: array[0..1] of Integer = (EN_ELEVATION, EN_BASEDEMAND);
  LinkFields: array[0..2] of string = ('diameter', 'length', 'roughness');
  LinkParams: array[0..2] of Integer = (EN_DIAMETER, EN_LENGTH, EN_ROUGHNESS);
  Statuses: array[0..2] of string = ('Open', 'Closed', 'CV');
var
  Edits: array of TPropEdit;
  EditCount, ErrCode: Integer;
  DryRun, Applied: Boolean;
  Changes, Problems: TJSONArray;
  Change: TJSONObject;
  E: TPropEdit;

  procedure AddProblem(const ID, Field, Text: string);
  var
    P: TJSONObject;
  begin
    P := TJSONObject.Create;
    P.Add('id', ID);
    if Field <> '' then P.Add('field', Field);
    P.Add('problem', Text);
    Problems.Add(P);
  end;

  procedure AddEdit(const Edit: TPropEdit);
  begin
    if EditCount = Length(Edits) then
      SetLength(Edits, 2 * EditCount + 16);
    Edits[EditCount] := Edit;
    Inc(EditCount);
  end;

  function ReadNumber(Item: TJSONObject; const ID, Field: string;
    var Value: Single): Boolean;
  var
    V: TJSONData;
    D: Double;
  begin
    Result := false;
    V := Item.Find(Field);
    if V = nil then exit;
    if V.JSONType = jtNumber then
      D := V.AsFloat
    else if (V.JSONType <> jtString)
    or not TryStrToFloat(Trim(V.AsString), D, JsonFormat) then
    begin
      AddProblem(ID, Field, 'is not a number');
      exit;
    end;
    if IsNan(D) or IsInfinite(D) then
    begin
      AddProblem(ID, Field, 'is not a number');
      exit;
    end;
    Value := D;
    Result := true;
  end;

  function Differs(OldValue, NewValue: Single): Boolean;
  begin
    // export_geojson writes 6 significant digits
    Result := Abs(NewValue - OldValue) > 1e-5 * Max(1.0, Abs(OldValue));
  end;

  procedure ReadItems(Category: Integer; const Key: string);
  var
    List: TJSONData;
    Item: TJSONObject;
    I, J, Index, Count: Integer;
    ID, What, S: string;
    Value: Single;
    Edit: TPropEdit;
    Editable: Boolean;
  begin
    List := Params.Find(Key);
    if List = nil then exit;
    if List.JSONType <> jtArray then
      raise Exception.CreateFmt('"%s" must be a list', [Key]);
    if Category = ctNodes then
    begin
      Count := Length(NodeFields);
      What := 'junctions';
    end
    else
    begin
      Count := Length(LinkFields);
      What := 'pipes';
    end;

    for I := 0 to List.Count - 1 do
    begin
      if List.Items[I].JSONType <> jtObject then
      begin
        AddProblem('', '', Format('item %d of "%s" is not an object', [I, Key]));
        continue;
      end;
      Item := TJSONObject(List.Items[I]);
      ID := '';
      if (Item.Find('id') <> nil)
      and (Item.Find('id').JSONType in [jtString, jtNumber]) then
        ID := Trim(Item.Find('id').AsString);
      if ID = '' then
      begin
        AddProblem('', '', Format('item %d of "%s" has no "id"', [I, Key]));
        continue;
      end;
      Index := project.GetItemIndex(Category, ID);
      if Index < 1 then
      begin
        AddProblem(ID, '', 'not found in the project');
        continue;
      end;
      if Category = ctNodes then
        Editable := project.GetNodeType(Index) = ntJunction
      else
        Editable := project.GetLinkType(Index) <= ltPipe;

      Edit := Default(TPropEdit);
      Edit.Category := Category;
      Edit.Index := Index;
      Edit.ID := ID;

      for J := 0 to Count - 1 do
      begin
        if Category = ctNodes then
        begin
          Edit.Field := NodeFields[J];
          Edit.Param := NodeParams[J];
          Edit.OldValue := project.GetNodeParam(Index, Edit.Param);
        end
        else
        begin
          Edit.Field := LinkFields[J];
          Edit.Param := LinkParams[J];
          Edit.OldValue := project.GetLinkParam(Index, Edit.Param);
        end;
        if not ReadNumber(Item, ID, Edit.Field, Value) then continue;
        if not Differs(Edit.OldValue, Value) then continue;
        if not Editable then
          AddProblem(ID, Edit.Field, 'only ' + What + ' can be changed')
        else if (Category = ctLinks) and (Value <= 0) then
          AddProblem(ID, Edit.Field, 'must be greater than zero')
        else
        begin
          Edit.NewValue := Value;
          AddEdit(Edit);
        end;
      end;

      if (Category = ctLinks) and (Item.Find('status') <> nil) then
      begin
        Edit.Field := 'status';
        Edit.Param := -1;
        if Item.Find('status').JSONType <> jtString then
          S := ''
        else
          S := Trim(Item.Get('status', ''));
        if not Editable then
        begin
          if S <> '' then
            AddProblem(ID, 'status', 'only pipes can be changed');
        end
        else if AnsiIndexText(S, Statuses) < 0 then
          AddProblem(ID, 'status', 'must be Open, Closed or CV')
        else
        begin
          Edit.OldStatus := PipeStatus(Index);
          Edit.NewStatus := Statuses[AnsiIndexText(S, Statuses)];
          if Edit.NewStatus <> Edit.OldStatus then
            AddEdit(Edit);
        end;
      end;
    end;
  end;

  procedure SetStatus(var Index: Integer; const Status: string);
  begin
    // As the property editor does it (see validator.ValidatePipe)
    if Status = 'CV' then
      ErrCode := epanet2.ENsetlinktype(Index, EN_CVPIPE, EN_UNCONDITIONAL)
    else
    begin
      ErrCode := epanet2.ENsetlinktype(Index, EN_PIPE, EN_UNCONDITIONAL);
      if ErrCode <= 100 then
      begin
        if Status = 'Open' then
          ErrCode := epanet2.ENsetlinkvalue(Index, EN_INITSTATUS, EN_OPEN)
        else
          ErrCode := epanet2.ENsetlinkvalue(Index, EN_INITSTATUS, EN_CLOSED);
      end;
    end;
  end;

var
  I: Integer;
begin
  CheckReady;
  if project.GetItemCount(ctNodes) = 0 then
    raise Exception.Create('no network is loaded');
  DryRun := Params.Get('dry_run', false);
  Applied := false;
  EditCount := 0;
  Edits := nil;

  Problems := TJSONArray.Create;
  Changes := TJSONArray.Create;
  Result := TJSONObject.Create;
  try
    ReadItems(ctNodes, 'nodes');
    ReadItems(ctLinks, 'links');

    if (Problems.Count = 0) and not DryRun then
    begin
      for I := 0 to EditCount - 1 do
      begin
        E := Edits[I];
        if E.Param < 0 then
          SetStatus(E.Index, E.NewStatus)
        else if E.Category = ctNodes then
          ErrCode := epanet2.ENsetnodevalue(E.Index, E.Param, E.NewValue)
        else
          ErrCode := epanet2.ENsetlinkvalue(E.Index, E.Param, E.NewValue);
        if ErrCode > 100 then
          AddProblem(E.ID, E.Field, Format('engine error %d', [ErrCode]));
      end;
      if EditCount > 0 then
      begin
        Applied := true;
        project.HasChanged := true;
        project.UpdateResultsStatus;
        MainForm.ProjectFrame.RefreshPropEditor;
        MainForm.MapFrame.RedrawMap;
      end;
    end;

    for I := 0 to Min(EditCount, MaxRowLimit) - 1 do
    begin
      E := Edits[I];
      Change := TJSONObject.Create;
      if E.Category = ctNodes then
        Change.Add('category', 'node')
      else
        Change.Add('category', 'link');
      Change.Add('id', E.ID);
      Change.Add('field', E.Field);
      if E.Param < 0 then
      begin
        Change.Add('old', E.OldStatus);
        Change.Add('new', E.NewStatus);
      end
      else
      begin
        Change.Add('old', Num(E.OldValue));
        Change.Add('new', Num(E.NewValue));
      end;
      Changes.Add(Change);
    end;

    Result.Add('applied', Applied);
    Result.Add('dry_run', DryRun);
    Result.Add('change_count', EditCount);
    Result.Add('changes', Changes);
    Changes := nil;
    if Problems.Count > 0 then
    begin
      Result.Add('problems', Problems);
      Problems := nil;
    end;
    Result.Add('has_unsaved_changes', project.HasChanged);
    Result.Add('results_status', ResultsStatusStr[EnsureRange(
      project.ResultsStatus, rsNotAvailable, rsNeedsUpdating)]);
  except
    Result.Free;
    Changes.Free;
    Problems.Free;
    raise;
  end;
  Changes.Free;
  Problems.Free;
end;

function Set3DView(Params: TJSONObject): TJSONObject;
//
//  Parameters (all optional):
//    show            false returns to the map (default is true)
//    valve           ID of a valve to display in detail; "" for the network
//    reset           true restores the default camera position
//    yaw, pitch      camera angles in degrees
//    zoom            magnification relative to the default view
//    vertical_scale  exaggeration of elevations and heads (0.25 to 4)
//    surface, flow, labels   true or false
//    image           PNG file to save what is on display to
//
var
  View: TView3DFrame;
  V: TJSONData;
  Index: Integer;
  Path: string;
  Camera: TCamera;
  Info: TValveInfo;
  Valve: TJSONObject;
begin
  View := MainForm.View3DFrame;
  Result := TJSONObject.Create;
  try
    if not Params.Get('show', true) then
    begin
      MainForm.ShowPage(MainForm.MapPage);
      Result.Add('showing', false);
      exit;
    end;
    MainForm.ShowPage(MainForm.View3DPage);
    Application.ProcessMessages;   // lets the page get onto the screen

    V := Params.Find('valve');
    if V <> nil then
    begin
      if V.IsNull or (V.AsString = '') then
        View.ShowNetwork
      else
      begin
        Index := project.GetItemIndex(ctLinks, V.AsString);
        if (Index < 1) or not View.ShowValve(Index, false) then
          raise Exception.CreateFmt('"%s" is not a valve', [V.AsString]);
      end;
    end;

    if Params.Get('reset', false) then View.ResetView;
    V := Params.Find('vertical_scale');
    if V <> nil then View.SetVerticalScale(V.AsFloat);
    V := Params.Find('surface');
    if V <> nil then View.SurfaceBox.Checked := V.AsBoolean;
    V := Params.Find('flow');
    if V <> nil then View.FlowBox.Checked := V.AsBoolean;
    V := Params.Find('labels');
    if V <> nil then View.LabelsBox.Checked := V.AsBoolean;
    Camera := View.GetCamera;
    if (Params.Find('yaw') <> nil) or (Params.Find('pitch') <> nil) then
      View.TurnTo(Params.Get('yaw', Double(Camera.Yaw)),
        Params.Get('pitch', Double(Camera.Pitch)));
    V := Params.Find('zoom');
    if V <> nil then View.ZoomBy(V.AsFloat);

    Path := Params.Get('image', '');
    if Path <> '' then
    begin
      Path := ExpandFileName(Path);
      if not View.SaveImage(Path) then
        raise Exception.Create(rs3dNotShowing);
      Result.Add('image', Path);
    end;

    Camera := View.GetCamera;
    Result.Add('showing', true);
    Result.Add('has_results', project.HasResults);
    Result.Add('period', mapthemes.TimePeriod);
    Result.Add('vertical_scale', Num(View.VerticalScale));
    Result.Add('yaw', Num(Camera.Yaw));
    Result.Add('pitch', Num(Camera.Pitch));
    if View.Mode = vmNetwork then
      Result.Add('view', 'network')
    else
    begin
      Result.Add('view', 'valve');
      if View.GetValveInfo(View.Valve, Info) then
      begin
        Valve := TJSONObject.Create;
        Valve.Add('id', Info.ID);
        Valve.Add('type', Info.TypeStr);
        if Info.HasResults then
        begin
          Valve.Add('status', Info.StatusStr);
          Valve.Add('setting', Num(Info.Setting));
          Valve.Add('flow', Num(Info.Flow));
          Valve.Add('velocity', Num(Info.Velocity));
          Valve.Add('upstream_pressure', Num(Info.PresIn));
          Valve.Add('downstream_pressure', Num(Info.PresOut));
          Valve.Add('head_drop', Num(Info.HeadDrop));
          Valve.Add('power_kw', Num(Info.PowerKW));
          if Info.LossCoeff >= 0 then
            Valve.Add('loss_coefficient', Num(Info.LossCoeff));
          if Info.OpeningKnown then
          begin
            Valve.Add('opening_percent', Num(Info.Opening * 100));
            Valve.Add('opening_is_estimate', Info.OpeningEstimated);
          end;
        end;
        Result.Add('valve', Valve);
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ShowReport(Params: TJSONObject): TJSONObject;
//
//  Parameters:
//    type   status, pumping, calibration, nodes, links, time_series, profile,
//           system_flow, energy, variability or fire_flow. Time series,
//           profile and variability reports first ask in EPANET-UI what to
//           report.
//
const
  Names: array[rtStatus..rtFireFlow] of string =
    ('status', 'pumping', 'calibration', 'nodes', 'links', 'time_series',
     'profile', 'system_flow', 'energy', 'variability', 'fire_flow');
var
  Name: string;
  RptType: TReportType;
begin
  CheckReady;
  Name := Params.Get('type', '');
  for RptType := rtStatus to rtFireFlow do
    if SameText(Name, Names[RptType]) then
    begin
      if (RptType <> rtStatus) and not project.HasResults then
        raise Exception.Create('no simulation results are available; ' +
          'run an analysis first');
      MainForm.ReportFrame.ShowReport(RptType);
      Result := TJSONObject.Create;
      Result.Add('report', Names[RptType]);
      Result.Add('showing', MainForm.Notebook1.PageIndex = 1);
      exit;
    end;
  raise Exception.CreateFmt('unknown report type "%s"; one of: %s',
    [Name, 'status, pumping, calibration, nodes, links, time_series, ' +
    'profile, system_flow, energy, variability, fire_flow']);
end;

function ExecuteCommand(const CmdType: string; Params: TJSONObject): TJSONData;
var
  Msg: string;
begin
  if SameText(CmdType, 'ping') then
    exit(Ping);

  // A modal form would end up underneath anything a command displays
  if Application.ModalLevel > 0 then
    raise Exception.Create('EPANET-UI is showing a dialog; close it first');

  if SameText(CmdType, 'get_project_info') then
    Result := GetProjectInfo
  else if SameText(CmdType, 'open_project') then
    Result := OpenProject(Params)
  else if SameText(CmdType, 'run_analysis') then
    Result := RunAnalysis
  else if SameText(CmdType, 'set_map_view') then
    Result := SetMapView(Params)
  else if SameText(CmdType, 'get_results') then
    Result := GetResults(Params)
  else if SameText(CmdType, 'export_geojson') then
    Result := ExportGeoJson(Params)
  else if SameText(CmdType, 'set_3d_view') then
    Result := Set3DView(Params)
  else if SameText(CmdType, 'show_report') then
    Result := ShowReport(Params)
  else if SameText(CmdType, 'apply_edits') then
    Result := ApplyEdits(Params)
  else if SameText(CmdType, 'send_to_qgis') then
  begin
    CheckReady;
    if not qgislink.SendToQgis(Msg) then
      raise Exception.Create(Msg);
    Result := TJSONObject.Create(['sent', true, 'message', Msg]);
  end
  else if SameText(CmdType, 'activate') then
  begin
    qgislink.ComeToFront;
    Result := TJSONObject.Create(['active', true]);
  end
  else
    raise Exception.CreateFmt('unknown command "%s"', [CmdType]);
end;

initialization
  JsonFormat := DefaultFormatSettings;
  JsonFormat.DecimalSeparator := '.';
  JsonFormat.ThousandSeparator := #0;

end.
