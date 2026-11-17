# Software

## OS and driver

Fedora 45 Server, headless, kernel 7.3.

The NVIDIA driver comes from **RPM Fusion's legacy 580xx branch**:

```
sudo dnf install akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda
```

RPM Fusion's plain `akmod-nvidia` is version 620, which **doesn't support Pascal**. The 580xx packages have their own
names, so `dnf upgrade` won't move them to 620. Installed: `580.196.07` (reports CUDA 13.0). Secure Boot is off, so the
module isn't signed.

`nvidia-persistenced` and `nvidia-modprobe` come in at RPM Fusion's shared 620 build. They work with the 580 driver.
`nvidia-persistenced.service` is enabled, and persistence mode shows `Enabled` on both cards.

**Check the kernel before rebooting.** Installing the driver pulled in a new kernel's `kernel-core` and `kernel-devel`
as build dependencies, but not `kernel-modules`, which holds most hardware drivers, including the NIC's. Install the
full kernel first:

```
sudo dnf install kernel-<version> kernel-modules-<version>
```

## Storage

The 512 GB SSD is one GPT partition, XFS, labeled `models`, mounted at `/mnt/models`:

```
UUID=<uuid> /mnt/models xfs defaults,noatime,nofail 0 0
```

`nofail` lets the box boot if the drive dies. `fstrim.timer` is enabled. The root LV was grown to fill the OS SSD
(`lvextend -r -l +100%FREE`); the installer had left it at 15 GB.

## Monitoring

- **Node exporter:** Fedora's `node-exporter` package, `prometheus-node-exporter.service`, port 9100.
- **GPU exporter:** [utkuozdemir/nvidia_gpu_exporter](https://github.com/utkuozdemir/nvidia_gpu_exporter) v1.16.0,
  from the release's `.rpm`, checked against the release's `checksums.txt`. Port 9835. It reads `nvidia-smi`, so it
  works on Pascal.
- Both ports open in firewalld.
- [config/poll-metrics.sh](config/poll-metrics.sh) logs per-card power, temperature, clock, utilization and VRAM,
  plus available RAM and load, every 2 s to a CSV during benchmarks.

## GPU power limit

[config/gpu-power-cap.service](config/gpu-power-cap.service), a oneshot that runs `nvidia-smi -i 0,1 -pl 150` at boot,
after `nvidia-persistenced` and before `strata.service`.

## GPU fan

The P100s are passively cooled, so they get their air from an ARCTIC USB fan controller driving one ARCTIC S8038-10K
(80 mm, up to about 9,800 rpm). Kernel 7.3 has a driver for the controller (`arctic_fan_controller`, hwmon name
`arctic_fan`), so the fan shows up as `pwm1` / `fan1_input` under `/sys/class/hwmon` with nothing to install.

[config/gpu-fan-curve](config/gpu-fan-curve) runs as [config/gpu-fan-curve.service](config/gpu-fan-curve.service) and
sets the fan from the hotter card's temperature every 2 s:

- The curve is in `/etc/default/gpu-fan-curve` ([config/gpu-fan-curve.default](config/gpu-fan-curve.default)):
  10% at 50 °C, 30% at 70 °C, 60% at 76 °C, 100% at 82 °C, straight lines in between.
- It follows a 10 s average, so short bursts don't rev the fan. It speeds up at once and slows down slowly (holds for
  60 s, then 0.5% per step), so it doesn't hunt.
- If the temperature can't be read, or the service stops or crashes, the fan goes to 100%.

The curve is tuned for quiet: the cards are allowed to run up to about 75 °C. Earlier curves that held them under
50 °C ran the fan near full speed, which was too loud. A loaded but idle P100 still needs 15-20% fan; at 10% it kept
climbing.

## Containers

podman (Fedora's own), with the NVIDIA Container Toolkit for GPU access through CDI:

```
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo dnf install nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable \
  docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
```

Regenerate the CDI spec after a driver update.

## The Strata image

[config/Containerfile](config/Containerfile). The build context holds three folders:

| Folder | What | Pin |
|---|---|---|
| `p100-engine/` | [Megla123/qwen3.8-flash-next-2x-p100](https://github.com/Megla123/qwen3.8-flash-next-2x-p100) with the recipe's `megla-incumbent-rounding.patch` applied | `5e2976057cf4135430671771e609b91dfb733a4a` |
| `strata/` | [Niko1221/Strata](https://github.com/Niko1221/Strata), the Python server and tools | `ffa80d73133ea5c548aefe57889a16e8085a938f` |
| `recipe/` | The Q4_K_XL recipe bundle (2026-11-13) shared on the P100 Discord: patch, `configure.py`, profile template | not in this repo |

The image is `nvidia/cuda:12.4.1-devel-rockylinux9` plus `gcc-toolset-13` and Python 3.12, the versions the recipe
asks for. The engine's `build.sh` fetches the llama.cpp headers it needs at `3cf03257`, builds Release for `sm_60`,
two cards, 64-row prefill jobs, and refuses a binary that can call CUDA peer access. With `JOBS=10` on this CPU the whole
image built in about 16 minutes. Engine SHA-256 here: `f067ea77f2a2ece51a9a43aadf26786dffe0250d60b55726f68159664f02c2dc`.

The last build step adds Strata's picture encoder, `strata-vision`, built from the same pinned Strata checkout against
the engine's pinned llama.cpp. It runs on the CPU, so it doesn't take any VRAM from the engine.

```
sudo podman build -t localhost/strata-p100:q4kxl-vision-2026-11-14 -f Containerfile .
```

## Model files

Into `/mnt/models/qwen3.8-flash-next-q4kxl`, all through the image so the tools match the server:

1. **The four UD-Q4_K_XL parts** from `unsloth/Qwen3.8-Flash-Next-GGUF` at revision
   `084c631ac221016019d6e0a863afe92d90edd3b0`, checked against the SHA-256 table in Megla's README. 111.3 GB, about
   50 minutes on this connection.
2. **Tokenizer** from the first part:
   `tools/strata_tokenizer.py --gguf <part 1> --out prep`.
3. **MTP draft layer.** The GGUF has none, so Strata's tools read 5.2 GB of it from Qwen's checkpoint and pack it with
   Q2_0 experts: `mtp_fetch.py inventory|fetch|verify`, `mtp_pack.py --experts q2_0`, `mtp_rt.py`.

4. **Q4_0 draft experts.** Megla's newer profiles draft with Q4_0 experts made from Qwen's BF16 tensors instead of
   Strata's 2-bit ones (same VRAM): `scripts/mtp_q4.py <mtp-bf16> mtp-rt/experts-q4_0.bin`, from Megla's repo
   (`a580ef7`). 1.4 GB.
5. **Picture projector** `mmproj-Qwen3.8-Flash-Next-BF16.gguf` from the same Unsloth repo, 908 MB, SHA-256
   `b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0`.

The tokenizer and `mtp-rt/` files, `experts-q4_0.bin` included, came out byte-identical to the SHA-256 list in Megla's
`docs/HISTORY.md`.

## Run config

[config/q4-vision.json](config/q4-vision.json). It started as the recipe's `configure.py` output with container paths:

```
python recipe/configure.py --engine-repo /opt/strata/p100-engine \
  --model /models/qwen3.8-flash-next-q4kxl/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --mtp /models/qwen3.8-flash-next-q4kxl/prep/mtp-rt \
  --tokenizer /models/qwen3.8-flash-next-q4kxl/prep/tokenizer \
  --out /models/strata/config/q4.json --lib-dir /usr/local/cuda-12.4/lib64 --draft-language en
```

The recipe's default "overnight" profile: 262,144 context, 4,000 MiB conversation cache, batch 1, MTP 4, lookup 15,
the lookup table in RAM, prefill mode 6 with sequence parallelism. Changed from the recipe since:

- **`FNX_EXPERT_RAM_GIB` 52.5 → 51.5.** One GiB more experts stay on the cards. Fresh writing +3.5%, edits +4.7%,
  answers bit for bit the same. 51.5 was the fastest of 49.5-53.5 ([BENCHMARKS.md](BENCHMARKS.md#tuning)).
- **`FNX_MTP_EXPERTS=q4_0`** uses the Q4_0 draft experts. About +0.5% here, one run, same answers.
- **Pictures on:** `--vision` and a `vision` block that runs `strata-vision` on the CPU (`"gpu": false`) with the
  `mmproj` file, up to 1,024 tokens per picture.
`--draft-language en` picks the English draft vocabulary over the recipe's default Slovenian-plus-English one. That
changes speed, not answers: every drafted token is checked by the full model. If RAM gets tight, the recipe's
`--profile megla-hybrid` uses less.

## Service

[config/strata.container](config/strata.container), a rootful podman quadlet in `/etc/containers/systemd/` that becomes
`strata.service`:

- Image `q4kxl-vision-2026-11-14`, config `q4-vision.json`.
- Host networking, both GPUs through CDI, `/mnt/models` mounted as `/models`.
- Listens on `0.0.0.0:8080` with **no API key**. That's a LAN-only choice; add a key before exposing it further.
- `--memory=118g`: if the load ever overruns, the kernel kills the container, not the box.
- `ManagedOOMPreference=avoid`, so Fedora's `systemd-oomd` picks something else first.
- `StopTimeout=60`: the server takes longer than podman's default 10 s to exit, and was being force-killed (exit 137).
- `Restart=on-failure`, starts at boot.

Endpoints: `/v1/chat/completions` (OpenAI), `/v1/messages` (Anthropic), `/health` (`"loaded": true` when ready,
`"images": true` with pictures on), and a web chat page at `/`. Pictures go in as normal OpenAI `image_url` or
Anthropic `image` parts. Strata runs one request at a time; others wait.

```
sudo systemctl restart strata
sudo podman logs -f strata
```
