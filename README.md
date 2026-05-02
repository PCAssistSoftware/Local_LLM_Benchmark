# Local LLM Benchmark

Benchmarks local language models using:

- Ollama HTTP API (`/api/generate`)
- LM Studio REST API (`/v1/chat/completions`); `lms` CLI used only for model load/unload

It runs one cold-start measurement per model, then runs a warm prompt suite and produces:

- `raw-results.json`
- `raw-results.csv`
- `leaderboard.csv`
- `failures.csv` (only when failures occur)
- `system-info.json`
- `summary-report.md`

## Prompt categories

The benchmark currently includes 15 warm prompts total:

- 3 reasoning
- 3 JSON formatting
- 3 coding
- 3 instruction-following
- 3 summarization

## Result columns

### Model metadata

| Column | Description |
|---|---|
| `Provider` | Runtime used: `ollama` or `lms` |
| `Model` | Model name as reported by the runtime |
| `ModelSizeGB` | Approximate on-disk model size reported by the runtime |
| `Params` | Parameter count (e.g. `7B`, `30.5B`) |
| `Quantization` | Quantization format (e.g. `Q4_K_M`, `MXFP4`) |

### Performance metrics

| Column | Description |
|---|---|
| `InitialLoadMs` | Time for the model weights to load into memory during the cold-start call, as reported by Ollama's `load_duration`. Shown as `n/a` for LM Studio, which does not expose this separately. |
| `InitialTotalMs` | Total wall-clock time for the cold-start call, from request sent to response received. Includes load time, prompt evaluation, and generation. For LM Studio this is the only cold-start timing available. |
| `WarmAvgTotalMs` | Average total latency per warm prompt run (ms). |
| `WarmAvgTokensPerSec` | Average generation throughput across all warm runs (tokens/sec). |

### Quality scores

| Column | Description |
|---|---|
| `AvgQualityScore` | Mean `QualityScore` across all warm benchmark runs (0–100). Reflects answer correctness only — a model that times out or crashes does not affect this score, but its run is counted as a failure in `SuccessRate`. |
| `ReasoningScore` | Average quality score for reasoning prompts. |
| `JsonScore` | Average quality score for JSON formatting prompts. |
| `CodingScore` | Average quality score for coding prompts. |
| `InstructionScore` | Average quality score for instruction-following prompts. |
| `SummarizationScore` | Average quality score for summarization prompts. |

### Composite scores

| Column | Description |
|---|---|
| `SuccessRate` | Percentage of **warm** runs (excludes the cold-start row) that completed without error (HTTP timeout, CLI crash, empty response, etc.). Answer correctness does not affect this — a wrong answer still counts as a success. With 3 repeats × 15 prompts = 45 warm runs, one failure = 97.78%. |
| `SpeedScore` | Normalised 0–100 speed score, **relative to all models in the same run**. See formula below. |
| `ReliabilityScore` | Equal to `SuccessRate` (0–100). No separate normalisation is applied. When all models complete all runs successfully, this is 100 for everyone. |
| `OverallScore` | Weighted composite of quality, speed, and reliability. See formula below. |

> **Important:** `SpeedScore` is relative — it is normalised against the fastest and slowest models in the current run. Adding or removing models from a run will shift all SpeedScore values. `ReliabilityScore` is simply equal to `SuccessRate` and is not relative. For stable absolute comparisons, use the raw metrics (`WarmAvgTokensPerSec`, `WarmAvgTotalMs`, `SuccessRate`) directly.

## Quality scoring

Each warm prompt gets a `QualityScore` based on its scoring rule:

- `exact`  
  Exact string match scores 100. Partial containment scores 70. No match scores 0.

- `regex`  
  The output is matched against a regular expression. Scores 100 on match, 0 otherwise.

- `contains_all`  
  Score is the percentage of required terms that appear in the output. All present = 100, none present = 0.

- `json_keys`  
  Partial credit for required keys being present, plus additional credit for matching expected values.

- `python_is_palindrome`  
  Heuristic check for a correct Python `is_palindrome(s)` function. Requires the function definition, case normalisation (`.lower()` or `.casefold()`), non-alphabetic character filtering (`.isalpha()` or `re.sub`), and a palindrome comparison (reverse slice `[::-1]` or `reversed()`). Scores 100 if all components are present, 75 if filtering or normalisation is missing but the reverse comparison is present, 50 if only the function signature is found.

- `python_factorial`  
  Heuristic check for a correct Python `factorial(n)` function. Accepts recursive (`factorial(n - 1)`) and iterative (loop-based) implementations. Recursive implementations must include an explicit base case (`n == 0`, `n == 1`, or `n <= 1`); iterative implementations do not require one, since a loop from `2` to `n + 1` with a multiplication accumulator is correct without an explicit branch. Partial credit if the function signature is present but logic is missing.

- `js_clamp`  
  Heuristic check for a correct JavaScript `clamp(value, min, max)` function. Accepts `Math.min(Math.max(...))` or `Math.max(min, Math.min(...))`, `if/else` branching, or ternary implementations. Partial credit if the function signature is present but logic is missing.

All outputs are normalised before scoring: ANSI escape sequences and `<think>...</think>` blocks (emitted by reasoning models) are stripped, and surrounding code fences are removed.

## Scoring formulas

### SpeedScore

Normalised 0–100 relative to all models in the same run:

- 50% warm tokens/sec (higher is better)
- 30% warm average latency (lower is better)
- 20% cold-start total time (lower is better)

### ReliabilityScore

Directly equal to `SuccessRate` (0–100). No normalisation is applied.

### OverallScore

```
OverallScore = (0.75 × AvgQualityScore) + (0.15 × SpeedScore) + (0.10 × ReliabilityScore)
```

`AvgQualityScore` reflects answer correctness only. `OverallScore` reflects overall usefulness across quality, speed, and reliability.

## Notes

- `ModelSizeGB` is the approximate on-disk size as reported by the local runtime, not the in-memory footprint.
- LM Studio runs show `InitialLoadMs` as `n/a` because the CLI does not separate load time from inference time.
- `SpeedScore` shifts when models are added or removed from a run, since it is normalised relative to the current set of models.
- `ReliabilityScore` is simply equal to `SuccessRate` and does not shift unless the model's own failure rate changes.
- Results can vary slightly between runs due to model non-determinism and system load.
- Ollama benchmarks use `/api/generate` (completion endpoint, `temperature=0`, no system prompt). LM Studio benchmarks use `/v1/chat/completions` (chat endpoint, `temperature=0`, `max_tokens=32768`, no system prompt). Both use identical prompts. The endpoint difference is an intentional pragmatic choice — Ollama's `/v1/chat/completions` endpoint triggers extended thinking in Qwen3-family MoE models, exhausting the token budget before producing output; `/api/generate` does not. Removing the system prompt on LMS requests was equally important — it significantly reduces Qwen3 thinking token consumption and keeps generation times within the timeout budget.
- Output normalisation strips ANSI sequences, closed `<think>...</think>` blocks, and unclosed `<think>` blocks (which occur when a thinking model hits the token limit mid-reasoning).

## Example usage

### LM Studio only
```powershell
.\benchmark-local-llms.ps1 -Provider lms -AutoDetectLmsModels -Repeats 3 -OutputDir .\results-lms
```

### Ollama only
```powershell
.\benchmark-local-llms.ps1 -Provider ollama -AutoDetectOllamaModels -Repeats 3 -OutputDir .\results-ollama
```

### Both providers
```powershell
.\benchmark-local-llms.ps1 -Provider all -AutoDetectOllamaModels -AutoDetectLmsModels -Repeats 3 -OutputDir .\results-all
```

### With extended timeout (recommended for large thinking models)
```powershell
.\benchmark-local-llms.ps1 -Provider all -AutoDetectOllamaModels -AutoDetectLmsModels -Repeats 3 -TimeoutSec 600 -OutputDir .\results-all
```

## Viewing results in GridView

Replace `.\results\` below with the output directory you used, for example `.\results-lms\`, `.\results-ollama\`, or `.\results-all\`.

### Leaderboard
```powershell
Import-Csv .\results\leaderboard.csv | Out-GridView -Title "Leaderboard"
```

### Leaderboard with all columns sortable
```powershell
Import-Csv .\results\leaderboard.csv |
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

Raw results include a `RunTimestampUtc` field in ISO UTC format (example: `2026-03-30T18:42:15Z`), making it easy to sort and compare rows across runs.
