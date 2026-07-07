param(
    [string]$Needle = 'VID_30C9&PID_00C1',
    [switch]$CaptureProbeFrame
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Media.Capture.MediaCapture,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.StreamingCaptureMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureSharingMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureMemoryPreference,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameReaderStartStatus,Windows.Media.Capture,ContentType=WindowsRuntime]

function Await-WinRtOperation {
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)][type]$ResultType
    )

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Count -eq 1 -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Await-WinRtAction {
    param([Parameter(Mandatory)]$Action)

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            -not $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    $task = $asTaskMethod.Invoke($null, @($Action))
    $task.Wait()
}

function Format-Value {
    param($Value)

    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [System.Array]) { return ($Value -join ', ') }
    return $Value.ToString()
}

function Dump-PropertyMap {
    param(
        [string]$Indent,
        $Map
    )

    if ($null -eq $Map) {
        Write-Host "${Indent}<no property map>"
        return
    }

    $count = 0
    foreach ($pair in $Map) {
        $count++
        Write-Host "${Indent}$($pair.Key) = $(Format-Value $pair.Value) [$($pair.Value.GetType().FullName)]"
    }

    if ($count -eq 0) {
        Write-Host "${Indent}<empty>"
    }
}

function Dump-MediaDeviceControl {
    param(
        [string]$Name,
        $Control
    )

    if ($null -eq $Control) {
        Write-Host "    ${Name}: <null>"
        return
    }

    try {
        $cap = $Control.Capabilities
        Write-Host "    ${Name}: Supported=$($cap.Supported) Auto=$($cap.AutoModeSupported) Min=$($cap.Min) Max=$($cap.Max) Step=$($cap.Step) Default=$($cap.Default)"
    }
    catch {
        Write-Host "    ${Name}: $($_.Exception.Message)"
    }
}

function Dump-AdvancedControl {
    param(
        [string]$Name,
        $Control
    )

    if ($null -eq $Control) {
        Write-Host "    ${Name}: <null>"
        return
    }

    $props = $Control.GetType().GetProperties() | Sort-Object Name
    $parts = @()
    foreach ($prop in $props) {
        try {
            $parts += "$($prop.Name)=$(Format-Value $prop.GetValue($Control, $null))"
        }
        catch {}
    }

    Write-Host "    ${Name}: $($parts -join '; ')"
}

$groupListType = [System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]]
$groups = Await-WinRtOperation `
    -Operation ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) `
    -ResultType $groupListType

Write-Host "MediaFrameSourceGroup count: $($groups.Count)"
Write-Host "Needle: $Needle"
Write-Host ''

foreach ($group in $groups) {
    $groupText = "$($group.DisplayName) $($group.Id)"
    foreach ($sourceInfo in $group.SourceInfos) {
        $groupText += " $($sourceInfo.Id) $($sourceInfo.DeviceInformation.Id) $($sourceInfo.SourceKind)"
    }

    if ($groupText -notlike "*$Needle*") { continue }

    Write-Host "=== Group: $($group.DisplayName) ==="
    Write-Host "Id: $($group.Id)"

    foreach ($sourceInfo in $group.SourceInfos) {
        Write-Host "  SourceInfo: $($sourceInfo.Id)"
        Write-Host "    SourceKind: $($sourceInfo.SourceKind)"
        Write-Host "    MediaStreamType: $($sourceInfo.MediaStreamType)"
        Write-Host "    DeviceName: $($sourceInfo.DeviceInformation.Name)"
        Write-Host "    DeviceId: $($sourceInfo.DeviceInformation.Id)"
        Write-Host "    SourceInfo.Properties:"
        Dump-PropertyMap -Indent '      ' -Map $sourceInfo.Properties
        Write-Host "    DeviceInformation.Properties:"
        Dump-PropertyMap -Indent '      ' -Map $sourceInfo.DeviceInformation.Properties
    }

    $settings = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $settings.SourceGroup = $group
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly
    $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu

    $mediaCapture = [Windows.Media.Capture.MediaCapture]::new()
    try {
        Await-WinRtAction -Action ($mediaCapture.InitializeAsync($settings))
        Write-Host '  InitializeAsync: OK'

        $controller = $mediaCapture.VideoDeviceController
        Write-Host '  VideoDeviceController basic controls:'
        Dump-MediaDeviceControl -Name 'Brightness' -Control $controller.Brightness
        Dump-MediaDeviceControl -Name 'Contrast' -Control $controller.Contrast
        Dump-MediaDeviceControl -Name 'Hue' -Control $controller.Hue
        Dump-MediaDeviceControl -Name 'WhiteBalance' -Control $controller.WhiteBalance
        Dump-MediaDeviceControl -Name 'BacklightCompensation' -Control $controller.BacklightCompensation
        Dump-MediaDeviceControl -Name 'Pan' -Control $controller.Pan
        Dump-MediaDeviceControl -Name 'Tilt' -Control $controller.Tilt
        Dump-MediaDeviceControl -Name 'Zoom' -Control $controller.Zoom
        Dump-MediaDeviceControl -Name 'Roll' -Control $controller.Roll
        Dump-MediaDeviceControl -Name 'Exposure' -Control $controller.Exposure
        Dump-MediaDeviceControl -Name 'Focus' -Control $controller.Focus

        Write-Host '  VideoDeviceController advanced controls:'
        Dump-AdvancedControl -Name 'ExposureControl' -Control $controller.ExposureControl
        Dump-AdvancedControl -Name 'ExposureCompensationControl' -Control $controller.ExposureCompensationControl
        Dump-AdvancedControl -Name 'FocusControl' -Control $controller.FocusControl
        Dump-AdvancedControl -Name 'IsoSpeedControl' -Control $controller.IsoSpeedControl
        Dump-AdvancedControl -Name 'WhiteBalanceControl' -Control $controller.WhiteBalanceControl
        Dump-AdvancedControl -Name 'ZoomControl' -Control $controller.ZoomControl
        Dump-AdvancedControl -Name 'TorchControl' -Control $controller.TorchControl
        Dump-AdvancedControl -Name 'FlashControl' -Control $controller.FlashControl
        Dump-AdvancedControl -Name 'SceneModeControl' -Control $controller.SceneModeControl

        foreach ($pair in $mediaCapture.FrameSources) {
            $source = $pair.Value
            Write-Host "  FrameSource: $($pair.Key)"
            Write-Host "    Kind: $($source.Info.SourceKind)"
            Write-Host "    StreamType: $($source.Info.MediaStreamType)"
            Write-Host "    Current: $($source.CurrentFormat.VideoFormat.Width)x$($source.CurrentFormat.VideoFormat.Height) $($source.CurrentFormat.Subtype)"
            Write-Host '    Source.Properties:'
            Dump-PropertyMap -Indent '      ' -Map $source.Properties
            Write-Host '    SupportedFormats:'
            foreach ($format in $source.SupportedFormats) {
                Write-Host "      $($format.VideoFormat.Width)x$($format.VideoFormat.Height) $($format.Subtype) $($format.FrameRate.Numerator)/$($format.FrameRate.Denominator) fps"
                Write-Host '        Properties:'
                Dump-PropertyMap -Indent '          ' -Map $format.Properties
            }

            if ($CaptureProbeFrame) {
                $readerType = [Windows.Media.Capture.Frames.MediaFrameReader]
                $reader = $null
                $frame = $null
                try {
                    $reader = Await-WinRtOperation -Operation ($mediaCapture.CreateFrameReaderAsync($source)) -ResultType $readerType
                    $startStatusType = [Windows.Media.Capture.Frames.MediaFrameReaderStartStatus]
                    $startStatus = Await-WinRtOperation -Operation ($reader.StartAsync()) -ResultType $startStatusType
                    Write-Host "    ReaderStart: $startStatus"

                    if ($startStatus.ToString() -eq 'Success') {
                        $deadline = [DateTimeOffset]::Now.AddMilliseconds(1500)
                        while ([DateTimeOffset]::Now -lt $deadline -and $null -eq $frame) {
                            Start-Sleep -Milliseconds 50
                            $frame = $reader.TryAcquireLatestFrame()
                        }

                        if ($null -eq $frame) {
                            Write-Host '    ProbeFrame: <no frame>'
                        }
                        else {
                            Write-Host "    ProbeFrame.RelativeTime: $($frame.RelativeTime)"
                            Write-Host "    ProbeFrame.SystemRelativeTime: $($frame.SystemRelativeTime)"
                            Write-Host "    ProbeFrame.Duration: $($frame.Duration)"
                            Write-Host "    ProbeFrame.Properties:"
                            Dump-PropertyMap -Indent '      ' -Map $frame.Properties

                            $videoFrame = $frame.VideoMediaFrame
                            Write-Host "    VideoMediaFrame.FrameReference: $($videoFrame.FrameReference)"
                            Write-Host "    VideoMediaFrame.CameraIntrinsics: $($videoFrame.CameraIntrinsics)"
                            Write-Host "    VideoMediaFrame.DepthMediaFrame: $($videoFrame.DepthMediaFrame)"
                            Write-Host "    VideoMediaFrame.InfraredMediaFrame: $($videoFrame.InfraredMediaFrame)"
                            Write-Host "    VideoMediaFrame.SoftwareBitmap: $($videoFrame.SoftwareBitmap.BitmapPixelFormat) $($videoFrame.SoftwareBitmap.PixelWidth)x$($videoFrame.SoftwareBitmap.PixelHeight)"
                        }
                    }
                }
                finally {
                    if ($frame -is [System.IDisposable]) { $frame.Dispose() }
                    if ($reader -is [System.IDisposable]) { $reader.Dispose() }
                }
            }
        }
    }
    catch {
        Write-Host '  Initialize/probe failed:'
        Write-Host $_.Exception.ToString()
    }
    finally {
        if ($mediaCapture -is [System.IDisposable]) { $mediaCapture.Dispose() }
    }

    Write-Host ''
}
