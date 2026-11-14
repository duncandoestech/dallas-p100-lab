# Benchmarks

All on 2026-11-14, Strata at the default "overnight" profile ([SOFTWARE.md](SOFTWARE.md#run-config)), English draft
vocabulary, one request at a time.

## Load and memory

| | Result |
|---|---|
| Load, warm restart (model files in page cache) | about 160 s until `/health` reports loaded |
| Load, cold boot (power-on to ready) | about 330 s |
| RAM peak during load | 107 GiB used, 18 GiB minimum available (of 125 GiB) |
| RAM once loaded | 105 GiB used, about 19-20 GiB available |
| VRAM | 16,081 MiB on each card |

Logged at 1 Hz during the first load. Host RAM use stayed under the 118 GB container cap the whole time.

## Single requests

Through the OpenAI API from another machine on the LAN, before the 150 W cap was set:

| Request | Prompt | Generated | Generation speed | MTP drafts accepted |
|---|---:|---:|---:|---:|
| "Write a Python function is_prime(n)" | 69 tokens | 151 tokens | 41.9 tokens/s | 99 of 119 |
| "What is 17*23?" (after a cold boot) | short | short | 40.5 tokens/s | |

Both answers were correct. These are single runs, not a sweep. The recipe's own numbers, on hosts with 384 GB of RAM, are about 880-930 tokens/s prompt processing and 35-45 tokens/s generation from 32K to 250K tokens of
uncached input. Long-prompt prefill hasn't been measured on this box yet.

## Agent battery

Nine tool-use trap tasks from the Hermes Agent `toolperf_abeval` suite, 3 reps each, plus a no-tool check, run with
Hermes Agent against the Strata endpoint. 65,536-token agent context.

| Task | Passed | Mean wall time |
|---|---:|---:|
| `err_python_env` | 3/3 | 50 s |
| `err_replay_patch` | 3/3 | 46 s |
| `err_ambiguous_edit` | 3/3 | 56 s |
| `err_case_search` | 3/3 | 71 s |
| `err_hidden_search` | 3/3 | 45 s |
| `err_big_output` | 3/3 | 36 s |
| `err_multi_dir` | 3/3 | 60 s |
| `err_inline_script` | 3/3 | 32 s |
| `err_big_file_read` | 3/3 | 169 s |
| **Total** | **27/27 (100%)** | **63 s** |
| `no_tool_required` | 0/3 | 23-43 s |

- **`no_tool_required` failed on format, not arithmetic.** The check wants the reply to be exactly `RESULT=323`. The
  model answered 323 each time but wrote `17 * 19 = 323.` twice before the `RESULT=323` line.
- `err_hidden_search` is the unstable task across this suite (0-100% from run to run at 3 reps on other setups), so
  treat a one-task difference in pass rate as noise.
- Strata caps thinking at 6,144 of an 8,192-token `max_tokens`, so the answer always has room. llama.cpp doesn't do
  this, which can move pass rates and wall times on its own.

For a rough comparison, houston's production setup (Qwen3.8-27B `UD-Q6_K_XL` on four P100s with Kmic's llama.cpp fork)
passed 26 of 27 at 120 s mean per task on the same nine tasks. Different model, engine and card count, so this
says where dallas stands, not which part is responsible.

### Telemetry during the battery

1,732 samples at 2 s:

| | Result |
|---|---|
| GPU temperature | 68 °C peak |
| GPU utilization | 99-100% during tasks |
| Power | 190 W peak reading; 30 samples (1.8%) above 155 W, the rest at or under the 150 W cap |
| RAM available | 16.6 GiB minimum |
