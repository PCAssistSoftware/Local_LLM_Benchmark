# Local LLM Benchmark (v2)

Benchmarks local language models using:

- Ollama HTTP API (`/api/generate`)
- LM Studio REST API (`/v1/chat/completions`); `lms` CLI used only for model load/unload

It runs one cold-start measurement per model, then runs a harder warm prompt suite and produces:

- `raw-results.json`
- `raw-results.csv`
- `leaderboard.csv` (includes `ErrorSummary`; models with 0% warm success remain listed with `OverallScore` 0)
- `failures.csv` (only when failures occur)
- `system-info.json`
- `summary-report.md`

## Prompt categories

The v2 benchmark includes 22 warm prompts total:

- 4 reasoning
- 4 JSON formatting
- 4 coding
- 4 instruction-following
- 3 summarization
- 3 context extraction

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
| `InitialLoadMs` | **Ollama:** model load time reported by API `load_duration` (ms), excluding script-side unload/sleep. **LM Studio:** wall-clock around `lms unload` + sleeps + `lms load`, ending before HTTP call. |
| `InitialTotalMs` | **Ollama:** full cold wall-clock including unload + sleep + generate. **LM Studio:** full cold wall-clock including unload/load phase plus chat completion request. |
| `WarmAvgTotalMs` | Average total latency per warm prompt run (ms). |
| `WarmAvgTokensPerSec` | Average generation throughput across warm runs (tokens/sec). |

### Quality scores

| Column | Description |
|---|---|
| `AvgQualityScore` | Mean `QualityScore` across warm runs (0-100). |
| `ReasoningScore` | Average quality score for reasoning prompts. |
| `JsonScore` | Average quality score for JSON prompts. |
| `CodingScore` | Average quality score for coding prompts. |
| `InstructionScore` | Average quality score for instruction prompts. |
| `SummarizationScore` | Average quality score for summarization prompts. |
| `ContextScore` | Average quality score for context-extraction prompts. |

### Composite scores

| Column | Description |
|---|---|
| `SuccessRate` | Percentage of warm runs (excludes startup row) that completed without runtime error. |
| `SpeedScore` | Normalized 0-100 speed score, relative to models in the same run with warm `SuccessRate > 0`. |
| `ReliabilityScore` | Equal to `SuccessRate` for normally scored rows; 0 for all-warm-failure rows. |
| `OverallScore` | Weighted composite of quality, speed, and reliability. |
| `ErrorSummary` | Distinct non-empty error messages for that provider/model across failed rows, concatenated with ` | `. |

## Quality scoring

Each warm prompt gets a `QualityScore` based on its scoring rule:

- `exact`  
  Exact string match = 100, partial containment = 70, else 0.

- `regex`  
  Output must match regex exactly to score 100.

- `contains_all`  
  Percentage of required terms found.

- `contains_all_one_sentence`  
  Same term coverage as `contains_all`, but penalized if output is not exactly one sentence.

- `json_keys`  
  Key/value scoring with optional strict controls:
  - `RequireExactKeys = $true`: fail when keys are missing or extra.
  - `ForbidExtraText = $true`: fail when non-JSON wrapper text is present.
  - Supports expected array comparison with ordered equality by default; optional per-test order-insensitive matching via `ArrayOrderInsensitive = $true`.

- `python_is_palindrome`, `python_factorial`, `js_clamp`, `code_contains`  
  Heuristic code-structure checks as defined in script logic.

All outputs are normalized before scoring: ANSI escapes, `<think>...</think>` blocks, trailing unclosed `<think>`, and surrounding code fences are stripped.

## Scoring formulas

### SpeedScore

Normalized 0-100:

- 50% warm tokens/sec (higher is better)
- 30% warm average latency (lower is better)
- 20% cold-start total time (`InitialTotalMs`, lower is better)

Min/max for each component are computed from rows with warm `SuccessRate > 0`, so all-failure rows do not distort scaling.

### ReliabilityScore

`ReliabilityScore = SuccessRate` for normally scored rows.  
Rows with 0% warm success use `ReliabilityScore = 0`, `SpeedScore = 0`, and `OverallScore = 0`.

### OverallScore

```text
OverallScore = (0.75 * AvgQualityScore) + (0.15 * SpeedScore) + (0.10 * ReliabilityScore)
```

## Notes

- `SpeedScore` is relative to the current run composition; adding/removing models shifts it.
- For stable absolute comparisons, prefer raw metrics (`WarmAvgTokensPerSec`, `WarmAvgTotalMs`, `InitialTotalMs`, `SuccessRate`).
- JSON and instruction prompts in v2 are intentionally stricter to improve model separation.

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

### With extended timeout
```powershell
.\benchmark-local-llms.ps1 -Provider all -AutoDetectOllamaModels -AutoDetectLmsModels -Repeats 3 -TimeoutSec 600 -OutputDir .\results-all
```
