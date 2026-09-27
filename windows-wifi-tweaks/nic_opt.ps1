$log = Join-Path $PSScriptRoot 'nic_opt_result.txt'
$out = @()
$targets = @(
  @{ k = 'MIMOPowerSaveMode';        v = 3; name = 'MIMO power save    -> No SMPS (was Auto SMPS)' },
  @{ k = 'ThroughputBoosterEnabled'; v = 1; name = 'Throughput booster -> Enabled (was Disabled)' },
  @{ k = 'RoamAggressiveness';       v = 0; name = 'Roam aggressiveness-> Lowest (was Medium-low)' },
  @{ k = 'RoamingPreferredBandType'; v = 2; name = 'Preferred band     -> 5GHz (was No preference)' }
)
foreach ($t in $targets) {
  try {
    Set-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword $t.k -RegistryValue $t.v -NoRestart -ErrorAction Stop
    $out += "  [OK]   $($t.name)"
  } catch {
    $out += "  [FAIL] $($t.name)"
    $out += "         $($_.Exception.Message)"
  }
}
$out += ""
$out += "IsAdmin = " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out | Out-File -FilePath $log -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
