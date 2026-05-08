#!/usr/bin/env python3
"""Trim Liberty (.lib) files by removing timing tables.

Keeps: library header, cell definitions, pin functions, areas, directions.
Removes: timing groups, internal_power groups, NLDM lookup tables.

This produces a much smaller file suitable for Yosys ABC technology mapping
where we only need cell function and area, not full timing characterization.
"""

import re
import sys
import os


def trim_liberty(input_path, output_path):
    with open(input_path, 'r') as f:
        lines = f.readlines()

    out = []
    skip_depth = 0  # depth counter for groups we're skipping
    brace_depth = 0
    in_skip = False

    # Groups to remove (they contain large NLDM tables)
    skip_groups = {'timing', 'internal_power', 'leakage_power',
                   'cell_fall', 'cell_rise', 'fall_transition', 'rise_transition',
                   'fall_constraint', 'rise_constraint',
                   'fall_power', 'rise_power', 'power'}

    for line in lines:
        stripped = line.strip()

        if in_skip:
            brace_depth += stripped.count('{') - stripped.count('}')
            if brace_depth <= 0:
                in_skip = False
                brace_depth = 0
            continue

        # Check if this line starts a group we want to skip
        skip_this = False
        for group in skip_groups:
            if re.match(rf'\s*{group}\s*\(', stripped) or stripped == f'{group} {{':
                skip_this = True
                break

        if skip_this:
            brace_depth = stripped.count('{') - stripped.count('}')
            if brace_depth > 0:
                in_skip = True
            continue

        out.append(line)

    with open(output_path, 'w') as f:
        f.writelines(out)

    orig_size = os.path.getsize(input_path)
    new_size = os.path.getsize(output_path)
    print(f"  {os.path.basename(input_path)}: {orig_size/1024:.0f}KB -> {new_size/1024:.0f}KB "
          f"({100*new_size/orig_size:.1f}%)")


if __name__ == '__main__':
    lib_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'lib')

    libs = [
        ('asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib',
         'asap7sc7p5t_SIMPLE_RVT_TT_trimmed.lib'),
        ('asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib',
         'asap7sc7p5t_INVBUF_RVT_TT_trimmed.lib'),
        ('asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib',
         'asap7sc7p5t_SEQ_RVT_TT_trimmed.lib'),
    ]

    print("Trimming Liberty files (removing timing tables)...")
    for src, dst in libs:
        src_path = os.path.join(lib_dir, src)
        dst_path = os.path.join(lib_dir, dst)
        if os.path.exists(src_path):
            trim_liberty(src_path, dst_path)
        else:
            print(f"  WARNING: {src} not found, skipping")

    print("Done.")
