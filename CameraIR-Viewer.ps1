param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'captures')
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[void][Windows.Media.Capture.MediaCapture,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.StreamingCaptureMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureSharingMode,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureMemoryPreference,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameReaderStartStatus,Windows.Media.Capture,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap,Windows.Graphics,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapPixelFormat,Windows.Graphics,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapAlphaMode,Windows.Graphics,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.Buffer,Windows.Storage.Streams,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    Write-AppException -Context 'WinForms ThreadException' -Exception $eventArgs.Exception.ToString()
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $eventArgs)
    Write-AppException -Context 'AppDomain UnhandledException' -Exception $eventArgs.ExceptionObject.ToString()
})

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$script:LogPath = Join-Path $OutputDirectory ('CameraIR_{0:yyyyMMdd_HHmmss}.log' -f [DateTime]::Now)

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    try {
        $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] [{1}] {2}' -f [DateTime]::Now, $Level, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {}
}

function Write-AppException {
    param(
        [string]$Context,
        [object]$Exception
    )

    Write-AppLog -Level 'ERROR' -Message "$Context`r`n$Exception"
}

Write-AppLog "CameraIR Viewer starting. OutputDirectory=$OutputDirectory"

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

function Get-FrameGroups {
    $groupListType = [System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]]
    return Await-WinRtOperation `
        -Operation ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) `
        -ResultType $groupListType
}

function Get-FfmpegPath {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) {
        return $null
    }

    return $ffmpeg
}

function Get-DshowAudioDevices {
    $ffmpeg = Get-FfmpegPath
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) { return @() }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ffmpeg
    $psi.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $output = $process.StandardOutput.ReadToEnd() + "`n" + $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $devices = @()

    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '"(.+)" \(audio\)') {
            $devices += $matches[1]
        }
    }

    return $devices
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    $escaped = @()
    foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            $escaped += '"' + $arg.Replace('"', '\"') + '"'
        }
        else {
            $escaped += $arg
        }
    }

    return ($escaped -join ' ')
}

function Invoke-Ffmpeg {
    param([string[]]$Arguments)

    $ffmpeg = Get-FfmpegPath
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) {
        throw 'No encontre ffmpeg en PATH.'
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ffmpeg
    $psi.Arguments = Join-ProcessArguments -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    Write-AppLog "ffmpeg $($psi.Arguments)"
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $output = "$stdout`n$stderr"

    Write-AppLog "ffmpeg exit=$($process.ExitCode)`r`n$output"
    if ($process.ExitCode -ne 0) {
        throw "ffmpeg fallo con codigo $($process.ExitCode):`r`n$output"
    }

    return $output
}

function Convert-SoftwareBitmapToBitmap {
    param([Parameter(Mandatory)]$SoftwareBitmap)

    $width = $SoftwareBitmap.PixelWidth
    $height = $SoftwareBitmap.PixelHeight
    $format = $SoftwareBitmap.BitmapPixelFormat.ToString()

    function New-RgbBitmap {
        param(
            [int]$Width,
            [int]$Height,
            [byte[]]$RgbBytes
        )

        $bitmap = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $Width, $Height)
        $bits = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)

        try {
            $stride = [Math]::Abs($bits.Stride)
            $padded = New-Object byte[] ($stride * $Height)

            for ($y = 0; $y -lt $Height; $y++) {
                [Array]::Copy($RgbBytes, $y * $Width * 3, $padded, $y * $stride, $Width * 3)
            }

            [System.Runtime.InteropServices.Marshal]::Copy($padded, 0, $bits.Scan0, $padded.Length)
        }
        finally {
            $bitmap.UnlockBits($bits)
        }

        return $bitmap
    }

    function Convert-YuvToRgbByte {
        param([int]$Y, [int]$U, [int]$V)

        $c = $Y - 16
        $d = $U - 128
        $e = $V - 128
        $r = [Math]::Max(0, [Math]::Min(255, (($298 * $c + 409 * $e + 128) -shr 8)))
        $g = [Math]::Max(0, [Math]::Min(255, (($298 * $c - 100 * $d - 208 * $e + 128) -shr 8)))
        $b = [Math]::Max(0, [Math]::Min(255, (($298 * $c + 516 * $d + 128) -shr 8)))
        return @([byte]$b, [byte]$g, [byte]$r)
    }

    function Get-BitmapBytes {
        param(
            [Parameter(Mandatory)]$Bitmap,
            [int]$ByteCount
        )

        $buffer = [Windows.Storage.Streams.Buffer]::new($ByteCount)
        $Bitmap.CopyToBuffer($buffer)

        $bytes = New-Object byte[] $ByteCount
        $dataReader = [Windows.Storage.Streams.DataReader]::FromBuffer($buffer)
        $dataReader.ReadBytes($bytes)
        return $bytes
    }

    function Convert-BgraBitmapToDrawingBitmap {
        param([Parameter(Mandatory)]$Bitmap)

        $bgraBytes = Get-BitmapBytes -Bitmap $Bitmap -ByteCount ($Bitmap.PixelWidth * $Bitmap.PixelHeight * 4)
        $drawingBitmap = [System.Drawing.Bitmap]::new($Bitmap.PixelWidth, $Bitmap.PixelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.PixelWidth, $Bitmap.PixelHeight)
        $bits = $drawingBitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $drawingBitmap.PixelFormat)

        try {
            $stride = [Math]::Abs($bits.Stride)
            $rowBytes = $Bitmap.PixelWidth * 4

            if ($stride -eq $rowBytes) {
                [System.Runtime.InteropServices.Marshal]::Copy($bgraBytes, 0, $bits.Scan0, $bgraBytes.Length)
            }
            else {
                $padded = New-Object byte[] ($stride * $Bitmap.PixelHeight)
                for ($y = 0; $y -lt $Bitmap.PixelHeight; $y++) {
                    [Array]::Copy($bgraBytes, $y * $rowBytes, $padded, $y * $stride, $rowBytes)
                }
                [System.Runtime.InteropServices.Marshal]::Copy($padded, 0, $bits.Scan0, $padded.Length)
            }
        }
        finally {
            $drawingBitmap.UnlockBits($bits)
        }

        return $drawingBitmap
    }

    if ($format -eq 'Gray8') {
        $gray = Get-BitmapBytes -Bitmap $SoftwareBitmap -ByteCount ($width * $height)

        $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        $palette = $bitmap.Palette
        for ($i = 0; $i -lt 256; $i++) {
            $palette.Entries[$i] = [System.Drawing.Color]::FromArgb($i, $i, $i)
        }
        $bitmap.Palette = $palette

        $rect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
        $bits = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)

        try {
            $stride = [Math]::Abs($bits.Stride)
            if ($stride -eq $width) {
                [System.Runtime.InteropServices.Marshal]::Copy($gray, 0, $bits.Scan0, $gray.Length)
            }
            else {
                $padded = New-Object byte[] ($stride * $height)
                for ($y = 0; $y -lt $height; $y++) {
                    [Array]::Copy($gray, $y * $width, $padded, $y * $stride, $width)
                }
                [System.Runtime.InteropServices.Marshal]::Copy($padded, 0, $bits.Scan0, $padded.Length)
            }
        }
        finally {
            $bitmap.UnlockBits($bits)
        }

        return $bitmap
    }

    if ($format -eq 'Bgra8') {
        return Convert-BgraBitmapToDrawingBitmap -Bitmap $SoftwareBitmap
    }

    if ($format -eq 'Yuy2' -or $format -eq 'Nv12') {
        $converted = $null
        try {
            $converted = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
                $SoftwareBitmap,
                [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
                [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied
            )

            return Convert-BgraBitmapToDrawingBitmap -Bitmap $converted
        }
        finally {
            if ($converted -is [System.IDisposable]) { $converted.Dispose() }
        }
    }

    if ($format -eq 'Yuy2') {
        $bytes = Get-BitmapBytes -Bitmap $SoftwareBitmap -ByteCount ($width * $height * 2)
        $rgb = New-Object byte[] ($width * $height * 3)

        for ($i = 0; $i -lt $bytes.Length; $i += 4) {
            $pixelIndex = ($i / 4) * 2
            $y0 = $bytes[$i]
            $u = $bytes[$i + 1]
            $y1 = $bytes[$i + 2]
            $v = $bytes[$i + 3]

            $rgb0 = Convert-YuvToRgbByte -Y $y0 -U $u -V $v
            $rgb1 = Convert-YuvToRgbByte -Y $y1 -U $u -V $v

            $offset0 = $pixelIndex * 3
            $offset1 = ($pixelIndex + 1) * 3
            $rgb[$offset0] = $rgb0[0]
            $rgb[$offset0 + 1] = $rgb0[1]
            $rgb[$offset0 + 2] = $rgb0[2]
            $rgb[$offset1] = $rgb1[0]
            $rgb[$offset1 + 1] = $rgb1[1]
            $rgb[$offset1 + 2] = $rgb1[2]
        }

        return New-RgbBitmap -Width $width -Height $height -RgbBytes $rgb
    }

    if ($format -eq 'Nv12') {
        $yPlaneSize = $width * $height
        $bytes = Get-BitmapBytes -Bitmap $SoftwareBitmap -ByteCount ($yPlaneSize + ($yPlaneSize / 2))
        $rgb = New-Object byte[] ($width * $height * 3)

        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $yValue = $bytes[($y * $width) + $x]
                $uvOffset = $yPlaneSize + ([Math]::Floor($y / 2) * $width) + ([Math]::Floor($x / 2) * 2)
                $u = $bytes[$uvOffset]
                $v = $bytes[$uvOffset + 1]
                $rgbPixel = Convert-YuvToRgbByte -Y $yValue -U $u -V $v
                $offset = (($y * $width) + $x) * 3
                $rgb[$offset] = $rgbPixel[0]
                $rgb[$offset + 1] = $rgbPixel[1]
                $rgb[$offset + 2] = $rgbPixel[2]
            }
        }

        return New-RgbBitmap -Width $width -Height $height -RgbBytes $rgb
    }

    throw "Unsupported preview bitmap format '$format'. Try another resolution/format."
}

function Dispose-CaptureState {
    if ($script:Frame -is [System.IDisposable]) { $script:Frame.Dispose(); $script:Frame = $null }
    if ($script:Reader -is [System.IDisposable]) { $script:Reader.Dispose(); $script:Reader = $null }
    if ($script:MediaCapture -is [System.IDisposable]) { $script:MediaCapture.Dispose(); $script:MediaCapture = $null }
}

$script:Groups = Get-FrameGroups
$script:MediaCapture = $null
$script:Reader = $null
$script:CurrentSource = $null
$script:Frame = $null
$script:LastBitmap = $null
$script:IsRecording = $false
$script:RecordDirectory = $null
$script:RecordFrameIndex = 0
$script:RecordStartedAt = $null
$script:AudioProcess = $null
$script:AudioPath = $null
$script:IsRefreshingSelection = $false
$script:IsProcessingFrame = $false
$script:FrameTickCount = 0
$script:AutoPreviewEnabled = $false

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'CameraIR Viewer'
$form.Width = 1180
$form.Height = 780
$form.StartPosition = 'CenterScreen'

$leftPanel = [System.Windows.Forms.Panel]::new()
$leftPanel.Dock = 'Left'
$leftPanel.Width = 360
$leftPanel.Padding = [System.Windows.Forms.Padding]::new(12)
$form.Controls.Add($leftPanel)

$preview = [System.Windows.Forms.PictureBox]::new()
$preview.Dock = 'Fill'
$preview.BackColor = [System.Drawing.Color]::Black
$preview.SizeMode = 'Zoom'
$form.Controls.Add($preview)

$lblGroup = [System.Windows.Forms.Label]::new()
$lblGroup.Text = 'Fuente / camara'
$lblGroup.Top = 12
$lblGroup.Left = 12
$lblGroup.Width = 320
$leftPanel.Controls.Add($lblGroup)

$cmbGroup = [System.Windows.Forms.ComboBox]::new()
$cmbGroup.Top = 34
$cmbGroup.Left = 12
$cmbGroup.Width = 320
$cmbGroup.DropDownStyle = 'DropDownList'
$leftPanel.Controls.Add($cmbGroup)

$lblSource = [System.Windows.Forms.Label]::new()
$lblSource.Text = 'Stream'
$lblSource.Top = 72
$lblSource.Left = 12
$lblSource.Width = 320
$leftPanel.Controls.Add($lblSource)

$cmbSource = [System.Windows.Forms.ComboBox]::new()
$cmbSource.Top = 94
$cmbSource.Left = 12
$cmbSource.Width = 320
$cmbSource.DropDownStyle = 'DropDownList'
$leftPanel.Controls.Add($cmbSource)

$lblFormat = [System.Windows.Forms.Label]::new()
$lblFormat.Text = 'Resolucion / formato'
$lblFormat.Top = 132
$lblFormat.Left = 12
$lblFormat.Width = 320
$leftPanel.Controls.Add($lblFormat)

$cmbFormat = [System.Windows.Forms.ComboBox]::new()
$cmbFormat.Top = 154
$cmbFormat.Left = 12
$cmbFormat.Width = 320
$cmbFormat.DropDownStyle = 'DropDownList'
$leftPanel.Controls.Add($cmbFormat)

$btnStart = [System.Windows.Forms.Button]::new()
$btnStart.Text = 'Iniciar preview'
$btnStart.Top = 196
$btnStart.Left = 12
$btnStart.Width = 150
$btnStart.Visible = $false
$leftPanel.Controls.Add($btnStart)

$btnStop = [System.Windows.Forms.Button]::new()
$btnStop.Text = 'Detener'
$btnStop.Top = 196
$btnStop.Left = 182
$btnStop.Width = 150
$btnStop.Visible = $false
$leftPanel.Controls.Add($btnStop)

$btnPhoto = [System.Windows.Forms.Button]::new()
$btnPhoto.Text = 'Tomar foto PNG'
$btnPhoto.Top = 206
$btnPhoto.Left = 12
$btnPhoto.Width = 150
$leftPanel.Controls.Add($btnPhoto)

$chkAudio = [System.Windows.Forms.CheckBox]::new()
$chkAudio.Text = 'Incluir audio en video'
$chkAudio.Top = 211
$chkAudio.Left = 182
$chkAudio.Width = 160
$chkAudio.Checked = $true
$leftPanel.Controls.Add($chkAudio)

$btnVideo = [System.Windows.Forms.Button]::new()
$btnVideo.Text = 'Grabar video'
$btnVideo.Top = 246
$btnVideo.Left = 12
$btnVideo.Width = 150
$leftPanel.Controls.Add($btnVideo)

$btnBridge = [System.Windows.Forms.Button]::new()
$btnBridge.Text = 'Puente virtual'
$btnBridge.Top = 246
$btnBridge.Left = 182
$btnBridge.Width = 150
$leftPanel.Controls.Add($btnBridge)

$lblAudio = [System.Windows.Forms.Label]::new()
$lblAudio.Text = 'Microfono para video'
$lblAudio.Top = 286
$lblAudio.Left = 12
$lblAudio.Width = 320
$leftPanel.Controls.Add($lblAudio)

$cmbAudio = [System.Windows.Forms.ComboBox]::new()
$cmbAudio.Top = 308
$cmbAudio.Left = 12
$cmbAudio.Width = 320
$cmbAudio.DropDownStyle = 'DropDownList'
$leftPanel.Controls.Add($cmbAudio)

$txtMetadata = [System.Windows.Forms.TextBox]::new()
$txtMetadata.Top = 346
$txtMetadata.Left = 12
$txtMetadata.Width = 320
$txtMetadata.Height = 360
$txtMetadata.Multiline = $true
$txtMetadata.ScrollBars = 'Vertical'
$txtMetadata.ReadOnly = $true
$txtMetadata.Font = [System.Drawing.Font]::new('Consolas', 9)
$leftPanel.Controls.Add($txtMetadata)

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 500

function Set-MetadataText {
    param([string]$Text)
    $txtMetadata.Text = $Text
}

function Set-CameraSelectionEnabled {
    param([bool]$Enabled)

    $cmbGroup.Enabled = $Enabled
    $cmbSource.Enabled = $Enabled
    $cmbFormat.Enabled = $Enabled
    $cmbAudio.Enabled = $Enabled
    $chkAudio.Enabled = $Enabled
}

function Get-GroupLabel {
    param($Group)
    return "$($Group.DisplayName) | $($Group.Id)"
}

function Get-SourceLabel {
    param($SourceInfo)
    return "$($SourceInfo.SourceKind) | $($SourceInfo.MediaStreamType) | $($SourceInfo.DeviceInformation.Name)"
}

function Get-FormatLabel {
    param($Format)
    return "$($Format.VideoFormat.Width)x$($Format.VideoFormat.Height) $($Format.Subtype) $($Format.FrameRate.Numerator)/$($Format.FrameRate.Denominator) fps"
}

function Refresh-Groups {
    $cmbGroup.Items.Clear()
    $preferredIndex = -1
    foreach ($group in $script:Groups) {
        $item = [pscustomobject]@{ Label = (Get-GroupLabel $group); Value = $group }
        [void]$cmbGroup.Items.Add($item)
        if ($preferredIndex -lt 0 -and $group.DisplayName -like '*IR*') {
            $preferredIndex = $cmbGroup.Items.Count - 1
        }
    }
    $cmbGroup.DisplayMember = 'Label'
    if ($preferredIndex -ge 0) {
        $cmbGroup.SelectedIndex = $preferredIndex
    }
    elseif ($cmbGroup.Items.Count -gt 0) {
        $cmbGroup.SelectedIndex = 0
    }
}

function Refresh-AudioDevices {
    $cmbAudio.Items.Clear()
    [void]$cmbAudio.Items.Add([pscustomobject]@{ Label = 'Sin audio'; Value = '' })

    foreach ($device in (Get-DshowAudioDevices)) {
        [void]$cmbAudio.Items.Add([pscustomobject]@{ Label = $device; Value = $device })
    }

    $cmbAudio.DisplayMember = 'Label'
    if ($cmbAudio.Items.Count -gt 1) {
        $cmbAudio.SelectedIndex = 1
        $chkAudio.Checked = $true
    }
    else {
        $cmbAudio.SelectedIndex = 0
        $chkAudio.Checked = $false
    }
}

function Refresh-Sources {
    Write-AppLog "Refresh-Sources group=$($cmbGroup.SelectedItem.Label)"
    $script:IsRefreshingSelection = $true
    $cmbSource.Items.Clear()
    $groupItem = $cmbGroup.SelectedItem
    if ($null -eq $groupItem) {
        $script:IsRefreshingSelection = $false
        return
    }

    foreach ($sourceInfo in $groupItem.Value.SourceInfos) {
        [void]$cmbSource.Items.Add([pscustomobject]@{ Label = (Get-SourceLabel $sourceInfo); Value = $sourceInfo })
    }
    $cmbSource.DisplayMember = 'Label'
    if ($cmbSource.Items.Count -gt 0) { $cmbSource.SelectedIndex = 0 }
    $script:IsRefreshingSelection = $false
    Refresh-Formats
}

function Initialize-CaptureForSelectedGroup {
    Dispose-CaptureState

    $group = $cmbGroup.SelectedItem.Value
    $settings = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $settings.SourceGroup = $group
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly
    $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu

    $script:MediaCapture = [Windows.Media.Capture.MediaCapture]::new()
    Await-WinRtAction -Action ($script:MediaCapture.InitializeAsync($settings))
}

function Refresh-Formats {
    Write-AppLog "Refresh-Formats group=$($cmbGroup.SelectedItem.Label) source=$($cmbSource.SelectedItem.Label) wasRunning=$($timer.Enabled)"
    $wasRunning = $timer.Enabled
    if ($wasRunning) {
        Stop-Preview -KeepSelection
    }

    $script:IsRefreshingSelection = $true
    $cmbFormat.Items.Clear()
    if ($null -eq $cmbGroup.SelectedItem -or $null -eq $cmbSource.SelectedItem) {
        $script:IsRefreshingSelection = $false
        return
    }

    try {
        Initialize-CaptureForSelectedGroup
        $sourceInfo = $cmbSource.SelectedItem.Value

        foreach ($pair in $script:MediaCapture.FrameSources) {
            if ($pair.Value.Info.Id -eq $sourceInfo.Id) {
                $script:CurrentSource = $pair.Value
                break
            }
        }

        if ($null -eq $script:CurrentSource) { throw 'No se encontro el stream seleccionado dentro de MediaCapture.' }

        foreach ($format in $script:CurrentSource.SupportedFormats) {
            [void]$cmbFormat.Items.Add([pscustomobject]@{ Label = (Get-FormatLabel $format); Value = $format })
        }
        $cmbFormat.DisplayMember = 'Label'
        if ($cmbFormat.Items.Count -gt 0) { $cmbFormat.SelectedIndex = 0 }
        $script:IsRefreshingSelection = $false

        Set-MetadataText "Grupo: $($cmbGroup.SelectedItem.Value.DisplayName)`r`nStream: $($script:CurrentSource.Info.SourceKind)`r`nActual: $(Get-FormatLabel $script:CurrentSource.CurrentFormat)`r`nFormatos: $($cmbFormat.Items.Count)"
        Write-AppLog "Selected source=$($script:CurrentSource.Info.Id) current=$(Get-FormatLabel $script:CurrentSource.CurrentFormat) formats=$($cmbFormat.Items.Count)"

        if ($wasRunning -or $script:AutoPreviewEnabled) {
            Start-Preview
        }
    }
    catch {
        $script:IsRefreshingSelection = $false
        Write-AppException -Context 'Refresh-Formats failed' -Exception $_.Exception.ToString()
        Set-MetadataText $_.Exception.ToString()
    }
}

function Start-Preview {
    Write-AppLog "Start-Preview group=$($cmbGroup.SelectedItem.Label) source=$($cmbSource.SelectedItem.Label) format=$($cmbFormat.SelectedItem.Label)"
    if ($null -eq $script:MediaCapture -or $null -eq $script:CurrentSource) {
        Initialize-CaptureForSelectedGroup
        Refresh-Formats
    }

    if ($null -ne $cmbFormat.SelectedItem) {
        Await-WinRtAction -Action ($script:CurrentSource.SetFormatAsync($cmbFormat.SelectedItem.Value))
    }

    $readerType = [Windows.Media.Capture.Frames.MediaFrameReader]
    $script:Reader = Await-WinRtOperation -Operation ($script:MediaCapture.CreateFrameReaderAsync($script:CurrentSource)) -ResultType $readerType

    $startStatusType = [Windows.Media.Capture.Frames.MediaFrameReaderStartStatus]
    $startStatus = Await-WinRtOperation -Operation ($script:Reader.StartAsync()) -ResultType $startStatusType
    if ($startStatus.ToString() -ne 'Success') { throw "No pudo iniciar el reader: $startStatus" }

    $timer.Start()
    $btnStart.Text = 'Preview activo'
    Write-AppLog "Preview started status=$startStatus intervalMs=$($timer.Interval)"
}

function Stop-Preview {
    param([switch]$KeepSelection)

    if ($script:IsRecording) {
        Stop-Recording
    }

    $timer.Stop()
    Dispose-CaptureState
    $btnStart.Text = 'Iniciar preview'
    Write-AppLog "Preview stopped keepSelection=$KeepSelection"

    if (-not $KeepSelection) {
        Set-MetadataText 'Preview detenido.'
    }
}

function Start-Recording {
    Write-AppLog "Start-Recording audioChecked=$($chkAudio.Checked) audio=$($cmbAudio.SelectedItem.Label)"
    if ($script:IsRecording) { return }
    if ($null -eq $script:Reader) {
        Start-Preview
    }

    $ffmpeg = Get-FfmpegPath
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) {
        throw 'No encontre ffmpeg en PATH. Sin ffmpeg puedo capturar fotos, pero no codificar video MP4.'
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tempDirectory = Join-Path $OutputDirectory 'temp'
    if (-not (Test-Path -LiteralPath $tempDirectory)) {
        New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    }

    $script:RecordDirectory = Join-Path $tempDirectory "recording_$stamp"
    New-Item -ItemType Directory -Path $script:RecordDirectory | Out-Null

    $script:RecordFrameIndex = 0
    $script:RecordStartedAt = [DateTimeOffset]::Now
    $script:AudioProcess = $null
    $script:AudioPath = Join-Path $script:RecordDirectory 'audio.wav'

    if ($chkAudio.Checked) {
        $audioDevice = if ($null -ne $cmbAudio.SelectedItem) { $cmbAudio.SelectedItem.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($audioDevice)) {
            throw 'Marcaste audio, pero no seleccionaste un microfono.'
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ffmpeg
        $psi.Arguments = Join-ProcessArguments -Arguments @('-y', '-f', 'dshow', '-i', "audio=$audioDevice", '-acodec', 'pcm_s16le', $script:AudioPath)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $script:AudioProcess = [System.Diagnostics.Process]::Start($psi)
    }

    $script:IsRecording = $true
    $btnVideo.Text = 'Detener video'
    Set-CameraSelectionEnabled $false
    Set-MetadataText "Grabando frames en:`r`n$($script:RecordDirectory)"
    Write-AppLog "Recording started directory=$($script:RecordDirectory)"
}

function Stop-AudioRecording {
    if ($null -eq $script:AudioProcess) { return }

    try {
        if (-not $script:AudioProcess.HasExited) {
            $script:AudioProcess.StandardInput.WriteLine('q')
            if (-not $script:AudioProcess.WaitForExit(3000)) {
                $script:AudioProcess.Kill()
                $script:AudioProcess.WaitForExit()
            }
        }
    }
    finally {
        $script:AudioProcess.Dispose()
        $script:AudioProcess = $null
    }
}

function Stop-Recording {
    Write-AppLog "Stop-Recording frames=$($script:RecordFrameIndex)"
    if (-not $script:IsRecording) { return }

    $script:IsRecording = $false
    $btnVideo.Text = 'Grabar video'
    Set-CameraSelectionEnabled $true
    Stop-AudioRecording

    if ($script:RecordFrameIndex -le 0) {
        throw 'No se capturaron frames para codificar.'
    }

    $videoDirectory = Join-Path $OutputDirectory 'video'
    if (-not (Test-Path -LiteralPath $videoDirectory)) {
        New-Item -ItemType Directory -Path $videoDirectory | Out-Null
    }

    $outputFile = Join-Path $videoDirectory ("CameraIR_{0:yyyyMMdd_HHmmss}.mp4" -f [DateTime]::Now)
    $framesPattern = Join-Path $script:RecordDirectory 'frame_%06d.jpg'
    $elapsedSeconds = [Math]::Max(1, ([DateTimeOffset]::Now - $script:RecordStartedAt).TotalSeconds)
    $fps = [Math]::Max(1, [Math]::Round($script:RecordFrameIndex / $elapsedSeconds, 2))

    $args = @('-hide_banner', '-y', '-framerate', "$fps", '-i', $framesPattern)
    if ((Test-Path -LiteralPath $script:AudioPath) -and ((Get-Item -LiteralPath $script:AudioPath).Length -gt 44)) {
        $args += @('-i', $script:AudioPath, '-shortest')
    }
    $args += @('-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', $outputFile)

    Set-MetadataText "Codificando MP4...`r`nFrames: $($script:RecordFrameIndex)`r`nFPS estimado: $fps"
    [void](Invoke-Ffmpeg -Arguments $args)

    Set-MetadataText "Video guardado:`r`n$outputFile`r`nFrames: $($script:RecordFrameIndex)`r`nFPS estimado: $fps"
    Write-AppLog "Recording encoded output=$outputFile frames=$($script:RecordFrameIndex) fps=$fps"
}

$timer.Add_Tick({
    if ($script:IsProcessingFrame) { return }
    $script:IsProcessingFrame = $true

    try {
        if ($null -eq $script:Reader) { return }
        $frame = $script:Reader.TryAcquireLatestFrame()
        if ($null -eq $frame) { return }

        if ($script:Frame -is [System.IDisposable]) { $script:Frame.Dispose() }
        $script:Frame = $frame

        $softwareBitmap = $frame.VideoMediaFrame.SoftwareBitmap
        if ($null -eq $softwareBitmap) { return }

        $bitmap = Convert-SoftwareBitmapToBitmap -SoftwareBitmap $softwareBitmap
        $oldImage = $preview.Image
        $preview.Image = $bitmap
        if ($oldImage -is [System.IDisposable]) { $oldImage.Dispose() }
        $script:LastBitmap = $bitmap

        if ($script:IsRecording) {
            $script:RecordFrameIndex++
            $framePath = Join-Path $script:RecordDirectory ("frame_{0:D6}.jpg" -f $script:RecordFrameIndex)
            $bitmap.Save($framePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }

        $recordText = if ($script:IsRecording) { "`r`nGrabando: frame $($script:RecordFrameIndex)" } else { '' }
        Set-MetadataText "Grupo: $($cmbGroup.SelectedItem.Value.DisplayName)`r`nStream: $($script:CurrentSource.Info.SourceKind)`r`nFormato: $($softwareBitmap.PixelWidth)x$($softwareBitmap.PixelHeight) $($softwareBitmap.BitmapPixelFormat)`r`nFrame duration: $($frame.Duration)`r`nSystemRelativeTime: $($frame.SystemRelativeTime)`r`nFoto dir: $OutputDirectory$recordText"

        $script:FrameTickCount++
        if (($script:FrameTickCount % 50) -eq 0) {
            Write-AppLog "Preview frame tick=$($script:FrameTickCount) format=$($softwareBitmap.PixelWidth)x$($softwareBitmap.PixelHeight) $($softwareBitmap.BitmapPixelFormat) recording=$($script:IsRecording)"
        }
    }
    catch {
        $timer.Stop()
        Write-AppException -Context 'Preview timer failed' -Exception $_.Exception.ToString()
        Set-MetadataText $_.Exception.ToString()
    }
    finally {
        $script:IsProcessingFrame = $false
    }
})

$cmbGroup.Add_SelectedIndexChanged({
    if (-not $script:IsRefreshingSelection) { Refresh-Sources }
})
$cmbSource.Add_SelectedIndexChanged({
    if (-not $script:IsRefreshingSelection) { Refresh-Formats }
})
$cmbFormat.Add_SelectedIndexChanged({
    if (-not $script:IsRefreshingSelection -and ($timer.Enabled -or $script:AutoPreviewEnabled)) {
        try {
            Stop-Preview -KeepSelection
            Start-Preview
        }
        catch { Set-MetadataText $_.Exception.ToString() }
    }
})
$btnStart.Add_Click({
    try {
        if ($timer.Enabled) {
            Stop-Preview
        }
        else {
            Start-Preview
        }
    }
    catch { Set-MetadataText $_.Exception.ToString() }
})
$btnStop.Add_Click({ Stop-Preview })
$btnPhoto.Add_Click({
    try {
        if ($null -eq $preview.Image) { throw 'No hay frame visible para guardar.' }
        $file = Join-Path $OutputDirectory ("CameraIR_{0:yyyyMMdd_HHmmss}.png" -f [DateTime]::Now)
        $preview.Image.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        Set-MetadataText "Foto guardada:`r`n$file"
        Write-AppLog "Photo saved path=$file"
    }
    catch {
        Write-AppException -Context 'Photo button failed' -Exception $_.Exception.ToString()
        Set-MetadataText $_.Exception.ToString()
    }
})
$btnVideo.Add_Click({
    try {
        if ($script:IsRecording) {
            Stop-Recording
        }
        else {
            Start-Recording
        }
    }
    catch {
        Write-AppException -Context 'Video button failed' -Exception $_.Exception.ToString()
        Set-MetadataText $_.Exception.ToString()
    }
})
$btnBridge.Add_Click({
    Set-MetadataText 'Puente virtual proximamente. La base sera este mismo capturador, publicando frames como camara virtual.'
})
$form.Add_Shown({
    try {
        $script:AutoPreviewEnabled = $true
        Start-Preview
    }
    catch { Set-MetadataText $_.Exception.ToString() }
})
$form.Add_FormClosing({ Stop-Preview })

Refresh-Groups
Refresh-AudioDevices
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
