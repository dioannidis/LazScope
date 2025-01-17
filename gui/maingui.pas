unit mainGUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, TAGraph, TASeries, TATransformations, TATools,
  SerialThread, commands, LMessages, LCLIntf, Spin, EpikTimer, types;

type
  { TForm1 }

  TForm1 = class(TForm)
    ADCchannelsList: TCheckGroup;
    ADCScalerSelector: TComboBox;
    ADCResolutionSelector: TComboBox;
    BaudEdit: TEdit;
    Chart1: TChart;
    ChartToolset1: TChartToolset;
    ChartToolset1DataPointCrosshairTool1: TDataPointCrosshairTool;
    ChartToolset1PanDragTool1: TPanDragTool;
    ChartToolset1ZoomDragTool1: TZoomDragTool;
    connectButton: TButton;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    Label7: TLabel;
    LabelX: TLabel;
    LabelXlbl: TLabel;
    LabelY: TLabel;
    LabelYlbl: TLabel;
    Panel1: TPanel;
    ReferenceVoltageSelector: TComboBox;
    RunningCheck: TCheckBox;
    SerialComboBox: TComboBox;
    SingleShotCheck: TCheckBox;
    StatusBar1: TStatusBar;
    TriggerLevelEdit: TSpinEdit;
    TriggerOptionsRadioBox: TRadioGroup;
    procedure ADCchannelsListClick(Sender: TObject);
    procedure ADCchannelsListItemClick(Sender: TObject; Index: integer);
    procedure ADCResolutionSelectorChange(Sender: TObject);
    procedure ChartToolset1DataPointCrosshairTool1AfterKeyUp(ATool: TChartTool;
      APoint: TPoint);
    procedure ChartToolset1DataPointCrosshairTool1AfterMouseMove(
      ATool: TChartTool; APoint: TPoint);
    procedure ChartToolset1DataPointCrosshairTool1Draw(
      ASender: TDataPointCrosshairTool);
    procedure connectButtonClick(Sender: TObject);
    procedure SerialComboBoxDropDown(Sender: TObject);
    procedure SingleShotCheckChange(Sender: TObject);
    procedure RunningCheckChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormShow(Sender: TObject);
    procedure FrameWidthSelectorClick(Sender: TObject);
    procedure ReferenceVoltageSelectorChange(Sender: TObject);
    procedure TriggerOptionsRadioBoxClick(Sender: TObject);
  private
    SerialThread: TSerialInterface;
    running: boolean;
    TimeFrame: double;
    buf: array of byte;
    data: array of word;
    AskForNewData: boolean;
    PreviousFrameTime: TimerData;
    epTimer: TEpikTimer;
    numPortsSelected: integer;
    connected: boolean;

    procedure Processdata;
    procedure Status(const s: string; stopRun: boolean);
    procedure DataWaiting(var Message: TLMessage); message WM_DataWaiting;
    procedure CheckSelectedADCchannels;
    function CloseSerialThread: boolean;
    procedure doConnected;
    procedure doDisconnected;
    // Returns true on success
    function waitForCmdReply: boolean;
    procedure updateTriggerLimits;
  public
    { public declarations }
  end; 

var
  Form1: TForm1;
  numsamples: integer = 0;
  bufsize: integer;
  singleShot: boolean = false;

implementation

{$R *.lfm}

{ TForm1 }

uses
  TACustomSeries, TAChartUtils, serialobject;

const
  LineColors: array[0..7] of TColor =
    (clLime, clBlue, clRed, clPurple, clYellow, clMaroon, clWhite, clAqua);

procedure TForm1.RunningCheckChange(Sender: TObject);
begin
  if RunningCheck.Checked then
  begin
    AskForNewData := true;
    SerialThread.SetCommand(cmdSendData);  // Get thread processing

    epTimer.Clear(PreviousFrameTime);
    epTimer.Start(PreviousFrameTime);
  end
  else
    AskForNewData := false;
end;

procedure TForm1.ADCchannelsListItemClick(Sender: TObject; Index: integer);
begin
  CheckSelectedADCchannels;
end;

procedure TForm1.ADCResolutionSelectorChange(Sender: TObject);
var
  s: string;
begin
  s := ADCResolutionSelector.Items[ADCResolutionSelector.ItemIndex];
  if s = '8 bit' then
    SerialThread.SetCommand(cmdSet8bit)
  else if s = '10 bit' then
    SerialThread.SetCommand(cmdSet10bit);

  updateTriggerLimits;
  TriggerOptionsRadioBoxClick(nil);
end;

procedure TForm1.ChartToolset1DataPointCrosshairTool1AfterKeyUp(
  ATool: TChartTool; APoint: TPoint);
begin
  TAChartUtils.Unused(ATool, APoint);
  ChartToolset1DataPointCrosshairTool1.Hide;
end;

procedure TForm1.ChartToolset1DataPointCrosshairTool1AfterMouseMove(
  ATool: TChartTool; APoint: TPoint);
begin
  TAChartUtils.Unused(ATool, APoint);
  Chart1.SetFocus;
end;

procedure TForm1.ChartToolset1DataPointCrosshairTool1Draw(
  ASender: TDataPointCrosshairTool);
const
  R = 20;
var
  p: TPoint;
begin
  p := Chart1.GraphToImage(ASender.Position);

  Chart1.Drawer.Ellipse(p.X - R, p.Y - R, p.X + R, p.Y + R);
  LabelX.Caption := FloatToStrF(ASender.Position.X, ffFixed, 4, 3);
  LabelY.Caption := IntToStr(round(ASender.Position.y));
end;

procedure TForm1.connectButtonClick(Sender: TObject);
var
  cmd: byte;
  baud, i: integer;
  OK: boolean;
begin
  if not connected then
  begin
    baud := StrToInt(BaudEdit.Text);
    if (SerialComboBox.Text <> '') and (baud > 0) then
    begin
      if not assigned(SerialThread) then
      begin
        SerialThread := TSerialInterface.Create(SerialComboBox.Text, baud);

        AskForNewData := false;
        SerialThread.OnErrorNotify := @self.Status;
      end;

      // Check if device responds correctly to echo
      SerialThread.SetCommand(cmdEcho);
      OK := waitForCmdReply and (SerialThread.SerialReturnValue = cmdEcho);

      // Get size of data buffer
      if OK then
      begin
        SerialThread.SerialReturnValue := 0;
        SerialThread.SetCommand(cmdGetBufferSize);
        OK := waitForCmdReply and (SerialThread.SerialReturnValue > 0);
        if OK then
        begin
          bufsize := SerialThread.SerialReturnValue;
          SetLength(buf, bufsize);
        end;
      end;

      // Configure default prescaler setting
      if OK then
      begin
        ADCScalerSelector.ItemIndex := 3;
        cmd := cmdSetADCDiv2 + ADCScalerSelector.ItemIndex;
        SerialThread.SetCommand(cmd);
      end;

      // Check if controller supports 2.56V internal reference
      if OK then
      begin
        SerialThread.SetCommand(cmdGetADCVoltage_2_56);
        OK := waitForCmdReply;
        if OK and (SerialThread.SerialReturnValue = cmdHasADCVoltage_2_56) then
        begin
          if ReferenceVoltageSelector.Items.Count < 4 then
            ReferenceVoltageSelector.Items.Add('2.56V');
        end
        else
        begin
          if ReferenceVoltageSelector.Items.Count > 3 then
          begin
            i := ReferenceVoltageSelector.ItemIndex;
            ReferenceVoltageSelector.Items.Delete(ReferenceVoltageSelector.Items.Count-1);
            // Preserve previous item, unless it was the last item just deleted
            if i < ReferenceVoltageSelector.Items.Count then
              ReferenceVoltageSelector.ItemIndex := i
            else
              ReferenceVoltageSelector.ItemIndex := 0;
          end;
        end;
      end;

      // Configure ADC channels
      if OK then
      begin
        SerialThread.SerialReturnValue := 0;
        SerialThread.SetCommand(cmdListADCchannels);
        OK := waitForCmdReply and (SerialThread.SerialReturnValue > 0);
        if OK then
        begin
          ADCchannelsList.Items.Clear;
          cmd := SerialThread.SerialReturnValue;
          for i := 0 to 7 do
          begin
            if (cmd and (1 shl i)) > 0 then
              ADCchannelsList.Items.Add(IntToStr(i));
          end;

          // Sync ADC prescaler with Arduino
          ADCchannelsList.Checked[0] := true;
          CheckSelectedADCchannels;
        end;
      end;

      // Configure supported data resolutions
      if OK then
      begin
        SerialThread.SerialReturnValue := 0;
        SerialThread.SetCommand(cmdListResolutions);
        OK := waitForCmdReply and ((SerialThread.SerialReturnValue and 3) > 0);
        if OK then
        begin
          ADCResolutionSelector.Items.Clear;
          i := SerialThread.SerialReturnValue;
          if (i and 1) = 1 then
            ADCResolutionSelector.Items.Add('8 bit');
          if (i and 2) = 2 then
            ADCResolutionSelector.Items.Add('10 bit');

          // Default to lower resolution
          ADCResolutionSelector.ItemIndex := 0;
          ADCResolutionSelectorChange(nil);

          // Sync ADC trigger with GUI
          TriggerOptionsRadioBoxClick(nil);
          doConnected;
          connected := true;
        end;
      end
      else
      begin
        CloseSerialThread;
        doDisconnected;
        Status('Error connecting to '+SerialComboBox.Text, true);
        connected := false;
      end;
    end;
  end
  else  // connected, so disconnect now
  begin
    CloseSerialThread;
    doDisconnected;
    connected := false;
  end;
end;

procedure TForm1.SerialComboBoxDropDown(Sender: TObject);
begin
  SerialComboBox.Items.CommaText := GetSerialPortNames;
end;

procedure TForm1.SingleShotCheckChange(Sender: TObject);
begin
  singleShot :=  SingleShotCheck.Checked;
end;

procedure TForm1.ADCchannelsListClick(Sender: TObject);
begin
  CheckSelectedADCchannels;
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  if not CloseSerialThread then
  begin
    Status('Could not close serial thread, calling Halt', false);
    Application.ProcessMessages;
    Sleep(1500);
    Halt(255);
  end;
end;

procedure TForm1.FormShow(Sender: TObject);
begin
  epTimer := TEpikTimer.Create(self);
  if epTimer.HWCapabilityDataAvailable then
    epTimer.TimebaseSource:= HardwareTimebase;

  Chart1.Extent.YMin := 0;
  Chart1.Extent.YMax := 1024;
  Chart1.Extent.UseYMin := true;
  Chart1.Extent.UseYMax := true;
  Chart1.Extent.XMin := 0;
  Chart1.Extent.XMax := TimeFrame;
  Chart1.Extent.UseXMin := true;
  Chart1.Extent.UseXMax := true;
  Chart1.BottomAxis.Title.Caption := 'Time - ms';
  Chart1.BottomAxis.Title.Visible := true;
end;

procedure TForm1.FrameWidthSelectorClick(Sender: TObject);
var
  cmd: byte;
begin
  cmd := cmdSetADCDiv2 + ADCScalerSelector.ItemIndex;
  SerialThread.SetCommand(cmd);
end;


procedure TForm1.ReferenceVoltageSelectorChange(Sender: TObject);
var
  cmd: byte;
begin
  cmd := cmdSetADCVoltage_VCC + byte(ReferenceVoltageSelector.ItemIndex);
  SerialThread.SetCommand(cmd);

  updateTriggerLimits;
  TriggerOptionsRadioBoxClick(nil);
end;

procedure TForm1.TriggerOptionsRadioBoxClick(Sender: TObject);
var
  val: byte;
  rawVal: integer;
  s: string;
begin
  rawVal := TriggerLevelEdit.Value;
  s := ADCResolutionSelector.Text;
  // Scale trigger value from mV to ADC count
  if ReferenceVoltageSelector.ItemIndex = 1 then
  begin
    // Max = 1020 mV
    if s = '8 bit' then
      val := rawVal shr 4
    else
      val := rawVal shr 2;
  end
  else if ReferenceVoltageSelector.ItemIndex = 3 then
  begin
    // Max = 2550 mV
    if s = '8 bit' then
      val := rawVal div 40
    else
      val := rawVal div 10;
  end
  else
    val := rawVal shr 2;

  case TriggerOptionsRadioBox.ItemIndex of
  1: begin
       SerialThread.SetCommand(cmdTriggerRising);
       SerialThread.SetCommand(val);
     end;
  2: begin
       SerialThread.SetCommand(cmdTriggerFalling);
       SerialThread.SetCommand(val);
     end;
  else
    SerialThread.SetCommand(cmdTriggerOff);
  end;
end;

procedure TForm1.Processdata;
var
  i, j, yscale: integer;
  checksum, l, h, d: byte;
  t: dword;
  delta: double;
  Vref, currentChannelCount: integer;
  tenBitData, triggered: boolean;
  newLineSeries: TLineSeries;
begin
  checksum := 0;

  // Data settings byte
  case (buf[0] and $03) of
    1: Vref := 1100;
    2: Vref := 2560;
  otherwise
    Vref := 0;  // Vcc or Aref
  end;
  triggered := (buf[0] and triggerMask) <> 0;
  tenBitData := (buf[0] and tenBitFlagMask) <> 0;
  checksum := checksum XOR buf[0];

  // Channels
  d := buf[1];
  checksum := checksum XOR buf[1];

  currentChannelCount := PopCnt(d);
  if currentChannelCount > Chart1.SeriesCount then
    while currentChannelCount > Chart1.SeriesCount do
    begin
      newLineSeries := TLineSeries.Create(self);
      Chart1.AddSeries(newLineSeries);
    end
  else if currentChannelCount < Chart1.SeriesCount then
    while currentChannelCount < Chart1.SeriesCount do
      Chart1.DeleteSeries(Chart1.Series[Chart1.SeriesCount-1]);

  j := 0;
  for i := 0 to 7 do
  begin
    if ((d shr i) and 1) <> 0 then
    begin
      TLineSeries(Chart1.Series[j]).Title := 'A' + IntToStr(i);
      TLineSeries(Chart1.Series[j]).SeriesColor := LineColors[j];
      inc(j);
    end;
  end;

  // Subtract sizeof information
  numsamples := bufsize - 7;

  if tenBitData then
  begin
    // Adjust for 10 bit packing
    numsamples := (numsamples div 3) * 2 + ((numsamples mod 3) shr 1);
    yscale := 1023;
  end
  else
  begin
    yscale := 255;
  end;

  if Vref = 0 then
  begin
    Chart1.LeftAxis.Title.Caption := 'ADC counts';
    Chart1.Extent.YMax := yscale + 1;
  end
  else
  begin
    Chart1.LeftAxis.Title.Caption := 'Millivolt';
    Chart1.Extent.YMax := Vref;
  end;

  SetLength(data, numsamples);

  if tenBitData then
    for i := 0 to length(data)-1 do
    begin
      j := 3*(i shr 1) + (i mod 2) + 2; // 2 is data starting offset into buffer

      h := buf[j];
      l := buf[j+1];
      if (i mod 2) = 0 then  // left adjusted
      begin
        t := h shl 2 + l shr 6;
        data[i] := t;
        checksum := checksum XOR buf[j];
        checksum := checksum XOR buf[j + 1];
      end
      else  // right adjusted
      begin
        t := (h and %00000011);
        t := t shl 8;
        t := t + l;
        data[i] := t;
        checksum := checksum XOR buf[j+1];
      end;
    end
  else
    for i := 0 to length(data)-1 do
    begin
      j := i + dataOffset;
      data[i] := buf[j];
      checksum := checksum XOR buf[j];
    end;

  // Time frame in microseconds
  j := bufsize - 5;
  t := (buf[j + 0] shl 24);
  t := t + (buf[j + 1] shl 16);
  t := t + (buf[j + 2] shl 8);
  t := t + buf[j + 3];
  checksum := checksum XOR buf[j + 0];
  checksum := checksum XOR buf[j + 1];
  checksum := checksum XOR buf[j + 2];
  checksum := checksum XOR buf[j + 3];

  TimeFrame := t / 1000;  // convert to milliseconds
  StatusBar1.Panels[1].Text := FloatToStrF(TimeFrame, ffFixed, 3, 2);

  // Set Extent to some sensible rounded value
  if TimeFrame < 10 then
    Chart1.Extent.XMax := round((TimeFrame*10) + 0.5) / 10
  else
    Chart1.Extent.XMax := round(TimeFrame + 0.5);

  // Check checksum:
  checksum := checksum XOR buf[j + 4];

  if currentChannelCount = 0 then exit;

  for j := 0 to currentChannelCount-1 do
  begin
    TLineSeries(Chart1.Series[j]).Clear;
    TLineSeries(Chart1.Series[j]).BeginUpdate;
  end;

  delta := TimeFrame / (numsamples-1);
  j := 0;
  for i := 0 to numsamples-1 do
  begin
    if Vref = 0 then
      TLineSeries(Chart1.Series[j]).AddXY(delta*i, data[i])
    else
      TLineSeries(Chart1.Series[j]).AddXY(delta*i, data[i]*Vref/yscale);

    // Waiting for trigger condition gives two data points for the first channel
    // So add the first two data points to the first series
    if (i > 0) or not triggered or (currentChannelCount = 1) then
      inc(j);

    if j = currentChannelCount then
      j := 0;
  end;

  for j := 0 to currentChannelCount-1 do
    TLineSeries(Chart1.Series[j]).EndUpdate;

  if checksum = 0 then
    Status('OK', false)
  else
  begin
    // Do not stop, could be a temporary problem
    Status('Checksum failed', false);
    Application.ProcessMessages;
    Sleep(100);
  end;
end;

procedure TForm1.Status(const s: string; stopRun: boolean);
begin
  StatusBar1.Panels[6].Text := s;

  // An error (e.g. time-out) interrupted data flow
  if stopRun then
  begin
    RunningCheck.Checked := false;
    AskForNewData := false;
  end;
end;

procedure TForm1.DataWaiting(var Message: TLMessage);
var
  localtimedata: TimerData;
begin
  // Check for race condition if serial thread is terminated while main thread is pulling data
  if Assigned(SerialThread) and AskForNewData then
    SerialThread.PullData(buf)
  else
    exit;

  if AskForNewData and not singleShot then
    SerialThread.SetCommand(cmdSendData)
  else
    RunningCheck.Checked := false;

  epTimer.Stop(PreviousFrameTime);
  StatusBar1.Panels[3].Text := FloatToStrF(epTimer.Elapsed(PreviousFrameTime)*1000, ffGeneral, 4, 3);
  epTimer.Clear(PreviousFrameTime);
  epTimer.Start(PreviousFrameTime);

  epTimer.Clear(localtimedata);
  epTimer.Start(localtimedata);
  Processdata;
  epTimer.Stop(localtimedata);
  StatusBar1.Panels[5].Text := FloatToStrF(epTimer.Elapsed(localtimedata)*1000, ffGeneral, 4, 3);
end;

procedure TForm1.CheckSelectedADCchannels;
var
  i, offset: integer;
  PortsSelected: byte;
  newLineSeries: TLineSeries;
  sl: TStringList;
begin
  PortsSelected := 0;
  numPortsSelected := 0;
  sl := TStringList.Create;

  offset := StrToInt(ADCchannelsList.Items[0]);
  for i := 0 to ADCchannelsList.Items.Count-1 do
    if ADCchannelsList.Checked[i] then
    begin
      PortsSelected := PortsSelected + (1 shl (i+offset));
      inc(numPortsSelected);
      sl.Add(copy(ADCchannelsList.Items[i], 1, 2));
    end;

  // Same number of series & ports
  if numPortsSelected > Chart1.SeriesCount then
    while numPortsSelected > Chart1.SeriesCount do
    begin
      newLineSeries := TLineSeries.Create(self);
      Chart1.AddSeries(newLineSeries);
    end
  else if numPortsSelected < Chart1.SeriesCount then
    while numPortsSelected < Chart1.SeriesCount do
      Chart1.DeleteSeries(Chart1.Series[Chart1.SeriesCount-1]);

  // Copy titles of series from saved list
  for i := 0 to sl.Count-1 do
  begin
    TLineSeries(Chart1.Series[i]).Title := sl[i];
    TLineSeries(Chart1.Series[i]).SeriesColor := LineColors[i];
  end;

  sl.free;

  SerialThread.SetCommand(cmdSetActiveADCchannels);
  SerialThread.SetCommand(PortsSelected);
end;

function TForm1.CloseSerialThread: boolean;
var
  timeout: integer;
begin
  AskForNewData := false;
  running := false;
  if Assigned(SerialThread) then
  begin
    SerialThread.WakeUpAndTerminate;
    timeout := 10;
    while not SerialThread.Done and (timeout > 0) do
    begin
      Application.ProcessMessages;
      Sleep(100);
      dec(timeout);
    end;
    Result := SerialThread.Done;
    if not Result then
      FreeAndNil(SerialThread);
  end
  else
    Result := true;
end;

procedure TForm1.doConnected;
begin
  RunningCheck.Enabled := true;
  RunningCheck.Checked := false;
  AskForNewData := false;
  SingleShotCheck.Enabled := true;
  ADCScalerSelector.Enabled := true;
  ADCchannelsList.Enabled := true;
  ADCResolutionSelector.Enabled := true;
  ReferenceVoltageSelector.Enabled := true;
  TriggerOptionsRadioBox.Enabled := true;
  TriggerLevelEdit.Enabled := true;
  SerialComboBox.Enabled := false;
  BaudEdit.Enabled := false;
  connectButton.Caption := 'Disconnect';
  Status('Connected to '+SerialComboBox.Text, false);
end;

procedure TForm1.doDisconnected;
begin
  RunningCheck.Enabled := false;
  SingleShotCheck.Enabled := false;
  ADCScalerSelector.Enabled := false;
  ADCchannelsList.Enabled := false;
  ADCResolutionSelector.Enabled := false;
  ReferenceVoltageSelector.Enabled := false;
  TriggerOptionsRadioBox.Enabled := false;
  TriggerLevelEdit.Enabled := false;
  SerialComboBox.Enabled := true;
  BaudEdit.Enabled := true;
  connectButton.Caption := 'Connect';
  Status('Disconnected', true);
end;

function TForm1.waitForCmdReply: boolean;
var
  i: integer;
begin
  i := 0;
  repeat
    Sleep(10);
    Application.ProcessMessages;
    inc(i);
  until (SerialThread.SerialReturnValue > 0) or (i > 100);
  Result := i < 100;
end;

procedure TForm1.updateTriggerLimits;
var
  s: string;
  oldVal, oldMax: integer;
begin
  oldVal := TriggerLevelEdit.Value;
  oldMax := TriggerLevelEdit.MaxValue;
  // If reference is in mV, trigger max should also be in mV
  if ReferenceVoltageSelector.ItemIndex in [1, 3] then
  begin
    if ReferenceVoltageSelector.ItemIndex = 1 then
    begin
      TriggerLevelEdit.MaxValue := 1020; // mV
      TriggerLevelEdit.Increment := 4;
    end
    else
    begin
      TriggerLevelEdit.MaxValue := 2550; // mV
      TriggerLevelEdit.Increment := 10;
    end;
  end
  else
  begin
    s := ADCResolutionSelector.Items[ADCResolutionSelector.ItemIndex];
    if s = '8 bit' then
    begin
      TriggerLevelEdit.MaxValue := 252; // ADC counts
      TriggerLevelEdit.Increment := 4;
    end
    else if s = '10 bit' then
    begin
      TriggerLevelEdit.MaxValue := 1020; // ADC counts
      TriggerLevelEdit.Increment := 4;
    end;
  end;

  // Update trigger value to maintain approximately the same ratio of the scale
  // if the scale changed
  if oldMax <> TriggerLevelEdit.MaxValue then
    TriggerLevelEdit.Value := round(oldVal/oldMax * TriggerLevelEdit.MaxValue);
end;

end.
