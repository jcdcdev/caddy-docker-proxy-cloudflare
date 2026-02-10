<#
.SYNOPSIS
    Checks for updates to Caddy and its plugins, optionally updating the Dockerfile.
.PARAMETER DockerfilePath
    Path to the Dockerfile. Defaults to ../Dockerfile.
.PARAMETER Apply
    Updates the Dockerfile with new versions.
#>
[CmdletBinding()]
param(
    [string]$DockerfilePath = (Join-Path $PSScriptRoot '..' 'Dockerfile'),
    [switch]$Apply
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Component definitions - add new components here
$Components = @(
    @{
        Name         = 'Caddy Core'
        Pattern      = 'ARG CADDY_VERSION=([0-9.]+)'
        Repo         = 'library/caddy'
        Type         = 'DockerHub'
        TagRegex     = '^(\d+(\.\d+)*)-builder$'
        VersionGroup = 1
        ValueGroup   = 1
        BranchPrefix = 'caddy'
        GoModule     = $null
    },
    @{
        Name         = 'Caddy Docker Proxy'
        Pattern      = 'ARG CADDY_DOCKER_PROXY_VERSION=(v[0-9.]+)'
        Repo         = 'lucaslorentz/caddy-docker-proxy'
        Type         = 'GitHub'
        TagRegex     = '^v(\d+(\.\d+)*)$'
        VersionGroup = 1
        ValueGroup   = 0
        BranchPrefix = 'proxy'
        GoModule     = 'github.com/lucaslorentz/caddy-docker-proxy'
    },
    @{
        Name         = 'Cloudflare DNS'
        Pattern      = 'ARG CLOUDFLARE_DNS_VERSION=(v[0-9.]+)'
        Repo         = 'caddy-dns/cloudflare'
        Type         = 'GitHub'
        TagRegex     = '^v(\d+(\.\d+)*)$'
        VersionGroup = 1
        ValueGroup   = 0
        BranchPrefix = 'cloudflare'
        GoModule     = 'github.com/caddy-dns/cloudflare'
    }
)

function Get-Tags {
    param([string]$Type, [string]$Repo)
    
    if ($Type -eq 'GitHub') {
        $uri = "https://api.github.com/repos/$Repo/tags?per_page=100"
        try {
            $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop
            return $response.name
        }
        catch {
            Write-Warning "Failed to fetch GitHub tags: $_"
            return @()
        }
    }
    else {
        $results = @()
        $uri = "https://hub.docker.com/v2/repositories/$Repo/tags?page_size=100"
        $pageCount = 0
        
        while ($uri -and $pageCount -lt 5) {
            try {
                $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop
                $results += $response.results | Select-Object -ExpandProperty name
                $uri = $response.next
                $pageCount++
            }
            catch {
                Write-Warning "Failed to fetch Docker Hub tags: $_"
                break
            }
        }
        return $results
    }
}

function Get-NextVersion {
    param([string]$Current, [array]$Tags, [hashtable]$Component)
    
    $cleanCurrent = $Current -replace '^v', ''
    $parseableCurrent = if ($cleanCurrent -notmatch '\.\d+\.') { "$cleanCurrent.0" } else { $cleanCurrent }
    
    try {
        $currentVersion = [version]$parseableCurrent
    }
    catch {
        Write-Warning "Could not parse version: $Current"
        return $null
    }
    
    $updates = foreach ($tag in $Tags) {
        if ($tag -match $Component.TagRegex) {
            $verStr = $matches[$Component.VersionGroup]
            $valStr = $matches[$Component.ValueGroup]
            $parseable = if ($verStr -notmatch '\.\d+\.') { "$verStr.0" } else { $verStr }
            
            try {
                $ver = [version]$parseable
                if ($ver -gt $currentVersion) {
                    [PSCustomObject]@{ Version = $ver; Tag = $valStr }
                }
            }
            catch { }
        }
    }
    
    if ($updates) {
        return $updates | Sort-Object Version | Select-Object -First 1
    }
    return $null
}

function Update-GoModulePath {
    param([ref]$FileContent, [string]$Module, [version]$Version)
    
    if ($Version.Major -ge 2) {
        $newPath = "$Module/v$($Version.Major)"
        $escaped = [regex]::Escape($Module)
        
        if ($FileContent.Value -match "$escaped(/v\d+)?") {
            $oldPath = $matches[0]
            if ($oldPath -ne $newPath) {
                $FileContent.Value = $FileContent.Value -replace [regex]::Escape($oldPath), $newPath
                return " (Module path -> $newPath)"
            }
        }
    }
    return $null
}

# Main execution
try {
    $DockerfilePath = Resolve-Path $DockerfilePath -ErrorAction Stop
    Write-Host "Checking Dockerfile: $DockerfilePath" -ForegroundColor Cyan
    
    $content = Get-Content -Path $DockerfilePath -Raw -ErrorAction Stop
    $updates = @()
    
    # Check each component
    foreach ($component in $Components) {
        Write-Host "`n--- Checking $($component.Name) ---" -ForegroundColor Cyan
        
        if ($content -notmatch $component.Pattern) {
            Write-Warning "Could not find version pattern for $($component.Name)"
            continue
        }
        
        $currentVersion = $matches[1]
        Write-Host "Current version: $currentVersion"
        
        $tags = Get-Tags -Type $component.Type -Repo $component.Repo
        if ($tags.Count -eq 0) {
            Write-Warning "No tags found"
            continue
        }
        
        $nextVersion = Get-NextVersion -Current $currentVersion -Tags $tags -Component $component
        
        if ($nextVersion) {
            Write-Host "New version available: $($nextVersion.Tag)" -ForegroundColor Yellow
            $updates += [PSCustomObject]@{
                Component = $component
                Current   = $currentVersion
                Next      = $nextVersion
            }
        }
        else {
            Write-Host "Up to date." -ForegroundColor Green
        }
    }
    
    # Process updates
    if ($updates.Count -eq 0) {
        Write-Host "`nAll components are up to date." -ForegroundColor Green
        if ($env:GITHUB_OUTPUT) {
            "update_available=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
        exit 0
    }
    
    Write-Host "`nFound $($updates.Count) update(s) available." -ForegroundColor Yellow
    
    # Apply updates if requested
    if ($Apply) {
        Write-Host "`nApplying updates..." -ForegroundColor Cyan
        $messages = @()
        $branchParts = @()
        
        foreach ($update in $updates) {
            $comp = $update.Component
            $escaped = [regex]::Escape($update.Current)
            $content = $content -replace $escaped, $update.Next.Tag
            
            $msg = "$($comp.Name) $($update.Current) -> $($update.Next.Tag)"
            
            if ($comp.GoModule) {
                $modUpdate = Update-GoModulePath -FileContent ([ref]$content) -Module $comp.GoModule -Version $update.Next.Version
                if ($modUpdate) { $msg += $modUpdate }
            }
            
            $messages += $msg
            $branchParts += "$($comp.BranchPrefix)-$($update.Next.Tag)"
        }
        
        [System.IO.File]::WriteAllText($DockerfilePath, $content)
        Write-Host "`nDockerfile updated successfully." -ForegroundColor Green
        
        $summary = $messages -join ', '
        $branch = "update/$($branchParts -join '-' -replace '[^a-zA-Z0-9\-\.]', '-')"
        
        Write-Host "`nUpdate Summary: $summary" -ForegroundColor Cyan
        Write-Host "Suggested Branch: $branch" -ForegroundColor Cyan
        
        if ($env:GITHUB_OUTPUT) {
            "update_available=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "new_version=$summary" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "branch_name=$branch" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
    }
    else {
        Write-Host "`nRe-run with -Apply to apply changes." -ForegroundColor Yellow
        
        if ($env:GITHUB_OUTPUT) {
            $summary = ($updates | ForEach-Object { "$($_.Component.Name) -> $($_.Next.Tag)" }) -join ', '
            $branch = "update/$(($updates | ForEach-Object { "$($_.Component.BranchPrefix)-$($_.Next.Tag)" }) -join '-' -replace '[^a-zA-Z0-9\-\.]', '-')"
            
            "update_available=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "new_version=$summary" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "branch_name=$branch" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
    }
}
catch {
    Write-Error "An error occurred: $_"
    if ($env:GITHUB_OUTPUT) {
        "update_available=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    exit 1
}