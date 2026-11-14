# Troubleshooting

Problems hit on this build and what fixed them.

## The driver pulled in half a kernel

**Symptom:** after `dnf install akmod-nvidia-580xx`, `akmods` said it couldn't build for the running kernel but had
built for a newer one. `grubby --default-kernel` already pointed at the newer kernel, but `rpm -qa` showed only its
`kernel-core`, `kernel-modules-core` and `kernel-devel`, no `kernel` or `kernel-modules`.

**Why it matters:** `kernel-modules` holds most hardware drivers. Rebooting into that kernel risked coming up without
the network card's driver (`e1000e`) on a headless box.

**Fix:** install the full kernel before rebooting, then check the NIC driver is there:

```
sudo dnf install kernel-<version> kernel-modules-<version>
find /lib/modules/<version> -name 'e1000e.ko*'
```

`dnf repoquery` didn't list the new kernel at first because of a stale metadata cache; `dnf makecache --refresh` fixed
that.

## podman: "short-name resolution enforced but cannot prompt without a TTY"

A Dockerfile that says `FROM nvidia/cuda:...` fails under `podman build` from a script, because podman won't guess
which registry a short name means. Either write `docker.io/nvidia/cuda:...`, or pull the image under its full name
first; podman then matches the short name to the local copy:

```
sudo podman pull docker.io/nvidia/cuda:12.9.1-devel-ubuntu22.04
```

## Strata shows "failed" after `systemctl stop`

**Symptom:** `systemctl stop strata` leaves the unit `failed`, with `status=137` in the journal.

**Cause:** podman's default stop timeout is 10 s. The server takes longer to shut the engine down, so podman
force-killed it.

**Fix:** `StopTimeout=60` in the quadlet's `[Container]` section and `TimeoutStopSec=90` in `[Service]`.

## RPM Fusion's `akmod-nvidia` installs a driver that ignores the cards

`akmod-nvidia` from RPM Fusion is the current branch (620 here), which dropped Pascal. Install the `580xx` packages
instead (see [SOFTWARE.md](SOFTWARE.md#os-and-driver)). The GT 610 display card (Fermi) isn't supported by 580 either.
That's fine: the box is headless and the console works without a driver.

## Don't build next to a loaded engine

The loaded engine holds about 105 GiB of 125 GiB. `nvcc` jobs take 1-2 GB each. Stop `strata` before rebuilding the
image or compiling anything else.
