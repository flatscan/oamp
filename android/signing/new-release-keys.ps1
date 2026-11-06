# Makes OAmp's private Android signing keys and, optionally, stores them as
# GitHub Actions secrets. Run once, on a trusted PC, from the repo root:
#
#   powershell -ExecutionPolicy Bypass -File android\signing\new-release-keys.ps1
#
# It writes two keystores to a folder outside the repo:
#
#   oamp-release.p12  signs GitHub release APKs, and is given to Google Play
#                     as the app signing key. Losing it means users must
#                     reinstall to get updates. Keep it, and its password,
#                     in a password manager AND an offline backup.
#   oamp-upload.p12   signs the bundles uploaded to Google Play. Google can
#                     reset it if it is lost.
#
# Passwords are random and written next to the keystores in passwords.txt.
# Move that into your password manager, then delete it.
#
# With -SetSecrets, the GitHub CLI (gh, signed in) stores the eight secrets
# that .github/workflows/release.yml reads. See docs/signing.md.

param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'oamp-signing'),
    [string]$Repo = 'flatscan/oamp',
    [switch]$SetSecrets
)

$ErrorActionPreference = 'Stop'

function Find-Keytool {
    $candidates = @(
        "$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe",
        "$env:ProgramFiles\Android\Android Studio\jre\bin\keytool.exe"
    )
    if ($env:JAVA_HOME) { $candidates = @("$env:JAVA_HOME\bin\keytool.exe") + $candidates }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'keytool not found. Install Android Studio or set JAVA_HOME.'
}

function New-Password {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    # URL-safe base64, no padding: 32 characters that keytool accepts.
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$keytool = Find-Keytool
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$keys = @(
    @{ Name = 'release'; Alias = 'oamp-release'; DName = 'CN=OAmp, O=OAmp contributors' },
    @{ Name = 'upload';  Alias = 'oamp-upload';  DName = 'CN=OAmp upload, O=OAmp contributors' }
)

$passwordLines = @()
foreach ($k in $keys) {
    $file = Join-Path $OutDir "oamp-$($k.Name).p12"
    if (Test-Path $file) {
        throw "$file already exists. Never overwrite a signing key; move it away first if you really mean to."
    }
    $password = New-Password
    # PKCS12 keystores use one password for the store and the key.
    & $keytool -genkeypair -v `
        -storetype PKCS12 -keystore $file `
        -alias $k.Alias -keyalg RSA -keysize 4096 -validity 11000 `
        -dname $k.DName -storepass $password -keypass $password
    if ($LASTEXITCODE -ne 0) { throw "keytool failed for $($k.Name)" }
    $k.File = $file
    $k.Password = $password
    $passwordLines += "$($k.Alias)  $file  $password"
}

$pwFile = Join-Path $OutDir 'passwords.txt'
$passwordLines | Set-Content -Encoding ascii $pwFile
Write-Host ''
Write-Host "Keystores written to $OutDir"
Write-Host "Passwords in ${pwFile}: move them to your password manager, then delete that file."

if ($SetSecrets) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh (GitHub CLI) not found.' }
    foreach ($k in $keys) {
        $prefix = "OAMP_$($k.Name.ToUpper())"
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($k.File))
        $b64 | gh secret set "${prefix}_KEYSTORE_BASE64" -R $Repo
        $k.Password | gh secret set "${prefix}_KEYSTORE_PASSWORD" -R $Repo
        $k.Alias | gh secret set "${prefix}_KEY_ALIAS" -R $Repo
        $k.Password | gh secret set "${prefix}_KEY_PASSWORD" -R $Repo
    }
    Write-Host "Secrets stored in $Repo."
}
