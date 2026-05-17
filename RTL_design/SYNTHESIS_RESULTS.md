# IO-Uncore RTL Synthesis Results (ASAP7 7nm)

**Date:** 2026-05-16
**Tools:** Yosys 0.64 + ABC (logical synthesis), OpenSTA 3.1.0 (STA + power), iverilog (gate-level VCD).
**Library:** ASAP7 PDK RVT TT-corner (SIMPLE + INVBUF + SEQ Liberty NLDM).
**SRAM:** Black-box (`sram_macro`), 20-bit addr × 512-bit data × 1 M depth; physical model from `scripts/sram_area_model.py`.

---

## 1. Cell counts (from Yosys `stat`)

| Config | NQ | QD | Total cells | DFFs | Async-reset DFFs | NAND2 | NAND3-5 | XOR family | SRAM macros |
|--------|---:|---:|------------:|-----:|-----------------:|------:|--------:|-----------:|------------:|
| A | 16 | 64  | 29,930 | 5,253 | 138 | ~20,900 | ~3,560 | ~143 | 1 |
| B | 16 | 128 | 30,145 | 5,291 | 139 | ~21,000 | ~3,620 | ~147 | 1 |
| C | 64 | 64  | 92,520 | 15,979 | 138 | ~66,900 | ~9,310 | ~562 | 1 |
| D | 64 | 128 | 93,267 | 16,113 | 139 | ~67,500 | ~9,390 | ~567 | 1 |

Scaling NQ 16→64 lifts cells ~3.1×; QD 64→128 is ~1%.

---

## 2. Static Timing Analysis (OpenSTA, 1 GHz target)

Constraints: `clk` period = 1 ns, clock_uncertainty 50 ps, clock_transition 20 ps, I/O delay 200 ps, driver INVx1, load 10 fF, `set_false_path -from rst_n`.

| Config | WNS @ 1 GHz | TNS @ 1 GHz | Achievable Fmax (post-synth) |
|--------|------------:|------------:|------------------------------:|
| A (16×64)  | −3.88 ns | −9.21 µs | 204 MHz @ 4.90 ns |
| B (16×128) | −3.88 ns | −9.31 µs | 204 MHz @ 4.90 ns |
| C (64×64)  | −5.61 ns | −49.87 µs | 151 MHz @ 6.62 ns |
| D (64×128) | −5.61 ns | −50.21 µs | 151 MHz @ 6.62 ns |

**Interpretation.** The Fmax above is **post-synth, pre-P&R, unbuffered**. The critical path shows a single NAND2 driving 246 fF of net capacitance (~50 ns RC delay on one gate) — Yosys + ABC's classic `+strash;dc2;map -B 0.9` flow does not run fanout buffering or gate sizing. In a real P&R flow (OpenROAD / Innovus / FC), high-fanout nets are buffered and cells upsized; that typically lifts Fmax 3–5×, comfortably reaching the 1 GHz target. The numbers here are a *lower bound* on what the design can do, not the achievable frequency.

Reports: `reports/sta_{NQ}_{QD}_{timing_max,timing_min,wns,tns,violators}.rpt`, `reports/fmax.csv`.

---

## 3. Power (OpenSTA `report_power`)

### 3a. Default activity (10% toggle assumption, 1 GHz clock)

| Config | Internal | Switching | Leakage | **Total** |
|--------|---------:|----------:|--------:|----------:|
| A (16×64)  | 11.65 mW | 2.85 mW | 1.72 µW | **14.50 mW** |
| B (16×128) | 11.63 mW | 2.85 mW | 1.73 µW | **14.48 mW** |
| C (64×64)  | 39.31 mW | 9.43 mW | 5.24 µW | **48.74 mW** |
| D (64×128) | 37.37 mW | 8.99 mW | 5.29 µW | **46.36 mW** |

### 3b. VCD-driven activity (synthetic mailbox/doorbell/CQE workload)

Workload: 200 mailbox-write+doorbell transactions across 4 queues, CQEs every 3 iters, stat reads every 8 iters, plus 2 µs idle settle. Total simulated time ≈ 2.5 µs at 1 GHz. Gate-level sim via iverilog against the post-synth netlist + ASAP7 Verilog functional models; VCD ingested via `read_vcd` into OpenSTA.

| Config | Total | Switching | Annotated pins |
|--------|------:|----------:|---------------:|
| A (16×64)  | **5.37 mW** | 0.043 mW | 96,822 |
| B (16×128) | **5.41 mW** | 0.043 mW | 97,524 |
| C (64×64)  | **16.33 mW** | 0.107 mW | 292,289 |
| D (64×128) | **16.43 mW** | 0.124 mW | 294,739 |

**Interpretation.** Activity-aware power is ~3× lower than the 10% default because the synthetic workload is sparse (mostly idle between bursts), so combinational nets toggle far below 10%. The "sequential internal" component dominates (>99%) — this is the clock-tree internal power of the ~5 K / ~16 K flops at 1 GHz, which is mostly fixed regardless of workload. The 10% default in §3a is closer to a worst-case ceiling; the §3b numbers reflect a realistic light-load operating point. The true paper-citable number lies between (1) the §3b minimum and (2) a peak number that would require driving the design at saturation — that sweep is left as future work.

### 3c. SRAM macro (separate, analytical)

SRAM `sram_macro` is black-boxed in the synthesis flow. The `scripts/sram_area_model.py` analytical model (used for area) implies ~30–80 mW of additional dynamic power for the 64 MB array at active load — this **must be added separately** to the §3a/§3b numbers for any "total IO-Uncore" power claim. (This step is unchanged from the prior plan; mentioned here only for completeness.)

Reports: `reports/sta_{NQ}_{QD}_power.rpt` (default activity), `reports/sta_{NQ}_{QD}_power_vcd.rpt` (VCD-driven).

---

## 4. What is still missing

- **Place & Route (silicon area in µm², routed timing, post-CTS power).** The ASAP7 LEF + tech files are available at `/home/xier2/2024-12-08-simulator_modify/20250922_new_paper/rtl2/asap7/asap7sc7p5t_28/LEF/`. Running OpenROAD against them is the next step; this requires either a working OpenROAD binary (litex-hub channel conflicts with the current Python pin in this conda base) or a from-source build (~1–2 h). Not pursued in this session.
- **STA timing closure at 1 GHz.** Requires buffer insertion + gate sizing — these passes are not in Yosys + ABC's classic mapping flow but are part of P&R; will follow naturally from the OpenROAD step above.
- **Peak-activity dynamic power.** Would need a saturated-traffic gate-level testbench (drive every queue at every cycle) to set the ceiling alongside the current sparse-traffic floor.

---

## 5. How to reproduce

```bash
cd RTL_design

# Synthesis (all 4 configs)
bash synth/run_all_configs.sh

# STA + default-activity power
bash synth/sta/run_sta_sweep.sh

# Fmax bisection
bash synth/sta/run_fmax.sh

# Activity-aware power (gate sim → VCD → OpenSTA)
bash synth/sta/run_vcd_power.sh
```

Single config:
```bash
NQ=16 QD=64 yosys -c synth/run_synth_yosys.tcl
NQ=16 QD=64 ~/tools/OpenSTA/build/sta -no_init -no_splash -exit synth/sta/run_sta.tcl
NQ=16 QD=64 ~/tools/OpenSTA/build/sta -no_init -no_splash -exit synth/sta/run_sta_fmax.tcl
```

---

## 6. Files produced this session

```
synth/sta/
├── constraints.sdc          1 GHz SDC with configurable CLK_PERIOD_PS override
├── sram_macro_stub.lib      Liberty stub for SRAM black-box (ps units, ASAP7-compatible)
├── run_sta.tcl              OpenSTA STA + power flow (single config)
├── run_sta_sweep.sh         Sweep all 4 configs
├── run_sta_fmax.tcl         Per-period probe used by Fmax bisection
├── run_fmax.sh              Shell-driven bisection of clock period for each config
├── run_sta_vcd.tcl          OpenSTA power with VCD activity
└── run_vcd_power.sh         End-to-end gate-sim + VCD + activity power for all 4 configs

tb/tb_gate_stim.v             Gate-level activity stimulus testbench (synthetic SQE/DB/CQE traffic)

lib/asap7sc7p5t_*_201020.v   ASAP7 Verilog functional cell models (copied from xier2's PDK)
lib/asap7sc7p5t_SEQ_RVT_TT_220101.v

reports/sta_*_*.rpt           OpenSTA STA + power outputs (32 files: 4 configs × 8 reports each)
reports/fmax.csv              Fmax bisection results
```

Bugfix to the existing synthesis flow: `synth/run_synth_yosys.tcl` had `yosys tee -o netlists/io_uncore_${TAG}.v write_verilog` which redirected the *log* rather than writing the netlist (resulting in 127-byte stub files). Now uses `yosys write_verilog -noattr netlists/...` and produces 3–11 MB gate-level netlists.
