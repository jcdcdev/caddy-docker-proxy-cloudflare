param (
    [string]$DockerfilePath = "$PSScriptRoot/../Dockerfile",
    [switch]$Update = $false
)

# Helper function to find next version
function Get-NextVersion {
    param (
        [string]$CurrentVersionStr,
        [array]$AvailableTags,
        [scriptblock]$TagParser
    )

    # Normalize current version (remove v)
    try {
        $cleanVer = $CurrentVersionStr -replace "^v", ""
        # Handle cases like "2.8" -> "2.8.0" for comparison
        $parseableCurrent = if ($cleanVer -notmatch '\.\d+\.') { "$cleanVer.0" } else { $cleanVer }
        $currentVersion = [version]$parseableCurrent
    } catch {
        Write-Warning "Could not parse current version: $CurrentVersionStr"
        return $null
    }

    $validUpdates = @()

    foreach ($tag in $AvailableTags) {
        $parsed = & $TagParser $tag
        if ($null -eq $parsed) { continue }
        
        $verObj = $parsed.Version
        $tagStr = $parsed.TagString
        
        if ($verObj -gt $currentVersion) {
            $validUpdates += [PSCustomObject]@{
                Version   = $verObj
                TagString = $tagStr
            }
        }
    }

    if ($validUpdates.Count -eq 0) { return $null }
    
    # Sort and pick the immediate next version
    return $validUpdates | Sort-Object Version | Select-Object -First 1
}

# Helper to fetch GitHub tags
function Get-GitHubTags {
    param ([string]$Repo)
    $url = "https://api.github.com/repos/$Repo/tags?per_page=100"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get
        return $resp.name
    }
    catch {
        Write-Warning "Failed to fetch tags for ${Repo}: $_"
        return @()
    }
}

# Ensure absolute path
$DockerfilePath = Resolve-Path $DockerfilePath
Write-Host "Checking Dockerfile at: $DockerfilePath"
$content = Get-Content $DockerfilePath -Raw
$updatesFound = $false
$updateSummary = @()

# --- 1. Check CADDY_VERSION (Docker Hub) ---
Write-Host "`n--- Checking Caddy Core ---"
if ($content -match 'ARG CADDY_VERSION=([0-9.]+)') {
    $current = $matches[1]
    Write-Host "Current: $current"

    # Fetch Docker Hub tags
    $baseUrl = "https://hub.docker.com/v2/repositories/library/caddy/tags?page_size=100"
    $url = $baseUrl
    $results = @()
    # Fetch first few pages (limit to avoid infinite loops if something breaks)
    $page = 1
    do {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get
            $results += $resp.results
            $url = $resp.next
            $page++
        } catch { break }
    } while ($url -and $page -le 10)

    # Parser for Caddy Docker tags (looks for *-builder)
    $parser = {
        param($tagObj)
        if ($tagObj.name -match '^(\d+(\.\d+)*)-builder$') {
            $vStr = $matches[1]
            $pVer = if ($vStr -notmatch '\.') { "$vStr.0" } else { $vStr }
            return [PSCustomObject]@{ Version = [version]$pVer; TagString = $vStr }
        }
        return $null
    }

    $next = Get-NextVersion -CurrentVersionStr $current -AvailableTags $results -TagParser $parser
    
    if ($next) {
        Write-Host "Found new version: $($next.TagString)"
        if ($Update) {
            $content = $content -replace "ARG CADDY_VERSION=[0-9.]+", "ARG CADDY_VERSION=$($next.TagString)"
            $updatesFound = $true
            $updateSummary += "Caddy: $current -> $($next.TagString)"
        }
    } else { Write-Host "Up to date." }
}

# --- 2. Check CADDY_DOCKER_PROXY_VERSION (GitHub) ---
Write-Host "`n--- Checking Caddy Docker Proxy ---"
if ($content -match 'ARG CADDY_DOCKER_PROXY_VERSION=(v[0-9.]+)') {
    $current = $matches[1]
    Write-Host "Current: $current"
    $tags = Get-GitHubTags -Repo "lucaslorentz/caddy-docker-proxy"
    
    $parser = {
        param($tagName)
        if ($tagName -match '^v(\d+(\.\d+)*)$') {
             try { return [PSCustomObject]@{ Version = [version]$matches[1]; TagString = $tagName } } catch {}
        }
        return $null
    }

    $next = Get-NextVersion -CurrentVersionStr $current -AvailableTags $tags -TagParser $parser
    if ($next) {
        Write-Host "Found new version: $($next.TagString)"
        if ($Update) {
            $content = $content -replace "ARG CADDY_DOCKER_PROXY_VERSION=v[0-9.]+", "ARG CADDY_DOCKER_PROXY_VERSION=$($next.TagString)"
            
            # Update module path if major version bump (e.g. /v2 -> /v3)
            if ($next.Version.Major -gt 1) {
                $moduleBase = "github.com/lucaslorentz/caddy-docker-proxy"
                $major = $next.Version.Major
                $newPath = "$moduleBase/v$major"
                
                # Check if we need to update the path in xcaddy cmd
                # Look for current path (regex escape base)
                $escapedBase = [regex]::Escape($moduleBase)
                if ($content -match "$escapedBase(/v\d+)?") {
                    $oldPath = $matches[0]
                    if ($oldPath -ne $newPath) {
                       $content = $content -replace [regex]::Escape($oldPath), $newPath
                       $updateSummary += " (Module path -> $newPath)"
                    }
                }
            }

            $updatesFound = $true
            $updateSummary += "Docker-Proxy: $current -> $($next.TagString)"
        }
    } else { Write-Host "Up to date." }
}

# --- 3. Check CLOUDFLARE_DNS_VERSION (GitHub) ---
Write-Host "`n--- Checking Cloudflare DNS ---"
if ($content -match 'ARG CLOUDFLARE_DNS_VERSION=(v[0-9.]+)') {
    $current = $matches[1]
    Write-Host "Current: $current"
    $tags = Get-GitHubTags -Repo "caddy-dns/cloudflare"
    
    $parser = {
        param($tagName)
        if ($tagName -match '^v(\d+(\.\d+)*)$') {
             try { return [PSCustomObject]@{ Version = [version]$matches[1]; TagString = $tagName } } catch {}
        }
        return $null
    }

    $next = Get-NextVersion -CurrentVersionStr $current -AvailableTags $tags -TagParser $parser
    if ($next) {
        Write-Host "Found new version: $($next.TagString)"
        if ($Update) {
            $content = $content -replace "ARG CLOUDFLARE_DNS_VERSION=v[0-9.]+", "ARG CLOUDFLARE_DNS_VERSION=$($next.TagString)"
            
             # Update module path if major version bump (e.g. /v2)
             # Note: Cloudflare might not use /v0 or /v1 explicitly, but standard is /v2 for >= 2.0
             if ($next.Version.Major -ge 2) {
                $moduleBase = "github.com/caddy-dns/cloudflare"
                $major = $next.Version.Major
                $newPath = "$moduleBase/v$major"
                
                $escapedBase = [regex]::Escape($moduleBase)
                if ($content -match "$escapedBase(/v\d+)?") {
                    $oldPath = $matches[0]
                    if ($oldPath -ne $newPath) {
                       $content = $content -replace [regex]::Escape($oldPath), $newPath
                       $updateSummary += " (Module path -> $newPath)"
                    }
                }
            }
            
            $updatesFound = $true
            $updateSummary += "Cloudflare: $current -> $($next.TagString)"
        }
    } else { Write-Host "Up to date." }
}

# --- Finalize ---
if ($updatesFound) {
    if ($Update) {
        Set-Content -Path $DockerfilePath -Value $content -NoNewline
    }
    $summaryStr = $updateSummary -join ", "
    if ($env:GITHUB_OUTPUT) {
        "new_version=$summaryStr" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        "update_available=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    }
} elseif ($env:GITHUB_OUTPUT) {
    "update_available=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
