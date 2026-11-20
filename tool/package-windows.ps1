[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $InnoCompiler,

    [string] $ReleaseDir = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release'),
    [string] $OutputDir = (Join-Path $PSScriptRoot '..\build\windows\installer'),
    [string] $RuntimeDir
)

$ErrorActionPreference = 'Stop'
$release = (Get-Item -LiteralPath $ReleaseDir).FullName
$compiler = (Get-Item -LiteralPath $InnoCompiler).FullName
$runner = Get-Item -LiteralPath (Join-Path $release 'Dorm.exe')
if (-not (Test-Path -LiteralPath (Join-Path $release 'data\app.so') -PathType Leaf)) {
    throw 'ReleaseDir must contain the complete Flutter Windows release.'
}

$productVersion = $runner.VersionInfo.ProductVersion
if ($productVersion -notmatch '^(\d+\.\d+\.\d+)\+(\d+)$') {
    throw "Unexpected Dorm product version '$productVersion'."
}
$version = $Matches[1]
$fileVersion = "$version.$($Matches[2])"

$runtimeFiles = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
if (-not $RuntimeDir) {
    $vswherePath = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswherePath -PathType Leaf) {
        $visualStudio = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
            Select-Object -First 1
        if ($visualStudio) {
            $redist = Join-Path $visualStudio 'VC\Redist\MSVC'
            if (Test-Path -LiteralPath $redist -PathType Container) {
                $versions = Get-ChildItem -LiteralPath $redist -Directory |
                    Where-Object { $_.Name -match '^\d+\.\d+\.\d+(?:\.\d+)?$' } |
                    Sort-Object -Property { [version]$_.Name } -Descending
                foreach ($item in $versions) {
                    $RuntimeDir = Get-Item -Path (Join-Path $item.FullName 'x64\Microsoft.VC*.CRT') -ErrorAction SilentlyContinue |
                        Select-Object -First 1 -ExpandProperty FullName
                    if ($RuntimeDir) { break }
                }
            }
        }
    }
}
if (-not $RuntimeDir) {
    throw 'Specify -RuntimeDir with the Visual Studio x64 Microsoft.VC*.CRT redistributable directory.'
}
$runtime = (Get-Item -LiteralPath $RuntimeDir).FullName

foreach ($path in @($runner.FullName) + @($runtimeFiles | ForEach-Object { Join-Path $runtime $_ })) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($path))
    try {
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Expected an x64 Windows executable or library at '$path'."
        }
    } finally {
        $reader.Dispose()
    }
}

$destination = (New-Item -Path $OutputDir -ItemType Directory -Force).FullName
$script = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\windows\installer\Dorm.iss')).FullName
& $compiler "/O$destination" "/DReleaseDir=$release" "/DRuntimeDir=$runtime" "/DDormVersion=$version" "/DDormFileVersion=$fileVersion" $script
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup exited with code $LASTEXITCODE."
}
Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destination "Dorm-Windows-x64-Setup-v$version.exe")
