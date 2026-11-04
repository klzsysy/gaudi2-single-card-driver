<div align="center">

# Gaudi2 Single-Card Driver Guide

**Bring an Intel Gaudi2 OAM module online through a PCIe adapter on Ubuntu.**

[![Hardware: Gaudi2 HL-225](https://img.shields.io/badge/Gaudi2-HL--225-0071C5?style=flat-square)](#validated-setup)
[![Gaudi software: 1.24.1](https://img.shields.io/badge/Gaudi_Software-1.24.1-4B5563?style=flat-square)](#validated-setup)
[![PyTorch: Intel build 2.11](https://img.shields.io/badge/PyTorch-Intel_2.11-EE4C2C?style=flat-square)](#validated-setup)

[Quick start](#quick-start) · [Five-part fix](#the-five-part-fix) · [Troubleshooting](#troubleshooting) · [Documentation](#documentation) · [Limitations](#limitations)

</div>

<p align="center">
  <img src="docs/assets/bring-up-path.svg" width="100%" alt="Gaudi2 bring-up sequence: enumerate the OAM module through a PCIe adapter, initialize the patched driver with identity IOMMU mapping, and validate HPU computation.">
</p>

A practical record of **hardware installation, driver patches, PyTorch setup, and kernel-panic diagnosis** for a Gaudi2 HL-225 on a platform outside Intel's supported server configurations. The documented setup uses an OAM-to-PCIe adapter, including a fix for a Gaudi 1.24.1 device-acquisition panic.

> [!WARNING]
> **The tested Gaudi 1.24.1 setup requires `iommu=pt` and an `identity` IOMMU domain.** The recorded translated-domain configuration panics when acquiring the HPU. Read [Before installation](#before-installation) and the [complete solution](./完整解决方案.md) before running the installer.

## Validated setup

The project's final solution records successful computation and reboot verification on **GIGABYTE MU70-SU0-NV-XX + Xeon E5-2696 v3 + Gaudi2 HL-225**. These are existing project results, not new tests performed for this documentation update.

| Component / check | Recorded result |
|:---|:---|
| Host | Ubuntu 24.04.4, kernel `6.8.0-136-generic`; PCIe Gen3 x8 on the tested platform |
| Gaudi software | **`1.24.1-482`** |
| Intel Gaudi PyTorch | `2.11.0a0+git009b5f6` |
| Habana Torch Plugin / Python | `1.24.1.482` / Python 3.12 |
| Device acquisition | HPU available, device name `GAUDI2` |
| Memory check | Original tool output reports **101.6 GB**; the card is documented as a 96 GB HBM2e model |
| Compute | **4,096×4,096 matmul**, ReLU, and Softmax passed |
| Training path | Forward and backward propagation passed |
| Reboot | Configuration remained functional after restart |

The [final solution](./完整解决方案.md) supersedes interim failure conclusions in the historical investigation logs.

## Choose your entry point

| Situation | Start here |
|:---|:---|
| First installation | [Quick start](#quick-start), then the [deployment manual](./部署手册.md) |
| Card missing from PCIe | [Hardware diagnostics](#hardware-diagnostics) and [installation / LED notes](./硬件安装与LED诊断.md) |
| `bad SerDes type 65535` | [SerDes diagnosis](#serdes-type-0xffff) |
| Panic while acquiring the HPU | [IOMMU root cause](#why-iommupt-matters) and the [panic investigation](./1.24.1升级与panic排查记录.md) |
| Existing installation needs a health check | `/usr/local/bin/gaudi-check` |

## Before installation

This is a **community adaptation for a specific hardware combination**. The installer changes kernel boot arguments, patches DKMS source, installs software, writes module parameters, and holds selected packages. Arrange console access or a recovery path before changing a host.

| Requirement | What to check |
|:---|:---|
| Hardware | Gaudi2 OAM module and a compatible OAM-to-PCIe adapter |
| Slot | A CPU-connected PCIe x16 slot; the tested link negotiated Gen3 x8 |
| Power | The documented adapter setup uses **48 V / 54 V auxiliary power**, not an ordinary 12 V PCIe power lead |
| Operating system | Ubuntu; the recorded working setup uses 24.04.4 |
| Access / tools | `sudo`, `gcc`, `make`, `dkms`, `curl`, `dpkg-deb`, and Python 3.12 for the pinned wheels |
| IOMMU | `iommu=pt` in the active boot command line; device group type `identity` |
| Module options | `nic_ports_ext_mask=0`; **do not add `card_type=0`** |
| Python packages | Install the Habana PyTorch wheels last so upstream CPU wheels do not replace them |

## Quick start

### Install

Run on the target Ubuntu host after reviewing the requirements:

```bash
git clone https://github.com/JChen-318/gaudi2-single-card-driver.git
cd gaudi2-single-card-driver

sudo ./scripts/install-gaudi2.sh
```

The installer checks the environment, verifies/configures `iommu=pt`, installs Gaudi 1.24.1, applies three source patches, rebuilds DKMS, writes module options, installs PyTorch, and runs compute validation. If it adds a boot argument, reboot and rerun the installer to continue.

| Option | Actual scope |
|:---|:---|
| `--skip-pytorch` | Skip the PyTorch installation stage |
| `--verify-only` | Skip driver installation, source patches, and DKMS rebuild; still performs runtime setup, writes helper scripts/log directories, and runs compute checks |
| `--check-iommu` | Check the boot argument and IOMMU domain; exits before later installation stages; may attempt a runtime domain change |

**`--verify-only` is not a read-only audit.** For routine inspection after installation, use the installed health-check command below.

### Check and use the device

```bash
# Inspect the installed setup
/usr/local/bin/gaudi-check

# Run a program with the Habana environment loaded
hpu-run python3 your_script.py
```

Confirm that `iommu=pt` is active and the device's IOMMU domain is `identity` before acquiring the HPU. A successful `hl-smi` or `torch.hpu.is_available()` result alone did not prove safe device acquisition in the recorded failing setup.

## The five-part fix

The complete working solution combines **three driver patches**, **one kernel boot parameter**, and **one module parameter**.

| # | Change | Purpose on the tested platform |
|:---:|:---|:---|
| 1 | Set `server_type = HL_SERVER_GAUDI2_HLS2` | Handle an otherwise `UNKNOWN` server type |
| 2 | Ignore `bad SerDes type 0xFFFF` | Bypass the adapter configuration's unsupported enumeration |
| 3 | Preserve `ports_mask` when firmware `link_mask=0` | Keep CN initialization and RDMA available |
| **4** | **Set `iommu=pt`** | **Avoid the host-resident page-table address mismatch implicated in the panic** |
| 5 | Set `nic_ports_ext_mask=0` | Allow SCAL to establish its scale-up cluster |

Patch locations, validation, and rollback are documented in the [complete solution](./完整解决方案.md). Apply source patches under `/usr/src/` and force the DKMS rebuild as described there; patching a temporary build tree does not persist.

## Why `iommu=pt` matters

The repository's investigation traces the Gaudi 1.24.1 panic to **host-resident PMMU page tables**. In the translated (`DMA-FQ`) domain, the driver treats a DMA/IOVA address as a physical address in the page pool, then writes a page-table entry through a CPU virtual-address conversion. On the tested system this corrupts page tables and leads to a kernel panic.

The documented workaround uses `iommu=pt` and verifies an **`identity`** domain so that the driver's address conversion works as expected. This is a finding from this repository's investigation, not a claim that every Gaudi platform has the same failure.

<p align="center">
  <img src="docs/assets/iommu-address-path.svg" width="100%" alt="Diagnosed failure: an IOVA is treated as a physical address in the host page-table path. Tested workaround: identity IOMMU mapping with iommu=pt.">
</p>

<details>
<summary><strong>Driver code and investigation evidence</strong></summary>

The documented Gaudi2 configuration enables host-resident PMMU tables:

```c
/* gaudi2/gaudi2.c */
prop->dmmu.host_resident = 0;
prop->pmmu.host_resident = 1;
```

The investigation identifies these two operations:

```c
/* common/mmu/mmu.c :: hl_mmu_hr_init() */
rc = gen_pool_add_virt(pool, virt_addr, (phys_addr_t) dma_addr,
                       pool_chunk_size, -1);

/* common/mmu/mmu.c :: hl_mmu_hr_write_pte() */
*((u64 *) (uintptr_t) virt_addr) = val;
```

The recorded isolation experiments found that skipping CN/NIC initialization or reinstalling PyTorch did not remove the panic. Temporarily disabling host-resident PMMU tables did, pointing the investigation toward the page-table path. Seven panic captures and the final workaround are preserved in the [investigation record](./1.24.1升级与panic排查记录.md) and [netconsole log](./scripts/netconsole-panic证据.log).

</details>

## Hardware diagnostics

### PCIe enumeration and mounting

If `lspci` cannot find the module or the relevant link reports `LnkSta: Width x0`, check the OAM module's seating and evenly secured mounting screws, then the CPU-connected slot and BIOS settings. Poor connector contact caused the recorded enumeration failure.

### LED reference

The [hardware notes](./硬件安装与LED诊断.md) describe two LEDs on the tested module/adapter setup:

| Orientation | Meaning in the recorded setup | Yellow: check |
|:---|:---|:---|
| Horizontal | Power status | Auxiliary supply and power connections |
| Vertical | Installation / system recognition | Module seating, mounting pressure, adapter, and slot |

Do not use PCIe enumeration alone as proof of correct auxiliary power: the notes record an enumerated device that remained `Disabled` without the supply connected.

### CPLD `0x10`

The corrected hardware notes identify **CPLD `0x10` as expected for the documented HL-225H/C configuration**. The earlier investigation initially treated it as suspicious. Use the corrected [hardware guide](./硬件安装与LED诊断.md), and do not attempt a CPLD flash solely because this version appears.

### SerDes type `0xFFFF`

The adapter configuration can produce:

```text
habanalabs: bad SerDes type 65535
habanalabs: Failed to get cpucp info
habanalabs: Failed to initialize accel0. Device is NOT usable!
```

This was recorded with both 1.18.0 and 1.24.1. The working solution uses the server-type and SerDes source patches above; the version string alone does not explain the adapter enumeration failure.

## Troubleshooting

| Symptom | First check |
|:---|:---|
| No PCIe device / link width x0 | Module seating, evenly secured screws, CPU-connected slot, vertical LED |
| Power fault / device `Disabled` | Correct 48 V / 54 V auxiliary supply for this adapter; horizontal LED |
| Panic when acquiring the HPU | Active `iommu=pt` and `identity` domain |
| Zero-byte DKMS module | Source patched under `/usr/src/`; force the documented rebuild |
| SCAL cluster setup failure | `nic_ports_ext_mask=0`; no `card_type=0` |
| PyTorch cannot use HPU | Habana wheels installed last; `/etc/profile.d/habanalabs.sh` loaded |
| Need to inspect a compressed module | Decompress it before searching for the patch marker |
| CPLD version `0x10` | Check the corrected hardware guide; this value alone is not a fault |

<details>
<summary><strong>Capture a panic with netconsole</strong></summary>

When a hard lockup prevents journald from flushing logs, receive netconsole output on a second machine:

```bash
# Receiver
python3 scripts/netconsole-listen.py

# Target host: replace the network placeholders
sudo modprobe netconsole \
  netconsole=6666@<target-IP>/<interface>,6666@<receiver-IP>/<receiver-MAC>
echo 8 | sudo tee /proc/sys/kernel/printk
```

The [complete solution](./完整解决方案.md) documents watchdog settings, panic reboot, persistence, and rollback. The installer writes persistent `kernel.panic` / `kernel.panic_on_oops` settings during installation.

</details>

## Documentation

The README is in English. The detailed installation and investigation records below remain in Chinese; some historical logs contain interim conclusions that the final solution corrects.

| Document | Contents |
|:---|:---|
| [Complete solution](./完整解决方案.md) | **Primary reference:** all five fixes, root cause, evidence, and rollback |
| [Deployment manual](./部署手册.md) | Installation sequence and operational checks |
| [Hardware and LED guide](./硬件安装与LED诊断.md) | Mounting, power, PCIe, LEDs, and corrected CPLD interpretation |
| [1.24.1 upgrade / panic investigation](./1.24.1升级与panic排查记录.md) | Upgrade timeline, isolation tests, and panic evidence |
| [Initial HL-225 investigation](./HL225-排查全记录.md) | Original bring-up history |

### Scripts

| Script | Purpose |
|:---|:---|
| [`install-gaudi2.sh`](scripts/install-gaudi2.sh) | Main Gaudi 1.24.1 deployment entry point |
| [`install-gaudi2-1.18.0-legacy.sh`](scripts/install-gaudi2-1.18.0-legacy.sh) | Legacy installation and rollback reference |
| [`patch-gaudi.py`](scripts/patch-gaudi.py) | Re-runnable source-patch helper |
| [`patch-hr-pgt.py`](scripts/patch-hr-pgt.py) / [`patch-nic-skip.py`](scripts/patch-nic-skip.py) | Diagnostic isolation patches |
| [`netconsole-listen.py`](scripts/netconsole-listen.py) | Remote kernel-log receiver |
| [Panic evidence log](./scripts/netconsole-panic证据.log) | Recorded kernel-panic captures |

## Limitations

- Validated on a specific, older Haswell-EP host outside Intel's supported server configurations; other adapters, motherboards, and drivers need independent validation.
- The tested **Gen3 x8** link has roughly one quarter of the raw link bandwidth of Gen4 x16. Workload performance also depends on transfer patterns.
- Driver source patches can be overwritten by a DKMS package update. The installer holds selected packages to prevent accidental replacement.
- The recorded 1.24.1 setup has no `ens2*` network interfaces, unlike the 24 seen with 1.18.0; single-card computation still worked in the documented tests. This does not establish multi-card networking support.
- Driver and PyTorch verification here establishes the recorded compute path; it does not certify arbitrary applications or production workloads.

## Share compatibility results

Report other adapters, motherboards, or driver versions through [Issues](https://github.com/JChen-318/gaudi2-single-card-driver/issues). Include the CPU/board/slot/adapter, Ubuntu/kernel/Gaudi versions, relevant `lspci -vv`, `hl-smi`, and `dmesg` output, plus the applied patches and boot parameters. Results for 1.22/1.23 and vendor feedback on the page-table issue are welcome.

## Project status

This is an **unofficial community workaround**, unaffiliated with Intel. Patching the kernel driver and bypassing platform checks can affect stability and data integrity; validate on the intended hardware before production use. Intel Gaudi and Habana trademarks belong to Intel Corporation.
