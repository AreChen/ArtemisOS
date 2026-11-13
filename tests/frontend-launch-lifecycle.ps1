$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\frontend-lifecycle-tests'
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$processes = @()
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
function Function-Body([string]$Path, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) ('Syntax error in ' + $Path)
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name}, $false)
    Assert ($null -ne $function) ('Missing lifecycle implementation: ' + $Name)
    return [scriptblock]::Create($function.Extent.Text)
}
function Run-Script([string]$Path, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{Code=$code;Output=($output -join "`n")}
}
function Start-Stub([string]$Path, [string[]]$Arguments) {
    $quoted = @($Arguments | ForEach-Object { '"' + $_ + '"' })
    $process = Start-Process -FilePath $Path -ArgumentList $quoted -WindowStyle Hidden -PassThru
    $script:processes += [pscustomobject]@{Process=$process;Path=$Path;Ticks=$process.StartTime.ToUniversalTime().Ticks}
    return $process
}
function Wait-File([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw ('Fixture signal timed out: ' + $Path) }
        Start-Sleep -Milliseconds 25
    }
}
try {
    $launchSource = Join-Path $project 'stage\launch.ps1'
    . (Function-Body $launchSource 'Get-ArtemisLaunchMode')
    foreach ($headless in @($false,$true)) {
        foreach ($external in @($false,$true)) {
            if ($headless -and $external) { Reject { Get-ArtemisLaunchMode -Headless -ExternalDisplay -FrontendAvailable } 'Conflicting window modes were accepted.'; continue }
            $mode = Get-ArtemisLaunchMode -Headless:$headless -ExternalDisplay:$external -FrontendAvailable
            Assert ($mode.DelegateFrontend -eq (-not $headless -and -not $external)) 'Normal launch delegation differs from the specified mode.'
            Assert ($mode.StartBridge -eq (-not $headless)) 'External display disabled the OTA bridge or Headless enabled it.'
            if ($external) { Assert (($mode.EmulatorArguments -join '|') -ceq '-no-window' -and $mode.InitializeHeadless) 'External display must hide Qt while preserving audio and initialization.' }
            if ($headless) { Assert (($mode.EmulatorArguments -join '|') -ceq '-no-window|-no-audio|-no-boot-anim') 'The existing Headless flags changed.' }
        }
    }
    Assert (-not (Get-ArtemisLaunchMode).DelegateFrontend) 'Missing frontend prevented the legacy entry.'
    $helperSource = Join-Path $project 'stage\update\frontend-handoff.ps1'
    Assert (Test-Path -LiteralPath $helperSource -PathType Leaf) 'The frontend session/handoff implementation is missing.'
    . $helperSource

    $root = Join-Path $fixture 'install with spaces'
    foreach ($relative in @('update\frontend','sdk\emulator','sdk\platform-tools','data\avd','data\runtime')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $relative))
    }
    foreach ($relative in @('launch.ps1','initialize.ps1','settings.ps1')) { Copy-Item -LiteralPath (Join-Path $project ('stage\' + $relative)) -Destination (Join-Path $root $relative) }
    Copy-Item -LiteralPath $helperSource -Destination (Join-Path $root 'update\frontend-handoff.ps1')
    [IO.File]::WriteAllText((Join-Path $root 'version.ini'), "[ArtemisOS]`nVersion=1.0.5`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $root 'data\preferences.ini'), "profile=medium`ncleanup=1`ncarrier=mobile`ngraphics=host`nresolution=900p`ncustom_preserved=yes`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $root 'data\setup-state.ini'), "locale=1`nnetwork=1`ncarrier=mobile`ncleanup=1`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllBytes((Join-Path $root 'data\avd\preserved-marker.txt'), [byte[]](0,1,13,10,127,128,255))
    $preferences = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'data\preferences.ini')))
    $marker = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'data\avd\preserved-marker.txt')))
    $frontendExe = Join-Path $root 'update\frontend\ArtemisFrontend.exe'
    $stubSource = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Text;
using System.Threading;
public static class FrontendLifecycleFixture {
    public static int Main(string[] args) {
        string name = Path.GetFileName(Environment.GetCommandLineArgs()[0]);
        if (String.Equals(name, "adb.exe", StringComparison.OrdinalIgnoreCase)) {
            string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "../.."));
            string command = String.Join(" ", args);
            File.AppendAllText(Path.Combine(root, "adb-commands.txt"), command + "\n");
            if (command.EndsWith("getprop sys.boot_completed")) Console.WriteLine("1");
            else if (command.EndsWith("getprop ro.boot.qemu")) Console.WriteLine("0");
            else if (command.EndsWith("settings get global auto_time_zone")) Console.WriteLine("0");
            else if (command.EndsWith("pm list packages com.android.settings")) Console.WriteLine("package:com.android.settings");
            else if (command.EndsWith("settings get global airplane_mode_on")) Console.WriteLine("0");
            else if (command.EndsWith("settings get global wifi_on")) Console.WriteLine("1");
            else if (command.EndsWith("cmd wifi status")) Console.WriteLine("Wifi is connected");
            else if (command.EndsWith("dumpsys SurfaceFlinger")) Console.WriteLine(File.ReadAllText(Path.Combine(root, "renderer.txt")));
            else if (command.EndsWith("emu kill") && File.Exists(Path.Combine(root, "backend-identity.txt"))) {
                string[] identity = File.ReadAllLines(Path.Combine(root, "backend-identity.txt"));
                using (Process backend = Process.GetProcessById(Int32.Parse(identity[0]))) {
                    if (!String.Equals(backend.MainModule.FileName, Path.Combine(root, "sdk/emulator/emulator.exe").Replace('/', '\\'), StringComparison.OrdinalIgnoreCase) ||
                        backend.StartTime.ToUniversalTime().Ticks.ToString() != identity[1]) return 3;
                    backend.Kill(); backend.WaitForExit(5000);
                }
                File.WriteAllText(Path.Combine(root, "backend-stopped.txt"), "owned fixture stopped");
            }
            return 0;
        }
        string install = null, pipe = null, session = null, mode = "good";
        bool hold = false;
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--root") install = args[++i];
            else if (args[i] == "--pipe") pipe = args[++i];
            else if (args[i] == "--session") session = args[++i];
            else if (args[i] == "--mode") mode = args[++i];
            else if (args[i] == "--hold" || args[i] == "--backend") hold = true;
        }
        if (pipe != null) {
            using (var server = new NamedPipeServerStream(pipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous)) {
                File.WriteAllText(Path.Combine(install, "pipe-ready-" + session), "ready");
                server.WaitForConnection();
                using (var reader = new StreamReader(server, Encoding.UTF8, false, 1024, true))
                using (var writer = new StreamWriter(server, new UTF8Encoding(false), 1024, true)) {
                    File.WriteAllText(Path.Combine(install, "pipe-request-" + session), reader.ReadLine());
                    if (mode == "hang") { Thread.Sleep(60000); return 0; }
                    writer.WriteLine((mode == "wrong" ? "wrong:" : "ready:") + session); writer.Flush();
                    if (mode == "stay") Thread.Sleep(60000);
                }
            }
        } else if (hold) { Thread.Sleep(60000); }
        else { File.WriteAllLines(Path.Combine(install, "frontend-arguments.txt"), args); }
        return 0;
    }
}
'@
    Add-Type -OutputAssembly $frontendExe -OutputType WindowsApplication -TypeDefinition $stubSource
    Copy-Item -LiteralPath $frontendExe -Destination (Join-Path $root 'sdk\emulator\emulator.exe')
    Add-Type -OutputAssembly (Join-Path $root 'sdk\platform-tools\adb.exe') -OutputType ConsoleApplication -TypeDefinition ($stubSource.Replace('FrontendLifecycleFixture', 'AdbLifecycleFixture'))

    # The actual entry delegates before SDK checks or launch locks; arguments retain spaces.
    $delegated = Run-Script (Join-Path $root 'launch.ps1') @('-Graphics','swiftshader','-Port','5576')
    Assert ($delegated.Code -eq 0) ('Normal frontend delegation failed: ' + $delegated.Output)
    Wait-File (Join-Path $root 'frontend-arguments.txt')
    $arguments = [IO.File]::ReadAllLines((Join-Path $root 'frontend-arguments.txt'))
    Assert (($arguments -join '|') -ceq ('--root|' + $root + '|--graphics|swiftshader|--port|5576')) 'The frontend lost the root, shortcut override or explicit port.'
    [IO.File]::Delete((Join-Path $root 'frontend-arguments.txt'))
    $default = Run-Script (Join-Path $root 'launch.ps1') @('-Graphics','auto')
    Assert ($default.Code -eq 0) ('The default shortcut did not delegate: ' + $default.Output)
    Wait-File (Join-Path $root 'frontend-arguments.txt')
    $arguments = [IO.File]::ReadAllLines((Join-Path $root 'frontend-arguments.txt'))
    $defaultPort = [int]$arguments[5]
    Assert ($arguments.Count -eq 6 -and $arguments[4] -ceq '--port' -and $defaultPort -ge 5554 -and $defaultPort -le 5584 -and $defaultPort % 2 -eq 0) 'The default shortcut passed Port=0 or an invalid port to the native frontend.'
    & {
        . (Function-Body $launchSource 'Get-ArtemisLaunchPort')
        function Get-ArtemisAdbReservedPorts { 5554; 5558 }
        function Test-PortPair([int]$Number) { return $Number -ne 5556 }
        Assert ((Get-ArtemisLaunchPort) -eq 5560) 'Automatic selection did not skip ADB-reserved and bound port pairs.'
        Assert ((Get-ArtemisLaunchPort 5576) -eq 5576) 'An explicit available port changed.'
        Reject { Get-ArtemisLaunchPort 5555 } 'An odd explicit port was accepted.'
        Reject { Get-ArtemisLaunchPort 5558 } 'An ADB-reserved port was accepted.'
        Reject { Get-ArtemisLaunchPort 5556 } 'A bound port pair was accepted.'
        function Test-PortPair([int]$Number) { return $false }
        Reject { Get-ArtemisLaunchPort } 'Exhausted automatic port selection was accepted.'
    }
    $conflicting = Run-Script (Join-Path $root 'launch.ps1') @('-ExternalDisplay','-Headless')
    Assert ($conflicting.Code -ne 0) 'The actual launch entry accepted conflicting display modes.'
    $backend = Start-Stub (Join-Path $root 'sdk\emulator\emulator.exe') @('--backend','-port','5554')
    $frontend = Start-Stub $frontendExe @('--hold','--root',$root)
    $frontendTicks = $frontend.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $backendTicks = $backend.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $snapshot = Get-ArtemisFrontendProcessSnapshot $frontend.Id
    Assert (Test-ArtemisFrontendIdentity $snapshot $root $frontend.Id $frontendTicks) 'The owned frontend was rejected.'
    Assert (-not (Test-ArtemisFrontendIdentity $snapshot $root $frontend.Id ([string]([long]$frontendTicks + 1)))) 'PID reuse with a different creation time was accepted.'
    Assert (-not (Test-ArtemisFrontendIdentity $snapshot (Join-Path $fixture 'other') $frontend.Id $frontendTicks)) 'Another installation was accepted.'
    foreach ($bad in @('', '..\outside', ('A' * 32), ('a' * 31), ('a' * 33))) {
        Reject { Get-ArtemisFrontendSessionPath $root $bad } 'An invalid or traversal session identifier was accepted.'
    }
    $session = [Guid]::NewGuid().ToString('N')
    $path = Get-ArtemisFrontendSessionPath $root $session
    Assert ($path -ceq (Join-Path $root ('data\runtime\' + $session + '.json'))) 'The session path escaped its fixed runtime directory.'
    New-ArtemisFrontendSession -InstallRoot $root -SessionId $session -Serial 'emulator-5554' -EmulatorPid $backend.Id -EmulatorStartTimeUtcTicks $backendTicks -FrontendPid $frontend.Id -FrontendStartTimeUtcTicks $frontendTicks -GraphicsOverride auto -GraphicsRenderer host -GraphicsDevice '' -StdoutLog 'stdout-fixture.log' -StderrLog 'stderr-fixture.log'
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $keys = @($state.PSObject.Properties | ForEach-Object Name | Sort-Object)
    $expectedKeys = @('schemaVersion','sessionId','installRoot','serial','emulatorPid','emulatorStartTimeUtcTicks','graphicsOverride','graphicsRenderer','graphicsDevice','frontendPid','frontendStartTimeUtcTicks','state','error','stdoutLog','stderrLog','actualRenderer') | Sort-Object
    Assert (($keys -join '|') -ceq ($expectedKeys -join '|') -and $state.state -ceq 'starting' -and $state.emulatorPid -eq $backend.Id -and $state.frontendPid -eq $frontend.Id -and $state.emulatorStartTimeUtcTicks -is [string]) 'The starting receipt schema or process identities are incorrect.'
    Reject { New-ArtemisFrontendSession -InstallRoot $root -SessionId $session -Serial 'emulator-5554' -EmulatorPid $backend.Id -EmulatorStartTimeUtcTicks $backendTicks -FrontendPid $frontend.Id -FrontendStartTimeUtcTicks $frontendTicks -GraphicsOverride auto -GraphicsRenderer host -StdoutLog x -StderrLog y } 'An existing session receipt was overwritten.'
    Reject { Set-ArtemisFrontendSessionState -InstallRoot $root -SessionId $session -Serial 'emulator-5556' -EmulatorPid $backend.Id -State ready } 'A different device changed this session state.'

    $renderer = 'GLES: Google, Android Emulator OpenGL ES Translator (ANGLE (Intel(R) UHD Graphics 770, Vulkan 1.4.323 (Intel(R) UHD Graphics 770))), OpenGL ES 3.1'
    [IO.File]::WriteAllText((Join-Path $root 'renderer.txt'), $renderer, [Text.Encoding]::ASCII)
    $initialized = Run-Script (Join-Path $root 'initialize.ps1') @('-Serial','emulator-5554','-EmulatorPid',[string]$backend.Id,'-Headless','-SessionId',$session,'-GraphicsRenderer','vulkan_intel','-GraphicsDevice','Intel(R) UHD Graphics 770','-WaitSeconds','2')
    Assert ($initialized.Code -eq 0) ('External initialization failed: ' + $initialized.Output)
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    Assert ($state.state -ceq 'ready' -and $state.actualRenderer -ceq $renderer -and $state.error -ceq '') 'Initialization did not atomically report ready and the actual GPU.'
    [IO.File]::WriteAllText((Join-Path $root 'renderer.txt'), 'GLES: ANGLE (Google, Vulkan 1.3 (SwiftShader Device (Subzero)))', [Text.Encoding]::ASCII)
    $failed = Run-Script (Join-Path $root 'initialize.ps1') @('-Serial','emulator-5554','-EmulatorPid',[string]$backend.Id,'-Headless','-SessionId',$session,'-GraphicsRenderer','vulkan','-WaitSeconds','2')
    Assert ($failed.Code -ne 0) 'A hardware verification failure returned success.'
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    Assert ($state.state -ceq 'failed' -and -not [string]::IsNullOrWhiteSpace($state.error)) 'A failed initialization left a misleading ready/starting receipt.'
    # A reused PID must be rejected before any device command, including emu kill.
    $state.emulatorStartTimeUtcTicks = ([long]$state.emulatorStartTimeUtcTicks + 1).ToString()
    [IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 4), [Text.Encoding]::UTF8)
    $commandsBefore = [IO.File]::ReadAllText((Join-Path $root 'adb-commands.txt'))
    $reused = Run-Script (Join-Path $root 'initialize.ps1') @('-Serial','emulator-5554','-EmulatorPid',[string]$backend.Id,'-Headless','-SessionId',$session,'-GraphicsRenderer','vulkan','-WaitSeconds','2')
    Assert ($reused.Code -ne 0 -and [IO.File]::ReadAllText((Join-Path $root 'adb-commands.txt')) -ceq $commandsBefore) 'A reused backend PID reached device commands before rejection.'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp' -Force).Count -eq 0) 'An atomic state write left temporary files.'
    $frontend.Kill(); [void]$frontend.WaitForExit(5000)

    # Use real pipe servers and child process exit, never a mocked acknowledgment.
    foreach ($mode in @('good','wrong','hang','stay')) {
        $session = [Guid]::NewGuid().ToString('N')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $pipe = 'ArtemisOS-Frontend-' + $digest + '-' + $session
        Assert ((Get-ArtemisFrontendPipeName $root $session) -ceq $pipe) 'The pipe name differs from the C# contract.'
        $frontend = Start-Stub $frontendExe @('--root',$root,'--pipe',$pipe,'--session',$session,'--mode',$mode)
        Wait-File (Join-Path $root ('pipe-ready-' + $session))
        New-ArtemisFrontendSession -InstallRoot $root -SessionId $session -Serial 'emulator-5554' -EmulatorPid $backend.Id -EmulatorStartTimeUtcTicks $backendTicks -FrontendPid $frontend.Id -FrontendStartTimeUtcTicks ($frontend.StartTime.ToUniversalTime().Ticks.ToString()) -GraphicsOverride auto -GraphicsRenderer host -StdoutLog x -StderrLog y
        $timer = [Diagnostics.Stopwatch]::StartNew()
        if ($mode -ceq 'good') {
            Assert (Request-ArtemisFrontendExitForUpdate -InstallRoot $root -Serial 'emulator-5554' -EmulatorPid $backend.Id -TimeoutMilliseconds 4000) 'The actual update exit handshake was not completed.'
            Assert ($frontend.WaitForExit(1000)) 'A frontend acknowledged but still locked its executable.'
        } else {
            Reject { Request-ArtemisFrontendExitForUpdate -InstallRoot $root -Serial 'emulator-5554' -EmulatorPid $backend.Id -TimeoutMilliseconds 700 } ('A bad/unfinished handshake was accepted: ' + $mode)
            Assert ($timer.ElapsedMilliseconds -lt 5000) 'The named-pipe handoff exceeded its bounded timeout.'
        }
        Assert ([IO.File]::ReadAllText((Join-Path $root ('pipe-request-' + $session))) -ceq ('prepare-update:' + $session)) 'The updater sent an unexpected pipe command.'
        Assert (-not $backend.HasExited) 'The frontend handoff stopped the backend itself.'
        $frontend.Refresh()
        if (-not $frontend.HasExited) { $frontend.Kill(); [void]$frontend.WaitForExit(5000) }
    }
    Assert (-not (Request-ArtemisFrontendExitForUpdate -InstallRoot $root -Serial 'emulator-5554' -EmulatorPid $backend.Id -TimeoutMilliseconds 500)) 'Stale receipts prevented a legacy update with no live frontend.'

    # Run the real signed updater against a fixture backend. A rejected handshake
    # must precede adb/recovery; an accepted handshake must unlock the frontend
    # executable before the verified transaction replaces it.
    foreach ($relative in @('core.ps1','apply.ps1','recovery.ps1')) {
        Copy-Item -LiteralPath (Join-Path $project ('stage\update\' + $relative)) -Destination (Join-Path $root ('update\' + $relative))
    }
    $staged = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staged)
    $versionPath = Join-Path $root 'version.ini'
    $oldVersion = [IO.File]::ReadAllText($versionPath)
    $versionBytes = [Text.Encoding]::ASCII.GetBytes("[ArtemisOS]`nVersion=1.0.6`n")
    $frontendBytes = [byte[]](@([IO.File]::ReadAllBytes($frontendExe)) + [byte]0)
    $files = @()
    foreach ($replacement in @(
        @{Path='update/frontend/ArtemisFrontend.exe';Bytes=$frontendBytes},
        @{Path='version.ini';Bytes=$versionBytes}
    )) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([byte[]]$replacement.Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $target = Join-Path $root $replacement.Path
        $files += [ordered]@{path=$replacement.Path;base_sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();sha256=$hash;size=$replacement.Bytes.Length}
        [IO.File]::WriteAllBytes((Join-Path $staged $hash), [byte[]]$replacement.Bytes)
    }
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes((([ordered]@{schema=1;product='ArtemisOS-15';from='1.0.5';to='1.0.6';notes='isolated frontend lifecycle fixture';files=$files}) | ConvertTo-Json -Depth 6))
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    try {
        [IO.File]::WriteAllText((Join-Path $root 'update\trusted-key.xml'), $rsa.ToXmlString($false))
        [IO.File]::WriteAllBytes((Join-Path $staged 'manifest.json'), $manifestBytes)
        [IO.File]::WriteAllText((Join-Path $staged 'manifest.sig'), [Convert]::ToBase64String($rsa.SignData($manifestBytes, 'SHA256')))
    } finally { $rsa.Dispose() }
    [IO.File]::WriteAllLines((Join-Path $root 'backend-identity.txt'), @([string]$backend.Id,$backendTicks))
    $runner = Join-Path $fixture 'apply-runner.ps1'
    [IO.File]::WriteAllText($runner, @'
param([string]$Root,[string]$Staged,[int]$BackendPid)
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter)
    if ($Filter -notlike "*Name='qemu-system-x86_64-headless.exe'*") {
        return CimCmdlets\Get-CimInstance @PSBoundParameters
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'backend-stopped.txt')) { return }
    $sdk = Join-Path $Root 'sdk\emulator'
    [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $sdk 'emulator.exe');CommandLine='emulator.exe -port 5554';ProcessId=$BackendPid;ParentProcessId=10}
    [pscustomobject]@{Name='qemu-system-x86_64-headless.exe';ExecutablePath=(Join-Path $sdk 'qemu\windows-x86_64\qemu-system-x86_64-headless.exe');CommandLine='qemu.exe -port 5554';ProcessId=2147483646;ParentProcessId=$BackendPid}
}
& (Join-Path $Root 'update\apply.ps1') -Staging $Staged -Serial 'emulator-5554' -EmulatorPid $BackendPid -NoRestart
if (-not $?) { exit 1 }
'@, [Text.Encoding]::ASCII)
    foreach ($mode in @('wrong','good')) {
        $session = [Guid]::NewGuid().ToString('N')
        $pipe = Get-ArtemisFrontendPipeName $root $session
        $frontend = Start-Stub $frontendExe @('--root',$root,'--pipe',$pipe,'--session',$session,'--mode',$mode)
        Wait-File (Join-Path $root ('pipe-ready-' + $session))
        New-ArtemisFrontendSession -InstallRoot $root -SessionId $session -Serial 'emulator-5554' -EmulatorPid $backend.Id -EmulatorStartTimeUtcTicks $backendTicks -FrontendPid $frontend.Id -FrontendStartTimeUtcTicks ($frontend.StartTime.ToUniversalTime().Ticks.ToString()) -GraphicsOverride auto -GraphicsRenderer host -StdoutLog x -StderrLog y
        $applied = Run-Script $runner @('-Root',$root,'-Staged',$staged,'-BackendPid',[string]$backend.Id)
        if ($mode -ceq 'wrong') {
            Assert ($applied.Code -ne 0 -and -not $backend.HasExited -and -not (Test-Path -LiteralPath (Join-Path $root 'backend-stopped.txt')) -and
                [IO.File]::ReadAllText($versionPath) -ceq $oldVersion -and -not (Test-Path -LiteralPath (Join-Path $root 'data\update\pending'))) ('A rejected handoff reached backend shutdown, replacement or recovery: ' + $applied.Output)
        } else {
            Assert ($applied.Code -eq 0 -and $backend.WaitForExit(1000) -and $frontend.WaitForExit(1000)) ('The real updater did not stop the owned backend after frontend exit: ' + $applied.Output)
            Assert ((Get-FileHash -LiteralPath $frontendExe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $files[0].sha256 -and
                [IO.File]::ReadAllText($versionPath) -ceq [Text.Encoding]::ASCII.GetString($versionBytes) -and
                (Test-Path -LiteralPath (Join-Path $root 'data\update\pending\completed.flag'))) 'The signed frontend/version transaction was not completed.'
        }
        Assert ([IO.File]::ReadAllText((Join-Path $root ('pipe-request-' + $session))) -ceq ('prepare-update:' + $session)) 'Apply did not use the expected session-bound handshake.'
        [void]$frontend.WaitForExit(1000)
    }
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'data\preferences.ini'))) -ceq $preferences -and [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'data\avd\preserved-marker.txt'))) -ceq $marker) 'The lifecycle changed preferences or AVD data.'
    Write-Host 'PASS: launch modes, identity-bound atomic states, initialization success/failure, bounded pipe handoff and real signed apply with frontend replacement; user data preserved.'
} finally {
    foreach ($owned in $processes) {
        $process = $owned.Process
        $process.Refresh()
        if (-not $process.HasExited) {
            Assert ($process.StartTime.ToUniversalTime().Ticks -eq $owned.Ticks -and $owned.Path.StartsWith(($fixture + '\'), [StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture process cleanup.'
            $process.Kill(); [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    Assert ([string]::Equals($resolved, [IO.Path]::GetFullPath($fixture), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -cmatch '^[a-f0-9]{32}$' -and [string]::Equals((Split-Path -Parent $resolved), [IO.Path]::GetFullPath($parent), [StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture cleanup.'
    foreach ($item in Get-ChildItem -LiteralPath $resolved -Recurse -Force) { Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Unsafe reparse cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
