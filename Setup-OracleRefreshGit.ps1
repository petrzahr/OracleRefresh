[CmdletBinding()]
param(
    [string]$ProjectPath = 'C:\Users\pzahr\Disk Google\Antigravity\OracleRefresh',
    [string]$RemoteUrl = 'https://github.com/petrzahr/OracleRefresh.git',
    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & git -C $ProjectPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not installed or is missing from PATH.'
}
if ($Push -and -not $RemoteUrl) {
    throw 'Use -Push together with -RemoteUrl.'
}

New-Item -ItemType Directory -Path $ProjectPath -Force | Out-Null
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$dotGit = Join-Path $ProjectPath '.git'

if (-not (Test-Path -LiteralPath $dotGit)) {
    # Avoid silently adding a nested repository inside another project.
    $parent = Split-Path -Parent $ProjectPath
    while ($parent) {
        if (Test-Path -LiteralPath (Join-Path $parent '.git')) {
            throw "Project path is inside an existing Git repository: $parent"
        }
        $next = Split-Path -Parent $parent
        if (-not $next -or $next -eq $parent) { break }
        $parent = $next
    }
    Invoke-Git -Arguments @('init', '-b', 'main')
}

$root = (& git -C $ProjectPath rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or
    [IO.Path]::GetFullPath($root).TrimEnd('\', '/') -ine
    [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')) {
    throw 'The project directory is not the root of its Git repository.'
}

$ignoreFile = Join-Path $ProjectPath '.gitignore'
$required = @(
    '/config/credentials.json',
    '/config/database.json',
    '/config/schemas/*.json',
    '!/config/schemas/*.example.json',
    '/snapshots/',
    '/logs/',
    '__pycache__/',
    '*.pyc',
    '*.log',
    '.env',
    '.env.*'
)
$existing = if (Test-Path -LiteralPath $ignoreFile) {
    @(Get-Content -LiteralPath $ignoreFile -Encoding UTF8)
} else { @() }
$missing = @($required | Where-Object { $existing -cnotcontains $_ })
if ($missing.Count -gt 0) {
    $content = (($existing + $missing) -join "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($ignoreFile, $content, [Text.UTF8Encoding]::new($false))
}

# Refuse to proceed if secrets were already tracked before this script ran.
$tracked = @(& git -C $ProjectPath ls-files)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tracked files.' }
$sensitive = @($tracked | Where-Object {
    $_ -eq 'config/credentials.json' -or
    $_ -eq 'config/database.json' -or
    ($_ -like 'config/schemas/*.json' -and $_ -notlike '*.example.json') -or
    $_ -like 'snapshots/*' -or $_ -like 'logs/*' -or $_ -like '.env*'
})
if ($sensitive.Count -gt 0) {
    throw "Sensitive files are already tracked. Remove them from the Git index before committing: $($sensitive -join ', ')"
}

# Stage only known source and example files, never `git add .`.
$safePaths = @('.gitignore')
foreach ($file in @('README.md', 'DELETE_EXAMPLES.md')) {
    if (Test-Path -LiteralPath (Join-Path $ProjectPath $file)) { $safePaths += $file }
}
foreach ($directory in @('scripts', 'config', 'config/schemas')) {
    $full = Join-Path $ProjectPath $directory
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $pattern = if ($directory -eq 'scripts') { '*.ps1', '*.py' } else { '*.example.json' }
    foreach ($file in (Get-ChildItem -LiteralPath $full -File | Where-Object {
        $n = $_.Name
        @($pattern | Where-Object { $n -like $_ }).Count -gt 0
    })) {
        $safePaths += ($directory + '/' + $file.Name)
    }
}
Invoke-Git -Arguments (@('add', '--') + $safePaths)

$commitCount = (& git -C $ProjectPath rev-list --all --count).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Git history.' }
if ($commitCount -eq '0') {
    $staged = @(& git -C $ProjectPath diff --cached --name-only)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect staged files.' }
    if ($staged.Count -gt 0) {
        $author = & git -C $ProjectPath config user.name
        $email = & git -C $ProjectPath config user.email
        if (-not $author -or -not $email) {
            Write-Warning 'Git author name or email is missing; files are staged, but no commit was made.'
            Write-Warning 'Set git config user.name and user.email, then run git commit -m "Initial OracleRefresh setup".'
        } else {
            Invoke-Git -Arguments @('commit', '-m', 'Initial OracleRefresh setup')
        }
    }
}

if ($RemoteUrl) {
    $remotes = @(& git -C $ProjectPath remote)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Git remotes.' }
    if ($remotes -contains 'origin') {
        $origin = & git -C $ProjectPath remote get-url origin
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read origin URL.' }
        if ($origin.Trim() -ne $RemoteUrl) { throw "origin already points to a different URL: $origin" }
    } else {
        Invoke-Git -Arguments @('remote', 'add', 'origin', $RemoteUrl)
    }
}

if ($Push) {
    $commitCount = (& git -C $ProjectPath rev-list --all --count).Trim()
    if ($LASTEXITCODE -ne 0 -or $commitCount -eq '0') { throw 'Nothing to push: create the initial commit first.' }
    $branch = (& git -C $ProjectPath branch --show-current).Trim()
    Invoke-Git -Arguments @('push', '-u', 'origin', $branch)
}

Write-Host "Git is configured in: $ProjectPath"
Invoke-Git -Arguments @('status', '--short')
Invoke-Git -Arguments @('remote', '-v')
