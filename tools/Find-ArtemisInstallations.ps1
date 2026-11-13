param(
    [string]$ExplicitPath = '',
    [string]$TargetVersion = '',
    [switch]$NonInteractive,
    [ValidateSet('Json','Inno')][string]$Format = 'Json',
    [string]$OutputFile = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ArtemisInstallDiscovery.psm1') -Force -ErrorAction Stop
$registry = Get-ArtemisRegistryRegistrations
$discovery = Get-ArtemisInstallCandidates -Registrations $registry.Records -InitialIssues $registry.Issues
$selection = Resolve-ArtemisInstallTarget -Discovery $discovery -ExplicitPath $ExplicitPath -TargetVersion $TargetVersion
$result = [pscustomobject]@{ Schema = 1; Candidates = @($discovery.Candidates); Issues = @($discovery.Issues); Selection = $selection }
if ($Format -eq 'Json') {
    $output = $result | ConvertTo-Json -Depth 8
} else {
    # The installer consumes only canonical paths, numeric versions and status.
    # No reason or registry data is interpolated into script code or commands.
    $lines = @('schema=1', ('status=' + $selection.Status), ('count=' + $discovery.Candidates.Count))
    for ($i = 0; $i -lt $discovery.Candidates.Count; $i++) {
        $candidate = $discovery.Candidates[$i]
        $lines += "path$i=$($candidate.Path)"
        $lines += "version$i=$($candidate.Version)"
        $lines += "ambiguous$i=$($candidate.RegistrationAmbiguous)"
    }
    $output = $lines -join "`r`n"
}
if ($OutputFile) {
    [IO.File]::WriteAllText($OutputFile, $output + "`r`n", [Text.UTF8Encoding]::new($true))
} else { $output }
if ($NonInteractive -and $selection.Status -in @('selection_required','registration_uncertain','registration_ambiguous','invalid_target','newer')) {
    exit 2
}
