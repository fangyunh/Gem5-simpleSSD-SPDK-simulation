#!/usr/bin/env python3
"""parse_reports.py — Extract PPA metrics from Synopsys DC reports.

Reads area_*.rpt, timing_*.rpt, power_*.rpt from reports/ directory.
Combines with sram_sizing.json for total area.
Outputs reports/ppa_summary.json for plot_ppa.py.
"""

import re
import json
import os
import sys

REPORT_DIR = "reports"

CONFIGS = [
    {"tag": "16_64",  "name": "A", "nq": 16, "qd":  64},
    {"tag": "64_64",  "name": "B", "nq": 64, "qd":  64},
    {"tag": "16_128", "name": "C", "nq": 16, "qd": 128},
    {"tag": "64_128", "name": "D", "nq": 64, "qd": 128},
]


def parse_area(filepath: str) -> dict:
    """Extract total area from DC area report."""
    result = {"total_area_um2": 0, "comb_area_um2": 0, "seq_area_um2": 0}
    if not os.path.exists(filepath):
        return result
    with open(filepath) as f:
        for line in f:
            m = re.match(r"\s*Total cell area:\s+([\d.]+)", line)
            if m:
                result["total_area_um2"] = float(m.group(1))
            m = re.match(r"\s*Combinational area:\s+([\d.]+)", line)
            if m:
                result["comb_area_um2"] = float(m.group(1))
            m = re.match(r"\s*Noncombinational area:\s+([\d.]+)", line)
            if m:
                result["seq_area_um2"] = float(m.group(1))
    return result


def parse_timing(filepath: str) -> dict:
    """Extract worst slack from DC timing report."""
    result = {"slack_ns": None}
    if not os.path.exists(filepath):
        return result
    with open(filepath) as f:
        for line in f:
            m = re.match(r"\s*slack\s*\(MET\)\s+([\d.]+)", line)
            if m:
                result["slack_ns"] = float(m.group(1))
                break
            m = re.match(r"\s*slack\s*\(VIOLATED\)\s+(-[\d.]+)", line)
            if m:
                result["slack_ns"] = float(m.group(1))
                break
    return result


def parse_power(filepath: str) -> dict:
    """Extract total power from DC power report."""
    result = {"total_power_mw": 0, "dynamic_power_mw": 0, "leakage_power_mw": 0}
    if not os.path.exists(filepath):
        return result
    with open(filepath) as f:
        for line in f:
            m = re.match(r"\s*Total Dynamic Power\s+=\s+([\d.]+)\s+(\w+)", line)
            if m:
                val = float(m.group(1))
                unit = m.group(2)
                if unit == "uW":
                    val /= 1000
                elif unit == "W":
                    val *= 1000
                result["dynamic_power_mw"] = val
            m = re.match(r"\s*Cell Leakage Power\s+=\s+([\d.]+)\s+(\w+)", line)
            if m:
                val = float(m.group(1))
                unit = m.group(2)
                if unit == "uW":
                    val /= 1000
                elif unit == "nW":
                    val /= 1e6
                elif unit == "W":
                    val *= 1000
                result["leakage_power_mw"] = val
    result["total_power_mw"] = result["dynamic_power_mw"] + result["leakage_power_mw"]
    return result


def main():
    # Load SRAM sizing
    sram_path = os.path.join(REPORT_DIR, "sram_sizing.json")
    if os.path.exists(sram_path):
        with open(sram_path) as f:
            sram_data = {r["name"]: r for r in json.load(f)}
    else:
        print("Warning: sram_sizing.json not found. Run sram_area_model.py first.")
        sram_data = {}

    results = []
    for cfg in CONFIGS:
        tag = cfg["tag"]
        area = parse_area(os.path.join(REPORT_DIR, f"area_{tag}.rpt"))
        timing = parse_timing(os.path.join(REPORT_DIR, f"timing_{tag}.rpt"))
        power = parse_power(os.path.join(REPORT_DIR, f"power_{tag}.rpt"))

        logic_area_mm2 = area["total_area_um2"] / 1e6
        sram_area_mm2 = sram_data.get(cfg["name"], {}).get("area_mm2", 0)

        entry = {
            "config": cfg["name"],
            "nq": cfg["nq"],
            "qd": cfg["qd"],
            "logic_area_mm2": round(logic_area_mm2, 6),
            "sram_area_mm2": sram_area_mm2,
            "total_area_mm2": round(logic_area_mm2 + sram_area_mm2, 6),
            "slack_ns": timing["slack_ns"],
            "dynamic_power_mw": round(power["dynamic_power_mw"], 4),
            "leakage_power_mw": round(power["leakage_power_mw"], 4),
            "total_power_mw": round(power["total_power_mw"], 4),
        }
        results.append(entry)

        print(f"Config {cfg['name']} (NQ={cfg['nq']}, QD={cfg['qd']}):")
        print(f"  Logic area: {logic_area_mm2:.6f} mm^2")
        print(f"  SRAM area:  {sram_area_mm2:.4f} mm^2")
        print(f"  Total area: {entry['total_area_mm2']:.4f} mm^2")
        print(f"  Slack:      {timing['slack_ns']} ns")
        print(f"  Power:      {entry['total_power_mw']:.4f} mW")
        print()

    out_path = os.path.join(REPORT_DIR, "ppa_summary.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"PPA summary saved to {out_path}")


if __name__ == "__main__":
    main()
