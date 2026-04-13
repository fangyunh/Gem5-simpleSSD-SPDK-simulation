# ASAP7 PDK Setup

Download the ASAP7 PDK from Arizona State University and place the following files here:

1. `asap7sc7p5t_AO_RVT_TT_nldm_211120.db` — Liberty timing/power (TT corner)
2. `asap7sc7p5t.sdb` — Symbol library
3. `dw_foundation.sldb` — DesignWare synthetic library (from Synopsys installation)

The DesignWare library is typically found at:
`$SYNOPSYS/libraries/syn/dw_foundation.sldb`

To copy it:
```bash
cp /usr/local/syn/Y-2026.03/libraries/syn/dw_foundation.sldb RTL_design/lib/
```
