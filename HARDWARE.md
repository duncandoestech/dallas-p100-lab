# Hardware

## Parts

| Part | What | Notes |
|---|---|---|
| Workstation | Dell Precision Tower 7910 | Board 0NK5PH, BIOS A34 |
| CPU | 1x Intel Xeon E5-2620 v3 (Haswell-EP, 6c/12t, 2.4 GHz) | AVX2. One socket populated, so one NUMA node |
| RAM | 128 GB DDR4 (4x 32 GB) | 2400 MT/s modules; the E5-2620 v3 runs them at 1866 MT/s |
| GPUs | 2x Tesla P100 PCIe 16 GB (GP100) | 32 GB VRAM as two pools; no NVLink, so cross-card traffic goes over PCIe |
| PSU | Stock Dell Precision 7910 power supply | The 7910 takes a single PSU, which feeds both cards |
| Display | NVIDIA GeForce GT 610 (GF119, Fermi) | Console only. No current driver supports it, which is fine headless |
| OS disk | Samsung 850 EVO 120 GB SATA SSD | EFI, `/boot`, LVM root (110 GB) |
| Model disk | Patriot P220 512 GB SATA SSD | One XFS partition at `/mnt/models` |

## PCIe

- Both P100s run at **PCIe Gen 3 x16**. `nvidia-smi topo -m` shows the pair as `PHB` (through the host bridge).
- Both cards hang off the one populated CPU socket, so there's no cross-socket hop.
- The engine never uses CUDA peer access: its build refuses a binary that calls a peer-access function. Cross-card
  sums go through pinned host memory.

## Power and cooling

- **Power limit: 150 W per card,** set at boot (see [SOFTWARE.md](SOFTWARE.md#gpu-power-limit)). The cap is an
  average: during the battery single readings reached 190 W, and 1.8% of samples were over 155 W.
- Measured during the agent battery: 68 °C peak. Idle: 33-37 °C.

## RAM is the constraint

The Q4_K_XL model is 111 GB on disk, more than three times the VRAM. Most experts stay in pinned RAM and are copied to
the cards as needed, and the 28.8 GB per-layer lookup table is also held in RAM. With the default profile:

- 105 GiB used once loaded, out of 125 GiB that Linux sees.
- 107 GiB peak during the load, 18 GiB minimum available.

Megla's README lists 96 GB as the minimum for this file, with a lower-RAM profile. The recipe's benchmark hosts had
384 GB. 128 GB works for the default profile, but with little room for anything else.
