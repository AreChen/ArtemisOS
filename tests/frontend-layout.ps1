$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$layout = Join-Path $root 'desktop\frontend\FrontendLayout.cs'
if (-not (Test-Path -LiteralPath $layout)) { throw 'ASSERT: frontend layout has not been implemented.' }
$source = Get-Content -LiteralPath $layout -Raw
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
    foreach ($screen in @(@(720,1600), @(1600,720), @(1080,1920))) {
        $size = New-Object Drawing.Size ([int](520*$scale)),([int](860*$scale))
        $video = New-Object Drawing.Size $screen[0],$screen[1]
        $layout = [ArtemisOS.Frontend.FrontendLayout]::Calculate($size,$scale,$video)
        Assert ($layout.Video.Width -gt 0 -and $layout.Video.Height -gt 0) 'Video remains visible.'
        Assert ($layout.Video.Top -ge $layout.Header.Bottom) 'Header does not cover video.'
        Assert ($layout.Video.Bottom -le $layout.Footer.Top) 'Footer does not cover video.'
        Assert ($layout.Video.Right -lt $layout.Toolbar.Left) 'Controls never cover the video.'
        $errorRatio = [Math]::Abs(($layout.Video.Width / [double]$layout.Video.Height) - ($video.Width / [double]$video.Height))
        Assert ($errorRatio -lt 0.005) 'Portrait and landscape video preserve aspect ratio at each DPI.'
        $fitted = [ArtemisOS.Frontend.FrontendLayout]::WindowForVideo($video,[int](800*$scale),$scale)
        $compact = [ArtemisOS.Frontend.FrontendLayout]::Calculate($fitted,$scale,$video)
        $padding = [int][Math]::Round(14*$scale)
        Assert ([Math]::Abs($compact.Video.Left-$padding) -le 1) 'Automatic window width leaves no unused side column.'
        Assert ([Math]::Abs($compact.Video.Top-$compact.Header.Bottom-$padding) -le 1) 'Automatic window height leaves no unused video area.'
    }
}
Write-Output 'PASS: 12 portrait/landscape and DPI layouts, aspect ratio, isolation and compact automatic window size.'
