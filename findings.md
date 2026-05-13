# Findings — DiskANN trace capture

## Host capability snapshot (2026-05-09)
- Ubuntu 22.04.5 LTS, kernel 5.15.0-173-generic
- 32 cores, 376 GB RAM, 8 GB swap (6.1 GB used → minor; not relevant for this work)
- /home: 5.5 TB, 2.9 TB used, **2.4 TB free** — no space pressure even for 1B-scale
- /home is on `/dev/nvme0n1` via LVM (Intel SSDPE2KE064T8, 5.8 TB, TRAN=nvme, ROTA=0)
- Other NVMe devices present but partitioned differently and not relevant

## Existing conda envs
| Env | Purpose | Reuse for DiskANN? |
|-----|---------|-------------------|
| base | Python 3.13 | No — too modern, will be polluted by build deps |
| simplessd_env | Existing repo env | No — keep clean |
| llm | Existing | No — keep clean |
| spdk | Existing | No — keep clean |

Decision: create a fresh `diskann` env per §5.2.

## Toolchain checks (will re-verify after env activate)
- g++ 11.4 (system) — satisfies DiskANN's 9+ requirement
- cmake 3.22.1 (system) — satisfies 3.21+ requirement
- python 3.13 (base) — will pin to 3.11 inside `diskann` env

## Things to remember for the trace metadata header
- `device-target`: `/dev/nvme0n1` (where /home lives, where the index file ends up)
- `device-model`: `Intel SSDPE2KE064T8`
- `device-namespace-bytes`: 5.8 TB raw
- `filesystem`: ext4 (typical Ubuntu default; will verify with `stat -f -c %T`)
- `kernel`: `5.15.0-173-generic`
- `os`: `Ubuntu 22.04.5 LTS`
- `capture-host`: `<hostname>` (will run `hostname` at capture time)
