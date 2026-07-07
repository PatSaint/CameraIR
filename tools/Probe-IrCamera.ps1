param(
    [string]$Needle = 'VID_30C9&PID_00C1&MI_02'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime

[void][Windows.Media.Capture.MediaCapture,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.StreamingCaptureMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceKind,Windows.Media.Capture,ContentType=WindowsRuntime]

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

Write-Host "MediaFrameSourceGroup count: $($groups.Count)"
Write-Host "Needle: $Needle"
Write-Host ''

$matchedGroups = @()

for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
    $group = $groups[$groupIndex]
    $groupText = "$($group.DisplayName) $($group.Id)"
    $sourceTexts = @()

    foreach ($sourceInfo in $group.SourceInfos) {
        $sourceTexts += "$($sourceInfo.Id) $($sourceInfo.SourceKind) $($sourceInfo.MediaStreamType) $($sourceInfo.DeviceInformation.Id)"
    }

    $isMatch = ($groupText -like "*$Needle*") -or (($sourceTexts -join "`n") -like "*$Needle*")

    Write-Host "=== Group #$groupIndex ==="
    Write-Host "DisplayName: $($group.DisplayName)"
    Write-Host "Id: $($group.Id)"
    Write-Host "Match: $isMatch"

    foreach ($sourceInfo in $group.SourceInfos) {
        Write-Host "  SourceInfo.Id: $($sourceInfo.Id)"
        Write-Host "    SourceKind: $($sourceInfo.SourceKind)"
        Write-Host "    MediaStreamType: $($sourceInfo.MediaStreamType)"
        Write-Host "    DeviceInformation.Id: $($sourceInfo.DeviceInformation.Id)"
        Write-Host "    DeviceInformation.Name: $($sourceInfo.DeviceInformation.Name)"
    }

    Write-Host ''

    if ($isMatch) {
        $matchedGroups += $group
    }
}

if ($matchedGroups.Count -eq 0) {
    Write-Host 'No matching MediaFrameSourceGroup found. The sensor interface exists, but Media Foundation did not expose it here.'
    exit 2
}

foreach ($group in $matchedGroups) {
    Write-Host "=== Trying MediaCapture init for: $($group.DisplayName) ==="

    $settings = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $settings.SourceGroup = $group
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly
    $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu

    $mediaCapture = [Windows.Media.Capture.MediaCapture]::new()

    try {
        Await-WinRtAction -Action ($mediaCapture.InitializeAsync($settings))
        Write-Host 'InitializeAsync: OK'
        Write-Host "  FrameSources count: $($mediaCapture.FrameSources.Count)"

        foreach ($pair in $mediaCapture.FrameSources) {
            $key = $pair.Key
            $source = $pair.Value
            Write-Host "  FrameSource key: $key"
            Write-Host "    Info.Id: $($source.Info.Id)"
            Write-Host "    SourceKind: $($source.Info.SourceKind)"
            Write-Host "    MediaStreamType: $($source.Info.MediaStreamType)"
            Write-Host "    CurrentFormat: $($source.CurrentFormat.VideoFormat.Width)x$($source.CurrentFormat.VideoFormat.Height) $($source.CurrentFormat.Subtype)"

            foreach ($format in $source.SupportedFormats) {
                Write-Host "      Format: $($format.VideoFormat.Width)x$($format.VideoFormat.Height) $($format.Subtype) $($format.FrameRate.Numerator)/$($format.FrameRate.Denominator) fps"
            }
        }
    }
    catch {
        Write-Host "InitializeAsync: FAILED"
        Write-Host $_.Exception.ToString()
    }
    finally {
        if ($mediaCapture -is [System.IDisposable]) {
            $mediaCapture.Dispose()
        }
    }
}
