# CameraIR

CameraIR is a Windows PowerShell/WinRT viewer for laptop camera modules that expose a normal RGB camera and a Windows Hello infrared sensor camera.

It was built for an HP/Realtek module where the IR camera is hidden from normal DirectShow webcam enumeration but is available through `MediaFrameSourceGroup` as an infrared source.

## Run The Viewer

```powershell
powershell -ExecutionPolicy Bypass -File ".\CameraIR-Viewer.ps1"
```

The viewer supports:

- RGB and IR source selection.
- Resolution/format selection per source.
- Live preview for `Gray8`, `YUY2`, and `NV12` frames.
- PNG snapshots.
- MP4 recording through `ffmpeg` by encoding preview frames.
- Optional microphone capture through FFmpeg/DirectShow.
- A virtual bridge button marked as coming soon.

## Diagnostic Tools

Probe WinRT camera groups and formats:

```powershell
powershell -ExecutionPolicy Bypass -File ".\tools\Probe-IrCamera.ps1"
```

Capture one IR frame to PGM/PNG:

```powershell
powershell -ExecutionPolicy Bypass -File ".\tools\Capture-IrFrame.ps1"
```

Inspect camera capabilities and frame metadata:

```powershell
powershell -ExecutionPolicy Bypass -File ".\tools\Inspect-CameraCapabilities.ps1" -CaptureProbeFrame
```

## Notes

- Generated captures are ignored by Git because they may contain biometric/face data.
- The app does not modify drivers, INF files, registry camera flags, or Windows Hello settings.
- The virtual camera bridge is intentionally not implemented yet.
