param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','CimCmdlets')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this developer-only test in Windows PowerShell -STA.' }
$project = Split-Path -Parent $PSScriptRoot
$fixtureParent = Join-Path $project 'build\frame-rate-ui-binding-tests'
$fixture = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data'))
$checks = 0
$form = $null
function Assert([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }; $script:checks++
}
try {
    Copy-Item -LiteralPath (Join-Path $project 'stage\settings.ps1') -Destination $fixture
    $source = [IO.File]::ReadAllText((Join-Path $project 'stage\configure.ps1'))
    $tail = '(?m)^\[void\]\$form\.ShowDialog\(\)\r?\n\$form\.Dispose\(\)\r?\n?\z'
    if ([regex]::Matches($source,'\[void\]\$form\.ShowDialog\(\)').Count -ne 1 -or
        [regex]::Matches($source,'\$form\.Dispose\(\)').Count -ne 1 -or
        [regex]::Matches($source,$tail).Count -ne 1) { throw 'The unique terminal ShowDialog/Dispose pair changed; refusing to construct UI.' }
    $constructionOnly = [regex]::Replace($source,$tail,'')
    if ($constructionOnly.Contains('$form.ShowDialog()') -or $constructionOnly.Contains('$form.Dispose()')) { throw 'Terminal UI calls were not removed exactly.' }
    [IO.File]::WriteAllText((Join-Path $fixture 'configure.ps1'),$constructionOnly,[Text.UTF8Encoding]::new($true))
    $preferencePath = Join-Path $fixture 'data\preferences.ini'
    foreach ($scenario in @('default60','custom77')) {
        if ($scenario -ceq 'custom77') {
            [IO.File]::WriteAllText($preferencePath,"frontend=artemis`nmax_fps=77`nfuture_key=keep`n",[Text.Encoding]::UTF8)
        }
        $before = if (Test-Path -LiteralPath $preferencePath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath)) } else { $null }
        try {
            . (Join-Path $fixture 'configure.ps1')
            Assert (-not $form.Visible -and [Windows.Forms.Application]::OpenForms.Count -eq 0) 'The binding test displayed a window.'
            Assert ($form.ClientSize.Width -eq 620 -and $form.ClientSize.Height -eq 686) 'The new FPS row changed the existing form size.'
            Assert ($customFps.Minimum -eq 1 -and $customFps.Maximum -eq 240 -and $customFps.DecimalPlaces -eq 0) 'The custom FPS control exposes an invalid range.'
            if ($scenario -ceq 'default60') {
                Assert ($frameRate.SelectedIndex -eq 2 -and $customFps.Value -eq 60 -and $frameRate.Enabled -and -not $customFps.Enabled) 'Default 60 FPS preset binding is incorrect.'
            } else {
                Assert ($frameRate.SelectedIndex -eq 3 -and $customFps.Value -eq 77 -and $customFps.Enabled) 'A saved custom FPS was not restored.'
                $frontend.SelectedIndex = 1
                Assert (-not $frameRate.Enabled -and -not $customFps.Enabled -and -not $frameRateLabel.Enabled -and -not $fpsUnit.Enabled -and $customFps.Value -eq 77) 'Native frontend did not disable FPS controls while retaining the chosen value.'
                $frontend.SelectedIndex = 0
                Assert ($frameRate.Enabled -and $customFps.Enabled -and $frameRate.SelectedIndex -eq 3 -and $customFps.Value -eq 77) 'Returning to the custom frontend lost the chosen value.'
                foreach ($preset in @(@(0,20),@(1,30),@(2,60))) {
                    $frameRate.SelectedIndex = $preset[0]
                    Assert ($customFps.Value -eq $preset[1] -and -not $customFps.Enabled) 'A preset did not update the numeric FPS value.'
                }
                $frameRate.SelectedIndex = 3
                $customFps.Value = 77
                Assert ($customFps.Enabled -and $customFps.Value -eq 77) 'Custom selection did not enable its numeric control.'
            }
            $preferred = $note.GetPreferredSize([Drawing.Size]::new(575,0))
            Assert ($note.Width -eq 575 -and $preferred.Height -le $note.Height) ('The note text needs '+$preferred.Height+'px but its allocated height is '+$note.Height+'px.')
            Assert ($note.Bottom -le $save.Top -and $note.Bottom -le $cancel.Top -and $save.Bottom -le $form.ClientSize.Height -and $cancel.Bottom -le $form.ClientSize.Height) 'The note overlaps save/cancel or pushes a button outside the form.'
            Assert ($frameRate.Bottom -le $note.Top -and $customFps.Bottom -le $note.Top) 'The FPS controls overlap the note.'
            $after = if (Test-Path -LiteralPath $preferencePath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath)) } else { $null }
            Assert ($after -ceq $before) 'Constructing or rebinding the hidden UI changed preferences.'
            Assert (-not $form.Visible -and [Windows.Forms.Application]::OpenForms.Count -eq 0) 'A binding change unexpectedly displayed a window.'
        } finally {
            if ($null -ne $form) { $form.Dispose(); $form = $null }
        }
    }
    Write-Output "PASS: $checks hidden WinForms FPS binding/layout checks at the current host font/DPI; no window shown or installed instance accessed."
} finally {
    if ($null -ne $form) { $form.Dispose() }
    $resolved = [IO.Path]::GetFullPath($fixture).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe UI-binding fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected UI-binding fixture reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
