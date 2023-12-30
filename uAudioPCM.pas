unit uAudioPCM;

(* Delphi Audio Processing Class: Record, Play, and Manipulate PCM Data with Ease *)

(*
  todo:
  =====
  1- support compressed audio -> as property CompressionEnabled: Boolean read FCompressionEnabled write SetCompressionEnabled;

*)


(*
  Incompatible Audio Format: Some devices may not support certain audio formats.
  For example, ENCODING_PCM_8BIT might not be supported on all devices. Try using ENCODING_PCM_16BIT instead.

  Incorrect Channel Configuration: Ensure that the specified channel configuration
  is supported by your device. Some devices may support only stereo or mono configurations.

  If getMinBufferSize returns an error '-2', consider adjusting the audio parameters such as sample rate,
  channel configuration, and audio format.
  Experiment with different configurations to find a supported combination for the specific device.

  WAV Format:
  https://isip.piconepress.com/projects/speech/software/tutorials/production/fundamentals/v1.0/section_02/s02_01_p05.html

  PCM is a method of encoding audio, and WAV is a file format that can contain PCM-encoded audio data along with
  additional information in its header
*)

(*
  xx = class(Exception);
  ======================
  when you create an exception object using a class that inherits from the built-in Exception class,
  you typically don't need to explicitly free the exception object.
  This is because the Delphi runtime system takes care of deallocating the memory for the exception object
  when the exception is handled (either by a try..except block or at the top level of the application).
*)

{$WARN COMPARING_SIGNED_UNSIGNED OFF}

interface

uses
  System.Threading, System.SyncObjs, System.NetEncoding,
  System.SysUtils, System.Types, System.UITypes, System.Classes,

  zlib,

  AndroidApi.JNI.Media, AndroidApi.JNIBridge, Androidapi.Helpers;

const
  WavHeaderSize = 44;

type
  TOnRecordingProgress = procedure(ADataRecordedLength: DWORD; ATotalDuration: Double; ACurrentBuffer: TBytes) of object;

  EAudioPCMError = class(Exception);

  TAudioPCM = class
  private
    // Critical sections
    CsRecordingState: TCriticalSection;
    CsIsRecordingAndReading: TCriticalSection;
    CsIsPlaying: TCriticalSection;
    CsUpdateRecordedData: TCriticalSection;

    // Audio parameters
    FIsInitialized: Boolean;
    FSampleRate, FInChannel, FOutChannel, FFormat: Integer;
    FMintrack: Integer;
    FMinBufferSize: Integer;

    // Audio objects
    FAudioPlay: JAudioTrack;
    FAudioRecorder: JAudioRecord;
    FAudioArray: TJavaArray<Byte>;
    FRecordedData: TArray<Byte>;

    // State variables
    FRecordingState: Boolean;
    FVolume: Single;

    // use Compression
    FCompressCurrentBuffer: Boolean;

    // Event
    FOnRecordingProgress: TOnRecordingProgress;

    // Private methods
    function IniRecorder: Boolean;
    function IniAudioTrack: Boolean;
    procedure SetRecordingState(AValue: Boolean);
    function GetRecordingState: Boolean;
    function CompressByteArray(const Input: TBytes): TBytes;
    function ConvertBufferToBase64(Buffer: TArray<Byte>): string;
    function ConvertBase64ToBuffer(EncodedBuffer: string): TBytes;
    function PrepareHtmlCode(AudioBase64: string): string;
    function CreateWavHeader(Length, samplefrequency, monostereoflag, BitsPerSample: Integer): TArray<Byte>;
    function ReadBuffer: TArray<Byte>;
    procedure SetRecordedData(Buffer: TArray<Byte>);
    function GetRecordedData: TArray<Byte>;
    function PlayBuffer(Buffer: TArray<Byte>): Integer;
    procedure SetOnRecordingProgress(const Value: TOnRecordingProgress);
    function CalcTimeToWaitAfterReadBuffer: Integer;
    function GetRecordedDataLength: DWORD;
    function IsValidRange(StartPos, EndPos: PInteger): Boolean;
    function GetBitDepth(Encoding: Integer): Integer;
    function GetChannelCount(ChannelConfig: Integer): Integer;
    procedure RaiseException(E: string);
    function GetPlayingSate: Boolean;
    function GetDuration: Double;
    function GetVolume: Single;
    procedure SetVolume(const Value: Single);
    procedure SetCompressCurrentBuffer(const Value: Boolean);
  public
    // Constructor and Destructor
    constructor Create(ASampleRate, AInChannel, AOutChannel, AFormat: Integer);
    destructor Destroy; override;

    // Public methods
    procedure StopRecording;
    procedure StartRecording;
    function PlayPartialBuffer(StartPos, EndPos: DWORD): Integer; overload;
    function PlayPartialBuffer(Buffer: TBytes): Integer; overload;
    function GetHtmlBase64PCM(StartPos, EndPos: DWORD): string; overload;
    function GetHtmlBase64PCM(Buffer: TBytes): string; overload;
    function GetBase64PCM(StartPos, EndPos: DWORD; AddWavHeader, Compress: Boolean): string; overload;
    function GetBase64PCM(EncodedCompressedByffer: string): string; overload;
    function GetPartialBuffer(StartPos, EndPos: DWORD; Compress: Boolean = False): TArray<Byte>;
    function ClearBuffer: Boolean;
    function DecompressBuffer(const Input: TBytes): TBytes;
    function CalculateDuration(ARecordedDataLength: Integer): Double;
    function LoadFromFile(const FileName: string): TBytes;
    procedure SaveToFile(const FileName: string; StartPos, EndPos: DWORD; AddWavHeader: Boolean = True);
    function TrimSilence8BitFormat(const AudioData: TBytes): TBytes;
    procedure PausePlaying;
    procedure ResumePlaying;
    // Properties
    property IsInitialized: Boolean read FIsInitialized;
    property RecordedData: TArray<Byte> read GetRecordedData write SetRecordedData;
    property RecordingState: Boolean read GetRecordingState;
    property PlayingState: Boolean read GetPlayingSate;
    property Duration: Double read GetDuration;
    property Volume: Single read GetVolume write SetVolume;
    property CompressCurrentBuffer: Boolean read FCompressCurrentBuffer write SetCompressCurrentBuffer;
    property OnRecordingProgress: TOnRecordingProgress read FOnRecordingProgress write SetOnRecordingProgress;
  end;

implementation

{ TAudioPCM }



{$REGION 'Private methods'}

function TAudioPCM.IniAudioTrack: Boolean;
begin
  if Assigned(FAudioPlay) then
  begin
    Result := FAudioPlay.getState = TJAudioTrack.JavaClass.STATE_INITIALIZED;

    if Result = True then Exit;
  end
  else
  Result := False;

  try
    FMintrack := TJAudioTrack.JavaClass.getMinBufferSize
                                                        (
                                                          FSampleRate,
                                                          FOutChannel,
                                                          FFormat
                                                        );
    //ERROR_BAD_VALUE
    if FMintrack = -2 then FMintrack := 1024;

    FAudioPlay:= TJAudioTrack.JavaClass.init
                                           (
                                              TJAudioManager.JavaClass.STREAM_MUSIC,
                                              FSampleRate,
                                              FOutChannel,
                                              FFormat,
                                              FMintrack,
                                              TJAudioTrack.JavaClass.MODE_STREAM
                                           );

    // Check the state
    if FAudioPlay.getState = TJAudioTrack.JavaClass.STATE_INITIALIZED then
    begin
      // AudioTrack has been successfully initialized
      if FAudioPlay.getPlayState <> TJAudioTrack.JavaClass.PLAYSTATE_PLAYING then
      FAudioPlay.play;

      Result := True;
    end;

  except
    on E: Exception do
    RaiseException('IniAudioTrack err: ' + E.Message);
  end;

end;

function TAudioPCM.IniRecorder: Boolean;
begin
  if Assigned(FAudioRecorder) then
  begin
    Result := (FAudioRecorder.getState = TJAudioRecord.JavaClass.STATE_INITIALIZED);

    if Result = True then Exit;
  end
  else
  Result := False;

  try
    FMinBufferSize := TJAudioRecord.JavaClass.getMinBufferSize
                                                             (
                                                               FSampleRate ,
                                                               FInChannel,
                                                               FFormat
                                                             );
    //ERROR_BAD_VALUE
    if FMinBufferSize = -2 then FMinBufferSize := 1024;

    FAudioRecorder:= TJAudioRecord.JavaClass.init
                                                (
                                                  TJMediaRecorder_AudioSource.JavaClass.MIC,
                                                  FSampleRate ,
                                                  FInChannel,
                                                  FFormat,
                                                  FMinBufferSize
                                                );

    // Check the state
    if FAudioRecorder.getState = TJAudioRecord.JavaClass.STATE_INITIALIZED then
    begin
      // AudioRecord has been successfully initialized
      FAudioArray := TJavaArray<Byte>.Create(FMinBufferSize);

      FAudioRecorder.startRecording;

      Result := True;
    end
  except
    on E: Exception do
    RaiseException('IniRecorder err: ' + E.Message);
  end;
end;

procedure TAudioPCM.SetRecordingState(AValue: Boolean);
begin
  CsRecordingState.Enter;
  try
    FRecordingState := AValue;
  finally
    CsRecordingState.Leave;
  end;
end;

function TAudioPCM.GetRecordingState: Boolean;
begin
  CsRecordingState.Enter;
  try
    Result := FRecordingState;
  finally
    CsRecordingState.Leave;
  end;
end;

function TAudioPCM.CompressByteArray(const Input: TBytes): TBytes;
begin
  SetLength(Result, 0);
  ZCompress(Input, Result, TZCompressionLevel(3));
end;

function TAudioPCM.ConvertBufferToBase64(Buffer: TArray<Byte>): string;
begin
  try
    // Convert the byte array to Base64
    Result := TNetEncoding.Base64.EncodeBytesToString(Buffer);
  except
    Result := EmptyStr;
  end;
end;

function TAudioPCM.ConvertBase64ToBuffer(EncodedBuffer: string): TBytes;
begin
  try
    // Decode String To Bytes
    Result := TNetEncoding.Base64.DecodeStringToBytes(EncodedBuffer);
  except

  end;
end;

function TAudioPCM.PrepareHtmlCode(AudioBase64: string): string;
begin
  try
    Result :=
              '<!DOCTYPE html>'+
              '<html>'+
              '<head>'+
              '</head>'+
              '<body>'+
              '    <audio controls>'+
              '        <source type="audio/wav" src="data:audio/wav;base64,' + AudioBase64 + '">' +
              '        Your browser does not support the audio tag or there is an issue playing the audio.' +
              '    </audio>'+
              '</body>'+
              '</html>';
  except
    Result := EmptyStr;
  end;
end;

function TAudioPCM.CreateWavHeader(Length, samplefrequency, monostereoflag, BitsPerSample : Integer): TArray<Byte>;
var
  RIFFfiledescriptionheader: array [0..3] of AnsiChar;
  sizeoffile: dword;
  wavedescription: array [0..7] of AnsiChar;
  sizeofWAVsectionchunk: dword;
  WAVtypeformat: word;
  ByteRate: dword;
  datadescriptionheader: array [0..3] of AnsiChar;
  BlockAlign,
  sizeofthedatachunk: DWORD;
begin
  try
    // Construct the WAVE header
    RIFFfiledescriptionheader := 'RIFF';
    sizeoffile := 36 + Length;
    wavedescription := 'WAVEfmt ';
    sizeofWAVsectionchunk := 16;
    WAVtypeformat := 1; // PCM
    ByteRate := samplefrequency * monostereoflag * (BitsPerSample div 8);
    BlockAlign := monostereoflag * (BitsPerSample div 8);
    datadescriptionheader := 'data';
    sizeofthedatachunk := Length;

    // Set the length of the result array
    SetLength(Result, WavHeaderSize);

    // Copy values to the result array
    Move(RIFFfiledescriptionheader[0], Result[0], 4);
    Move(sizeoffile, Result[4], SizeOf(DWORD));
    Move(wavedescription[0], Result[8], 8);
    Move(sizeofWAVsectionchunk, Result[16], SizeOf(DWORD));
    Move(WAVtypeformat, Result[20], SizeOf(Word));
    Move(monostereoflag, Result[22], SizeOf(Word));
    Move(samplefrequency, Result[24], SizeOf(DWORD));
    Move(ByteRate, Result[28], SizeOf(DWORD));
    Move(BlockAlign, Result[32], SizeOf(Word));
    Move(BitsPerSample, Result[34], SizeOf(Word));
    Move(datadescriptionheader, Result[36], 4);
    Move(sizeofthedatachunk, Result[40], SizeOf(DWORD));
  except
    on E: Exception do
    RaiseException('CreateWavHeader err: ' + E.Message);
  end;
end;

function TAudioPCM.ReadBuffer: TArray<Byte>;
begin
  try
    (*
      The read mode indicating the read operation will block until all data requested has been read.
      Constant Value: 0 (0x00000000)
    *)

    FAudioRecorder.read(FAudioArray, 0, FMinBufferSize, 0);
    Result := TJavaArrayToTBytes(FAudioArray)
  except
    on E: Exception do
    RaiseException('ReadDataRecorded err: ' + E.Message);
  end;
end;

// Save recorded data.
procedure TAudioPCM.SetRecordedData(Buffer: TArray<Byte>);
begin
  TTask.Run(procedure
  var
    PreviousLength: Integer;
    NewLength     : Integer;
    Duration      : Double;
    CompressedBuffer: TArray<Byte>;
  begin
    CsUpdateRecordedData.Enter;
    try
      // Store the recorded data in the buffer array
      PreviousLength := Length(FRecordedData);
      NewLength      := PreviousLength + length(Buffer);
      SetLength(FRecordedData, NewLength);
      Move(Buffer[0], FRecordedData[PreviousLength], Length(Buffer));

      if Assigned(FOnRecordingProgress) then
      begin
        // Just compress buffer send via event OnRecordingProgress
        if FCompressCurrentBuffer then
        begin
          CompressedBuffer := CompressByteArray(Buffer);
          Buffer           := CompressedBuffer;
        end;

        Duration := CalculateDuration(NewLength);
        FOnRecordingProgress(NewLength, Duration, Buffer);
      End;

    finally
      CsUpdateRecordedData.Leave;
    end;
  end);
end;

function TAudioPCM.GetRecordedData: TArray<Byte>;
begin
  CsUpdateRecordedData.Enter;
  try
    Result := FRecordedData;
  finally
    CsUpdateRecordedData.Leave;
  end;
end;

function TAudioPCM.PlayBuffer(Buffer: TArray<Byte>): Integer;
begin
  CsIsPlaying.Enter;
  try
    Result := 0;
    try
      if FIsInitialized then
      Result := FAudioPlay.write(TBytesToTJavaArray(Buffer), 0, Length(Buffer));
    except
      on E: Exception do
      RaiseException('Playing err ' + E.Message);
    end;
  finally
    CsIsPlaying.Leave;
  end;
end;

procedure TAudioPCM.SetOnRecordingProgress(const Value: TOnRecordingProgress);
begin
  FOnRecordingProgress := Value;
end;

function TAudioPCM.CalcTimeToWaitAfterReadBuffer: Integer;
begin
  (* Time between reads =  ((MinBufferSize / samplefrequency(8000, 44100, ...) * BytesPerSample(8bit, 16bit ...) * mono or stereo flag (1, 2 ...)) * 1000) *)
  Result := round(FMinBufferSize / (FSampleRate * GetBitDepth(FFormat) * GetChannelCount(FInChannel)) * 1000);
end;

function TAudioPCM.GetRecordedDataLength: DWORD;
begin
  Result := 0;

  CsUpdateRecordedData.Enter;
  try
    if FIsInitialized then
    Result := Length(RecordedData);
  finally
    CsUpdateRecordedData.Release;
  end;
end;

//using pointer like PInteger just for can update EndPos value in proc caller.
function TAudioPCM.IsValidRange(StartPos, EndPos: PInteger): Boolean;
var
  RecordedDataLength: Int64;
begin
  Result := False;

  RecordedDataLength := GetRecordedDataLength;

  if EndPos^ > RecordedDataLength then  EndPos^ := RecordedDataLength;

  if EndPos^ = 0 then  Exit;

  Result := (StartPos^ < RecordedDataLength) and
            (EndPos^ > StartPos^) and
            ((StartPos^ + (EndPos^ - StartPos^)) <= RecordedDataLength);
end;

function TAudioPCM.GetBitDepth(Encoding: Integer): Integer;
begin
  if Encoding = TJAudioFormat.JavaClass.ENCODING_PCM_8BIT then          Result := 8
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_PCM_16BIT then    Result := 16
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_PCM_FLOAT then    Result := 32
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_AC3 then          Result := 16 // Example, actual bit depth may vary
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_DOLBY_TRUEHD then Result := 24 // Example, actual bit depth may vary
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_DTS then          Result := 24 // Example, actual bit depth may vary
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_DTS_HD then       Result := 24 // Example, actual bit depth may vary
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_E_AC3 then        Result := 16 // Example, actual bit depth may vary
  else if Encoding = TJAudioFormat.JavaClass.ENCODING_IEC61937 then     Result := 16 // Example, actual bit depth may vary
  // Add more conditions as needed for other encodings
  else
  Result := 0; // Unknown encoding
end;

function TAudioPCM.GetChannelCount(ChannelConfig: Integer): Integer;
begin
  if (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_MONO) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_IN_MONO) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_CENTER) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_BACK_CENTER) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_LEFT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_RIGHT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_BACK_LEFT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_BACK_RIGHT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_LOW_FREQUENCY) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_LEFT_OF_CENTER) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_RIGHT_OF_CENTER) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_SIDE_LEFT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_SIDE_RIGHT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_QUAD) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_5POINT1) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1_SURROUND) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_DEFAULT) or
     (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_INVALID)
  then
    Result := 1 // Mono
  else if (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_STEREO) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_IN_STEREO) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_LEFT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_RIGHT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_BACK_LEFT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_BACK_RIGHT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_LEFT_OF_CENTER) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_FRONT_RIGHT_OF_CENTER) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_SIDE_LEFT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_SIDE_RIGHT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_QUAD) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_5POINT1) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1_SURROUND) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_DEFAULT) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_INVALID)
  then
    Result := 2 // Stereo
  else if (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_5POINT1) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1) or
          (ChannelConfig = TJAudioFormat.JavaClass.CHANNEL_OUT_7POINT1_SURROUND)
  then
    Result := 6 // 5.1, 7.1
  // Add more conditions as needed for other configurations
  else
  Result := 0; // Unknown configuration
end;

procedure TAudioPCM.RaiseException(E: string);
begin
  TThread.Queue(nil, procedure
  begin
    raise EAudioPCMError.Create(E);
  end);
end;

function TAudioPCM.GetPlayingSate: Boolean;
begin
  Result := not CsIsPlaying.TryEnter;
  if Result = False then
  CsIsPlaying.Leave;
end;

function TAudioPCM.GetDuration: Double;
var
  NumberOfFrames: Int64;
begin
  // Calculate the number of audio frames based on the duration and sample rate
  NumberOfFrames := GetRecordedDataLength div (GetBitDepth(FFormat) div 8) div GetChannelCount(FInChannel);

  // Convert the number of frames to seconds (perform division separately)
  Result := NumberOfFrames / FSampleRate;
end;

procedure TAudioPCM.SetVolume(const Value: Single);
begin
  if FVolume <> Value then
  begin
    FVolume := Value;

    // Apply the volume only if the audio is playing
    if FIsInitialized and (FAudioPlay.getState = TJAudioTrack.JavaClass.STATE_INITIALIZED) then
      FAudioPlay.setStereoVolume(FVolume, FVolume);
  end;
end;

function TAudioPCM.GetVolume: Single;
begin
  Result := FVolume;
end;

procedure TAudioPCM.SetCompressCurrentBuffer(const Value: Boolean);
begin
  FCompressCurrentBuffer := Value;
end;


{$ENDREGION}

{$REGION 'Public methods'}

constructor TAudioPCM.Create(ASampleRate, AInChannel, AOutChannel, AFormat: Integer);
begin
  CsRecordingState        := TCriticalSection.Create;
  CsUpdateRecordedData    := TCriticalSection.Create;
  CsIsPlaying             := TCriticalSection.Create;
  CsIsRecordingAndReading := TCriticalSection.Create;
  FSampleRate             := ASampleRate;
  FInChannel              := AInChannel;
  FOutChannel             := AOutChannel;
  FFormat                 := AFormat;
  FIsInitialized          := False;
end;

destructor TAudioPCM.Destroy;
begin
  (* Ensure threads recording are properly terminated *)
  StopRecording;

  if Assigned(CsRecordingState) then CsRecordingState.Free;
  if Assigned(CsIsPlaying) then CsIsPlaying.Free;
  if Assigned(CsUpdateRecordedData) then CsUpdateRecordedData.Free;
  if Assigned(CsIsRecordingAndReading) then CsIsRecordingAndReading.Free;

  if Assigned(FAudioArray) then FAudioArray.Free;

  if Assigned(FAudioRecorder) then
  begin
    FAudioRecorder.stop;
    FAudioRecorder.release;
  end;

  if Assigned(FAudioPlay) then
  begin
    FAudioPlay.stop;
    FAudioPlay.release;
  end;

  inherited;
end;


procedure TAudioPCM.StopRecording;
begin
  try
    if Assigned(FAudioRecorder)and(FAudioRecorder.getRecordingState <> TJAudioRecord.JavaClass.RECORDSTATE_RECORDING) then
    FAudioRecorder.stop;

    SetRecordingState(False);
  except
    on E: Exception do
    RaiseException('StopRecording err: ' + E.Message);
  end;
end;

procedure TAudioPCM.StartRecording;
begin
   TThread.CreateAnonymousThread(procedure
   var
     TimeWait: DWORD;
     Buffer: TArray<Byte>;
   begin
      if IniRecorder and IniAudioTrack then
      begin
        if (FAudioRecorder.getRecordingState <> TJAudioRecord.JavaClass.RECORDSTATE_RECORDING) then
        FAudioRecorder.startRecording;

        SetRecordingState(True);
        FIsInitialized := True;
      end
      else
      Exit;


      // to ensure that only one thread can record and save date recorded.
      // if deadlocks then remove CsIsRecordingAndReading and
      // disable UI controls related to recording while a recording is in progress.
      if not CsIsRecordingAndReading.TryEnter then Exit;
      try
        TimeWait :=  CalcTimeToWaitAfterReadBuffer;

        while (RecordingState = True) do
        begin
          Buffer := ReadBuffer;
          SetRecordedData(Buffer);
          TThread.CurrentThread.Sleep(TimeWait);
        end;

      finally
        CsIsRecordingAndReading.Leave;
      end;

   end).Start;
end;

function TAudioPCM.PlayPartialBuffer(StartPos, EndPos: DWORD): Integer;
var
  PartialData        : TArray<Byte>;
begin
  // Get the partial audio data
  PartialData := GetPartialBuffer(StartPos, EndPos, False);

  // Check if PartialData contains data
  if Length(PartialData) = 0 then
  begin
    Result := -1;
    Exit;
  end;

  // Play the selected audio data
  Result := PlayBuffer(PartialData);
end;

function TAudioPCM.PlayPartialBuffer(Buffer: TBytes): Integer;
begin
  Result := 0;

  if not FIsInitialized then Exit;

  // Play Buffer
  Result := PlayBuffer(Buffer);
end;

function TAudioPCM.GetHtmlBase64PCM(StartPos, EndPos: DWORD): string;
var
  BufferWithHeader   : TArray<Byte>;
  PartialData        : TArray<Byte>;
begin
  // Get the partial audio data
  PartialData := GetPartialBuffer(StartPos, EndPos, False);

  // Check if PartialData contains data
  if Length(PartialData) = 0 then
  begin
    Result := EmptyStr;
    Exit;
  end;

  // Combine the WAV header with the audio data
  BufferWithHeader := CreateWavHeader(
                                       {size of PCM data without header}
                                       EndPos - StartPos,
                                       {frequency = 8000, 44100, 11025, ... }
                                       FSampleRate,
                                       {Mono= 1, stereo = 2, ...}
                                       GetChannelCount(FInChannel),
                                       {PCM_8BIT = 08, PCM_16BIT = 16, ...}
                                       GetBitDepth(FFormat)
                                      )
                                      +
                                      {PCM data without header}
                                      PartialData;

  // Convert the entire audio data (including the header) to Base64
  Result := PrepareHtmlCode(ConvertBufferToBase64(BufferWithHeader));
end;

function TAudioPCM.GetHtmlBase64PCM(Buffer: TBytes): string;
begin
  try
    // Convert the entire audio data (including the header) to Base64
    Result := PrepareHtmlCode(ConvertBufferToBase64(Buffer));
  except
    Result := EmptyStr;
  end;
end;

function TAudioPCM.GetBase64PCM(StartPos, EndPos: DWORD; AddWavHeader, Compress: Boolean): string;
var
  Buffer: TArray<Byte>;
  PartialData: TArray<Byte>;
begin
  // Get the partial audio data
  PartialData := GetPartialBuffer(StartPos, EndPos, False);

  // Check if PartialData contains data
  if Length(PartialData) = 0 then
  begin
    Result := EmptyStr;
    Exit;
  end;

  // Combine the WAV header with the audio data
  if AddWavHeader then
  begin
    Buffer := CreateWavHeader(
                               EndPos - StartPos,
                               FSampleRate,
                               GetChannelCount(FInChannel),
                               GetBitDepth(FFormat)
                             ) + PartialData;
  end
  else
  begin
    Buffer := PartialData;
  end;

  // Optionally compress the data
  if Compress then
  begin
    Buffer := CompressByteArray(Buffer);
  end;

  // Convert the buffer to Base64
  Result := ConvertBufferToBase64(Buffer);
end;

function TAudioPCM.GetBase64PCM(EncodedCompressedByffer: string): string;
begin
  try
    Result := PrepareHtmlCode(GetHtmlBase64PCM(DecompressBuffer(ConvertBase64ToBuffer(EncodedCompressedByffer))));
  except
    Result := EmptyStr;
  end;
end;

function TAudioPCM.GetPartialBuffer(StartPos, EndPos: DWORD; Compress: Boolean): TArray<Byte>;
begin
  if not FIsInitialized then Exit;
  if not IsValidRange(@StartPos, @EndPos) then Exit;

  SetLength(Result, EndPos - StartPos);
  Move(RecordedData[StartPos], Result[0], EndPos - StartPos);

  if Compress then
  Result := CompressByteArray(Result);
end;



function TAudioPCM.ClearBuffer: Boolean;
begin
  CsUpdateRecordedData.Enter;
  try
    try
      SetLength(FRecordedData, 0);
    except
      on E: Exception do
      RaiseException('ClearBuffer err: ' + E.Message);
    end;
  finally
    CsUpdateRecordedData.Release;
    Result := GetRecordedDataLength = 0;
  end;
end;

function TAudioPCM.DecompressBuffer(const Input: TBytes): TBytes;
begin
  SetLength(Result, 0);
  ZDecompress(Input, Result);
end;

function TAudioPCM.CalculateDuration(ARecordedDataLength: Integer): Double;
var
  NumberOfFrames: Int64;
begin
  // Calculate the number of audio frames based on the duration and sample rate
  NumberOfFrames := ARecordedDataLength div (GetBitDepth(FFormat) div 8) div GetChannelCount(FInChannel);

  // Convert the number of frames to seconds (perform division separately)
  Result := NumberOfFrames / FSampleRate;
end;

function TAudioPCM.LoadFromFile(const FileName: string): TBytes;
var
  FileStream: TFileStream;
begin
  try
    FileStream := TFileStream.Create(FileName, fmOpenRead);
    try
      SetLength(Result, FileStream.Size);
      FileStream.ReadBuffer(Result[0], Length(Result));
    finally
      FileStream.Free;
    end;
  except
    on E: Exception do
    RaiseException('LoadFromFile error: ' + E.Message);
  end;
end;

procedure TAudioPCM.SaveToFile(const FileName: string; StartPos, EndPos: DWORD; AddWavHeader: Boolean = True);
var
  FileStream: TFileStream;
  PartialBuffer: TArray<Byte>;
begin
  // Check if recording has been initialized
  if not FIsInitialized then
  begin
    RaiseException('SaveToFile error: Recording not initialized');
    Exit;
  end;

  if not IsValidRange(@StartPos, @EndPos) then Exit;
  try
    FileStream := TFileStream.Create(FileName, fmCreate);
    try
      if AddWavHeader then
      begin
        // Add the WAV header to the saved file
        PartialBuffer := CreateWavHeader(
          EndPos - StartPos,
          FSampleRate,
          GetChannelCount(FInChannel),
          GetBitDepth(FFormat)
        );
        FileStream.WriteBuffer(PartialBuffer[0], Length(PartialBuffer));
      end;

      // Append the recorded data to the file
      PartialBuffer := GetPartialBuffer(StartPos, EndPos, False); // Do not compress the data
      FileStream.WriteBuffer(PartialBuffer[0], Length(PartialBuffer));
    finally
      FileStream.Free;
    end;
  except
    on E: Exception do
    RaiseException('SaveToFile error: ' + E.Message);
  end;
end;

function TAudioPCM.TrimSilence8BitFormat(const AudioData: TBytes): TBytes;
var
  I, NonSilentDataLength: Integer;
begin
  if FFormat <> TJAudioFormat.JavaClass.ENCODING_PCM_8BIT then
  begin
    Result := AudioData;
    Exit;
  end;

  NonSilentDataLength := 0;

  // Count the length of non-silent data
  for I := 0 to High(AudioData) do
  begin
    if AudioData[I] <> $80 then
      Inc(NonSilentDataLength);
  end;

  // Allocate memory for non-silent data
  SetLength(Result, NonSilentDataLength);

  // Copy non-silent data
  NonSilentDataLength := 0;
  for I := 0 to High(AudioData) do
  begin
    if AudioData[I] <> $80 then
    begin
      Result[NonSilentDataLength] := AudioData[I];
      Inc(NonSilentDataLength);
    end;
  end;
end;

procedure TAudioPCM.PausePlaying;
begin
  if FIsInitialized and (FAudioPlay.getPlayState = TJAudioTrack.JavaClass.PLAYSTATE_PLAYING) then
  FAudioPlay.pause;
end;

procedure TAudioPCM.ResumePlaying;
begin
  // is not resume playing after execute pause  ??
  if FIsInitialized and (FAudioPlay.getPlayState = TJAudioTrack.JavaClass.PLAYSTATE_PAUSED) then
  begin
    FAudioPlay.flush; // Optional: flush any pending data before resuming
    FAudioPlay.play;
  end;
end;

{$ENDREGION}

end.
