# Connect-AzVm.ps1

Dieses PowerShell-Skript ermöglicht den **SSH-Login auf Azure Linux VMs mit Microsoft Entra ID (Azure AD)**.  
Es unterstützt **Windows-OpenSSH** und **MobaXterm** (eingebauter OpenSSH).  
PuTTY wird erkannt, aber **nicht empfohlen** für Entra-SSH (siehe Hinweis unten).

---

## Voraussetzungen

- **Azure CLI** ≥ 2.22.1  
  [Installationsanleitung](https://learn.microsoft.com/de-de/cli/azure/install-azure-cli)  
- **Azure CLI SSH-Extension**  
  ```powershell
  az extension add --name ssh
  ```
- **SSH-Client**
  - Windows 10/11: OpenSSH ist meist schon installiert (`ssh.exe`)
  - [MobaXterm](https://mobaxterm.mobatek.net/download.html) (empfohlen)
  - Optional: PuTTY ≥ 0.76 (unterstützt zwar OpenSSH-Zertifikate, ist aber für Entra-SSH unpraktisch)

---

## Funktionsweise

- Das Skript prüft, ob ein Azure-Login besteht. Falls nicht → `az login`.  
- Optional: Auswahl einer Subscription und VM über ein Menü (`-InteractiveMenu`).  
- Es erzeugt über `az ssh config` eine **SSH-Config** und **Kurzzeit-Schlüssel/Zertifikate** im MobaXterm-Home:  

  ```
  C:\Users\<USER>\Documents\MobaXterm\home\.ssh\
  ├── azure_ssh_config
  └── az_keys\id_XXXXXXXX
  ```

- Verbindung erfolgt dann automatisch mit dem gewählten Client (Moba oder Windows-ssh).

---

## Nutzung

### Menü-Variante (Subscription/VM auswählen)
```powershell
.\Connect-AzVm.ps1 -InteractiveMenu
```

### Direkt verbinden (Parameter-Modus)
```powershell
.\Connect-AzVm.ps1 -ResourceGroup MyRG -VmName my-vm01
```

### Client explizit wählen
```powershell
.\Connect-AzVm.ps1 -InteractiveMenu -Client moba
.\Connect-AzVm.ps1 -ResourceGroup MyRG -VmName my-vm01 -Client winssh
```

### Private IP bevorzugen (z. B. via VPN/ExpressRoute)
```powershell
.\Connect-AzVm.ps1 -InteractiveMenu -PreferPrivateIp
```

---

## Rollenvergabe in Azure

Damit Entra-SSH funktioniert, muss dem Benutzer/der Gruppe eine passende **Azure RBAC-Rolle** zugewiesen werden:

- **Virtual Machine User Login** → normaler User-Login ohne Root-Rechte  
- **Virtual Machine Administrator Login** → Login mit `sudo`-Rechten

Beispiel (Rolle auf Resource Group vergeben):

```powershell
az role assignment create   --role "Virtual Machine Administrator Login"   --assignee <UPN-oder-ObjektID>   --scope "/subscriptions/<sub-id>/resourceGroups/<rg>"
```

---

## Hinweise zu PuTTY

- **Ab Version 0.76** unterstützt PuTTY OpenSSH-Zertifikate.  
- Für **Azure Entra-SSH** ist PuTTY jedoch **nicht praxistauglich**, da:
  - Zertifikate nur **sehr kurzlebig** sind (Minuten),
  - sie bei jedem `az ssh config` neu erzeugt werden,
  - PuTTY diese **nicht automatisch lädt**.  
- Empfehlung: **OpenSSH** (Windows oder MobaXterm) nutzen.

---

## Bekannte Probleme / Troubleshooting

- **Fehler: "Azure role not assigned"**  
  → Prüfen, ob die Rolle `Virtual Machine User Login` oder `Virtual Machine Administrator Login` auf VM/RG/Sub vergeben wurde.

- **SSH schlägt sofort fehl**  
  → Prüfen, ob die VM die Extension `AADSSHLoginForLinux` hat und ob Port 22 erreichbar ist.

- **Mehrere Subscriptions**  
  → `-InteractiveMenu` nutzen, um die Subscription auszuwählen.

---

## Beispielablauf

1. PowerShell öffnen  
2. Script starten:  
   ```powershell
   .\Connect-AzVm.ps1 -InteractiveMenu
   ```
3. Subscription auswählen  
4. VM auswählen  
5. SSH-Client auswählen (MobaXterm oder Windows-ssh)  
6. Verbindung wird hergestellt 🎉

---
