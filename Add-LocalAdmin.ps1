<#
.SYNOPSIS
    Ajoute un utilisateur (du domaine) au groupe Administrateurs local, avec vérification
    et méthodes de repli à chaque étape.

.DESCRIPTION
    Chaque étape essaie plusieurs méthodes dans l'ordre : si l'une échoue, la suivante est tentée.
      1. Détection de l'utilisateur : explorer.exe de la session > Win32_ComputerSystem > quser > variables d'env.
      2. Nom du groupe            : traduction du SID S-1-5-32-544 > Win32_Group > "Administrateurs"
      3. SID de l'utilisateur     : contrôleur de domaine > profil en cache (registre) > Win32_UserAccount
      4. Ajout au groupe          : ADSI > Add-LocalGroupMember > net localgroup /add
      5. Vérification             : ADSI (SID) > Get-LocalGroupMember > net localgroup
    Chaque méthode d'ajout est validée par une vérification ; sinon la méthode suivante est tentée.
    Un journal est écrit dans C:\Windows\Temp (ou %TEMP% en repli).

.PARAMETER Utilisateur
    Format DOMAINE\utilisateur. Si omis : utilisateur connecté à la session courante.

.PARAMETER SansPause
    N'attend pas "Entrée" à la fin (exécution automatisée).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Add-LocalAdmin.ps1
    powershell -ExecutionPolicy Bypass -File .\Add-LocalAdmin.ps1 -Utilisateur "CONTOSO\jdupont"

.NOTES
    Codes de sortie : 0 = succès, 1 = échec, 2 = ajout effectué mais vérification impossible.
    Enregistrer ce fichier en UTF-8 avec BOM (sinon les accents s'affichent mal sous PowerShell 5.1).
#>
[CmdletBinding()]
param(
    [string]$Utilisateur,
    [switch]$SansPause
)

$ErrorActionPreference = 'Stop'
$SidAdmins = 'S-1-5-32-544'   # SID well-known de BUILTIN\Administrateurs (fixe sur tout Windows)

# ============================================================================
#  Fonctions utilitaires
# ============================================================================
function Ecrire {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'AVERT', 'ERREUR', 'ESSAI')][string]$Niveau = 'INFO')
    $couleurs = @{ INFO = 'Gray'; OK = 'Green'; AVERT = 'Yellow'; ERREUR = 'Red'; ESSAI = 'Cyan' }
    Write-Host ("[{0,-6}] {1}" -f $Niveau, $Message) -ForegroundColor $couleurs[$Niveau]
}

# Essaie chaque méthode dans l'ordre ; renvoie le premier résultat non vide (et validé si -Validation)
function Invoke-Repli {
    param(
        [string]$Etape,
        [string[]]$Noms,
        [scriptblock[]]$Methodes,
        [scriptblock]$Validation
    )
    for ($idx = 0; $idx -lt $Methodes.Count; $idx++) {
        Ecrire "$Etape - méthode $($idx + 1)/$($Methodes.Count) : $($Noms[$idx])" 'ESSAI'
        try {
            $resultat = & $Methodes[$idx]
            if ($null -eq $resultat -or "$resultat".Trim() -eq '') {
                Ecrire "  Aucun résultat, passage à la méthode suivante." 'AVERT'
                continue
            }
            if ($Validation -and -not (& $Validation $resultat)) {
                Ecrire "  Méthode exécutée mais validation négative, passage à la suivante." 'AVERT'
                continue
            }
            return $resultat
        } catch {
            Ecrire "  Échec : $($_.Exception.Message)" 'AVERT'
        }
    }
    return $null
}

# Renvoie les SID des membres d'un groupe ADSI (fonctionne aussi avec des SID orphelins)
function Get-SidMembres {
    param($Groupe)
    @($Groupe.Invoke('Members')) | ForEach-Object {
        $octets = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
        (New-Object Security.Principal.SecurityIdentifier($octets, 0)).Value
    }
}

# Renvoie 'OUI', 'NON' ou $null (vérification impossible)
function Test-Membre {
    Invoke-Repli -Etape 'Vérification' `
        -Noms @('ADSI (comparaison SID)', 'Get-LocalGroupMember', 'net localgroup') `
        -Methodes @(
            {
                $grp = [ADSI]"WinNT://$env:COMPUTERNAME/$nomGroupe,group"
                if ((Get-SidMembres $grp) -contains $sidUtilisateur) { 'OUI' } else { 'NON' }
            },
            {
                $membres = Get-LocalGroupMember -SID $SidAdmins
                if ($membres.SID.Value -contains $sidUtilisateur) { 'OUI' } else { 'NON' }
            },
            {
                $sortie = cmd /c "net localgroup `"$nomGroupe`" 2>&1"
                if ($LASTEXITCODE -ne 0) { throw "net localgroup : code $LASTEXITCODE" }
                $nomCourt = [regex]::Escape($Utilisateur.Split('\')[-1])
                if ($sortie | Where-Object { $_.Trim() -match "(^|\\)$nomCourt$" }) { 'OUI' } else { 'NON' }
            }
        )
}

# ============================================================================
#  1. Détection de l'utilisateur cible (AVANT l'élévation)
# ============================================================================
if (-not $Utilisateur) {
    $Utilisateur = Invoke-Repli -Etape "Détection de l'utilisateur" `
        -Noms @('Propriétaire de explorer.exe (session courante)', 'Win32_ComputerSystem', 'quser', "Variables d'environnement") `
        -Methodes @(
            {
                $session = (Get-Process -Id $PID).SessionId
                $proc = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$session" | Select-Object -First 1
                if ($proc) {
                    $prop = Invoke-CimMethod -InputObject $proc -MethodName GetOwner
                    if ($prop.User) { "$($prop.Domain)\$($prop.User)" }
                }
            },
            { (Get-CimInstance Win32_ComputerSystem).UserName },
            {
                $ligne = (cmd /c "quser 2>nul") | Where-Object { $_ -match '^\s*>' } | Select-Object -First 1
                if ($ligne) { ($ligne -replace '^\s*>', '').Trim().Split(' ')[0] }
            },
            { "$env:USERDOMAIN\$env:USERNAME" }
        )
}
if (-not $Utilisateur) {
    Ecrire "Impossible de déterminer l'utilisateur. Relancez avec -Utilisateur DOMAINE\nom." 'ERREUR'
    exit 1
}
Ecrire "Utilisateur cible : $Utilisateur" 'OK'

# ============================================================================
#  2. Élévation (si la console n'est pas déjà administrateur)
# ============================================================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (-not $PSCommandPath) {
        Ecrire "Droits administrateur requis. Enregistrez le script dans un fichier .ps1 ou ouvrez une console administrateur." 'ERREUR'
        exit 1
    }
    Ecrire "Droits administrateur requis : demande d'élévation (UAC)..." 'AVERT'
    $argsElev = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Utilisateur `"$Utilisateur`""
    if ($SansPause) { $argsElev += ' -SansPause' }
    $moteurs = @((Get-Process -Id $PID).Path, "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") | Select-Object -Unique
    foreach ($moteur in $moteurs) {
        try {
            Start-Process -FilePath $moteur -Verb RunAs -ArgumentList $argsElev
            exit 0
        } catch {
            Ecrire "Élévation via $moteur impossible : $($_.Exception.Message)" 'AVERT'
        }
    }
    Ecrire "Élévation refusée ou impossible. Ouvrez une console en tant qu'administrateur et relancez avec -Utilisateur `"$Utilisateur`"." 'ERREUR'
    exit 1
}

# ============================================================================
#  Journal (repli : C:\Windows\Temp > %TEMP% > sans journal)
# ============================================================================
$horodatage = Get-Date -Format 'yyyyMMdd_HHmmss'
$journalActif = $false
foreach ($dossier in @("$env:SystemRoot\Temp", $env:TEMP)) {
    try {
        Start-Transcript -Path (Join-Path $dossier "Add-LocalAdmin_$horodatage.log") | Out-Null
        $journalActif = $true
        break
    } catch { }
}
if (-not $journalActif) { Ecrire "Journal désactivé (aucun dossier accessible en écriture)." 'AVERT' }

$codeSortie = 0
try {
    # ------------------------------------------------------------------------
    #  Informations sur le poste
    # ------------------------------------------------------------------------
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain) { Ecrire "Poste : $env:COMPUTERNAME (domaine : $($cs.Domain))" }
        else { Ecrire "Le poste n'est pas membre d'un domaine (groupe de travail : $($cs.Domain))." 'AVERT' }
    } catch { Ecrire "Informations du poste indisponibles : $($_.Exception.Message)" 'AVERT' }

    # ------------------------------------------------------------------------
    #  3. Nom localisé du groupe Administrateurs
    # ------------------------------------------------------------------------
    $nomGroupe = Invoke-Repli -Etape 'Nom du groupe' `
        -Noms @('Traduction du SID', 'Win32_Group', 'Nom par défaut (français)') `
        -Methodes @(
            { (New-Object Security.Principal.SecurityIdentifier($SidAdmins)).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1] },
            { (Get-CimInstance Win32_Group -Filter "LocalAccount=True AND SID='$SidAdmins'").Name },
            { 'Administrateurs' }
        )
    Ecrire "Groupe : $nomGroupe ($SidAdmins)" 'OK'

    # ------------------------------------------------------------------------
    #  4. SID de l'utilisateur
    # ------------------------------------------------------------------------
    $sidUtilisateur = Invoke-Repli -Etape "Résolution du SID" `
        -Noms @('Contrôleur de domaine (NTAccount)', 'Profil en cache (registre ProfileList)', 'Win32_UserAccount') `
        -Methodes @(
            { (New-Object Security.Principal.NTAccount($Utilisateur)).Translate([Security.Principal.SecurityIdentifier]).Value },
            {
                $nomCourt = [regex]::Escape($Utilisateur.Split('\')[-1])
                Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
                    Where-Object {
                        $_.PSChildName -like 'S-1-5-21-*' -and
                        (Get-ItemProperty $_.PSPath).ProfileImagePath -match "\\$nomCourt(\.[^\\]+)?$"
                    } | Select-Object -First 1 -ExpandProperty PSChildName
            },
            {
                $nomCourt = $Utilisateur.Split('\')[-1]
                (Get-CimInstance Win32_UserAccount -Filter "Name='$nomCourt'" | Select-Object -First 1).SID
            }
        )
    if (-not $sidUtilisateur) {
        throw "Impossible de résoudre le SID de '$Utilisateur' (nom incorrect, ou contrôleur de domaine injoignable et aucun profil en cache)."
    }
    Ecrire "SID : $sidUtilisateur" 'OK'

    # ------------------------------------------------------------------------
    #  5. Ajout (si nécessaire), chaque méthode validée par une vérification
    # ------------------------------------------------------------------------
    $etat = Test-Membre
    if ($etat -eq 'OUI') {
        Ecrire "$Utilisateur est déjà membre de $nomGroupe." 'OK'
    } else {
        $ajout = Invoke-Repli -Etape 'Ajout au groupe' `
            -Noms @('ADSI (WinNT://SID)', 'Add-LocalGroupMember', 'net localgroup /add') `
            -Validation { param($x) (Test-Membre) -ne 'NON' } `
            -Methodes @(
                { ([ADSI]"WinNT://$env:COMPUTERNAME/$nomGroupe,group").Add("WinNT://$sidUtilisateur"); $true },
                { Add-LocalGroupMember -SID $SidAdmins -Member $sidUtilisateur; $true },
                {
                    $sortie = cmd /c "net localgroup `"$nomGroupe`" `"$Utilisateur`" /add 2>&1"
                    if ($LASTEXITCODE -ne 0) { throw ($sortie -join ' ') }
                    $true
                }
            )
        if (-not $ajout) { throw "Toutes les méthodes d'ajout ont échoué." }

        # --------------------------------------------------------------------
        #  6. Vérification finale
        # --------------------------------------------------------------------
        switch (Test-Membre) {
            'OUI'   { Ecrire "VÉRIFICATION OK : $Utilisateur est membre de $nomGroupe." 'OK' }
            'NON'   { throw "Vérification finale négative." }
            default { Ecrire "Ajout effectué, mais aucune méthode de vérification n'a abouti." 'AVERT'; $codeSortie = 2 }
        }
    }

    # ------------------------------------------------------------------------
    #  7. Liste des membres actuels (ADSI > net localgroup)
    # ------------------------------------------------------------------------
    Write-Host "`nMembres actuels de ${nomGroupe} :"
    try {
        @(([ADSI]"WinNT://$env:COMPUTERNAME/$nomGroupe,group").Invoke('Members')) | ForEach-Object {
            '  - ' + ($_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null) -replace '^WinNT://', '')
        }
    } catch {
        cmd /c "net localgroup `"$nomGroupe`""
    }

    Write-Host ''
    Ecrire "Déconnectez-vous puis reconnectez-vous avec $Utilisateur pour appliquer les droits." 'AVERT'
    Ecrire "Contrôle après reconnexion : whoami /groups | findstr S-1-5-32-544" 'INFO'
    Ecrire "Si la modification disparaît après un gpupdate, une GPO (Groupes restreints) écrase le groupe : vérifiez avec gpresult /h C:\gpo.html" 'INFO'
}
catch {
    Ecrire $_.Exception.Message 'ERREUR'
    $codeSortie = 1
}
finally {
    if ($journalActif) { try { Stop-Transcript | Out-Null } catch { } }
    if (-not $SansPause) { Read-Host "`nAppuyez sur Entrée pour fermer" | Out-Null }
}
exit $codeSortie