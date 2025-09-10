<# 
.SYNOPSIS
  Entra (Azure AD) SSH to Azure Linux VMs with client selection:
  - MobaXterm (OpenSSH) or
  - Windows OpenSSH (ssh.exe).
  PuTTY is detected but NOT supported for Entra SSH.
#>

param(
  [string]$ResourceGroup,
  [string]$VmName,
  [ValidateSet('moba','winssh','auto')]
  [string]$Client = 'auto',
  [switch]$InteractiveMenu,
  [switch]$PreferPrivateIp,
  [string]$KeysSubFolder = 'az_keys'
)

# ===== Paths & defaults =====
$UserName   = $env:USERNAME
$MobaHome   = "C:\Users\$UserName\Documents\MobaXterm\home"
$SshFolder  = Join-Path $MobaHome '.ssh'
$ConfigFile = Join-Path $SshFolder 'azure_ssh_config'
$KeysFolder = Join-Path $SshFolder $KeysSubFolder

# ===== Helpers =====
function Require-AzCli {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) not found. Install: https://aka.ms/azure-cli'
  }
}

function Ensure-AzLogin {
  $acct = az account show --query user.name -o tsv 2>$null
  if (-not $acct) {
    Write-Host "No active Azure login - running 'az login'..." -ForegroundColor Yellow
    az login | Out-Null
    $acct = az account show --query user.name -o tsv 2>$null
    if (-not $acct) { throw 'Azure login failed.' }
  }
  Write-Host "Signed in as: $acct"
}

function Ensure-SshExtension {
  az extension show --name ssh -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing Azure CLI SSH extension...' -ForegroundColor Yellow
    az extension add --name ssh | Out-Null
  }
}

function Ensure-Folders {
  foreach ($p in @($SshFolder, $KeysFolder)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
  }
}

function Detect-Clients {
  $hasWinSsh = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
  $mobaRoot1 = 'C:\Program Files (x86)\Mobatek\MobaXterm'
  $mobaRoot2 = 'C:\Program Files\Mobatek\MobaXterm'
  $hasMoba   = (Test-Path $mobaRoot1) -or (Test-Path $mobaRoot2) -or (Test-Path $MobaHome)
  $puttyExe  = (Get-Command putty -ErrorAction SilentlyContinue)
  $plinkExe  = (Get-Command plink -ErrorAction SilentlyContinue)
  $hasPutty  = [bool]($puttyExe -or $plinkExe)
  return [pscustomobject]@{
    HasWinSsh = $hasWinSsh
    HasMoba   = $hasMoba
    HasPutty  = $hasPutty
  }
}

function Select-FromList {
  param(
    [Parameter(Mandatory)][array]$Items,
    [Parameter(Mandatory)][string]$Title,
    [string]$DisplayProperty = 'name'
  )
  Write-Host ''
  Write-Host "== $Title ==" -ForegroundColor Cyan
  for ($i=0; $i -lt $Items.Count; $i++) {
    $label = if ($DisplayProperty) { $Items[$i].$DisplayProperty } else { $Items[$i] }
    Write-Host ("[{0}] {1}" -f ($i+1), $label)
  }
  do {
    $sel = Read-Host "Select (1-$($Items.Count))"
    [int]$idx = $sel - 1
  } until ($idx -ge 0 -and $idx -lt $Items.Count)
  return $Items[$idx]
}

function Pick-Client([object]$det) {
  $choices = @()
  if ($det.HasMoba)   { $choices += [pscustomobject]@{ name='MobaXterm (OpenSSH)'; val='moba' } }
  if ($det.HasWinSsh) { $choices += [pscustomobject]@{ name='Windows OpenSSH (ssh.exe)'; val='winssh' } }
  if ($det.HasPutty)  { $choices += [pscustomobject]@{ name='PuTTY (not compatible with Entra SSH)'; val='putty' } }

  if ($choices.Count -eq 0) {
    throw 'No supported SSH client found. Install MobaXterm or enable Windows OpenSSH.'
  }

  $pick = Select-FromList -Items $choices -Title 'Select SSH client' -DisplayProperty 'name'
  if ($pick.val -eq 'putty') {
    throw 'PuTTY does not support OpenSSH certs (id_*-cert.pub). Use MobaXterm or Windows OpenSSH.'
  }
  return $pick.val
}

function Pick-Subscription {
  $subs = az account list -o json | ConvertFrom-Json
  if (-not $subs) { throw 'No subscriptions found.' }
  $pick = Select-FromList -Items $subs -Title 'Select subscription' -DisplayProperty 'name'
  az account set --subscription $pick.id | Out-Null
  Write-Host "Subscription set: $($pick.name) ($($pick.id))" -ForegroundColor Green
  return $pick
}

function Pick-Vm {
  $vms = az vm list -d -o json | ConvertFrom-Json
  if (-not $vms) { throw 'No VMs visible in this subscription.' }

  $rgs = $vms | Select-Object -ExpandProperty resourceGroup -Unique | Sort-Object
  $rgChoice = if ($rgs.Count -gt 1) {
    Select-FromList -Items $rgs -Title 'Select Resource Group' -DisplayProperty $null
  } else { $rgs[0] }

  $vmsInRg = $vms | Where-Object { $_.resourceGroup -eq $rgChoice } |
    Sort-Object name |
    ForEach-Object {
      [pscustomobject]@{
        name       = $_.name
        rg         = $_.resourceGroup
        location   = $_.location
        powerState = $_.powerState
        publicIps  = $_.publicIps
        privateIps = $_.privateIps
      }
    }

  Select-FromList -Items $vmsInRg -Title "Select VM (RG: $rgChoice)" -DisplayProperty 'name'
}

function Build-SshConfig {
  param(
    [Parameter(Mandatory)][string]$RG,
    [Parameter(Mandatory)][string]$VM,
    [switch]$PreferPrivate
  )
  $args = @(
    '--file', $ConfigFile,
    '-n', $VM,
    '-g', $RG,
    '--keys-destination-folder', $KeysFolder,
    '--overwrite'
  )
  if ($PreferPrivate) { $args += '--prefer-private-ip' }

  Write-Host "Generating SSH config for $RG/$VM ..." -ForegroundColor Cyan
  az ssh config @args | Out-Null

  $Alias = Select-String -Path $ConfigFile -Pattern '^Host\s+' |
    Select-Object -First 1 |
    ForEach-Object { ($_.Line -split '\s+')[1] }

  if (-not $Alias) { throw "Could not determine host alias from $ConfigFile." }
  return $Alias
}

function Connect-OpenSsh {
  param([Parameter(Mandatory)][string]$Alias)
  Write-Host "Connecting via OpenSSH to '$Alias' ..." -ForegroundColor Green
  ssh -F $ConfigFile $Alias
}

# ===== Flow =====
try {
  Require-AzCli
  Ensure-AzLogin
  Ensure-SshExtension
  Ensure-Folders

  $det = Detect-Clients

  if ($InteractiveMenu) {
    $null = Pick-Subscription
    $vmPicked = Pick-Vm
    $ResourceGroup = $vmPicked.rg
    $VmName       = $vmPicked.name

    if ($Client -eq 'auto') {
      $Client = Pick-Client -det $det
    }
  } else {
    if (-not $ResourceGroup) { $ResourceGroup = Read-Host 'Enter Resource Group' }
    if (-not $VmName)        { $VmName        = Read-Host 'Enter VM name' }
    if ($Client -eq 'auto') {
      if     ($det.HasMoba)   { $Client = 'moba' }
      elseif ($det.HasWinSsh) { $Client = 'winssh' }
      elseif ($det.HasPutty)  { throw 'PuTTY detected, but not compatible with Entra SSH. Use OpenSSH.' }
      else                    { throw 'No SSH client found.' }
    }
  }

  # Generate SSH config and keys via az ssh config
  $alias = Build-SshConfig -RG $ResourceGroup -VM $VmName -PreferPrivate:$PreferPrivateIp

  switch ($Client) {
    'moba'   { Connect-OpenSsh -Alias $alias }
    'winssh' { Connect-OpenSsh -Alias $alias }
    default  { throw "Unexpected client: $Client" }
  }

} catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.Exception.Message -match 'PuTTY') {
    Write-Host 'Note: Entra SSH uses OpenSSH certificates (id_*-cert.pub). PuTTY/plink do not support those.' -ForegroundColor Yellow
    Write-Host 'Use MobaXterm (OpenSSH) or Windows OpenSSH (ssh.exe).' -ForegroundColor Yellow
  }
  exit 1
}
