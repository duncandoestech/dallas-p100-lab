# Benchmarks

Unless a section says otherwise: 2026-11-14, Strata at the recipe's default "overnight" profile
([SOFTWARE.md](SOFTWARE.md#run-config)), English draft vocabulary, one request at a time, 150 W per card. The
[tuning](#tuning) on 2026-11-16 made writing about 4% faster than the numbers in the earlier sections.

## Load and memory

| | Result |
|---|---|
| Load, warm restart (model files in page cache) | about 160 s until `/health` reports loaded |
| Load, cold boot (power-on to ready) | about 330 s |
| RAM peak during load | 107 GiB used, 18 GiB minimum available (of 125 GiB) |
| RAM once loaded | 105 GiB used, about 19-20 GiB available |
| VRAM | 16,081 MiB on each card |

Logged at 1 Hz during the first load. Host RAM use stayed under the 118 GB container cap the whole time.

## Prompt processing and generation

Single requests through the OpenAI API from another machine on the LAN. Each prompt was real text (code and Markdown
documentation) with a unique random prefix, so nothing came from Strata's conversation cache (`cache_n` 0 in both).
Temperature 0, 512 tokens generated.

| Prompt | Prompt processing | Generation | MTP drafts accepted | Wall time |
|---:|---:|---:|---:|---:|
| 17,101 tokens | 776.5 tokens/s | 43.5 tokens/s | 245 of 380 | 33.9 s |
| 34,872 tokens | 856.0 tokens/s | 44.2 tokens/s | 257 of 399 | 52.4 s |

One run per size. The recipe's numbers, on hosts with 384 GB of RAM, are 913-932 tokens/s prompt processing and
40-43 tokens/s generation at 32,757 tokens, so dallas reads a 35K prompt about 6-8% slower and generates at the same
speed or slightly faster. Longer prompts haven't been measured here yet; the recipe goes to 250K.

## Short requests

Before the 150 W cap was set:

| Request | Prompt | Generated | Generation speed | MTP drafts accepted |
|---|---:|---:|---:|---:|
| "Write a Python function is_prime(n)" | 69 tokens | 151 tokens | 41.9 tokens/s | 99 of 119 |
| "What is 17*23?" (after a cold boot) | short | short | 40.5 tokens/s | |

Both answers were correct. Single runs; prompts this short say nothing about prompt-processing speed.

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

## Pictures

2026-11-14, after adding `strata-vision` (CPU only). One PNG test picture through the OpenAI API:

| | Result |
|---|---|
| Answer | described the picture correctly |
| Wall time | 13.2 s |
| Prompt | 266 tokens |
| Generation | 37 tokens/s |
| RAM once loaded | 106 GiB used, 17-19 GiB available |

One run. The picture is encoded on the CPU, which is most of the extra wall time.

## Tuning

2026-11-15/16, with Megla's `bench.py` and `tune.py` (repo `a580ef7`), a fresh engine load per setting, 150 W.
Speeds in tokens/s. "Fresh" is writing from an empty conversation, "edit" is rewriting a Python or Markdown file,
"long read" is prefill of a 38,862-token prompt.

| Setting | Fresh | Edit py | Edit md | Long read | Write after long read |
|---|---:|---:|---:|---:|---:|
| Recipe default, `FNX_EXPERT_RAM_GIB=52.5` | 46.6 | 54.8 | 55.3 | 843 | 41.2-42.0 |
| `FNX_EXPERT_RAM_GIB=53.5` | 45.0 | 52.4 | 52.8 | 843 | 39.7 |
| `FNX_EXPERT_RAM_GIB=51.5` (3 runs) | 48.2-48.3 | 57.3-57.4 | 57.7-57.9 | 844-845 | 41.7-42.9 |
| `FNX_EXPERT_RAM_GIB=50.5` | 47.8 | 56.8 | 57.3 | 842 | 41.8 |
| `FNX_EXPERT_RAM_GIB=49.5` | 47.8 | 56.8 | 57.4 | 844 | 41.8 |
| **51.5 + `FNX_MTP_EXPERTS=q4_0` (now running)** | **48.7** | **56.9** | **58.1** | **844** | **43.2** |

- **51.5 is the one real gain:** +3.5% fresh, +4.7% edits, prefill the same. The first-token logits were bit for bit
  the same as the recipe default in every setting.
- **The Q4_0 draft experts** gave about +0.5% net here, from one run (Megla measured +10% on his box). It's on
  because it costs nothing.
- Run-to-run noise between two identical loads: 0.2% fresh, 0% edits, 0.1% long read, 1.9% write after long read.
- **No gain from:** Strata's own `tune auto` (thorough mode found nothing faster), Megla's lower-RAM hybrid switches
  (edits -4%), prefetch depth 2-9 or off, `DMA_SPLIT` 0/1. `FNX_PLE_RAM=0` halved prefill.
- **Prefill is flat** at about 830-850 tokens/s from 14K to 121K tokens, in every setting tried.
- **PCIe and RAM aren't the limit:** Megla's `check.py` measured 12.4 GB/s from pinned RAM to each card, 11.7 + 11.7
  GB/s to both at once, the same as his box.

Megla's reference box, at 185 W per card, does 50.3 fresh and 62.6 / 63.5 on edits. The likely reasons dallas is
slower are the 150 W cap and the English draft vocabulary (his prompts are Slovenian); that wasn't measured.

## llama.cpp 1.0 on the same box

2026-11-15. llama.cpp v1.0.0 (`b1b770d`, built for `sm_60`) has a new RAM-plus-GPU expert cache for MoE models. Same
model file, 262,144 context, `-cmoe -lm none -np 1 -t 6`, layer split, no MTP:

| `--moe-cache-mib` | Writing, tokens/s | Cache hit rate |
|---:|---:|---:|
| 4,096 (default mmap load) | 8.1 | |
| 7,296 | 14.1 (19.0 with `--moe-cache-cpu-share 0.95`) | about 75% |
| 14,500 (both cards full) | 18.7 (19.7 with share 0.95) | 88.6% |

Best case about **20 tokens/s against Strata's 46.7** on the same box (Strata measured with Megla's `bench.py`
before the tuning above). Doubling the cache barely moved it, so copying experts is no longer what holds it back; what
does wasn't measured. The two numbers come from different tests (llama.cpp's own tuner prompt, raw completion, no
MTP), so read it as "well under half", not an exact ratio. MTP, FP8 context, thread count and prefill speed weren't
tried on llama.cpp.

Two things to know if you try it:

- `scripts/moe-cache-tune.py` sizes the cache from the first GPU's free memory, but `--moe-cache-mib` is split across
  all the GPUs. On two cards it tests half of what fits. Size it by hand.
- Use `-lm none`. The default mmap loading is slow for experts held in RAM, and the server warns about it.
