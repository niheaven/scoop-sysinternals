#Discovers tools published upstream in MicrosoftDocs/sysinternals that have no
#manifest yet and generates one from the live download zip (hash + bin layout).
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = 'MicrosoftDocs/sysinternals'
$bucketDir = Convert-Path "$PSScriptRoot/../bucket"
$existing = Get-ChildItem $bucketDir -Filter *.json
$existingSlugs = $existing.Name
$existingUrls = foreach ($f in $existing) {
    $j = Get-Content $f -Raw | ConvertFrom-Json
    $j.url
    if ($j.architecture) { $j.architecture.PSObject.Properties | ForEach-Object { $_.Value.url } }
}

$tree = (Invoke-RestMethod "https://api.github.com/repos/$repo/git/trees/main?recursive=1").tree
$slugs = $tree.path | Where-Object { $_ -like 'sysinternals/downloads/*.md' } |
    ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }

foreach ($slug in $slugs) {
    if ("$slug.json" -in $existingSlugs) { continue }

    $md = Invoke-RestMethod "https://raw.githubusercontent.com/$repo/main/sysinternals/downloads/$slug.md"
    $zip = [regex]::Match($md, 'https://download\.sysinternals\.com/files/([A-Za-z0-9\-._]+\.zip)').Groups[1].Value
    if (-not $zip) { Write-Host "$slug : no download zip, skipping"; continue }
    $zipUrl = "https://download.sysinternals.com/files/$zip"
    if ($zipUrl -in $existingUrls) { Write-Host "$slug : shares existing zip $zip, skipping"; continue }
    try {
        Invoke-WebRequest -Method Head -Uri $zipUrl -UseBasicParsing | Out-Null
    } catch {
        Write-Host "$slug : dead download $zip, skipping"
        continue
    }

    $version = [regex]::Match($md, '(?m)^#.*?\bv(\d+(?:\.\d+)*)').Groups[1].Value
    $description = ([regex]::Match($md, '(?m)^description:\s*(.+)$').Groups[1].Value).Trim().Trim('"').Trim("'")
    if (-not $version -or -not $description) { Write-Host "$slug : unparsable title/description, skipping"; continue }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "checknew-$slug.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmp -UseBasicParsing
    $hash = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLower()
    $zipFile = [IO.Compression.ZipFile]::OpenRead($tmp)
    $exes = $zipFile.Entries |
        Where-Object { $_.FullName -notmatch '/' -and $_.Name -like '*.exe' } |
        ForEach-Object { $_.Name }
    $zipFile.Dispose()
    Remove-Item $tmp

    if (-not $exes) { Write-Host "$slug : no exe in zip, skipping"; continue }

    # Tool exes are shipped as Foo.exe / Foo64.exe / Foo64a.exe in one zip.
    $arch = [ordered]@{}
    foreach ($bit in '32bit', '64bit', 'arm64') {
        $suffix = @{ '32bit' = ''; '64bit' = '64'; 'arm64' = '64a' }[$bit]
        $pattern = '^(.*)' + [regex]::Escape($suffix) + '\.exe$'
        $bin = foreach ($exe in $exes) {
            $m = [regex]::Match($exe, $pattern)
            if ($m.Success) {
                if ($suffix -and $m.Groups[1].Value) { , @($exe, $m.Groups[1].Value) } else { $exe }
            }
        }
        if ($bin) { $arch[$bit] = [pscustomobject]@{ bin = @($bin) } }
    }
    if ($arch.Count -lt 3) { Write-Host "$slug : incomplete arch layout ($($arch.Keys -join ', ')), generated for review" }

    $manifest = [ordered]@{
        version     = $version
        description = $description
        homepage    = "https://learn.microsoft.com/sysinternals/downloads/$slug"
        license     = [ordered]@{
            identifier = 'Freeware'
            url        = 'https://learn.microsoft.com/sysinternals/license-terms'
        }
        url         = $zipUrl
        hash        = $hash
        architecture = $arch
        checkver    = [ordered]@{
            url   = "https://raw.githubusercontent.com/$repo/main/sysinternals/downloads/$slug.md"
            regex = '#.*?v([\d.]+)'
        }
        autoupdate  = [ordered]@{ url = $zipUrl }
    }

    $path = Join-Path $bucketDir "$slug.json"
    if ($DryRun) {
        Write-Host "$slug : would generate $path (version $version)"
        continue
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    # Repo style requires CRLF line endings (enforced by Scoop-Bucket.Tests)
    $raw = [IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($path, ($raw -replace "`r?`n", "`r`n"))
    Write-Host "$slug : generated $path (version $version)"
}
