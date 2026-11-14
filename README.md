# Dallas: a 2x Tesla P100 Strata server

`dallas` is a Dell Precision Tower 7910 workstation turned into a local LLM box with two NVIDIA Tesla P100 16 GB cards
(32 GB of VRAM) and 128 GB of RAM. It runs **Qwen3.8-Flash-Next** (unsloth `UD-Q4_K_XL`, 111 GB) on Megla123's
P100 port of Strata's split engine, in a podman container. This repo is the build notes and the measured results.

It's the sibling of [houston-p100-lab](https://github.com/duncandoestech/houston-p100-lab), the 4x P100 llama.cpp
build. Houston has little RAM and four cards, so it runs a dense 27B model fully in VRAM. Dallas has two cards and a
lot of RAM, so it runs a much bigger MoE model whose experts live in RAM and stream to the cards.

## The box

| | |
|---|---|
| GPUs | 2x Tesla P100 PCIe 16 GB (Pascal, HBM2), each at PCIe Gen 3 x16, no NVLink |
| Workstation | Dell Precision Tower 7910 (board 0NK5PH, BIOS A34) |
| CPU | 1x Xeon E5-2620 v3 (6 cores / 12 threads, 2.4 GHz, AVX2) |
| RAM | 128 GB DDR4 (4x 32 GB, 2400 MT/s modules running at 1866 MT/s, the CPU's limit) |
| PSU | Stock Dell 7910 power supply (single) |
| Display | GeForce GT 610 (Fermi, no driver; console only) |
| Storage | 120 GB SATA SSD for the OS, 512 GB SATA SSD for models |
| OS | Fedora 45 Server, kernel 7.3, NVIDIA 580xx driver |

Details: [HARDWARE.md](HARDWARE.md).

## What it runs

Qwen3.8-Flash-Next `UD-Q4_K_XL` on [Megla123/qwen3.8-flash-next-2x-p100](https://github.com/Megla123/qwen3.8-flash-next-2x-p100)
(`5e29760`) plus the incumbent-rounding patch from a recipe shared on the P100 Discord, served by [Strata](https://github.com/Niko1221/Strata)
(`ffa80d7`). 262,144-token context, MTP drafting, one request at a time, 150 W per card, OpenAI- and
Anthropic-compatible API plus a web chat page. How it's built and run: [SOFTWARE.md](SOFTWARE.md).

| Measurement | Result |
|---|---|
| Agent battery (9 tool-use tasks x 3) | **27 of 27 passed, 63 s mean per task** |
| Generation, short code prompt* | 41.9 tokens/s (MTP: 99 of 119 drafts accepted) |
| Load, warm restart / cold boot | about 160 s / about 330 s until ready |
| RAM while loaded | 105 GiB used, 18 GiB minimum available during load |
| VRAM | 16.1 GB of 16 GB on each card (by design) |
| GPU temperature, battery | 68 °C peak |

\*Measured before the 150 W cap was set. All measured 2026-11-14. More in [BENCHMARKS.md](BENCHMARKS.md). Long-prompt prefill speed has **not** been measured on
this box yet.

## What mattered

- **The driver has to be the 580xx branch.** RPM Fusion's plain `akmod-nvidia` is 620 and has no Pascal support.
- **CUDA 12.4 and GCC 13 come from the container,** not the host. Fedora 45's compilers are too new for CUDA 12.4,
  and CUDA 13 can't target `sm_60`. The image is `nvidia/cuda:12.4.1-devel-rockylinux9` with `gcc-toolset-13`.
- **RAM is the limit, not VRAM.** The recipe was measured on 384 GB hosts and never measured a minimum. On 128 GB the
  default profile fits with about 18 GiB to spare at the tightest point of the load. Nothing else big runs on the box.
- **Never compile on the box while the model is loaded.** It pins most of the RAM.
- **Installing the driver pulled in a half-installed new kernel** (core but not `kernel-modules`). Rebooting into it
  would have left the box without its network driver. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Files

| File | What's in it |
|---|---|
| [HARDWARE.md](HARDWARE.md) | Workstation, GPUs, RAM, storage, PCIe |
| [SOFTWARE.md](SOFTWARE.md) | Driver, storage, monitoring, power cap, container build, model prep, service |
| [BENCHMARKS.md](BENCHMARKS.md) | Load, memory, generation and agent battery results |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Problems hit during the build and what fixed them |
| [config/](config/) | Containerfile, podman quadlet, power-cap unit, run config, telemetry script |

## Credits

The recipe this box runs comes from [Megla123/qwen3.8-flash-next-2x-p100](https://github.com/Megla123/qwen3.8-flash-next-2x-p100)
and the P100 Discord, where the tuned Q4_K_XL profile and rounding patch were shared. GPU engine and P100 profile
work by Megla123, built on [Strata](https://github.com/Niko1221/Strata) (Niko1221 and
contributors), which ports John Fink's [sFNX](https://github.com/johnfink8/sfnx). Model quant by
[Unsloth](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF). All MIT; see their repositories for notices.
