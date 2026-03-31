<#
.SYNOPSIS
Benchmarks local LLMs using Ollama and/or LM Studio CLI.

.DESCRIPTION
Runs a benchmark suite against locally installed language models using:
- Ollama HTTP API
- LM Studio CLI (lms)

Cold startup is measured once per model.
All scored benchmark prompts are then run warm.

It measures:
- success rate
- initial load / total startup latency
- warm total latency
- warm tokens per second
- optional quality scores
- category-level quality scores

Results are written to:
- raw-results.json
- raw-results.csv
- leaderboard.csv
- failures.csv (only when failures occur)
- system-info.json
- summary-report.md

Raw CSV outputs can be inspected with Import-Csv ... | Out-GridView for sortable local viewing.

.PARAMETER Provider
Which provider(s) to benchmark.
Valid values:
- ollama
- lms
- all
#>

[CmdletBinding()]
param(
    [ValidateSet("ollama", "lms", "all")]
    [string]$Provider = "all",

    [string[]]$OllamaModels = @(),
    [string[]]$LmsModels = @(),

    [ValidateRange(1, 100)]
    [int]$Repeats = 2,

    [int]$TimeoutSec = 180,

    [string]$OutputDir = ".\results",

    [string]$OllamaBaseUrl = "http://localhost:11434",

    [switch]$AutoDetectLmsModels,
    [switch]$AutoDetectOllamaModels
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$PromptSuite = @(
    [pscustomobject]@{
        Id           = "reasoning_01"
        Category     = "reasoning"
        Prompt       = "A £50 item is discounted by 20%, then 10% tax is added to the discounted price. What is the final price? Answer with just the number."
        ScoreType    = "exact"
        ExpectedText = "44"
    },
    [pscustomobject]@{
        Id           = "reasoning_02"
        Category     = "reasoning"
        Prompt       = "A sequence starts 2, 6, 18, 54. What is the next number? Answer with just the number."
        ScoreType    = "exact"
        ExpectedText = "162"
    },
    [pscustomobject]@{
        Id           = "reasoning_03"
        Category     = "reasoning"
        Prompt       = "If 5 workers take 12 days to complete a job at the same constant rate, how many days would 10 workers take? Answer with just the number."
        ScoreType    = "exact"
        ExpectedText = "6"
    },
    [pscustomobject]@{
        Id           = "json_01"
        Category     = "json"
        Prompt       = "Return ONLY raw minified JSON. No markdown, no code fences. Keys: animal, sound. Values should describe a cat."
        ScoreType    = "json_keys"
        ExpectedJson = @{
            animal   = "cat"
            sound    = "meow"
        }
    },
    [pscustomobject]@{
        Id           = "json_02"
        Category     = "json"
        Prompt       = "Return ONLY raw minified JSON. No markdown, no code fences. Keys: planet, position. Use Earth and 3."
        ScoreType    = "json_keys"
        ExpectedJson = @{
            planet   = "Earth"
            position = "3"
        }
    },
    [pscustomobject]@{
        Id           = "coding_01"
        Category     = "coding"
        Prompt       = "Write a Python function is_even(n) that returns True if n is even, otherwise False. Do not include example usage."
        ScoreType    = "python_is_even"
    },
    [pscustomobject]@{
        Id           = "coding_02"
        Category     = "coding"
        Prompt       = "Write a JavaScript function clamp(value, min, max) that returns min if value is below min, max if value is above max, otherwise value. Do not include example usage."
        ScoreType    = "js_clamp"
    },
    [pscustomobject]@{
        Id           = "instruction_01"
        Category     = "instruction"
        Prompt       = "Return exactly this text and nothing else: BLUE"
        ScoreType    = "exact"
        ExpectedText = "BLUE"
    },
    [pscustomobject]@{
        Id           = "instruction_02"
        Category     = "instruction"
        Prompt       = "Return exactly three comma-separated lowercase colors and nothing else: red,blue,green"
        ScoreType    = "exact"
        ExpectedText = "red,blue,green"
    },
    [pscustomobject]@{
        Id            = "summary_01"
        Category      = "summarization"
        Prompt        = "Summarize this in exactly one sentence including the words coding, latency, JSON, and improved: OpenAI released a new model update that improved coding reliability, reduced latency, and made JSON output more consistent."
        ScoreType     = "contains_all"
        RequiredTerms = @(
            "coding",
            "latency",
            "JSON",
            "improved"
        )
    },
    [pscustomobject]@{
        Id            = "summary_02"
        Category      = "summarization"
        Prompt        = "Summarize this in exactly one sentence including the words budget, deadline, testing, and release: The team delayed the release by one week to finish testing, stay within budget, and reduce the risk of post-launch defects."
        ScoreType     = "contains_all"
        RequiredTerms = @(
            "budget",
            "deadline",
            "testing",
            "release"
        )
}
)

function Get-NowMs {
    [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-NowIsoUtc {
    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Estimate-TokenCount {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $wordCount = [regex]::Matches($Text, '\S+').Count
    return [Math]::Max(1, [int][Math]::Round($wordCount * 1.3))
}

function Normalize-ModelOutput {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = $Text
    $clean = [regex]::Replace($clean, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
    $clean = $clean.Trim()
    $clean = [regex]::Replace($clean, '^\s*```[a-zA-Z0-9_-]*\s*', '')
    $clean = [regex]::Replace($clean, '\s*```\s*$', '')

    return $clean.Trim()
}

function Try-ParseJsonFromText {
    param([string]$Text)

    $normalized = Normalize-ModelOutput -Text $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    try {
        return ($normalized | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
    }

    $start = $normalized.IndexOf('{')
    if ($start -lt 0) {
        return $null
    }

    $depth = 0
    $inString = $false
    $escape = $false
    $end = -1

    for ($i = $start; $i -lt $normalized.Length; $i++) {
        $ch = $normalized[$i]

        if ($escape) {
            $escape = $false
            continue
        }

        if ($ch -eq '\') {
            if ($inString) { $escape = $true }
            continue
        }

        if ($ch -eq '"') {
            $inString = -not $inString
            continue
        }

        if (-not $inString) {
            if ($ch -eq '{') {
                $depth++
            }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $end = $i
                    break
                }
            }
        }
    }

    if ($end -gt $start) {
        $candidate = $normalized.Substring($start, ($end - $start + 1))
        try {
            return ($candidate | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-SystemInfo {
    $cpuName = $null
    $cpuCores = $null
    $cpuLogical = $null
    $usableRamGb = $null
    $installedRamGb = $null
    $osCaption = $null
    $osVersion = $null
    $osBuild = $null
    $gpus = @()

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($null -ne $cpu) {
            $cpuName = $cpu.Name
            $cpuCores = $cpu.NumberOfCores
            $cpuLogical = $cpu.NumberOfLogicalProcessors
        }
    }
    catch {}

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($null -ne $cs.TotalPhysicalMemory) {
            $usableRamGb = [Math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
        }
    }
    catch {}

    try {
        $physicalMemory = @(Get-CimInstance Win32_PhysicalMemory)
        if ($physicalMemory.Count -gt 0) {
            $installedBytes = ($physicalMemory | Measure-Object -Property Capacity -Sum).Sum
            if ($null -ne $installedBytes -and [double]$installedBytes -gt 0) {
                $installedRamGb = [Math]::Round(([double]$installedBytes / 1GB), 2)
            }
        }
    }
    catch {}

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($null -ne $os) {
            $osCaption = $os.Caption
            $osVersion = $os.Version
            $osBuild = $os.BuildNumber
        }
    }
    catch {}

    try {
        $videoControllers = @(Get-CimInstance Win32_VideoController)
        foreach ($gpu in $videoControllers) {
            $name = [string]$gpu.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '(?i)remote display|basic display|rdp|citrix|parsec') { continue }

            $dedicatedVramGb = $null
            if ($null -ne $gpu.AdapterRAM -and [double]$gpu.AdapterRAM -gt 0) {
                $dedicatedVramGb = [Math]::Round(([double]$gpu.AdapterRAM / 1GB), 2)
            }

            $isIntegrated = $false
            if ($name -match '(?i)radeon.*graphics|intel\(r\).*graphics|uhd graphics|iris|vega|890m|880m|780m|760m') {
                $isIntegrated = $true
            }

            $sharedVramGb = $null
            if ($isIntegrated -and $null -ne $usableRamGb) {
                $sharedVramGb = $usableRamGb
            }

            $gpus += [pscustomobject]@{
                Name            = $name
                DedicatedVRAMGB = $dedicatedVramGb
                SharedVRAMGB    = $sharedVramGb
                IsIntegrated    = $isIntegrated
                DriverVersion   = $gpu.DriverVersion
                VideoProcessor  = $gpu.VideoProcessor
                Status          = $gpu.Status
            }
        }
    }
    catch {}

    [pscustomobject]@{
        CpuName              = $cpuName
        CpuCores             = $cpuCores
        CpuLogicalProcessors = $cpuLogical
        UsableRamGB          = $usableRamGb
        InstalledRamGB       = $installedRamGb
        OsCaption            = $osCaption
        OsVersion            = $osVersion
        OsBuild              = $osBuild
        Gpus                 = @($gpus)
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-OllamaAvailable {
    param([string]$BaseUrl)
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -Method Get -TimeoutSec 5
        return ($null -ne $resp)
    }
    catch {
        return $false
    }
}

function Show-StartupBanner {
    param(
        [string]$Provider,
        [string[]]$OllamaModels,
        [string[]]$LmsModels,
        [int]$Repeats,
        [string]$OutputDir,
        [string]$OllamaBaseUrl,
        [int]$PromptCount,
        $SystemInfo
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host " Local LLM Benchmark Configuration" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host ("Provider        : {0}" -f $Provider)
    Write-Host ("WarmRepeats     : {0}" -f $Repeats)
    Write-Host ("PromptCount     : {0}" -f $PromptCount)
    Write-Host ("OutputDir       : {0}" -f $OutputDir)
     if ($Provider -eq "ollama" -or $Provider -eq "all") {
        Write-Host ("OllamaBaseUrl   : {0}" -f $OllamaBaseUrl)
    }

    if ($null -ne $SystemInfo) {
        if (-not [string]::IsNullOrWhiteSpace($SystemInfo.CpuName)) {
            $cpuLine = $SystemInfo.CpuName
            if ($null -ne $SystemInfo.CpuCores -or $null -ne $SystemInfo.CpuLogicalProcessors) {
                $cpuLine = "{0} ({1}C/{2}T)" -f $SystemInfo.CpuName, $SystemInfo.CpuCores, $SystemInfo.CpuLogicalProcessors
            }
            Write-Host ("CPU             : {0}" -f $cpuLine)
        }

        if ($null -ne $SystemInfo.InstalledRamGB) {
            Write-Host ("Installed RAM   : {0} GB" -f $SystemInfo.InstalledRamGB)
        }

        if ($null -ne $SystemInfo.UsableRamGB) {
            Write-Host ("Usable RAM      : {0} GB" -f $SystemInfo.UsableRamGB)
        }

        if (-not [string]::IsNullOrWhiteSpace($SystemInfo.OsCaption)) {
            $osLine = $SystemInfo.OsCaption
            if (-not [string]::IsNullOrWhiteSpace($SystemInfo.OsVersion)) {
                $osLine += " " + $SystemInfo.OsVersion
            }
            if (-not [string]::IsNullOrWhiteSpace($SystemInfo.OsBuild)) {
                $osLine += " (Build " + $SystemInfo.OsBuild + ")"
            }
            Write-Host ("OS              : {0}" -f $osLine)
        }

        $gpuIndex = 1
        foreach ($gpu in @($SystemInfo.Gpus)) {
            if ([string]::IsNullOrWhiteSpace($gpu.Name)) { continue }

            if ($gpuIndex -eq 1) {
                Write-Host ("GPU             : {0}" -f $gpu.Name)
            }
            else {
                Write-Host ("GPU {0}           : {1}" -f $gpuIndex, $gpu.Name)
            }

            if ($null -ne $gpu.DedicatedVRAMGB) {
                if ($gpuIndex -eq 1) {
                    Write-Host ("Dedicated VRAM  : {0} GB" -f $gpu.DedicatedVRAMGB)
                }
                else {
                    Write-Host ("GPU {0} VRAM      : {1} GB" -f $gpuIndex, $gpu.DedicatedVRAMGB)
                }
            }

            if ($null -ne $gpu.SharedVRAMGB) {
                if ($gpuIndex -eq 1) {
                    Write-Host ("Shared VRAM     : {0} GB" -f $gpu.SharedVRAMGB)
                }
                else {
                    Write-Host ("GPU {0} Shared    : {1} GB" -f $gpuIndex, $gpu.SharedVRAMGB)
                }
            }

            if ($gpu.IsIntegrated) {
                if ($gpuIndex -eq 1) {
                    Write-Host "GPU Memory Type : Integrated / shared system memory (UMA; shared amount is a usable system memory pool, not permanently allocated VRAM)"
                }
                else {
                    Write-Host ("GPU {0} Type      : Integrated / shared system memory (UMA)" -f $gpuIndex)
                }
            }

            $gpuIndex++
        }
    }

    if ($OllamaModels.Count -gt 0) {
        Write-Host ("OllamaModels    : {0}" -f ($OllamaModels -join ", "))
    }

    if ($LmsModels.Count -gt 0) {
        Write-Host ("LmsModels       : {0}" -f ($LmsModels -join ", "))
    }

    Write-Host ""
}

function Get-QualityScore {
    param([string]$Text, $Test)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $normalized = Normalize-ModelOutput -Text $Text

    switch ($Test.ScoreType) {
        "exact" {
            if ($normalized -eq $Test.ExpectedText) { return 100 }
            if ($normalized -match [regex]::Escape([string]$Test.ExpectedText)) { return 70 }
            return 0
        }

        "regex" {
            if ($normalized -match $Test.ExpectedRegex) { return 100 }
            return 0
        }

        "contains_all" {
            $required = @($Test.RequiredTerms)
            if ($required.Count -eq 0) { return 0 }

            $hits = 0
            foreach ($term in $required) {
                if ($normalized -match [regex]::Escape([string]$term)) {
                    $hits++
                }
            }

            return [Math]::Round((100.0 * $hits) / $required.Count, 2)
        }

        "python_is_even" {
            $hasFunction = $normalized -match 'def\s+is_even\s*\('
            $hasDirectBoolean = $normalized -match 'return\s+.*%\s*2\s*==\s*0'
            $hasBranching = (
                ($normalized -match '\bif\b') -and
                ($normalized -match 'return\s+True') -and
                ($normalized -match 'return\s+False')
            )

            if ($hasFunction -and ($hasDirectBoolean -or $hasBranching)) {
                return 100
            }

            if ($hasFunction) {
                return 50
            }

            return 0
        }

        "js_clamp" {
            $hasFunction = $normalized -match 'function\s+clamp\s*\('
            $hasMathClamp = $normalized -match 'Math\.min\s*\(\s*Math\.max\s*\(\s*value\s*,\s*min\s*\)\s*,\s*max\s*\)'
            $hasBranching = (
                ($normalized -match '\bif\b') -and
                ($normalized -match 'return\s+min') -and
                ($normalized -match 'return\s+max') -and
                ($normalized -match 'return\s+value')
            )

            if ($hasFunction -and ($hasMathClamp -or $hasBranching)) {
                return 100
            }

            if ($hasFunction) {
                return 50
            }

            return 0
        }

        "code_contains" {
            $required = @($Test.RequiredSnippets)
            if ($required.Count -eq 0) { return 0 }

            $hits = 0
            foreach ($snippet in $required) {
                if ($normalized -match [regex]::Escape([string]$snippet)) {
                    $hits++
                }
            }

            $base = (100.0 * $hits) / $required.Count
            return [Math]::Round($base, 2)
        }

        "json_keys" {
            $obj = Try-ParseJsonFromText -Text $normalized
            if ($null -eq $obj) { return 0 }

            $expected = $Test.ExpectedJson
            if ($null -eq $expected) { return 0 }

            $keys = @($expected.Keys)
            if ($keys.Count -eq 0) { return 0 }

            $score = 0.0
            foreach ($key in $keys) {
                if ($obj.PSObject.Properties.Name -contains $key) {
                    $score += 50.0 / $keys.Count

                    $actualValue = [string]$obj.$key
                    $expectedValue = [string]$expected[$key]

                    if ($actualValue -eq $expectedValue) {
                        $score += 50.0 / $keys.Count
                    }
                }
            }

            return [Math]::Round([Math]::Min(100, $score), 2)
        }

        default {
            if ($null -ne $Test.ExpectedRegex -and $normalized -match $Test.ExpectedRegex) {
                return 100
            }
            return 0
        }
    }
}

function Normalize-Score {
    param(
        [double]$Value,
        [double]$Min,
        [double]$Max,
        [switch]$Reverse
    )

    if ($Max -le $Min) { return 100.0 }

    $norm = (($Value - $Min) / ($Max - $Min)) * 100.0
    if ($Reverse) { $norm = 100.0 - $norm }

    $norm = [Math]::Max(0.0, [Math]::Min(100.0, $norm))
    [Math]::Round($norm, 2)
}

function Get-InstalledOllamaModels {
    param([string]$BaseUrl)

    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -Method Get -TimeoutSec 10
        if ($null -ne $resp.models) {
            @($resp.models | ForEach-Object { $_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        else {
            @()
        }
    }
    catch {
        Write-Warning "Could not query Ollama models from $BaseUrl : $($_.Exception.Message)"
        @()
    }
}

function Invoke-OllamaUnload {
    param(
        [string]$BaseUrl,
        [string]$Model
    )

    try {
        $body = @{
            model      = $Model
            prompt     = ""
            keep_alive = 0
        } | ConvertTo-Json -Compress

        Invoke-RestMethod -Uri "$BaseUrl/api/generate" `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 20 | Out-Null

        Write-Host ("Unloaded Ollama model: {0}" -f $Model) -ForegroundColor DarkGray
    }
    catch {
        Write-Warning ("Failed to unload Ollama model '{0}': {1}" -f $Model, $_.Exception.Message)
    }
}

function Invoke-OllamaBenchmark {
    param(
        [string]$BaseUrl,
        [string]$Model,
        [string]$Prompt,
        [int]$TimeoutSec,
        [bool]$ColdStart
    )

    if ($ColdStart) {
        Invoke-OllamaUnload -BaseUrl $BaseUrl -Model $Model
        Start-Sleep -Milliseconds 400
    }

    $bodyObject = @{
        model   = $Model
        prompt  = $Prompt
        stream  = $false
        options = @{
            temperature = 0
        }
    }

    $body = $bodyObject | ConvertTo-Json -Depth 8 -Compress
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $startedMs = Get-NowMs

    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/generate" `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec $TimeoutSec

        $sw.Stop()

        $text = Normalize-ModelOutput -Text ([string]$resp.response)
        $outputTokens = Estimate-TokenCount -Text $text
        $totalMs = [int]$sw.ElapsedMilliseconds

        $evalCount = 0
        if ($null -ne $resp.eval_count) { $evalCount = [int]$resp.eval_count }
        if ($evalCount -le 0) { $evalCount = $outputTokens }

        $evalDurationNs = 0.0
        if ($null -ne $resp.eval_duration) { $evalDurationNs = [double]$resp.eval_duration }

        $loadDurationNs = 0.0
        if ($null -ne $resp.load_duration) { $loadDurationNs = [double]$resp.load_duration }

        $promptEvalNs = 0.0
        if ($null -ne $resp.prompt_eval_duration) { $promptEvalNs = [double]$resp.prompt_eval_duration }

        $promptEvalCount = 0
        if ($null -ne $resp.prompt_eval_count) { $promptEvalCount = [int]$resp.prompt_eval_count }

        $tokensPerSec = 0.0
        if ($evalDurationNs -gt 0 -and $evalCount -gt 0) {
            $tokensPerSec = [Math]::Round(($evalCount / ($evalDurationNs / 1e9)), 2)
        }
        elseif ($totalMs -gt 0 -and $outputTokens -gt 0) {
            $tokensPerSec = [Math]::Round(($outputTokens / ($totalMs / 1000.0)), 2)
        }

        [pscustomobject]@{
            Provider     = "ollama"
            Model        = $Model
            Success      = $true
            ColdStart    = $ColdStart
            OutputText   = $text
            OutputTokens = $outputTokens
            PromptTokens = $promptEvalCount
            TotalMs      = $totalMs
            LoadMs       = [Math]::Round($loadDurationNs / 1e6, 2)
            PromptEvalMs = [Math]::Round($promptEvalNs / 1e6, 2)
            TTFTMs       = $null
            TokensPerSec = $tokensPerSec
            Error        = $null
            StartedAtMs  = $startedMs
            Raw          = $resp
        }
    }
    catch {
        $sw.Stop()

        $msg = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = "Unknown Ollama error."
        }

        if ($msg -match '500\)\s*Internal Server Error') {
            $msg += " Possible causes: insufficient available RAM/VRAM, model load failure, or Ollama runtime instability. Check whether other large models are still loaded, free memory, or rerun the model individually."
        }

        if ($msg -match '(?i)requires more system memory|insufficient memory|out of memory|not enough memory') {
            $msg += " Memory-related Ollama failure detected. Try unloading other models, restarting Ollama, closing LM Studio, or benchmarking large models separately."
        }

        [pscustomobject]@{
            Provider     = "ollama"
            Model        = $Model
            Success      = $false
            ColdStart    = $ColdStart
            OutputText   = ""
            OutputTokens = 0
            PromptTokens = 0
            TotalMs      = [int]$sw.ElapsedMilliseconds
            LoadMs       = $null
            PromptEvalMs = $null
            TTFTMs       = $null
            TokensPerSec = 0.0
            Error        = $msg
            StartedAtMs  = $startedMs
            Raw          = $null
        }
    }
}

function Invoke-CmdCapture {
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 0
    )

    $tempOut = Join-Path $env:TEMP ("lms_cmd_out_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    $tempErr = Join-Path $env:TEMP ("lms_cmd_err_{0}.txt" -f [guid]::NewGuid().ToString("N"))

    try {
        $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/d", "/c", $Command `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr

        if ($TimeoutSec -gt 0) {
            $finished = $proc.WaitForExit($TimeoutSec * 1000)
            if (-not $finished) {
                try { $proc.Kill() } catch {}
                throw "Command timed out after $TimeoutSec seconds: $Command"
            }
        }

        $proc.WaitForExit()

        $stdout = ""
        $stderr = ""

        if (Test-Path -LiteralPath $tempOut) {
            $stdout = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $tempErr) {
            $stderr = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
        }

        $combined = @($stdout, $stderr) -join "`n"
        $combined = $combined.Trim()

        [pscustomobject]@{
            Output   = $combined
            StdOut   = $stdout
            StdErr   = $stderr
            ExitCode = [int]$proc.ExitCode
        }
    }
    finally {
        Remove-Item -LiteralPath $tempOut -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempErr -ErrorAction SilentlyContinue
    }
}

function Get-LmsModels {
    if (-not (Test-CommandExists -Name "lms")) {
        Write-Warning "The 'lms' command was not found in PATH."
        return @()
    }

    try {
        $result = Invoke-CmdCapture -Command 'lms ls --json'
        if ($result.ExitCode -ne 0) {
            throw "lms ls --json exited with code $($result.ExitCode). Output: $($result.Output)"
        }

        $parsed = $result.Output | ConvertFrom-Json

        if ($parsed -is [System.Array]) {
            $items = @($parsed)
        }
        elseif ($null -ne $parsed.models) {
            $items = @($parsed.models)
        }
        elseif ($null -ne $parsed.data) {
            $items = @($parsed.data)
        }
        else {
            $items = @($parsed)
        }

        $names = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            foreach ($prop in @("identifier", "modelKey", "key", "id", "name", "path")) {
                if ($item.PSObject.Properties.Name -contains $prop) {
                    $value = [string]$item.$prop
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        [void]$names.Add($value)
                        break
                    }
                }
            }
        }

        @(
            $names |
            Where-Object {
                $_ -and $_ -notmatch '(?i)(embed|embedding|bge|e5|nomic-embed|rerank|reranker)'
            } |
            Select-Object -Unique
        )
    }
    catch {
        Write-Warning "Could not query LM Studio models: $($_.Exception.Message)"
        @()
    }
}

function Invoke-LmsLoad {
    param([string]$Model)
    $escapedModel = $Model.Replace('"', '\"')
    Invoke-CmdCapture -Command "lms load `"$escapedModel`"" -TimeoutSec 60
}

function Invoke-LmsUnload {
    param([string]$Model)
    try {
        $escapedModel = $Model.Replace('"', '\"')
        [void](Invoke-CmdCapture -Command "lms unload `"$escapedModel`"" -TimeoutSec 30)
    }
    catch {}
}

function Parse-LmsStats {
    param(
        [string]$Text,
        [int]$FallbackTotalMs,
        [int]$FallbackOutputTokens
    )

    $tokensPerSec = $null
    $loadMs = $null
    $ttftMs = $null
    $promptEvalMs = $null
    $promptTokens = $null
    $predictedTokens = $null
    $totalTokens = $null

    if ($Text -match '(?i)Tokens\/Second:\s*([0-9]+(?:\.[0-9]+)?)') {
        $tokensPerSec = [double]$matches[1]
    }
    elseif ($Text -match '(?i)([0-9]+(?:\.[0-9]+)?)\s*(?:tokens\/s|tok\/s|t\/s)') {
        $tokensPerSec = [double]$matches[1]
    }

    if ($Text -match '(?i)Time to First Token:\s*([0-9]+(?:\.[0-9]+)?)s') {
        $ttftMs = [Math]::Round(([double]$matches[1]) * 1000.0, 2)
    }
    elseif ($Text -match '(?i)(ttft|first token)[^0-9]*([0-9]+(?:\.[0-9]+)?)\s*ms') {
        $ttftMs = [double]$matches[2]
    }

    if ($Text -match '(?i)Prompt Tokens:\s*([0-9]+)') {
        $promptTokens = [int]$matches[1]
    }

    if ($Text -match '(?i)Predicted Tokens:\s*([0-9]+)') {
        $predictedTokens = [int]$matches[1]
    }

    if ($Text -match '(?i)Total Tokens:\s*([0-9]+)') {
        $totalTokens = [int]$matches[1]
    }

    if ($Text -match '(?i)load[^0-9]*([0-9]+(?:\.[0-9]+)?)\s*ms') {
        $loadMs = [double]$matches[1]
    }

    if ($Text -match '(?i)prompt eval[^0-9]*([0-9]+(?:\.[0-9]+)?)\s*ms') {
        $promptEvalMs = [double]$matches[1]
    }

    if ($null -eq $tokensPerSec -and $FallbackTotalMs -gt 0) {
        $tokenBase = $FallbackOutputTokens
        if ($null -ne $predictedTokens -and $predictedTokens -gt 0) {
            $tokenBase = $predictedTokens
        }

        if ($tokenBase -gt 0) {
            $tokensPerSec = [Math]::Round(($tokenBase / ($FallbackTotalMs / 1000.0)), 2)
        }
    }

    [pscustomobject]@{
        TokensPerSec    = $tokensPerSec
        LoadMs          = $loadMs
        TTFTMs          = $ttftMs
        PromptEvalMs    = $promptEvalMs
        PromptTokens    = $promptTokens
        PredictedTokens = $predictedTokens
        TotalTokens     = $totalTokens
    }
}

function Invoke-LmsBenchmark {
    param(
        [string]$Model,
        [string]$Prompt,
        [int]$TimeoutSec,
        [bool]$ColdStart
    )

    if (-not (Test-CommandExists -Name "lms")) {
        throw "LM Studio CLI ('lms') was not found in PATH. Install LM Studio CLI or adjust PATH."
    }

    if ($ColdStart) {
        Invoke-LmsUnload -Model $Model
        Start-Sleep -Milliseconds 300
        [void](Invoke-LmsLoad -Model $Model)
        Start-Sleep -Milliseconds 500
    }

    $startedMs = Get-NowMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $escapedModel = $Model.Replace('"', '\"')
        $escapedPrompt = $Prompt.Replace('"', '\"')

        $result = Invoke-CmdCapture -Command "lms chat `"$escapedModel`" --prompt `"$escapedPrompt`" --stats" -TimeoutSec $TimeoutSec
        $sw.Stop()

        $fullText = $result.Output
        if ([string]::IsNullOrWhiteSpace($fullText)) {
            $fullText = "<no output captured>"
        }

        if ($result.ExitCode -ne 0) {
            throw "lms exited with code $($result.ExitCode). Output: $fullText"
        }

        $totalMs = [int]$sw.ElapsedMilliseconds

        $parts = $fullText -split '(?im)^\s*Prediction Stats:\s*$'
        if ($parts.Count -ge 2) {
            $responseText = Normalize-ModelOutput -Text (($parts[0]).Trim())
            $statsText = ($parts[1]).Trim()
        }
        else {
            $responseText = Normalize-ModelOutput -Text $fullText
            $statsText = $fullText
        }

        if ([string]::IsNullOrWhiteSpace($responseText)) {
            $responseText = Normalize-ModelOutput -Text $fullText
        }

        $outputTokens = Estimate-TokenCount -Text $responseText
        $stats = Parse-LmsStats -Text $statsText -FallbackTotalMs $totalMs -FallbackOutputTokens $outputTokens

        if ($null -ne $stats.PredictedTokens -and $stats.PredictedTokens -gt 0) {
            $outputTokens = $stats.PredictedTokens
        }

        [pscustomobject]@{
            Provider     = "lms"
            Model        = $Model
            Success      = $true
            ColdStart    = $ColdStart
            OutputText   = $responseText
            OutputTokens = $outputTokens
            PromptTokens = $stats.PromptTokens
            TotalMs      = $totalMs
            LoadMs       = $stats.LoadMs
            PromptEvalMs = $stats.PromptEvalMs
            TTFTMs       = $stats.TTFTMs
            TokensPerSec = $(if ($null -ne $stats.TokensPerSec) { [double]$stats.TokensPerSec } else { 0.0 })
            Error        = $null
            StartedAtMs  = $startedMs
            Raw          = $fullText
        }
    }
    catch {
        $sw.Stop()

        $msg = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = "Unknown LMS error."
        }

        if ($msg -match '(?i)timed out after') {
            $msg += " Possible causes: slow generation, model stall, or local CPU/GPU/memory pressure. Consider increasing -TimeoutSec, rerunning the model individually, or checking whether LM Studio is under heavy load."
        }

        if ($msg -match '(?i)out of memory|not enough memory|insufficient memory') {
            $msg += " Memory-related LM Studio failure detected. Try unloading other models, reducing concurrent runtime usage, or benchmarking large models separately."
        }

        [pscustomobject]@{
            Provider     = "lms"
            Model        = $Model
            Success      = $false
            ColdStart    = $ColdStart
            OutputText   = ""
            OutputTokens = 0
            PromptTokens = $null
            TotalMs      = [int]$sw.ElapsedMilliseconds
            LoadMs       = $null
            PromptEvalMs = $null
            TTFTMs       = $null
            TokensPerSec = 0.0
            Error        = $msg
            StartedAtMs  = $startedMs
            Raw          = $null
        }
    }
}

function New-MarkdownReport {
    param(
        [string]$Path,
        $SystemInfo,
        [string]$Provider,
        [int]$Repeats,
        [bool]$IncludeQuality,
        [int]$PromptCount,
        $Leaderboard
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("# Local LLM Benchmark Summary")
    $lines.Add("")
    $lines.Add(("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
    $lines.Add(("Provider: {0}" -f $Provider))
    $lines.Add(("Warm repeats: {0}" -f $Repeats))
    $lines.Add(("Prompt count: {0}" -f $PromptCount))
    $lines.Add("")

    $lines.Add("## System")
    $lines.Add("")
    if ($null -ne $SystemInfo) {
        if ($SystemInfo.CpuName) {
            $lines.Add(("- CPU: {0} ({1}C/{2}T)" -f $SystemInfo.CpuName, $SystemInfo.CpuCores, $SystemInfo.CpuLogicalProcessors))
        }
        if ($null -ne $SystemInfo.InstalledRamGB) {
            $lines.Add(("- Installed RAM: {0} GB" -f $SystemInfo.InstalledRamGB))
        }
        if ($null -ne $SystemInfo.UsableRamGB) {
            $lines.Add(("- Usable RAM: {0} GB" -f $SystemInfo.UsableRamGB))
        }
        if ($SystemInfo.OsCaption) {
            $lines.Add(("- OS: {0} {1} (Build {2})" -f $SystemInfo.OsCaption, $SystemInfo.OsVersion, $SystemInfo.OsBuild))
        }
        foreach ($gpu in @($SystemInfo.Gpus)) {
            $gpuLine = "- GPU: $($gpu.Name)"
            if ($null -ne $gpu.DedicatedVRAMGB) {
                $gpuLine += " | Dedicated VRAM: $($gpu.DedicatedVRAMGB) GB"
            }
            if ($null -ne $gpu.SharedVRAMGB) {
                $gpuLine += " | Shared VRAM: $($gpu.SharedVRAMGB) GB"
            }
            $lines.Add($gpuLine)
        }
    }
    $lines.Add("")

    if ($null -ne $Leaderboard -and $Leaderboard.Count -gt 0) {
        $lines.Add("## Leaderboard")
        $lines.Add("")
        $lines.Add("| Rank | Provider | Model | ModelGB | Params | Quant | OverallScore | SpeedScore | AvgQualityScore | SuccessRate |")
        $lines.Add("|---:|---|---|---:|---|---|---:|---:|---:|---:|")

        $rank = 1
        foreach ($row in $Leaderboard) {
          $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |" -f `
            $rank,
            $row.Provider,
            $row.Model,
            $(if ($null -ne $row.ModelSizeGB) { "{0:F2}" -f [double]$row.ModelSizeGB } else { "n/a" }),
            $(if (-not [string]::IsNullOrWhiteSpace($row.Params)) { $row.Params } else { "n/a" }),
            $(if (-not [string]::IsNullOrWhiteSpace($row.Quantization)) { $row.Quantization } else { "n/a" }),
            $(if ($null -ne $row.OverallScore) { "{0:F2}" -f [double]$row.OverallScore } else { "n/a" }),
            $(if ($null -ne $row.SpeedScore) { "{0:F2}" -f [double]$row.SpeedScore } else { "n/a" }),
            $(if ($null -ne $row.AvgQualityScore) { "{0:F2}" -f [double]$row.AvgQualityScore } else { "n/a" }),
            $(if ($null -ne $row.SuccessRate) { "{0:F2}" -f [double]$row.SuccessRate } else { "n/a" })))
            $rank++
        }

        $lines.Add("")
        $lines.Add("> **Note:** ModelGB is the approximate on-disk model size reported by the local runtime. Larger models will often be slower on the same hardware, and quantization can also materially affect speed and quality.")
         
        $lines.Add("")
        $lines.Add("## Performance")
        $lines.Add("")
        $lines.Add("| Provider | Model | ModelGB | Params | Quant | InitialLoadMs | InitialTotalMs | WarmAvgTotalMs | WarmAvgTokensPerSec |")
        $lines.Add("|---|---|---:|---|---|---:|---:|---:|---:|")
        foreach ($row in $Leaderboard) {
            $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
                $row.Provider,
                $row.Model,
                $(if ($null -ne $row.ModelSizeGB) { "{0:F2}" -f [double]$row.ModelSizeGB } else { "n/a" }),
                $(if (-not [string]::IsNullOrWhiteSpace($row.Params)) { $row.Params } else { "n/a" }),
                $(if (-not [string]::IsNullOrWhiteSpace($row.Quantization)) { $row.Quantization } else { "n/a" }),
                $(if ($null -ne $row.InitialLoadMs) { "{0:F2}" -f [double]$row.InitialLoadMs } else { "n/a" }),
                $(if ($null -ne $row.InitialTotalMs) { "{0:F2}" -f [double]$row.InitialTotalMs } else { "n/a" }),
                $(if ($null -ne $row.WarmAvgTotalMs) { "{0:F2}" -f [double]$row.WarmAvgTotalMs } else { "n/a" }),
                $(if ($null -ne $row.WarmAvgTokensPerSec) { "{0:F2}" -f [double]$row.WarmAvgTokensPerSec } else { "n/a" })))
        }

        $lines.Add("")
        $lines.Add("## Quality Breakdown")
        $lines.Add("")
        $lines.Add("| Provider | Model | AvgQualityScore | ReasoningScore | JsonScore | CodingScore | InstructionScore | SummarizationScore |")
        $lines.Add("|---|---|---:|---:|---:|---:|---:|---:|")
        foreach ($row in $Leaderboard) {
            $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f `
                $row.Provider,
                $row.Model,
                $(if ($null -ne $row.AvgQualityScore) { "{0:F2}" -f [double]$row.AvgQualityScore } else { "n/a" }),
                $(if ($null -ne $row.ReasoningScore) { "{0:F2}" -f [double]$row.ReasoningScore } else { "n/a" }),
                $(if ($null -ne $row.JsonScore) { "{0:F2}" -f [double]$row.JsonScore } else { "n/a" }),
                $(if ($null -ne $row.CodingScore) { "{0:F2}" -f [double]$row.CodingScore } else { "n/a" }),
                $(if ($null -ne $row.InstructionScore) { "{0:F2}" -f [double]$row.InstructionScore } else { "n/a" }),
                $(if ($null -ne $row.SummarizationScore) { "{0:F2}" -f [double]$row.SummarizationScore } else { "n/a" })))
        }

        $lines.Add("")
        $bestOverall = $Leaderboard[0]
        $fastest = $Leaderboard | Sort-Object WarmAvgTokensPerSec -Descending | Select-Object -First 1
        $bestQuality = $Leaderboard | Sort-Object AvgQualityScore -Descending | Select-Object -First 1

        $lines.Add("## Highlights")
        $lines.Add("")
        $lines.Add(("- Best overall: **{0} / {1}** (OverallScore {2})" -f $bestOverall.Provider, $bestOverall.Model, ("{0:F2}" -f [double]$bestOverall.OverallScore)))
        $lines.Add(("- Fastest warm model: **{0} / {1}** ({2} tokens/sec)" -f $fastest.Provider, $fastest.Model, ("{0:F2}" -f [double]$fastest.WarmAvgTokensPerSec)))
        $lines.Add(("- Highest quality model: **{0} / {1}** (AvgQualityScore {2})" -f $bestQuality.Provider, $bestQuality.Model, ("{0:F2}" -f [double]$bestQuality.AvgQualityScore)))
    }

    Set-Content -LiteralPath $Path -Value ($lines -join "`r`n") -Encoding UTF8
}

function Convert-BytesToGB {
    param(
        [Nullable[double]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes -le 0) {
        return $null
    }

    return [Math]::Round(($Bytes / 1000000000.0), 2)
}

function Get-OllamaModelMetadata {
    param(
        [string]$BaseUrl
    )

    $map = @{}

    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -Method Get -TimeoutSec 10

        foreach ($m in @($resp.models)) {
            $sizeBytes = $null
            if ($null -ne $m.size) {
                $sizeBytes = [double]$m.size
            }

            $params = $null
            $quant = $null

            if ($null -ne $m.details) {
                if ($null -ne $m.details.parameter_size) {
                    $params = [string]$m.details.parameter_size
                }
                if ($null -ne $m.details.quantization_level) {
                    $quant = [string]$m.details.quantization_level
                }
            }

            $key = "ollama|$($m.name)"
            $map[$key] = [pscustomobject]@{
                Provider       = "ollama"
                Model          = [string]$m.name
                ModelSizeBytes = $sizeBytes
                ModelSizeGB    = Convert-BytesToGB -Bytes $sizeBytes
                Params         = $params
                Quantization   = $quant
            }
        }
    }
    catch {
        Write-Warning "Could not query Ollama model metadata: $($_.Exception.Message)"
    }

    return $map
}

function Get-LmsModelMetadata {
    $map = @{}

    if (-not (Test-CommandExists -Name "lms")) {
        return $map
    }

    try {
        $result = Invoke-CmdCapture -Command 'lms ls --json'
        if ($result.ExitCode -ne 0) {
            throw "lms ls --json exited with code $($result.ExitCode). Output: $($result.Output)"
        }

        $parsed = $result.Output | ConvertFrom-Json

        if ($parsed -is [System.Array]) {
            $items = @($parsed)
        }
        elseif ($null -ne $parsed.models) {
            $items = @($parsed.models)
        }
        elseif ($null -ne $parsed.data) {
            $items = @($parsed.data)
        }
        else {
            $items = @($parsed)
        }

        foreach ($m in $items) {
            if ([string]$m.type -ne "llm") {
                continue
            }

            $modelName = $null
            foreach ($prop in @("modelKey", "identifier", "key", "id", "name", "path")) {
                if ($m.PSObject.Properties.Name -contains $prop) {
                    $value = [string]$m.$prop
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $modelName = $value
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($modelName)) {
                continue
            }

            $sizeBytes = $null
            if ($m.PSObject.Properties.Name -contains "sizeBytes" -and $null -ne $m.sizeBytes) {
                $sizeBytes = [double]$m.sizeBytes
            }

            $params = $null
            if ($m.PSObject.Properties.Name -contains "paramsString" -and $null -ne $m.paramsString) {
                $params = [string]$m.paramsString
            }

            $quant = $null
            if ($null -ne $m.quantization -and $m.quantization.PSObject.Properties.Name -contains "name" -and $null -ne $m.quantization.name) {
                $quant = [string]$m.quantization.name
            }

            $key = "lms|$modelName"
            $map[$key] = [pscustomobject]@{
                Provider       = "lms"
                Model          = $modelName
                ModelSizeBytes = $sizeBytes
                ModelSizeGB    = Convert-BytesToGB -Bytes $sizeBytes
                Params         = $params
                Quantization   = $quant
            }
        }
    }
    catch {
        Write-Warning "Could not query LM Studio model metadata: $($_.Exception.Message)"
    }

    return $map
}

$systemInfo = Get-SystemInfo

if ($Provider -eq "ollama" -or $Provider -eq "all") {
    if (-not (Test-OllamaAvailable -BaseUrl $OllamaBaseUrl)) {
        if ($Provider -eq "ollama") {
            throw "Ollama is not reachable at $OllamaBaseUrl. Ensure Ollama is installed and running."
        }
        else {
            Write-Warning "Ollama is not reachable at $OllamaBaseUrl. Ollama benchmarks may fail or no Ollama models may be detected."
        }
    }
}

if ($Provider -eq "lms" -or $Provider -eq "all") {
    if (-not (Test-CommandExists -Name "lms")) {
        if ($Provider -eq "lms") {
            throw "LM Studio CLI ('lms') was not found in PATH. Install LM Studio CLI or adjust PATH."
        }
        else {
            Write-Warning "LM Studio CLI ('lms') was not found in PATH. LM Studio benchmarks may fail or no LMS models may be detected."
        }
    }
}

if (($Provider -eq "ollama" -or $Provider -eq "all") -and $OllamaModels.Count -eq 0 -and $AutoDetectOllamaModels) {
    $OllamaModels = @(Get-InstalledOllamaModels -BaseUrl $OllamaBaseUrl)
    if ($OllamaModels.Count -gt 0) {
        Write-Host "Auto-detected Ollama models:" -ForegroundColor Green
        $OllamaModels | ForEach-Object { Write-Host "  $_" }
    }
}

if (($Provider -eq "lms" -or $Provider -eq "all") -and $LmsModels.Count -eq 0 -and $AutoDetectLmsModels) {
    $LmsModels = @(Get-LmsModels)
    if ($LmsModels.Count -gt 0) {
        Write-Host "Auto-detected LM Studio models:" -ForegroundColor Green
        $LmsModels | ForEach-Object { Write-Host "  $_" }
    }
}

if ($Provider -eq "ollama" -and $OllamaModels.Count -eq 0) {
    throw "No Ollama models supplied or detected. Pass -OllamaModels or use -AutoDetectOllamaModels."
}
if ($Provider -eq "lms" -and $LmsModels.Count -eq 0) {
    throw "No LM Studio models supplied or detected. Pass -LmsModels or use -AutoDetectLmsModels."
}
if ($Provider -eq "all" -and $OllamaModels.Count -eq 0 -and $LmsModels.Count -eq 0) {
    throw "No models supplied or detected for either provider."
}

$modelMetadataMap = @{}

if ($Provider -eq "ollama" -or $Provider -eq "all") {
    $ollamaMeta = Get-OllamaModelMetadata -BaseUrl $OllamaBaseUrl
    foreach ($k in $ollamaMeta.Keys) {
        $modelMetadataMap[$k] = $ollamaMeta[$k]
    }
}

if ($Provider -eq "lms" -or $Provider -eq "all") {
    $lmsMeta = Get-LmsModelMetadata
    foreach ($k in $lmsMeta.Keys) {
        $modelMetadataMap[$k] = $lmsMeta[$k]
    }
}

Show-StartupBanner `
    -Provider $Provider `
    -OllamaModels $OllamaModels `
    -LmsModels $LmsModels `
    -Repeats $Repeats `
    -OutputDir $OutputDir `
    -OllamaBaseUrl $OllamaBaseUrl `
    -PromptCount $PromptSuite.Count `
    -SystemInfo $systemInfo

$results = New-Object System.Collections.Generic.List[object]

function Add-BenchmarkRows {
    param(
        [string]$ProviderName,
        [string]$Model,
        [scriptblock]$InvokeFn
    )

    Write-Host ("Measuring initial cold start provider={0} model={1}" -f $ProviderName, $Model) -ForegroundColor Magenta

    $coldPrompt = "Say hello in one short sentence."
    $coldResult = & $InvokeFn $Model $coldPrompt $true

    $metaKey = "$ProviderName|$Model"
    $meta = $null
    if ($null -ne $modelMetadataMap -and $modelMetadataMap.ContainsKey($metaKey)) {
        $meta = $modelMetadataMap[$metaKey]
    }

    $runTimestampUtc = Get-NowIsoUtc

    $results.Add([pscustomobject]@{
            RunTimestampUtc = $runTimestampUtc
            TestId         = "__startup__"
            Category       = "startup"
            Repeat         = 0
            Provider       = $coldResult.Provider
            Model          = $coldResult.Model
            ModelSizeBytes = $(if ($null -ne $meta) { $meta.ModelSizeBytes } else { $null })
            ModelSizeGB    = $(if ($null -ne $meta) { $meta.ModelSizeGB } else { $null })
            Params         = $(if ($null -ne $meta) { $meta.Params } else { $null })
            Quantization   = $(if ($null -ne $meta) { $meta.Quantization } else { $null })
            Success        = $coldResult.Success
            ColdStart      = $true
            TotalMs        = $coldResult.TotalMs
            LoadMs         = $coldResult.LoadMs
            PromptEvalMs   = $coldResult.PromptEvalMs
            TTFTMs         = $coldResult.TTFTMs
            PromptTokens   = $coldResult.PromptTokens
            OutputTokens   = $coldResult.OutputTokens
            TokensPerSec   = $coldResult.TokensPerSec
            QualityScore   = $null
            Error          = $coldResult.Error
            OutputText     = $coldResult.OutputText
        })

    foreach ($test in $PromptSuite) {
        for ($i = 1; $i -le $Repeats; $i++) {
            Write-Host ("Running provider={0} model={1} test={2} warmRepeat={3}" -f $ProviderName, $Model, $test.Id, $i) -ForegroundColor Cyan

            $r = & $InvokeFn $Model $test.Prompt $false

            $quality = Get-QualityScore -Text $r.OutputText -Test $test

            $runTimestampUtc = Get-NowIsoUtc

            $results.Add([pscustomobject]@{
                    RunTimestampUtc = $runTimestampUtc
                    TestId         = $test.Id
                    Category       = $test.Category
                    Repeat         = $i
                    Provider       = $r.Provider
                    Model          = $r.Model
                    ModelSizeBytes = $(if ($null -ne $meta) { $meta.ModelSizeBytes } else { $null })
                    ModelSizeGB    = $(if ($null -ne $meta) { $meta.ModelSizeGB } else { $null })
                    Params         = $(if ($null -ne $meta) { $meta.Params } else { $null })
                    Quantization   = $(if ($null -ne $meta) { $meta.Quantization } else { $null })
                    Success        = $r.Success
                    ColdStart      = $false
                    TotalMs        = $r.TotalMs
                    LoadMs         = $r.LoadMs
                    PromptEvalMs   = $r.PromptEvalMs
                    TTFTMs         = $r.TTFTMs
                    PromptTokens   = $r.PromptTokens
                    OutputTokens   = $r.OutputTokens
                    TokensPerSec   = $r.TokensPerSec
                    QualityScore   = $quality
                    Error          = $r.Error
                    OutputText     = $r.OutputText
                })
        }
    }
}

if ($Provider -eq "ollama" -or $Provider -eq "all") {
    foreach ($model in $OllamaModels) {
        Add-BenchmarkRows -ProviderName "ollama" -Model $model -InvokeFn {
            param($m, $p, $c)
            Invoke-OllamaBenchmark -BaseUrl $OllamaBaseUrl -Model $m -Prompt $p -TimeoutSec $TimeoutSec -ColdStart $c
        }
        Write-Host ("Releasing Ollama model from memory: {0}" -f $model) -ForegroundColor DarkGray
        Invoke-OllamaUnload -BaseUrl $OllamaBaseUrl -Model $model
    }
}

if ($Provider -eq "lms" -or $Provider -eq "all") {
    foreach ($model in $LmsModels) {
        Add-BenchmarkRows -ProviderName "lms" -Model $model -InvokeFn {
            param($m, $p, $c)
            Invoke-LmsBenchmark -Model $m -Prompt $p -TimeoutSec $TimeoutSec -ColdStart $c
        }
        Write-Host ("Releasing LM Studio model from memory: {0}" -f $model) -ForegroundColor DarkGray
        Invoke-LmsUnload -Model $model
    }
}

$rawJson = Join-Path $OutputDir "raw-results.json"
$rawCsv = Join-Path $OutputDir "raw-results.csv"
$leaderboardCsv = Join-Path $OutputDir "leaderboard.csv"
$failuresCsv = Join-Path $OutputDir "failures.csv"
$systemInfoJson = Join-Path $OutputDir "system-info.json"
$summaryReportMd = Join-Path $OutputDir "summary-report.md"

$results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rawJson -Encoding UTF8
$results | Export-Csv -Path $rawCsv -NoTypeInformation -Encoding UTF8
$systemInfo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $systemInfoJson -Encoding UTF8

$failed = @($results | Where-Object { $_.Success -eq $false })
if ($failed.Count -gt 0) {
     $failed |
     Select-Object RunTimestampUtc, Provider, Model, TestId, Repeat, Error |
     Export-Csv -Path $failuresCsv -NoTypeInformation -Encoding UTF8
}

$grouped = $results | Group-Object Provider, Model

$summary = foreach ($g in $grouped) {
    $items = @($g.Group)
    $startup = @($items | Where-Object { $_.TestId -eq "__startup__" -and $_.Success -eq $true })
    $warm = @($items | Where-Object { $_.TestId -ne "__startup__" -and $_.Success -eq $true })

    $successRate = [Math]::Round(((@($items | Where-Object { $_.Success -eq $true }).Count / $items.Count) * 100), 2)

    $initialLoadMs = $null
    $initialTotalMs = $null
    if ($startup.Count -gt 0) {
        $initialLoadMs = $startup[0].LoadMs
        $initialTotalMs = $startup[0].TotalMs
    }

    $warmAvgTotalMs = $null
    if ($warm.Count -gt 0) {
        $warmAvgTotalMs = [Math]::Round((($warm | Measure-Object -Property TotalMs -Average).Average), 2)
    }

    $warmLoadItems = @($warm | Where-Object { $null -ne $_.LoadMs })
    $warmAvgLoadMs = $null
    if ($warmLoadItems.Count -gt 0) {
        $warmAvgLoadMs = [Math]::Round((($warmLoadItems | Measure-Object -Property LoadMs -Average).Average), 2)
    }

    $warmTpsItems = @($warm | Where-Object { $null -ne $_.TokensPerSec })
    $warmAvgTps = 0.0
    if ($warmTpsItems.Count -gt 0) {
        $warmAvgTps = [Math]::Round((($warmTpsItems | Measure-Object -Property TokensPerSec -Average).Average), 2)
    }

    $qualityItems = @($warm | Where-Object { $null -ne $_.QualityScore })
    $avgQuality = $null
    if ($qualityItems.Count -gt 0) {
        $avgQuality = [Math]::Round((($qualityItems | Measure-Object -Property QualityScore -Average).Average), 2)
    }

    $reasoningItems = @($warm | Where-Object { $_.Category -eq "reasoning" -and $null -ne $_.QualityScore })
    $jsonItems = @($warm | Where-Object { $_.Category -eq "json" -and $null -ne $_.QualityScore })
    $codingItems = @($warm | Where-Object { $_.Category -eq "coding" -and $null -ne $_.QualityScore })
    $instructionItems = @($warm | Where-Object { $_.Category -eq "instruction" -and $null -ne $_.QualityScore })
    $summarizationItems = @($warm | Where-Object { $_.Category -eq "summarization" -and $null -ne $_.QualityScore })

    $reasoningScore = if ($reasoningItems.Count -gt 0) { [Math]::Round((($reasoningItems | Measure-Object -Property QualityScore -Average).Average), 2) } else { $null }
    $jsonScore = if ($jsonItems.Count -gt 0) { [Math]::Round((($jsonItems | Measure-Object -Property QualityScore -Average).Average), 2) } else { $null }
    $codingScore = if ($codingItems.Count -gt 0) { [Math]::Round((($codingItems | Measure-Object -Property QualityScore -Average).Average), 2) } else { $null }
    $instructionScore = if ($instructionItems.Count -gt 0) { [Math]::Round((($instructionItems | Measure-Object -Property QualityScore -Average).Average), 2) } else { $null }
    $summarizationScore = if ($summarizationItems.Count -gt 0) { [Math]::Round((($summarizationItems | Measure-Object -Property QualityScore -Average).Average), 2) } else { $null }

    [pscustomobject]@{
        Provider            = $items[0].Provider
        Model               = $items[0].Model
        ModelSizeBytes      = $items[0].ModelSizeBytes
        ModelSizeGB         = $items[0].ModelSizeGB
        Params              = $items[0].Params
        Quantization        = $items[0].Quantization
        SuccessRate         = $successRate
        InitialLoadMs       = $initialLoadMs
        InitialTotalMs      = $initialTotalMs
        WarmAvgTotalMs      = $warmAvgTotalMs
        WarmAvgLoadMs       = $warmAvgLoadMs
        WarmAvgTokensPerSec = $warmAvgTps
        AvgQualityScore     = $avgQuality
        ReasoningScore      = $reasoningScore
        JsonScore           = $jsonScore
        CodingScore         = $codingScore
        InstructionScore    = $instructionScore
        SummarizationScore  = $summarizationScore
    }
}

$summary = @($summary | Where-Object { $_.SuccessRate -gt 0 })

$leaderboard = @()

if ($summary.Count -gt 0) {
    $minTps = ($summary | Measure-Object -Property WarmAvgTokensPerSec -Minimum).Minimum
    $maxTps = ($summary | Measure-Object -Property WarmAvgTokensPerSec -Maximum).Maximum

    $latencyCandidates = @($summary | Where-Object { $null -ne $_.WarmAvgTotalMs })
    $minWarmTotal = if ($latencyCandidates.Count -gt 0) { ($latencyCandidates | Measure-Object -Property WarmAvgTotalMs -Minimum).Minimum } else { 0 }
    $maxWarmTotal = if ($latencyCandidates.Count -gt 0) { ($latencyCandidates | Measure-Object -Property WarmAvgTotalMs -Maximum).Maximum } else { 1 }

    $coldCandidates = @($summary | Where-Object { $null -ne $_.InitialTotalMs })
    $minInitialTotal = if ($coldCandidates.Count -gt 0) { ($coldCandidates | Measure-Object -Property InitialTotalMs -Minimum).Minimum } else { 0 }
    $maxInitialTotal = if ($coldCandidates.Count -gt 0) { ($coldCandidates | Measure-Object -Property InitialTotalMs -Maximum).Maximum } else { 1 }

    foreach ($s in $summary) {
        $throughputScore = Normalize-Score -Value $s.WarmAvgTokensPerSec -Min $minTps -Max $maxTps

        $warmLatencyScore = 50.0
        if ($null -ne $s.WarmAvgTotalMs) {
            $warmLatencyScore = Normalize-Score -Value $s.WarmAvgTotalMs -Min $minWarmTotal -Max $maxWarmTotal -Reverse
        }

        $startupScore = 50.0
        if ($null -ne $s.InitialTotalMs) {
            $startupScore = Normalize-Score -Value $s.InitialTotalMs -Min $minInitialTotal -Max $maxInitialTotal -Reverse
        }

        $qualityScore = [double]$s.AvgQualityScore
        $reliabilityScore = [double]$s.SuccessRate

        $speedScore = [Math]::Round((0.50 * $throughputScore) + (0.30 * $warmLatencyScore) + (0.20 * $startupScore), 2)
        $overallScore = [Math]::Round((0.55 * $qualityScore) + (0.30 * $speedScore) + (0.15 * $reliabilityScore), 2)
      
        $leaderboard += [pscustomobject]@{
            Provider            = $s.Provider
            Model               = $s.Model
            ModelSizeGB         = $s.ModelSizeGB
            Params              = $s.Params
            Quantization        = $s.Quantization
            InitialLoadMs       = $s.InitialLoadMs
            InitialTotalMs      = $s.InitialTotalMs
            WarmAvgTotalMs      = $s.WarmAvgTotalMs
            WarmAvgTokensPerSec = $s.WarmAvgTokensPerSec
            SuccessRate         = $s.SuccessRate
            AvgQualityScore     = $qualityScore
            ReasoningScore      = $s.ReasoningScore
            JsonScore           = $s.JsonScore
            CodingScore         = $s.CodingScore
            InstructionScore    = $s.InstructionScore
            SummarizationScore  = $s.SummarizationScore
            SpeedScore          = $speedScore
            ReliabilityScore    = $reliabilityScore
            OverallScore        = $overallScore
        }
    }
}

$leaderboard = @($leaderboard | Sort-Object -Property OverallScore -Descending)
$leaderboard | Export-Csv -Path $leaderboardCsv -NoTypeInformation -Encoding UTF8

New-MarkdownReport `
    -Path $summaryReportMd `
    -SystemInfo $systemInfo `
    -Provider $Provider `
    -Repeats $Repeats `
    -PromptCount $PromptSuite.Count `
    -Leaderboard $leaderboard

Write-Host ""
Write-Host "Performance Summary:" -ForegroundColor Green
if ($leaderboard.Count -gt 0) {
    $leaderboard |
    Select-Object `
        Provider,
    Model,
    @{ Name = "ModelGB"; Expression = { if ($null -ne $_.ModelSizeGB) { $_.ModelSizeGB } else { "n/a" } } },
    @{ Name = "Params"; Expression = { if (-not [string]::IsNullOrWhiteSpace($_.Params)) { $_.Params } else { "n/a" } } },
    @{ Name = "Quantization"; Expression = { if (-not [string]::IsNullOrWhiteSpace($_.Quantization)) { $_.Quantization } else { "n/a" } } },
    @{ Name = "InitialLoadMs"; Expression = { if ($null -ne $_.InitialLoadMs) { $_.InitialLoadMs } else { "n/a" } } },
    InitialTotalMs,
    WarmAvgTotalMs,
    WarmAvgTokensPerSec,
    SuccessRate,
    SpeedScore,
    OverallScore |
    Format-Table -AutoSize
}
else {
    Write-Host "No leaderboard rows generated."
}

Write-Host ""
Write-Host "Quality Breakdown:" -ForegroundColor Green
if ($leaderboard.Count -gt 0) {
    $leaderboard |
    Select-Object Provider, Model, AvgQualityScore, ReasoningScore, JsonScore, CodingScore, InstructionScore, SummarizationScore |
    Format-Table -AutoSize
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Yellow
    $failed |
    Select-Object Provider, Model, TestId, Repeat, Error |
    Format-Table -AutoSize
}

Write-Host ""
Write-Host "Saved files:" -ForegroundColor Green
Write-Host "  $rawJson"
Write-Host "  $rawCsv"
Write-Host "  $leaderboardCsv"
Write-Host "  $systemInfoJson"
Write-Host "  $summaryReportMd"
if ($failed.Count -gt 0) {
    Write-Host "  $failuresCsv"
}

Import-Csv $leaderboardCsv |
    ForEach-Object {
        [pscustomobject]@{
            Provider             = $_.Provider
            Model                = $_.Model
            ModelSizeGB          = if ($_.ModelSizeGB) { [double]$_.ModelSizeGB } else { $null }
            Params               = $_.Params
            Quantization         = $_.Quantization
            InitialLoadMs        = if ($_.InitialLoadMs -and $_.InitialLoadMs -ne 'n/a') { [double]$_.InitialLoadMs } else { $null }
            InitialTotalMs       = if ($_.InitialTotalMs) { [double]$_.InitialTotalMs } else { $null }
            WarmAvgTotalMs       = if ($_.WarmAvgTotalMs) { [double]$_.WarmAvgTotalMs } else { $null }
            WarmAvgTokensPerSec  = if ($_.WarmAvgTokensPerSec) { [double]$_.WarmAvgTokensPerSec } else { $null }
            SuccessRate          = if ($_.SuccessRate) { [double]$_.SuccessRate } else { $null }
            AvgQualityScore      = if ($_.AvgQualityScore) { [double]$_.AvgQualityScore } else { $null }
            ReasoningScore       = if ($_.ReasoningScore) { [double]$_.ReasoningScore } else { $null }
            JsonScore            = if ($_.JsonScore) { [double]$_.JsonScore } else { $null }
            CodingScore          = if ($_.CodingScore) { [double]$_.CodingScore } else { $null }
            InstructionScore     = if ($_.InstructionScore) { [double]$_.InstructionScore } else { $null }
            SummarizationScore   = if ($_.SummarizationScore) { [double]$_.SummarizationScore } else { $null }
            SpeedScore           = if ($_.SpeedScore) { [double]$_.SpeedScore } else { $null }
            ReliabilityScore     = if ($_.ReliabilityScore) { [double]$_.ReliabilityScore } else { $null }
            OverallScore         = if ($_.OverallScore) { [double]$_.OverallScore } else { $null }
        }
    } |
    Sort-Object OverallScore -Descending |
    Out-GridView -Title "Benchmark Leaderboard"
