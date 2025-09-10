<#
.SYNOPSIS
  Entra (Azure AD) SSH zu Azure-Linux-VMs mit Client-Auswahl:
  - MobaXterm (OpenSSH intern) oder
  - Windows OpenSSH (ssh.exe).
  PuTTY wird erkannt, aber NICHT genutzt (fehlende OpenSSH-Zertifikat-Unterstützung).

.PARAMETER InteractiveMenu
  Menü zur Auswahl von Subscription + VM + Client.

.PARAMETER ResourceGroup / VmName
  Direkter Verbindungsmodus (ohne Menü).

.PARAMETER Client
  'moba' | 'winssh'
  Vorbelegung des SSH-Clients. Fallback automatisch, wenn nicht verfügbar.

.PARAMETER PreferPrivateIp
  Bevorzugt private IP (VPN/ER), az ssh config --prefer-private-ip.
#>

param(
  [string]$ResourceGroup,
  [string]$VmName,
  [ValidateSet('moba','winssh','auto')]
  [string]$Client = 'auto',
  [switch]$InteractiveMenu,
  [switch]$PreferPrivateIp,
  [string]$KeysSubFolder = "az_keys"
)

# ========= Pfade & Defaults =========
$UserName   = $env:USERNAME
$MobaHome   = "C:\Users\$UserName\Documents\MobaXterm\home"
$SshFolder  = Join-Path $MobaHome ".ssh"
$ConfigFile = Join-Path $SshFolder "azure_ssh_config"
$KeysFolder = Join-Path $SshFolder $KeysSubFolder

# ========= Helpers =========
function Require-AzCli {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) nicht gefunden. Installiere: https://aka.ms/azure-cli"
  }
}

function Ensure-AzLogin {
  $acct = az account show --query user.name -o tsv 2>$null
  if (-not $acct) {
    Write-Host "Kein aktiver Azure-Login – starte 'az login'..." -ForegroundColor Yellow
    az login | Out-Null
    $acct = az account show --query user.name -o tsv 2>$null
    if (-not $acct) { throw "Azure-Login fehlgeschlagen." }
  }
  Write-Host "Angemeldet als: $acct"
}

function Ensure-SshExtension {
  az extension show --name ssh -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Installiere Azure CLI SSH-Extension..." -ForegroundColor Yellow
    az extension add --name ssh | Out-Null
  }
}

function Ensure-Folders {
  foreach ($p in @($SshFolder, $KeysFolder)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
  }
}

function Detect-Clients {
  # MobaXterm eingebauter OpenSSH ist schlicht 'ssh' im Moba-Terminal, aber wir nutzen primär Windows-ssh.exe
  # Verfügbarkeit prüfen:
  $hasWinSsh = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
  # Prüfe (optionales) MobaXterm-Verzeichnis:
  $mobaRoot1 = "C:\Program Files (x86)\Mobatek\MobaXterm"
  $mobaRoot2 = "C:\Program Files\Mobatek\MobaXterm"
  $hasMoba   = (Test-Path $mobaRoot1) -or (Test-Path $mobaRoot2) -or (Test-Path $MobaHome)
  # PuTTY erkennen (nur Hinweis):
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
    [string]$DisplayProperty = "name"
  )
  Write-Host ""
  Write-Host "== $Title ==" -ForegroundColor Cyan
  for ($i=0; $i -lt $Items.Count; $i++) {
    $label = if ($DisplayProperty) { $Items[$i].$DisplayProperty } else { $Items[$i] }
    Write-Host ("[{0}] {1}" -f ($i+1), $label)
  }
  do {
    $sel = Read-Host "Auswahl (1-$($Items.Count))"
    [int]$idx = $sel - 1
  } until ($idx -ge 0 -and $idx -lt $Items.Count)
  return $Items[$idx]
}

function Pick-Client([object]$det) {
  $choices = @()
  if ($det.HasMoba)   { $choices += [pscustomobject]@{ name="MobaXterm (OpenSSH)"; val="moba" } }
  if ($det.HasWinSsh) { $choices += [pscustomobject]@{ name="Windows OpenSSH (ssh.exe)"; val="winssh" } }
  if ($det.HasPutty)  { $choices += [pscustomobject]@{ name="PuTTY (NICHT kompatibel mit Entra-SSH)"; val="putty" } }

  if ($choices.Count -eq 0) {
    throw "Kein unterstützter SSH-Client gefunden. Installiere MobaXterm oder aktiviere Windows OpenSSH."
  }

  $pick = Select-FromList -Items $choices -Title "SSH-Client wählen" -DisplayProperty "name"
  if ($pick.val -eq 'putty') {
    throw "PuTTY unterstützt OpenSSH-Zertifikate nicht. Bitte MobaXterm oder Windows OpenSSH verwenden."
  }
  return $pick.val
}

function Pick-Subscription {
  $subs = az account list -o json | ConvertFrom-Json
  if (-not $subs) { throw "Keine Subscriptions gefunden." }
  $pick = Select-FromList -Items $subs -Title "Subscription wählen" -DisplayProperty "name"
  az account set --subscription $pick.id | Out-Null
  Write-Host "Subscription gesetzt: $($pick.name) ($($pick.id))" -ForegroundColor Green
  return $pick
}

function Pick-Vm {
  $vms = az vm list -d -o json | ConvertFrom-Json
  if (-not $vms) { throw "Keine VMs in dieser Subscription sichtbar." }

  $rgs = $vms | Select-Object -ExpandProperty resourceGroup -Unique | Sort-Object
  $rgChoice = if ($rgs.Count -gt 1) {
    Select-FromList -Items $rgs -Title "Resource Group wählen" -DisplayProperty $null
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

  Select-FromList -Items $vmsInRg -Title "VM wählen (RG: $rgChoice)" -DisplayProperty "name"
}

function Build-SshConfig {
  param(
    [Parameter(Mandatory)][string]$RG,
    [Parameter(Mandatory)][string]$VM,
    [switch]$PreferPrivate
  )
  $args = @(
    "--file", $ConfigFile,
    "-n", $VM,
    "-g", $RG,
    "--keys-destination-folder", $KeysFolder,
    "--overwrite"
  )
  if ($PreferPrivate) { $args += "--prefer-private-ip" }

  Write-Host "Erzeuge SSH-Config für $RG/$VM ..." -ForegroundColor Cyan
  az ssh config @args | Out-Null

  $Alias = Select-String -Path $ConfigFile -Pattern "^Host\s+" |
    Select-Object -First 1 |
    ForEach-Object { ($_.Line -split "\s+")[1] }

  if (-not $Alias) { throw "Konnte Host-Alias aus $ConfigFile nicht ermitteln." }
  return $Alias
}

function Connect-OpenSsh {
  param([Parameter(Mandatory)] [string]$Alias)
  Write-Host "Verbinde via OpenSSH mit '$Alias' ..." -ForegroundColor Green
  ssh -F $ConfigFile $Alias
}

# ========== Ablauf ==========
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
    if (-not $ResourceGroup) { $ResourceGroup = Read-Host "Bitte ResourceGroup eingeben" }
    if (-not $VmName)        { $VmName        = Read-Host "Bitte VM-Namen eingeben" }
    if ($Client -eq 'auto') {
      # automatische Priorität: Moba (wenn vorhanden) -> Windows OpenSSH
      if ($det.HasMoba) { $Client = 'moba' }
      elseif ($det.HasWinSsh) { $Client = 'winssh' }
      elseif ($det.HasPutty) { throw "PuTTY erkannt, aber nicht kompatibel mit Entra-SSH. Bitte OpenSSH verwenden." }
      else { throw "Kein SSH-Client gefunden." }
    }
  }

  # SSH-Config + Keys (werden von az ssh config generiert)
  $alias = Build-SshConfig -RG $ResourceGroup -VM $VmName -PreferPrivate:$PreferPrivateIp

  switch ($Client) {
    'moba'   { Connect-OpenSsh -Alias $alias } # im Moba-Terminal genauso nutzbar
    'winssh' { Connect-OpenSsh -Alias $alias }
    default  { throw "Unerwarteter Client: $Client" }
  }

} catch {
  Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.Exception.Message -match "PuTTY") {
    Write-Host "Hinweis: Entra-SSH nutzt OpenSSH-Zertifikate (id_*-cert.pub). PuTTY/plink unterstützen das nicht." -ForegroundColor Yellow
    Write-Host "Verwende bitte MobaXterm (OpenSSH) oder Windows-OpenSSH (ssh.exe)." -ForegroundColor Yellow
  }
  exit 1
}