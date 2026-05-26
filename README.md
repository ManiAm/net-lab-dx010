
# Celestica Seastone DX010

Hardware documentation, setup guides, and platform-specific scripts for the Celestica Seastone DX010 — a 32x100G QSFP28 switch built on Broadcom Tomahawk running SONiC.

## Documentation

- **[DX010 Hardware](docs/01_README_dx010.md):** Broadcom Tomahawk ASIC, PCB architecture, port layout, SerDes configuration, Intel Atom management CPU, power subsystem, and SONiC compatibility.
- **[DX010 Cooling](docs/02_README_dx010_cooling.md):** Thermal design — airflow architecture, fan modules, thermal sensors, and CPLD-driven fan speed control.
- **[DX010 Setup](docs/03_README_dx010_setup.md):** Physical racking, cabling, serial console access, SONiC boot verification, image upgrade, transceiver installation, and port breakout configuration.
- **[SONiC Build](docs/Sonic_Build.md):** Building SONiC VS (Virtual Switch) images on Proxmox, bare metal, or cloud nodes.

## Scripts

- **[patch_dx010_xcvrd.sh](scripts/patch_dx010_xcvrd.sh)** — Fix DX010 transceiver presence detection for DAC cables.
