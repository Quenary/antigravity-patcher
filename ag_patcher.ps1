#Requires -Version 5.1
<#
  ag_patcher.ps1 — байтовый + JS-патч Antigravity на Windows.
  Сигнатуры держать в синхроне с ag_patcher.sh: ineligible → inexigible.
  Зависимостей нет: только Windows PowerShell 5.1.

  Не трогает Antigravity.exe (строки Chromium) и app.asar.
  Сеть, DNS, hosts и прокси не меняет.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 patch
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 unpatch
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 status
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 watch
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 install-watch
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1 uninstall-watch

  Лишние аргументы — только эти файлы, без поиска по системе.
  AG_YES=1 — не спрашивать подтверждение. AG_WATCH_ONCE=1 — один проход сторожа.
#>
param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Only
)

$ErrorActionPreference = "Continue"
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}

$script:From = "ineligible"
$script:To = "inexigible"
$script:Marker = "// UNLOCKED"
$script:Fence = "/*[AG_EXT_PATCHED]*/"
$script:TaskName = "AntigravityPatcher"
$script:Self = $MyInvocation.MyCommand.Path

# Та же регулярка, что PERL_JS в ag_patcher.sh. Группы 1..4 и 8..11.
$script:IdeRe = @'
async\s+([A-Za-z_$0-9]+)\(([A-Za-z_$0-9]+)\)\s*\{\s*if\(this\.([A-Za-z_$0-9]+)\.send\(\{type:[A-Za-z_$0-9]+\.isGcpTos\?"GCP_SIGN_IN":"SIGN_IN"\}\),this\.([A-Za-z_$0-9]+)\.resetIsTierGCPTos\(\),this\.[A-Za-z_$0-9]+\.isGoogleInternal\)\{try\{await this\.([A-Za-z_$0-9]+)\.loadCodeAssist\([A-Za-z_$0-9]+\);const\{settings:([A-Za-z_$0-9]+),userTier:([A-Za-z_$0-9]+)\}=await this\.refreshUserStatus\([A-Za-z_$0-9]+\),([A-Za-z_$0-9]+)=([A-Za-z_$0-9]+)\([A-Za-z_$0-9]+\);this\.([A-Za-z_$0-9]+)\.pushUpdate\([A-Za-z_$0-9]+\),this\.[A-Za-z_$0-9]+\.send\(\{type:"AUTH_SUCCESS",tokenInfo:[A-Za-z_$0-9]+\}\),this\.([A-Za-z_$0-9]+)\.fire\(\{settings:[A-Za-z_$0-9]+,userTier:[A-Za-z_$0-9]+\}\)\}catch\(([A-Za-z_$0-9]+)\)\{.*?(?:return\}|return;\s*\})
'@
$script:ExtRe = @'
const t=await ([A-Za-z_$][A-Za-z_$0-9.]*)\.UserStatus\.getUserStatus\(\);if\(!t\)return\[\];const n=\(0,([A-Za-z_$][A-Za-z_$0-9.]*)\)\(t,([A-Za-z_$][A-Za-z_$0-9.]*)\),\{email:([A-Za-z_$][A-Za-z_$0-9]*),name:([A-Za-z_$][A-Za-z_$0-9]*)\}=n;return""===([A-Za-z_$0-9]*)\?\[\]:
'@

if (-not ("AgPatch.Bytes" -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
namespace AgPatch {
  public static class Bytes {
    public static int Count(byte[] data, byte[] needle) {
      int n = 0;
      for (int i = 0; i + needle.Length <= data.Length; ) {
        if (At(data, i, needle)) { n++; i += needle.Length; }
        else i++;
      }
      return n;
    }
    public static int Replace(byte[] data, byte[] from, byte[] to) {
      int n = 0;
      for (int i = 0; i + from.Length <= data.Length; ) {
        if (At(data, i, from)) {
          Buffer.BlockCopy(to, 0, data, i, to.Length);
          n++;
          i += from.Length;
        } else i++;
      }
      return n;
    }
    static bool At(byte[] data, int i, byte[] needle) {
      for (int j = 0; j < needle.Length; j++) if (data[i + j] != needle[j]) return false;
      return true;
    }
  }
}
'@
}

function Say([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}
function Ok([string]$Text)   { Say "[OK] $Text" Green }
function Warn([string]$Text) { Say "[!] $Text" Yellow }
function Err([string]$Text)  { Say "[X] $Text" Red }
function Info([string]$Text) { Say "[i] $Text" Cyan }
function Dim([string]$Text)  { Say $Text DarkGray }

function Home-Of {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $env:HOME
}
function State-Dir {
    $root = $env:LOCALAPPDATA
    if (-not $root) { $root = Join-Path (Home-Of) "AppData\Local" }
    $d = Join-Path $root "ag-patcher"
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    return $d
}
function Write-WatchLog([string]$Text) {
    $log = Join-Path (State-Dir) "watch.log"
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    if ($env:AG_WATCH -ne "1") { Info $Text }
}

function Test-SkippedName([string]$Name) {
    return ($Name -like "*.agtmp*" -or $Name -like "*.ag_backup" -or $Name -like "*.old.*" -or $Name -like "*.tmp.*")
}
function Test-UpdaterPath([string]$Path) {
    return ($Path -match '(?i)antigravity-updater')
}
function Test-Pe([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $b0 = $fs.ReadByte()
            $b1 = $fs.ReadByte()
            return ($b0 -eq 77 -and $b1 -eq 90)
        } finally { $fs.Close() }
    } catch { return $false }
}
function Test-FileLocked([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close()
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch { return $false }
}
function Test-Writable([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    $probe = Join-Path (Split-Path -Parent $Path) (".agwrite." + [guid]::NewGuid().ToString("N"))
    try {
        [IO.File]::WriteAllText($probe, "x")
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}
function Test-InstallerBusy([string]$Path) {
    $dir = Split-Path -Parent $Path
    if (Test-Path -LiteralPath (Join-Path $dir ".agy-install.lock")) { return $true }
    $tmp = @(Get-ChildItem -LiteralPath $dir -Filter "agy.tmp.*" -ErrorAction SilentlyContinue)
    return ($tmp.Count -gt 0)
}

function Read-Bytes([string]$Path) {
    # Запятая не даёт PowerShell развернуть byte[] в отдельные байты.
    return , [IO.File]::ReadAllBytes($Path)
}
function Write-AtomicBytes([string]$Path, [byte[]]$Data) {
    $item = Get-Item -LiteralPath $Path -Force
    # Compressed, Encrypted, ReparsePoint и SparseFile нельзя записать через Attributes:
    # SetFileAttributes кидает ошибку и срывает патч.
    $keep = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::System
    $saved = $item.Attributes -band $keep
    $wasReadOnly = [bool]($saved -band [IO.FileAttributes]::ReadOnly)
    if ($wasReadOnly) { $item.IsReadOnly = $false }
    $tmp = "$Path.agtmp.$PID"
    try {
        [IO.File]::WriteAllBytes($tmp, $Data)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if ($wasReadOnly) {
            try { (Get-Item -LiteralPath $Path -Force).IsReadOnly = $true } catch {}
        }
        throw
    }
    if ([int]$saved -ne 0) {
        try { (Get-Item -LiteralPath $Path -Force).Attributes = $saved } catch {}
    }
}
function Ascii([string]$Text) { return , [Text.Encoding]::ASCII.GetBytes($Text) }

function Get-BinState([string]$Path) {
    try { $data = Read-Bytes $Path } catch { return "unreadable 0 0" }
    $a = [AgPatch.Bytes]::Count($data, (Ascii $script:From))
    $b = [AgPatch.Bytes]::Count($data, (Ascii $script:To))
    if ($b -gt 0 -and $a -eq 0) { return "patched $a $b" }
    if ($a -gt 0) { return "unpatched $a $b" }
    return "missing 0 0"
}

function Read-Text([string]$Path) {
    return [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
}
function Write-AtomicText([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding $false
    Write-AtomicBytes $Path $enc.GetBytes($Text)
}
function Test-JsMarker([string]$Text) {
    $t = $Text -replace '\s+\z', ''
    if (-not $t) { return $false }
    $lines = $t -split "`n", -1
    $last = $lines[-1] -replace '^\s+', ''
    return $last.StartsWith($script:Marker)
}
function Test-JsExt([string]$Path) {
    return $Path.ToLower().EndsWith("\extension.js") -or $Path.ToLower().EndsWith("/extension.js")
}
function Get-JsState([string]$Path) {
    try { $c = Read-Text $Path } catch { return "unreadable" }
    if (Test-JsExt $Path) {
        if ($c.Contains($script:Fence)) { return "patched" }
        if ([regex]::IsMatch($c, $script:ExtRe)) { return "unpatched" }
        return "missing"
    }
    if ($c.Contains("/*[AG_PATCHED]*/") -or $c.Contains("[AG_PROXY_HOOK]")) { return "stacked" }
    if (Test-JsMarker $c) { return "patched" }
    if ([regex]::IsMatch($c, $script:IdeRe, [Text.RegularExpressions.RegexOptions]::Singleline)) { return "unpatched" }
    return "missing"
}
function Get-Kind([string]$Path) {
    if ($Path -like "*.js") { return (Get-JsState $Path) }
    return ((Get-BinState $Path) -split ' ')[0]
}

function Backup-Once([string]$Path) {
    $bak = "$Path.ag_backup"
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $Path -Destination $bak -Force
    }
}
function Build-IdeBody($Match) {
    $g = $Match.Groups
    $fname = $g[1].Value
    $varT = $g[2].Value
    $send = $g[3].Value
    $y = $g[4].Value
    $varI = $g[8].Value
    $fn = $g[9].Value
    $f = $g[10].Value
    $h = $g[11].Value
    return @"
async $fname($varT){
    this.$send.send({type:$varT.isGcpTos?"GCP_SIGN_IN":"SIGN_IN"});
    this.$y.resetIsTierGCPTos();
    try {
        try { await this.$y.loadCodeAssist($varT); } catch(`$_) {}
        try { await this.$y.onboardUser("standard-tier", $varT); } catch(`$_) {
            try { await this.$y.onboardUser("free-tier", $varT); } catch(__) {}
        }
        let __res = { settings: {}, userTier: { id: "pro", description: "Pro" } };
        try { __res = await this.refreshUserStatus($varT); } catch(`$_) {}
        const $varI = $fn($varT);
        try { this.$f.pushUpdate($varI); } catch(`$_) {}
        this.$send.send({type:"AUTH_SUCCESS",tokenInfo:$varT});
        this.$h.fire({settings:__res.settings, userTier:__res.userTier});
    } catch(e) {}
    return;

"@
}
function Invoke-JsPatch([string]$Path) {
    $st = Get-JsState $Path
    if ($st -eq "patched") { return "already" }
    if ($st -ne "unpatched") { return $st }
    $c = Read-Text $Path
    $opts = [Text.RegularExpressions.RegexOptions]::Singleline
    if (Test-JsExt $Path) {
        $m = [regex]::Match($c, $script:ExtRe)
        if (-not $m.Success) { return "missing" }
        $ns = $m.Groups[1].Value
        $p2 = $m.Groups[2].Value
        $dz = $m.Groups[3].Value
        $email = $m.Groups[4].Value
        $name = $m.Groups[5].Value
        $repl = "const t=await $ns.UserStatus.getUserStatus();let $email=`"`",$name=`"`";try{if(t){const n=(0,$p2)(t,$dz);$email=n.email||`"`";$name=n.name||`"`";}}catch(`$_){}if($email===`"`"){$email=`"antigravity-user`";$name=`"User`";}return false?[]:"
        $new = $c.Remove($m.Index, $m.Length).Insert($m.Index, $repl)
        if ($new -eq $c) { return "missing" }
        $text = $script:Fence + "`n" + $new + "`n" + $script:Marker + "`n"
    } else {
        $m = [regex]::Match($c, $script:IdeRe, $opts)
        if (-not $m.Success) { return "missing" }
        $body = Build-IdeBody $m
        $new = $c.Remove($m.Index, $m.Length).Insert($m.Index, $body)
        if (-not $new.EndsWith("`n")) { $new += "`n" }
        $text = $new + $script:Marker + "`n"
    }
    Backup-Once $Path
    Write-AtomicText $Path $text
    return "ok"
}
function Invoke-JsUnpatch([string]$Path) {
    $bak = "$Path.ag_backup"
    if (Test-Path -LiteralPath $bak) {
        $text = Read-Text $bak
        Write-AtomicText $Path $text
        Remove-Item -LiteralPath $bak -Force
        return "ok"
    }
    $c = Read-Text $Path
    $changed = $false
    if ($c.StartsWith($script:Fence)) {
        $c = $c.Substring($script:Fence.Length) -replace '^\n', ''
        $changed = $true
    }
    if (Test-JsMarker $c) {
        $c = $c -replace '\s+\z', ''
        $nl = $c.LastIndexOf("`n")
        if ($nl -ge 0) { $c = $c.Substring(0, $nl) + "`n" } else { $c = "" }
        $changed = $true
    }
    if ($changed) {
        Write-AtomicText $Path $c
        return "marker-only"
    }
    return "already"
}
function Invoke-BinApply([string]$Path, [string]$Mode) {
    $data = Read-Bytes $Path
    if ($Mode -eq "patch") { $src = $script:From; $dst = $script:To }
    else { $src = $script:To; $dst = $script:From }
    $n = [AgPatch.Bytes]::Replace($data, (Ascii $src), (Ascii $dst))
    if ($n -gt 0) { Write-AtomicBytes $Path $data }
    return $n
}

$script:Seen = @{}
$script:Targets = @()
function Reset-Targets {
    $script:Seen = @{}
    $script:Targets = @()
}
function Add-Target([string]$Path, [string]$Kind) {
    if (-not $Path) { return }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $name = [IO.Path]::GetFileName($full)
    if ($name -eq "Antigravity.exe") { return }
    if (Test-SkippedName $name) { return }
    if (Test-UpdaterPath $full) { return }
    $key = $full.ToLower()
    if ($script:Seen.ContainsKey($key)) { return }
    if ($Kind -eq "bin" -and -not (Test-Pe $full)) { return }
    $script:Seen[$key] = $true
    $script:Targets += [pscustomobject]@{ Path = $full; Kind = $Kind }
}
function Add-Binary([string]$Path) { Add-Target $Path "bin" }
function Add-JsFile([string]$Path) { Add-Target $Path "js" }

function Add-BinDir([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like "language_server*" -and -not (Test-SkippedName $_.Name)) {
            Add-Binary $_.FullName
        }
    }
}
function Add-InstallRoot([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $local = ""
    if ($env:LOCALAPPDATA) { $local = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') }
    # Каталог agy сам по себе не делает родителем установку. Корень — там, где лежит файл.
    if ($local -and $full.Equals($local, [StringComparison]::OrdinalIgnoreCase)) { return }
    foreach ($rel in @(
        "agy.exe", "bin\agy.exe",
        "resources\bin\language_server.exe",
        "Contents\Resources\bin\language_server.exe",
        "Contents\resources\bin\language_server.exe"
    )) {
        Add-Binary (Join-Path $full $rel)
    }
    foreach ($rel in @(
        "resources\bin",
        "resources\app\extensions\antigravity\bin",
        "Contents\Resources\bin",
        "Contents\Resources\app\extensions\antigravity\bin",
        "Contents\resources\bin",
        "Contents\resources\app\extensions\antigravity\bin"
    )) {
        Add-BinDir (Join-Path $full $rel)
    }
    foreach ($rel in @(
        "resources\app\out\main.js",
        "resources\app\extensions\antigravity\dist\extension.js",
        "Contents\Resources\app\out\main.js",
        "Contents\Resources\app\extensions\antigravity\dist\extension.js",
        "Contents\resources\app\out\main.js",
        "Contents\resources\app\extensions\antigravity\dist\extension.js"
    )) {
        Add-JsFile (Join-Path $full $rel)
    }
}
function Add-AntigravityChildren([string]$Parent) {
    if (-not (Test-Path -LiteralPath $Parent)) { return }
    Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '(?i)antigravity' -and $_.Name -notmatch '(?i)updater') {
            Add-InstallRoot $_.FullName
        }
    }
}
function Add-UninstallKeys {
    $keys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $subs = @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)
        foreach ($sub in $subs) {
            try { $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop } catch { continue }
            $name = [string]$p.DisplayName
            $loc = [string]$p.InstallLocation
            $hit = ($name -match '(?i)antigravity' -or $name -match '(?i)agy' -or $loc -match '(?i)Antigravity')
            if ($hit -and $loc) { Add-InstallRoot $loc.Trim().Trim('"') }
        }
    }
}
function Add-PathAgy {
    $chunks = @()
    if ($env:Path) { $chunks += $env:Path -split ';' }
    foreach ($scope in @("User", "Machine")) {
        $p = [Environment]::GetEnvironmentVariable("Path", $scope)
        if ($p) { $chunks += $p -split ';' }
    }
    foreach ($dir in $chunks) {
        if (-not $dir) { continue }
        Add-Binary (Join-Path $dir.Trim() "agy.exe")
    }
    $cmd = Get-Command agy.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { Add-Binary $cmd.Source }
}
function Add-ExtensionDirs([string]$EditorHome) {
    $names = @(
        ".vscode", ".vscode-insiders", ".vscode-oss", ".vscode-server",
        ".cursor", ".cursor-server", ".windsurf", ".trae", ".vscodium",
        ".positron", ".antigravity", ".antigravity-ide"
    )
    foreach ($name in $names) {
        $d = Join-Path $EditorHome "$name\extensions"
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -notmatch '(?i)antigravity') { return }
            Get-ChildItem -LiteralPath $_.FullName -Recurse -Depth 4 -File -ErrorAction SilentlyContinue | ForEach-Object {
                if (Test-SkippedName $_.Name) { return }
                if ($_.Name -like "language_server*" -or $_.Name -eq "agy.exe") { Add-Binary $_.FullName }
            }
        }
    }
}
function Find-Targets {
    Reset-Targets
    if ($Only -and $Only.Count -gt 0) {
        foreach ($p in $Only) {
            if (-not $p) { continue }
            if ($p -like "*.js") { Add-JsFile $p } else { Add-Binary $p }
        }
        return
    }
    $userHome = Home-Of
    $local = $env:LOCALAPPDATA
    $pf = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    if ($env:AG_ROOT) { Add-InstallRoot $env:AG_ROOT }
    if ($local) {
        Add-AntigravityChildren (Join-Path $local "Programs")
        Add-AntigravityChildren $local
        foreach ($rel in @(
            "agy\bin", "agy",
            "Antigravity", "Antigravity IDE",
            "Programs\Antigravity", "Programs\Antigravity IDE", "Programs\Antigravity CLI",
            "Programs\antigravity"
        )) {
            Add-InstallRoot (Join-Path $local $rel)
        }
        Add-Binary (Join-Path $local "Programs\Antigravity CLI\agy.exe")
        Add-Binary (Join-Path $local "Antigravity\agy.exe")
        Add-Binary (Join-Path $local "agy\bin\agy.exe")
        Add-Binary (Join-Path $local "agy\agy.exe")
    }
    foreach ($base in @($pf, $pf86)) {
        if (-not $base) { continue }
        Add-AntigravityChildren $base
        Add-InstallRoot (Join-Path $base "Antigravity")
        Add-InstallRoot (Join-Path $base "Antigravity IDE")
    }
    if ($userHome) {
        Add-InstallRoot (Join-Path $userHome ".gemini\bin")
        Add-InstallRoot (Join-Path $userHome ".agy")
        Add-InstallRoot (Join-Path $userHome ".agy\bin")
        Add-Binary (Join-Path $userHome ".gemini\bin\agy.exe")
        Add-ExtensionDirs $userHome
    }
    Add-PathAgy
    Add-UninstallKeys
}

function Short-Path([string]$Path) {
    $userHome = Home-Of
    if ($userHome -and $Path.StartsWith($userHome, [StringComparison]::OrdinalIgnoreCase)) {
        return "~" + $Path.Substring($userHome.Length)
    }
    return $Path
}
function Show-Targets {
    if ($script:Targets.Count -eq 0) {
        Err "Ничего не найдено."
        Warn "Ожидаются: %LOCALAPPDATA%\Programs\antigravity, %LOCALAPPDATA%\agy\bin\agy.exe,"
        Warn "CLI и расширение: %USERPROFILE%\.gemini\bin\agy.exe."
        return $false
    }
    foreach ($t in $script:Targets) {
        $kind = Get-Kind $t.Path
        switch ($kind) {
            "patched"   { Ok "пропатчен   — $(Short-Path $t.Path)" }
            "unpatched" { Warn "НЕ пропатчен — $(Short-Path $t.Path)" }
            "missing"   { Warn "сигнатуры нет (новая сборка?) — $(Short-Path $t.Path)" }
            "stacked"   { Err "старый сторонний JS-патч — переустановите IDE: $(Short-Path $t.Path)" }
            default     { Err "не читается — $(Short-Path $t.Path)" }
        }
        if ($t.Kind -eq "bin") {
            $st = Get-BinState $t.Path
            $parts = $st -split ' '
            Dim "      ineligible: $($parts[1]), inexigible: $($parts[2])"
        }
        if (-not (Test-Writable $t.Path)) { Warn "      запись недоступна" }
    }
    return $true
}

function Confirm-Yes([string]$Prompt) {
    if ($env:AG_YES -eq "1") { return $true }
    $a = Read-Host "$Prompt [y/N]"
    return ($a -match '^[yYдД]')
}
function Get-OwnerApp([string]$File) {
    $dir = Split-Path -Parent $File
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        foreach ($name in @("Antigravity.exe", "Antigravity IDE.exe")) {
            $cand = Join-Path $dir $name
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return [IO.Path]::GetFullPath($cand) }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
function Stop-Lockers([string[]]$Paths) {
    $names = @(
        "Antigravity.exe", "Antigravity IDE.exe", "Antigravity CLI.exe",
        "agy.exe", "language_server.exe", "language_server_windows_x64.exe"
    )
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $names -contains $_.Name
    })
    $kill = @{}
    $relaunch = @()
    foreach ($file in $Paths) {
        if (-not (Test-FileLocked $file)) { continue }
        $owner = Get-OwnerApp $file
        foreach ($p in $procs) {
            if (-not $p.ExecutablePath) { continue }
            $exe = [IO.Path]::GetFullPath($p.ExecutablePath)
            $hit = $exe.Equals($file, [StringComparison]::OrdinalIgnoreCase)
            if ($owner -and $exe.Equals($owner, [StringComparison]::OrdinalIgnoreCase)) { $hit = $true }
            if (-not $hit) { continue }
            $kill[[string]$p.ProcessId] = $p
            if ($owner -and $exe.Equals($owner, [StringComparison]::OrdinalIgnoreCase)) {
                if ($p.Name -eq "Antigravity.exe" -or $p.Name -eq "Antigravity IDE.exe") {
                    $relaunch += $owner
                }
            }
        }
    }
    foreach ($p in $kill.Values) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-WatchLog ("закрыт процесс " + $p.Name + " pid " + $p.ProcessId)
    }
    if ($kill.Count -gt 0) { Start-Sleep -Seconds 2 }
    return @($relaunch | Select-Object -Unique)
}
function Start-Apps([string[]]$Apps) {
    foreach ($app in $Apps) {
        if ($app -and (Test-Path -LiteralPath $app)) {
            Start-Process -FilePath $app | Out-Null
            Write-WatchLog "запущен снова: $app"
        }
    }
}

function Invoke-PatchRun([string]$Mode, [switch]$Quiet) {
    $want = $(if ($Mode -eq "patch") { "unpatched" } else { "patched" })
    $expect = $(if ($Mode -eq "patch") { "patched" } else { "unpatched" })
    $todo = @()
    foreach ($t in $script:Targets) {
        if ((Get-Kind $t.Path) -eq $want) { $todo += $t }
    }
    if ($todo.Count -eq 0) {
        if (-not $Quiet -and $env:AG_WATCH -ne "1") { Info "Менять нечего — всё уже в нужном состоянии." }
        return 0
    }
    $blocked = @($todo | Where-Object { -not (Test-Writable $_.Path) })
    if ($blocked.Count -gt 0) {
        Err "Целей недоступно на запись: $($blocked.Count). Ничего не менял."
        foreach ($b in $blocked) { Warn "    $(Short-Path $b.Path)" }
        return 1
    }
    $locked = @($todo | Where-Object { Test-FileLocked $_.Path })
    $relaunch = @()
    if ($locked.Count -gt 0) {
        Warn "Часть файлов занята запущенным Antigravity."
        foreach ($f in $locked) { Dim "      $(Short-Path $f.Path)" }
        if (-not (Confirm-Yes "Закрыть Antigravity и продолжить?")) {
            Info "Отменено."
            return 1
        }
        $relaunch = @(Stop-Lockers @($locked.Path))
        foreach ($f in $locked) {
            if (Test-FileLocked $f.Path) {
                Err "файл всё ещё занят: $(Short-Path $f.Path)"
                return 1
            }
        }
    }
    $changed = 0
    $failed = 0
    foreach ($t in $script:Targets) {
        $kind = Get-Kind $t.Path
        if ($kind -ne $want) {
            if ($kind -eq "patched" -and $Mode -eq "patch" -and $env:AG_WATCH -ne "1") {
                Dim "  пропускаю (уже пропатчен): $(Short-Path $t.Path)"
            } elseif ($kind -eq "unpatched" -and $Mode -eq "unpatch" -and $env:AG_WATCH -ne "1") {
                Dim "  пропускаю (уже стоковый): $(Short-Path $t.Path)"
            } elseif ($kind -eq "missing" -and $env:AG_WATCH -ne "1") {
                Warn "сигнатуры нет, не трогаю: $(Short-Path $t.Path)"
            } elseif ($kind -eq "stacked") {
                Err "старый JS-патч в $(Short-Path $t.Path) — переустановите IDE"
                $failed++
            } elseif ($kind -eq "unreadable") {
                Err "не читается: $(Short-Path $t.Path)"
                $failed++
            }
            continue
        }
        try {
            if ($t.Kind -eq "js") {
                if ($Mode -eq "patch") { $out = Invoke-JsPatch $t.Path } else { $out = Invoke-JsUnpatch $t.Path }
                if ($out -ne "ok" -and $out -ne "marker-only") { throw $out }
            } else {
                [void](Invoke-BinApply $t.Path $Mode)
            }
        } catch {
            Err "не удалось записать $(Short-Path $t.Path): $($_.Exception.Message)"
            $failed++
            continue
        }
        $after = Get-Kind $t.Path
        if ($after -eq $expect) {
            if ($Mode -eq "patch") { Ok "пропатчен: $(Short-Path $t.Path)" }
            else { Ok "откачен: $(Short-Path $t.Path)" }
            $changed++
        } else {
            Err "проверка после записи не сошлась: $(Short-Path $t.Path) (состояние: $after)"
            $failed++
        }
    }
    if ($Mode -eq "patch" -and $failed -eq 0 -and $relaunch.Count -gt 0) { Start-Apps $relaunch }
    if ($changed -eq 0 -and $failed -eq 0) {
        if ($env:AG_WATCH -ne "1") { Info "Менять нечего — всё уже в нужном состоянии." }
    } else {
        Info "Изменено файлов: $changed, ошибок: $failed"
        if ($Mode -eq "patch" -and $changed -gt 0 -and $env:AG_WATCH -ne "1") {
            Info "Запустите Antigravity и войдите в Google-аккаунт."
            Info "После обновления патч затирается — прогоните скрипт снова или включите сторож."
        }
    }
    if ($failed -gt 0) { return 1 }
    return 0
}

function Register-Watchers {
    $dirs = @()
    $userHome = Home-Of
    $local = $env:LOCALAPPDATA
    if ($local) {
        $dirs += (Join-Path $local "Programs")
        $dirs += (Join-Path $local "agy")
        $dirs += (Join-Path $local "Antigravity")
        $dirs += (Join-Path $local "Antigravity IDE")
    }
    if ($userHome) {
        $dirs += (Join-Path $userHome ".gemini\bin")
        $dirs += (Join-Path $userHome ".agy")
    }
    if ($env:ProgramFiles) {
        $dirs += (Join-Path $env:ProgramFiles "Antigravity")
        $dirs += (Join-Path $env:ProgramFiles "Antigravity IDE")
    }
    $n = 0
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $d
        $w.IncludeSubdirectories = $true
        $w.NotifyFilter = [IO.NotifyFilters]"FileName, LastWrite, Size"
        $id = "agw-$n"
        Register-ObjectEvent -InputObject $w -EventName Changed -SourceIdentifier "$id-c" | Out-Null
        Register-ObjectEvent -InputObject $w -EventName Created -SourceIdentifier "$id-n" | Out-Null
        Register-ObjectEvent -InputObject $w -EventName Renamed -SourceIdentifier "$id-r" | Out-Null
        $w.EnableRaisingEvents = $true
        $n++
    }
}
function Clear-WatchEvents {
    $ev = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "agw-*" })
    if ($ev.Count -gt 0) { $ev | Remove-Event }
    return ($ev.Count -gt 0)
}
function Target-Signature {
    $lines = @()
    foreach ($t in $script:Targets) {
        $item = Get-Item -LiteralPath $t.Path -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $lines += "{0}|{1}|{2}" -f $t.Path.ToLower(), $item.Length, $item.LastWriteTimeUtc.Ticks
    }
    return ($lines -join "`n")
}
function Start-Watch {
    $once = ($env:AG_WATCH_ONCE -eq "1")
    $env:AG_YES = "1"
    $env:AG_WATCH = "1"
    $dir = State-Dir
    $pidFile = Join-Path $dir "watch.pid"
    if (-not $once) {
        if (Test-Path -LiteralPath $pidFile) {
            $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($old) {
                $alive = Get-Process -Id $old -ErrorAction SilentlyContinue
                if ($alive) {
                    Info "Сторож уже запущен (pid $old)"
                    return 0
                }
            }
        }
        Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
        Register-Watchers
    }
    $prev = ""
    $skip = 0
    $clean = $null
    try {
        while ($true) {
            Find-Targets
            $busy = $false
            foreach ($t in $script:Targets) {
                if (Test-InstallerBusy $t.Path) { $busy = $true; break }
            }
            if ($busy) {
                Write-WatchLog "установщик ещё пишет файлы, жду"
                if ($once) { return 0 }
                Start-Sleep -Seconds 5
                continue
            }
            if ($once) {
                $code = Invoke-PatchRun "patch" -Quiet
                return $code
            }
            $sig = Target-Signature
            if ($prev -and $sig -ne $prev) {
                $prev = $sig
                $skip = 1
                $clean = $null
            } elseif ($skip -gt 0) {
                $prev = $sig
                $skip = 0
            } else {
                $prev = $sig
                if ($clean -ne $sig) {
                    $code = Invoke-PatchRun "patch" -Quiet
                    if ($code -eq 0) { $clean = $sig }
                }
            }
            $hot = Clear-WatchEvents
            if ($hot) { Start-Sleep -Seconds 2 } else { Start-Sleep -Seconds 5 }
        }
    } finally {
        if (-not $once) {
            Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "agw-*" } | Unregister-Event -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Escape-Xml([string]$Text) {
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Install-WatchTask {
    if (-not $script:Self) { Err "Не вижу путь скрипта. Запустите через -File."; return 1 }
    $self = [IO.Path]::GetFullPath($script:Self)
    $user = "$env:USERDOMAIN\$env:USERNAME"
    # /SC ONLOGON без XML на этой системе требует права администратора.
    # Тот же планировщик через XML: вход в сессию, интерактивный токен, без повышения.
    $taskArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File &quot;' + (Escape-Xml $self) + '&quot; watch'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$taskArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $env:TEMP "ag-patcher-task.xml"
    $utf16 = New-Object System.Text.UnicodeEncoding $false, $true
    [IO.File]::WriteAllText($xmlPath, $xml, $utf16)
    $out = & schtasks.exe /Create /TN $script:TaskName /XML $xmlPath /F 2>&1
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
        Err "schtasks не создал задачу: $out"
        return 1
    }
    Ok "Автозапуск включён: задача $($script:TaskName) при входе в систему."
    Info "Сторож закрывает Antigravity, если файл занят, патчит и открывает его снова."
    return 0
}
function Stop-RecordedWatch {
    $pidFile = Join-Path (State-Dir) "watch.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -match '^\d+$') {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$old" -ErrorAction SilentlyContinue
        $cmd = ""
        if ($proc) { $cmd = [string]$proc.CommandLine }
        if ($cmd -match 'ag_patcher\.ps1' -and $cmd -match '(?i)(^|\s)watch($|\s)') {
            Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue
            Write-WatchLog "сторож остановлен (pid $old)"
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}
function Uninstall-WatchTask {
    & schtasks.exe /Delete /TN $script:TaskName /F 2>&1 | Out-Null
    $missing = ($LASTEXITCODE -ne 0)
    Stop-RecordedWatch
    if ($missing) {
        Warn "Задачи $($script:TaskName) не было."
        return 0
    }
    Ok "Автозапуск выключен."
    return 0
}

function Show-Help {
    Say "Использование: powershell -NoProfile -ExecutionPolicy Bypass -File ag_patcher.ps1 [команда] [файлы...]"
    Say "  patch            — пропатчить найденные бинари и JS IDE"
    Say "  unpatch          — откатить"
    Say "  status           — только показать состояние"
    Say "  watch            — тихий цикл, пока окно открыто"
    Say "  install-watch    — задача планировщика при входе (без прав администратора)"
    Say "  uninstall-watch  — убрать задачу"
    Say "  без аргументов   — меню"
    Say "Лишние пути вместо поиска. Нужен только Windows PowerShell 5.1."
}

function Invoke-Action([string]$Mode) {
    if ($env:AG_WATCH -ne "1") { Info "Ищу установки Antigravity…" }
    Find-Targets
    if (-not (Show-Targets)) { return 1 }
    Say ""
    return (Invoke-PatchRun $Mode)
}

switch ($Command) {
    "patch"           { exit (Invoke-Action "patch") }
    "unpatch"         { exit (Invoke-Action "unpatch") }
    "status"          { Info "Ищу установки Antigravity…"; Find-Targets; if (Show-Targets) { exit 0 } else { exit 1 } }
    "watch"           { exit (Start-Watch) }
    "install-watch"   { exit (Install-WatchTask) }
    "uninstall-watch" { exit (Uninstall-WatchTask) }
    "-h"              { Show-Help; exit 0 }
    "--help"          { Show-Help; exit 0 }
    "help"            { Show-Help; exit 0 }
    ""                { }
    default           { Err "Неизвестная команда: $Command (см. --help)"; exit 1 }
}

Info "Ищу установки Antigravity…"
Find-Targets
if (-not (Show-Targets)) { exit 1 }
Say ""
while ($true) {
    Say "===== Antigravity patcher (Windows) ====="
    Say " 1) Пропатчить всё найденное"
    Say " 2) Откатить патч"
    Say " 3) Сторож в этом окне"
    Say " 4) Включить автозапуск при входе"
    Say " 5) Выключить автозапуск"
    Say " 0) Выход"
    $choice = Read-Host "Выбор"
    Say ""
    switch ($choice) {
        "1" { [void](Invoke-PatchRun "patch"); Say ""; Info "Ищу установки Antigravity…"; Find-Targets; [void](Show-Targets); Say "" }
        "2" { [void](Invoke-PatchRun "unpatch"); Say ""; Info "Ищу установки Antigravity…"; Find-Targets; [void](Show-Targets); Say "" }
        "3" { [void](Start-Watch); exit 0 }
        "4" { [void](Install-WatchTask); Say "" }
        "5" { [void](Uninstall-WatchTask); Say "" }
        "0" { exit 0 }
        default { Warn "Неизвестный пункт меню"; Say "" }
    }
}
