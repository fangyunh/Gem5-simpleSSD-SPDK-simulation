# Progress log

## Session 2026-05-09
- 16:00 UTC: Phase 1 conda env `diskann` created (gxx_linux-64 + cmake + boost + mkl + libaio).
  - Persisted MKLROOT via `conda env config vars`.
- 16:01 UTC: Phase 2 DiskANN cloned. Tag `0.7.0` (SHA `df225d32`) — last C++ release.
  - cmake fixes: -DOMP_PATH, -DMKL_PATH, -DMKL_INCLUDE_PATH, symlink libmkl_def.so → .so.3,
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 (CMake 4 compatibility).
  - Built `search_disk_index` and `build_disk_index` — ~3 minutes wall.
- 16:01 UTC: Phase 3 shim built; smoke test against /bin/true produced header-only CSV.
  - Lazy dlsym fix: io_submit lookup moved to wrapper (was failing in __constructor__).
- 16:03 UTC: Phase 4 user confirmed 100M scale.
- 16:06 UTC: Phase 5 dataset acquisition.
  - URLs: doc's are template placeholders; used `dl.fbaipublicfiles.com`.
  - Saved bandwidth: HTTP-range first 12.8 GB only (cropped to 100M).
  - Header patched: npts 1B → 100M.
  - 4 min wall, 51 MB/s.
- 16:11 UTC: Phase 6 index build kicked off (nohup pid 736517). ETA 3–10 h per §8.
- 16:12 UTC: Monitor armed for build progress / completion / failure.

## Open: monitoring index build
Will re-arm monitor every hour until build exits.
Once index is built, proceed to:
- Phase 7: capture (1–10 min wall)
- Phase 8: validate trace
- Phase 9: write metadata header, copy to artifacts/, write SHA-256 sidecar
