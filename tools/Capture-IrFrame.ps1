param(
    [string]$Needle = 'VID_30C9&PID_00C1&MI_02',
    [string]$OutputPath = (Join-Path (Get-Location) 'ir-frame.pgm'),
    [string]$PngPath = '',
    [int]$TimeoutMs = 3000
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing

[void][Windows.Media.Capture.MediaCapture,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.StreamingCaptureMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureSharingMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureMemoryPreference,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameReaderStartStatus,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.Buffer,Windows.Storage.Streams,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]

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

$groupListType = [System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]]
$groups = Await-WinRtOperation `
    -Operation ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) `
    -ResultType $groupListType

$group = $null
foreach ($candidate in $groups) {
    $text = "$($candidate.DisplayName) $($candidate.Id)"
    foreach ($sourceInfo in $candidate.SourceInfos) {
        $text += " $($sourceInfo.Id) $($sourceInfo.DeviceInformation.Id) $($sourceInfo.SourceKind)"
    }

    if ($text -like "*$Needle*" -and $text -like '*Infrared*') {
        $group = $candidate
        break
    }
}

if ($null -eq $group) {
    throw "No infrared MediaFrameSourceGroup matched '$Needle'. Run Probe-IrCamera.ps1 first."
}

$settings = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$settings.SourceGroup = $group
$settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly
$settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu

$mediaCapture = [Windows.Media.Capture.MediaCapture]::new()
$reader = $null
$frame = $null

try {
    Await-WinRtAction -Action ($mediaCapture.InitializeAsync($settings))
    Write-Host "Initialized: $($group.DisplayName)"

    $source = $null
    foreach ($pair in $mediaCapture.FrameSources) {
        if ($pair.Value.Info.SourceKind.ToString() -eq 'Infrared') {
            $source = $pair.Value
            break
        }
    }

    if ($null -eq $source) {
        throw 'Initialized camera, but no Infrared FrameSource was available.'
    }

    Write-Host "Source: $($source.Info.Id)"
    Write-Host "Format: $($source.CurrentFormat.VideoFormat.Width)x$($source.CurrentFormat.VideoFormat.Height) $($source.CurrentFormat.Subtype)"

    $readerType = [Windows.Media.Capture.Frames.MediaFrameReader]
    $reader = Await-WinRtOperation -Operation ($mediaCapture.CreateFrameReaderAsync($source)) -ResultType $readerType

    $startStatusType = [Windows.Media.Capture.Frames.MediaFrameReaderStartStatus]
    $startStatus = Await-WinRtOperation -Operation ($reader.StartAsync()) -ResultType $startStatusType
    Write-Host "Reader start: $startStatus"

    if ($startStatus.ToString() -ne 'Success') {
        throw "MediaFrameReader did not start: $startStatus"
    }

    $deadline = [DateTimeOffset]::Now.AddMilliseconds($TimeoutMs)
    while ([DateTimeOffset]::Now -lt $deadline -and $null -eq $frame) {
        Start-Sleep -Milliseconds 50
        $frame = $reader.TryAcquireLatestFrame()
    }

    if ($null -eq $frame) {
        throw "No frame arrived within $TimeoutMs ms."
    }

    $bitmap = $frame.VideoMediaFrame.SoftwareBitmap
    if ($null -eq $bitmap) {
        throw 'Frame arrived, but SoftwareBitmap is null. The source may be delivering GPU-only frames.'
    }

    $width = $bitmap.PixelWidth
    $height = $bitmap.PixelHeight
    $pixelFormat = $bitmap.BitmapPixelFormat.ToString()
    $bytesPerPixel = switch ($pixelFormat) {
        'Gray8' { 1 }
        'Bgra8' { 4 }
        default { throw "Unsupported SoftwareBitmap pixel format: $pixelFormat" }
    }

    $byteCount = $width * $height * $bytesPerPixel
    $buffer = [Windows.Storage.Streams.Buffer]::new($byteCount)
    $bitmap.CopyToBuffer($buffer)

    $bytes = New-Object byte[] $byteCount
    $readerBuffer = [Windows.Storage.Streams.DataReader]::FromBuffer($buffer)
    $readerBuffer.ReadBytes($bytes)

    if ($pixelFormat -eq 'Bgra8') {
        $gray = New-Object byte[] ($width * $height)
        for ($i = 0; $i -lt $gray.Length; $i++) {
            $gray[$i] = $bytes[$i * 4]
        }
        $bytes = $gray
    }

    $header = [System.Text.Encoding]::ASCII.GetBytes("P5`n$width $height`n255`n")
    [System.IO.File]::WriteAllBytes($OutputPath, $header + $bytes)
    Write-Host "Saved: $OutputPath"
    Write-Host "Pixels: $width x $height, SoftwareBitmap: $pixelFormat"

    if ([string]::IsNullOrWhiteSpace($PngPath)) {
        $PngPath = [System.IO.Path]::ChangeExtension($OutputPath, '.png')
    }

    $bitmapPng = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
    $data = $bitmapPng.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmapPng.PixelFormat)

    try {
        $stride = [Math]::Abs($data.Stride)
        $rgbBytes = New-Object byte[] ($stride * $height)

        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $lum = $bytes[($y * $width) + $x]
                $offset = ($y * $stride) + ($x * 3)
                $rgbBytes[$offset] = $lum
                $rgbBytes[$offset + 1] = $lum
                $rgbBytes[$offset + 2] = $lum
            }
        }

        [System.Runtime.InteropServices.Marshal]::Copy($rgbBytes, 0, $data.Scan0, $rgbBytes.Length)
    }
    finally {
        $bitmapPng.UnlockBits($data)
    }

    $bitmapPng.Save($PngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmapPng.Dispose()
    Write-Host "Saved: $PngPath"
}
finally {
    if ($frame -is [System.IDisposable]) { $frame.Dispose() }
    if ($reader -is [System.IDisposable]) { $reader.Dispose() }
    if ($mediaCapture -is [System.IDisposable]) { $mediaCapture.Dispose() }
}
