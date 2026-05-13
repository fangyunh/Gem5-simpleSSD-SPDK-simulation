#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from typing import Dict


UNIT_TO_NS = {
    "ns": 1.0,
    "us": 1_000.0,
    "ms": 1_000_000.0,
}


def to_ns(value: float, unit: str) -> int:
    unit = unit.lower()
    if unit not in UNIT_TO_NS:
        raise ValueError(f"Unsupported unit: {unit}")
    return int(round(value * UNIT_TO_NS[unit]))


def load_profile(path: str) -> Dict[str, int]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    units = data.get("units", {})
    values = data.get("values", {})

    read_unit = units.get("read", "ns")
    prog_unit = units.get("program", "ns")
    erase_unit = units.get("erase", "ns")

    read_ns = to_ns(float(values["page_read_tR"]), read_unit)
    prog_ns = to_ns(float(values["page_program_tPROG"]), prog_unit)
    erase_ns = to_ns(float(values["block_erase_tBERS"]), erase_unit)

    return {
        "LSBRead": read_ns,
        "CSBRead": read_ns,
        "MSBRead": read_ns,
        "LSBWrite": prog_ns,
        "CSBWrite": prog_ns,
        "MSBWrite": prog_ns,
        "Erase": erase_ns,
    }


def apply_config(config_path: str, updates: Dict[str, int]) -> None:
    with open(config_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    out_lines = []
    for line in lines:
        stripped = line.strip()
        replaced = False
        for key, value in updates.items():
            if stripped.startswith(f"{key} ="):
                out_lines.append(f"{key} = {value}\n")
                replaced = True
                break
        if not replaced:
            out_lines.append(line)

    backup_path = config_path + ".bak"
    if not os.path.exists(backup_path):
        with open(backup_path, "w", encoding="utf-8") as f:
            f.writelines(lines)

    with open(config_path, "w", encoding="utf-8") as f:
        f.writelines(out_lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply SSD latency profile to fast_ssd.cfg")
    parser.add_argument("--profile", required=True, help="Path to latency profile JSON")
    args = parser.parse_args()

    config_path = "fast_ssd.cfg"
    updates = load_profile(args.profile)
    apply_config(config_path, updates)

    print(f"Applied profile {args.profile} to {config_path}")
    for k in sorted(updates.keys()):
        print(f"  {k} = {updates[k]}")


if __name__ == "__main__":
    main()
