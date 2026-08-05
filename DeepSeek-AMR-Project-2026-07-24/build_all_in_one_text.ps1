param(
    [string]$SourceFolder = $PSScriptRoot,
    [string]$OutputFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'DeepSeek-AMR-Project-2026-07-24-All-In-One.txt')
)

$ErrorActionPreference = 'Stop'

$allowedExtensions = @(
    '.cmd', '.css', '.csv', '.example', '.html', '.js', '.json',
    '.lock', '.md', '.mjs', '.ps1', '.sql', '.toml', '.txt'
)

$excludedNames = @(
    '.env',
    'FILE_MANIFEST_SHA256.csv'
)

$sourcePath = (Resolve-Path -LiteralPath $SourceFolder).Path
$files = @(
    Get-ChildItem -Recurse -File -LiteralPath $sourcePath |
        Where-Object {
            $_.Name -notin $excludedNames -and
            (
                $_.Extension.ToLowerInvariant() -in $allowedExtensions -or
                $_.Name -in @('.gitignore', '.gitmodules', 'package-lock.json')
            )
        } |
        Sort-Object FullName
)

$encoding = [System.Text.UTF8Encoding]::new($true)
$writer = [System.IO.StreamWriter]::new($OutputFile, $false, $encoding)

try {
    $writer.WriteLine('IOT2020 AMR PROJECT - ALL-IN-ONE TEXT EXPORT')
    $writer.WriteLine('Export date: 2026-07-24')
    $writer.WriteLine('Encoding: UTF-8 with BOM')
    $writer.WriteLine('Start reading: 00_README_FOR_DEEPSEEK.md -> AGENTS.md -> PROJECT_STATUS_COMPACT.md')
    $writer.WriteLine('This is a source snapshot. It contains no live database data, Git history, node_modules, or real .env credentials.')
    $writer.WriteLine('')
    $writer.WriteLine('==================== FILE INDEX ====================')

    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($sourcePath.Length + 1).Replace('\', '/')
        $writer.WriteLine($relativePath)
    }

    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($sourcePath.Length + 1).Replace('\', '/')
        $writer.WriteLine('')
        $writer.WriteLine('================================================================')
        $writer.WriteLine("BEGIN FILE: $relativePath")
        $writer.WriteLine('================================================================')
        $writer.WriteLine([System.IO.File]::ReadAllText($file.FullName))
        $writer.WriteLine('================================================================')
        $writer.WriteLine("END FILE: $relativePath")
        $writer.WriteLine('================================================================')
    }
}
finally {
    $writer.Dispose()
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $OutputFile
[PSCustomObject]@{
    OutputFile = $OutputFile
    SourceFiles = $files.Count
    Bytes = (Get-Item -LiteralPath $OutputFile).Length
    SHA256 = $hash.Hash
}
