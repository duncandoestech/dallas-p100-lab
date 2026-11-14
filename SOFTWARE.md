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

```
sudo podman build -t localhost/strata-p100:q4kxl-2026-11-13 -f Containerfile .
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

The tokenizer and `mtp-rt/` files came out byte-identical to the SHA-256 list in Megla's `docs/HISTORY.md`.

## Run config

[config/q4.json](config/q4.json), written by the recipe's `configure.py` with container paths:

```
python recipe/configure.py --engine-repo /opt/strata/p100-engine \
  --model /models/qwen3.8-flash-next-q4kxl/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --mtp /models/qwen3.8-flash-next-q4kxl/prep/mtp-rt \
  --tokenizer /models/qwen3.8-flash-next-q4kxl/prep/tokenizer \
  --out /models/strata/config/q4.json --lib-dir /usr/local/cuda-12.4/lib64 --draft-language en
```

The recipe's default "overnight" profile: 262,144 context, 4,000 MiB conversation cache, batch 1, MTP 4, lookup 15,
52.5 GiB of experts in RAM, the lookup table in RAM, prefill mode 6 with sequence parallelism.
`--draft-language en` picks the English draft vocabulary over the recipe's default Slovenian-plus-English one. That
changes speed, not answers: every drafted token is checked by the full model. If RAM gets tight, the recipe's
`--profile megla-hybrid` uses less.

## Service

[config/strata.container](config/strata.container), a rootful podman quadlet in `/etc/containers/systemd/` that becomes
`strata.service`:

- Host networking, both GPUs through CDI, `/mnt/models` mounted as `/models`.
- Listens on `0.0.0.0:8080` with **no API key**. That's a LAN-only choice; add a key before exposing it further.
- `--memory=118g`: if the load ever overruns, the kernel kills the container, not the box.
- `ManagedOOMPreference=avoid`, so Fedora's `systemd-oomd` picks something else first.
- `StopTimeout=60`: the server takes longer than podman's default 10 s to exit, and was being force-killed (exit 137).
- `Restart=on-failure`, starts at boot.

Endpoints: `/v1/chat/completions` (OpenAI), `/v1/messages` (Anthropic), `/health` (`"loaded": true` when ready), and a
web chat page at `/`. Strata runs one request at a time; others wait.

```
sudo systemctl restart strata
sudo podman logs -f strata
```
