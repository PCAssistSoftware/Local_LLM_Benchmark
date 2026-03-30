# Local LLM Benchmark

Benchmarks local language models using:

- Ollama HTTP API
- LM Studio CLI (`lms`)

It runs one cold-start measurement per model, then runs a warm prompt suite and produces:

- `raw-results.json`
- `raw-results.csv`
- `leaderboard.csv`
- `failures.csv` (only when failures occur)
- `system-info.json`
- `summary-report.md`

## What it measures

For each model, the benchmark records:

- `SuccessRate`
- `InitialLoadMs` (when exposed by the runtime)
- `InitialTotalMs`
- `WarmAvgTotalMs`
- `WarmAvgTokensPerSec`
- `AvgQualityScore`
- category quality scores
- model metadata such as `ModelGB`, `Params`, and `Quantization`

## Prompt categories

The benchmark currently includes prompts for:

- reasoning
- JSON formatting
- coding
- instruction following
- summarization

## Quality scoring

Each warm prompt gets a `QualityScore` based on its scoring rule:

- `exact`  
  Exact string match. Partial containment may receive partial credit.

- `contains_all`  
  Score is based on how many required terms appear in the output.

- `json_keys`  
  Partial credit for required keys being present, plus additional credit for expected values.

- `python_is_even`  
  Heuristic check for a correct Python `is_even(n)` function.

- `js_clamp`  
  Heuristic check for a correct JavaScript `clamp(value, min, max)` function.

`AvgQualityScore` is the average of all warm prompt quality scores for a model.

## Scoring formula

### SpeedScore

`SpeedScore` is a weighted combination of normalized performance metrics:

- 50% warm tokens/sec
- 30% warm latency
- 20% startup latency

### OverallScore

`OverallScore` is a weighted combination of:

- 55% `AvgQualityScore`
- 30% `SpeedScore`
- 15% `SuccessRate`

This means `AvgQualityScore` reflects answer quality only, while `OverallScore` reflects overall usefulness across quality, speed, and reliability.

## Notes

- `ModelGB` is approximate on-disk model size reported by the local runtime.
- Some runtimes may not expose all metrics. For example, LM Studio runs may show `InitialLoadMs` as `n/a`.
- Results can vary slightly between runs.

## Example usage

### LM Studio only
```powershell
.\benchmark-local-llms.ps1 -Provider lms -AutoDetectLmsModels -Repeats 2 -OutputDir .\results-lms
```

### Ollama only
```powershell
.\benchmark-local-llms.ps1 -Provider ollama -AutoDetectOllamaModels -Repeats 2 -OutputDir .\results-ollama
```

### Both providers
```powershell
.\benchmark-local-llms.ps1 -Provider all -AutoDetectOllamaModels -AutoDetectLmsModels -Repeats 2 -OutputDir .\results-all
```

## Viewing results in GridView

Replace `.\results\` below with the output directory you used, for example `.\results-lms\`, `.\results-ollama\`, or `.\results-all\`.

### Leaderboard 
```powershell
Import-Csv .\results\leaderboard.csv | Out-GridView -Title "Leaderboard"
```

### Leaderboard with all columns sortable
```powershell
Import-Csv .\results-all\leaderboard.csv |
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
    Out-GridView -Title "Leaderboard"
```

### Leaderboard by overall score
```powershell
Import-Csv .\results\leaderboard.csv |
    Sort-Object {[double]$_.OverallScore} -Descending |
    Out-GridView -Title "Leaderboard by OverallScore"
```

### Leaderboard by average quality
```powershell
Import-Csv .\results\leaderboard.csv |
    Sort-Object {[double]$_.AvgQualityScore} -Descending |
    Out-GridView -Title "Leaderboard by AvgQualityScore"
```

### Raw results sorted by time
```powershell
Import-Csv .\results\raw-results.csv |
    Sort-Object RunTimestampUtc -Descending |
    Out-GridView -Title "Raw Results by Time"
```

## Raw results fields

Raw results include a `RunTimestampUtc` field in ISO UTC format:

- example: `2026-03-30T18:42:15Z`

This makes it easy to sort and compare benchmark rows over time.
