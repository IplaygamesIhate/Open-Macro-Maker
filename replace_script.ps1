$path = "c:\Users\PRSMOID DESK\AppData\Roaming\REAPER\Scripts\PRSMOID Script\Open-Macro-Maker\OMM_UI.lua"
$lines = Get-Content $path
for ($i = 1580; $i -lt 1900; $i++) {
    $lines[$i] = $lines[$i].Replace("UI.camera.zoom", "ide_z").Replace("UI.camera.pan_x", "UI.ide_camera.pan_x").Replace("UI.camera.pan_y", "UI.ide_camera.pan_y")
}
Set-Content -Path $path -Value $lines
