#!/bin/bash
# Shared by the installer and the DKMS regression tests. No system changes on source.

module_strings() {
    case "$1" in
        *.zst) zstd -dc "$1" | strings ;;
        *.xz)  xz -dc "$1" | strings ;;
        *.gz)  gzip -dc "$1" | strings ;;
        *)     strings "$1" ;;
    esac
}

gaudi_kernel_targets() {
    local running_kernel=$1 boot_dir=$2 image kernel
    printf '%s\n' "$running_kernel"
    # /lib/modules may contain stale directories after kernel removal.
    for image in "$boot_dir"/vmlinuz-*; do
        [ -f "$image" ] || continue
        kernel=${image##*/vmlinuz-}
        [ "$kernel" = "$running_kernel" ] || printf '%s\n' "$kernel"
    done
}

gaudi_check_kernel_headers() {
    local modules_dir=$1 kernel
    shift
    for kernel in "$@"; do
        if [ ! -f "$modules_dir/$kernel/build/Makefile" ]; then
            bad "内核 $kernel 缺少 headers，请先安装: sudo apt install linux-headers-$kernel"
            return 1
        fi
    done
}

gaudi_kernel_driver_ready() {
    local kernel=$1 version=$2 status module ko vermagic markers aliases
    status=$(dkms status -m habanalabs -v "$version" -k "$kernel" 2>/dev/null) || return 1
    [[ "$status" == *": installed"* ]] || return 1
    for module in habanalabs_compat habanalabs_cn habanalabs_en habanalabs_ib habanalabs; do
        ko=$(modinfo -k "$kernel" -n "$module" 2>/dev/null) || return 1
        case "$ko" in
            */updates/dkms/*) ;;
            *) return 1 ;;
        esac
        [ -s "$ko" ] || return 1
        vermagic=$(modinfo -k "$kernel" -F vermagic "$module" 2>/dev/null) || return 1
        [ "${vermagic%% *}" = "$kernel" ] || return 1
    done
    # ko is now the main module; stock/unpatched modules must not pass.
    [ "$(stat -c%s "$ko")" -ge 10000 ] || return 1
    aliases=$(modinfo -k "$kernel" -F alias habanalabs 2>/dev/null) || return 1
    [[ "$aliases" == *"pci:v00001DA3d00001020"* ]] || return 1
    markers=$(module_strings "$ko") || return 1
    [[ "$markers" == *"PATCHED-ignore-bad-serdes"* ]] || return 1
    [[ "$markers" == *"PATCHED: FW link_mask=0"* ]] || return 1
}

gaudi_ensure_kernel_drivers() {
    local version=$1 verify_only=$2 kernel
    shift 2
    for kernel in "$@"; do
        if gaudi_kernel_driver_ready "$kernel" "$version"; then
            ok "内核 $kernel 的目标 DKMS 模块和补丁已就绪，跳过重建"
            continue
        fi
        if [ "$verify_only" = 1 ]; then
            bad "内核 $kernel 缺少完整的已打补丁 Habana $version 驱动；请先运行安装模式再重启"
            return 1
        fi
        info "为内核 $kernel 编译 Habana $version ..."
        # Always build before install; rebuild only the kernel that failed validation.
        $SUDO dkms build "habanalabs/$version" -k "$kernel" --force || return 1
        $SUDO dkms install "habanalabs/$version" -k "$kernel" --force || return 1
        $SUDO depmod -a "$kernel" || return 1
        if ! gaudi_kernel_driver_ready "$kernel" "$version"; then
            bad "内核 $kernel 安装后校验失败，请检查 DKMS 日志和 modinfo -k $kernel habanalabs"
            return 1
        fi
    done
}

gaudi_update_kernel_initramfs() {
    local kernel
    for kernel in "$@"; do
        $SUDO update-initramfs -u -k "$kernel" || return 1
    done
}
