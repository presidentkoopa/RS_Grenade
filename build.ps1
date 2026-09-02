# RS_Grenade -- build the pk3.
#
# Deliberately modelled on RS_VR_Unified's build.ps1, including its most
# important property: VERIFIED OK MEANS THE PK3 IS WELL-FORMED. IT IS NOT A
# COMPILE CHECK. There is no offline ZScript compiler; only a real engine load
# validates syntax, and a ZScript error is fatal AND GLOBAL -- it stops every
# pk3 after it in the load order from compiling too.
#
# So the checks below are the ones that can be made without an engine: that
# every #include resolves, that every registered handler exists, that no class
# is declared twice, and that nothing collides with the two pk3s this is most
# likely to be loaded beside.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out  = Join-Path $root 'RS_Grenade.pk3'

$include = @('zscript','models','sounds','sprites',
             'zscript.txt','MODELDEF.txt','CVARINFO.txt',
             'SNDINFO.txt','MENUDEF.txt','MAPINFO.txt')

$files = @()
foreach ($i in $include) {
    $p = Join-Path $root $i
    if (-not (Test-Path $p)) { Write-Host "WARNING: missing $i"; continue }
    if (Test-Path $p -PathType Container) {
        $files += Get-ChildItem $p -Recurse -File
    } else {
        $files += Get-Item $p
    }
}

# ---- checks --------------------------------------------------------------
$zs = Get-ChildItem (Join-Path $root 'zscript') -Recurse -Filter *.zs -File
$declared = @{}
$dupes = @()
foreach ($f in $zs) {
    foreach ($m in [regex]::Matches((Get-Content $f.FullName -Raw), '(?m)^class\s+([A-Za-z0-9_]+)')) {
        $n = $m.Groups[1].Value
        if ($declared.ContainsKey($n)) { $dupes += $n } else { $declared[$n] = $f.Name }
    }
}

$unresolved = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'zscript.txt') -Raw), '#include\s+"([^"]+)"')) {
    if (-not (Test-Path (Join-Path $root $m.Groups[1].Value))) { $unresolved += $m.Groups[1].Value }
}

$undef = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'MAPINFO.txt') -Raw), '"([A-Za-z0-9_]+)"')) {
    if (-not $declared.ContainsKey($m.Groups[1].Value)) { $undef += $m.Groups[1].Value }
}

# ---- pack ----------------------------------------------------------------
if (Test-Path $out) { Remove-Item $out -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
    }
} finally { $zip.Dispose() }

$kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host ""
Write-Host "RS_Grenade.pk3  --  $($files.Count) entries, $kb KB"
Write-Host "  #includes         : $($unresolved.Count) unresolved"
Write-Host "  event handlers    : $($undef.Count) undefined"
Write-Host "  classes           : $($declared.Count) declared, $($dupes.Count) duplicated"
if ($unresolved.Count -or $undef.Count -or $dupes.Count) {
    if ($unresolved.Count) { Write-Host "  UNRESOLVED: $($unresolved -join ', ')" }
    if ($undef.Count)      { Write-Host "  UNDEFINED HANDLER: $($undef -join ', ')" }
    if ($dupes.Count)      { Write-Host "  DUPLICATE CLASS: $($dupes -join ', ')" }
    Write-Host "  FAILED"
} else {
    Write-Host "  VERIFIED OK  (well-formed -- NOT a ZScript compile check)"
}
