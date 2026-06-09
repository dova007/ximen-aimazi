param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$errors = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) {
    $script:errors.Add($Message) | Out-Null
}

function Get-Text([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Test-Frontmatter {
    $skillPath = Join-Path $rootPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath)) {
        Add-Error 'SKILL.md is missing.'
        return
    }

    $text = Get-Text $skillPath
    if (-not $text.StartsWith("---`n") -and -not $text.StartsWith("---`r`n")) {
        Add-Error 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $match = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
    if (-not $match.Success) {
        Add-Error 'SKILL.md frontmatter is not closed.'
        return
    }

    $keys = @()
    foreach ($line in ($match.Groups[1].Value -split "\r?\n")) {
        if ($line.Trim() -eq '') { continue }
        if ($line -notmatch '^\s*([A-Za-z0-9_-]+)\s*:') {
            Add-Error "Invalid frontmatter line: $line"
            continue
        }
        $keys += $Matches[1]
    }

    $allowed = @('name', 'description')
    foreach ($required in $allowed) {
        if ($keys -notcontains $required) {
            Add-Error "SKILL.md frontmatter missing required key: $required"
        }
    }
    foreach ($key in $keys) {
        if ($allowed -notcontains $key) {
            Add-Error "SKILL.md frontmatter has unsupported key: $key"
        }
    }
}

function Test-VersionPins {
    $expected = '2.4.0'

    $metaPath = Join-Path $rootPath '_meta.json'
    $pluginPath = Join-Path $rootPath 'plugin.json'
    $readmePath = Join-Path $rootPath 'README.md'

    if (Test-Path -LiteralPath $metaPath) {
        $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($meta.version -ne $expected) {
            Add-Error "_meta.json version is $($meta.version), expected $expected."
        }
    } else {
        Add-Error '_meta.json is missing.'
    }

    if (Test-Path -LiteralPath $pluginPath) {
        $plugin = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($plugin.version -ne $expected) {
            Add-Error "plugin.json version is $($plugin.version), expected $expected."
        }
    } else {
        Add-Error 'plugin.json is missing.'
    }

    if (Test-Path -LiteralPath $readmePath) {
        $readme = Get-Text $readmePath
        if ($readme -notmatch [regex]::Escape("version-v$expected")) {
            Add-Error "README.md badge does not reference v$expected."
        }
    } else {
        Add-Error 'README.md is missing.'
    }
}

function Test-NoSecondarySkillDoc {
    $secondarySkillName = 'SKILL.' + 'en' + '.md'
    $secondarySkillPath = Join-Path $rootPath $secondarySkillName
    if (Test-Path -LiteralPath $secondarySkillPath) {
        Add-Error 'Secondary skill doc should not exist; this skill uses a single Chinese entrypoint.'
    }

    $scanFiles = @('README.md', 'CHANGELOG.md', 'plugin.json', '_meta.json') |
        ForEach-Object { Join-Path $rootPath $_ } |
        Where-Object { Test-Path -LiteralPath $_ }

    foreach ($file in $scanFiles) {
        $text = Get-Text $file
        if ($text -match [regex]::Escape($secondarySkillName)) {
            Add-Error "Secondary skill doc reference found in $([IO.Path]::GetFileName($file))."
        }
    }
}

function Test-AgentMetadata {
    $metadataPath = Join-Path $rootPath 'agents\openai.yaml'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        Add-Error 'agents/openai.yaml is missing.'
        return
    }

    $text = Get-Text $metadataPath
    $requiredSnippets = @(
        'interface:',
        'display_name:',
        'short_description:',
        'default_prompt:',
        '$ximen-aimazi',
        'policy:',
        'allow_implicit_invocation: true'
    )

    foreach ($snippet in $requiredSnippets) {
        if (-not $text.Contains($snippet)) {
            Add-Error "agents/openai.yaml missing required snippet: $snippet"
        }
    }
}

function Resolve-MarkdownReference([string]$Reference) {
    $normalized = $Reference -replace '/', [IO.Path]::DirectorySeparatorChar

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $rootPath $normalized)) | Out-Null

    if ($Reference -notmatch '^(references|assets|memory|scripts|output|\.learnings|正文|大纲|设定|追踪)/') {
        $candidates.Add((Join-Path (Join-Path $rootPath 'references') $normalized)) | Out-Null
        $candidates.Add((Join-Path (Join-Path $rootPath 'assets') $normalized)) | Out-Null
        $candidates.Add((Join-Path (Join-Path $rootPath 'memory') $normalized)) | Out-Null
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Test-MarkdownReferences {
    $scanRoots = @('SKILL.md', 'README.md', 'references', 'assets', 'memory') |
        ForEach-Object { Join-Path $rootPath $_ } |
        Where-Object { Test-Path -LiteralPath $_ }

    $files = foreach ($item in $scanRoots) {
        if ((Get-Item -LiteralPath $item).PSIsContainer) {
            Get-ChildItem -LiteralPath $item -Recurse -File -Filter '*.md'
        } else {
            Get-Item -LiteralPath $item
        }
    }

    $ignoredPatterns = @(
        '^\{',
        '^[A-Za-z0-9_-]+:\s+',
        '^https?:',
        '^\.\./',
        '^/',
        '\*',
        '\{.*\}',
        '^output/',
        '^\.learnings/',
        '[^\x00-\x7F]',
        '^CHARACTERS\.md$',
        '^EMOTIONS\.md$',
        '^ERRORS\.md$',
        '^LOCATIONS\.md$',
        '^PLOT_POINTS\.md$',
        '^RESOURCES\.md$',
        '^STORY_BIBLE\.md$',
        '^SUBPLOTS\.md$',
        '^SUSPENSE\.md$'
    )

    $missing = New-Object System.Collections.Generic.HashSet[string]
    $referencePattern = @'
`([^`]+\.md)`|\[([^\]]+)\]\(([^)]+\.md)\)
'@

    foreach ($file in $files) {
        $text = Get-Text $file.FullName
        foreach ($match in [regex]::Matches($text, $referencePattern)) {
            $ref = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[3].Value }
            $ref = ($ref -split '#')[0].Trim()
            if ($ref -eq '') { continue }

            $ignore = $false
            foreach ($pattern in $ignoredPatterns) {
                if ($ref -match $pattern) {
                    $ignore = $true
                    break
                }
            }
            if ($ignore) { continue }

            if (-not (Resolve-MarkdownReference $ref)) {
                $missing.Add($ref) | Out-Null
            }
        }
    }

    foreach ($ref in ($missing | Sort-Object)) {
        Add-Error "Missing markdown reference: $ref"
    }
}

Test-Frontmatter
Test-VersionPins
Test-NoSecondarySkillDoc
Test-AgentMetadata
Test-MarkdownReferences

if ($errors.Count -gt 0) {
    Write-Host "Skill validation failed:" -ForegroundColor Red
    foreach ($errorMessage in $errors) {
        Write-Host " - $errorMessage" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Skill validation passed." -ForegroundColor Green
