#!/bin/bash
# Linux regression tests: no sudo, package installation or accelerator needed.
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$TEST_DIR/../scripts/lib/gaudi-dkms.sh"

cases=(targets healthy_current_missing_next all_ready verify_missing verify_ready
       build_failure install_failure post_install_failure headers missing_aux
       empty_module stock_module wrong_vermagic missing_alias missing_patch
       wrong_version status_failure initramfs_all initramfs_failure)
if [ "$#" = 0 ]; then
    for test_case in "${cases[@]}"; do
        if bash "$0" "$test_case"; then
            printf 'PASS %s\n' "$test_case"
        else
            printf 'FAIL %s\n' "$test_case" >&2
            exit 1
        fi
    done
    printf '%s tests passed\n' "${#cases[@]}"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
calls="$tmp/calls"
: > "$calls"
SUDO=""
old=5.15.0-186-generic
next=5.15.0-202-generic
version=1.24.2-481
ok() { :; }
info() { :; }
bad() { printf '%s\n' "$*" >&2; }

make_ready() {
    local kernel=$1 module dir
    dir="$tmp/lib/modules/$kernel/updates/dkms"
    mkdir -p "$dir"
    for module in habanalabs_compat habanalabs_cn habanalabs_en habanalabs_ib habanalabs; do
        printf 'module\n' > "$dir/$module.ko"
    done
    dd if=/dev/zero of="$dir/habanalabs.ko" bs=12000 count=1 2>/dev/null
    printf '\nPATCHED-ignore-bad-serdes\nPATCHED: FW link_mask=0\n' >> "$dir/habanalabs.ko"
    printf '%s\n' "$version" > "$tmp/$kernel.installed"
}

dkms() {
    local action=$1 kernel
    if [ "$action" = status ]; then
        [ "${STATUS_FAIL:-0}" = 0 ] || return 1
        kernel=$7
        if [ -f "$tmp/$kernel.installed" ] && [ "$(cat "$tmp/$kernel.installed")" = "$5" ]; then
            printf 'habanalabs/%s, %s, x86_64: installed (Original modules exist)\n' "$5" "$kernel"
        fi
        return 0
    fi
    kernel=$4
    printf 'dkms %s %s\n' "$action" "$kernel" >> "$calls"
    case "$action" in
        build)
            [ "${BUILD_FAIL:-0}" = 0 ] || return 1
            touch "$tmp/$kernel.built"
            ;;
        install)
            [ "${INSTALL_FAIL:-0}" = 0 ] || return 1
            [ -f "$tmp/$kernel.built" ] || return 1
            make_ready "$kernel"
            if [ "${BROKEN_INSTALL:-0}" = 1 ]; then
                : > "$tmp/lib/modules/$kernel/updates/dkms/habanalabs_ib.ko"
            fi
            ;;
        *) echo "Unexpected dkms mutation: $*" >&2; return 1 ;;
    esac
}

modinfo() {
    local kernel=$2 field=$3 module=${!#}
    if [ "$field" = -n ]; then
        if [ "${STOCK_MODULE:-0}" = 1 ]; then
            printf '%s/lib/modules/%s/kernel/drivers/misc/%s.ko\n' "$tmp" "$kernel" "$module"
        else
            printf '%s/lib/modules/%s/updates/dkms/%s.ko\n' "$tmp" "$kernel" "$module"
        fi
    elif [ "$4" = vermagic ]; then
        printf '%s SMP mod_unload modversions\n' "${VERMAGIC:-$kernel}"
    elif [ "$4" = alias ]; then
        [ "${NO_ALIAS:-0}" = 1 ] || printf 'pci:v00001DA3d00001020sv*sd*bc*sc*i*\n'
        return 0
    else
        return 1
    fi
}

depmod() { printf 'depmod %s\n' "$2" >> "$calls"; }
update-initramfs() {
    printf 'initramfs %s\n' "$3" >> "$calls"
    [ "${INITRAMFS_FAIL:-}" != "$3" ]
}

expect_not_ready() {
    if gaudi_kernel_driver_ready "$old" "$version"; then
        echo 'Invalid driver was accepted' >&2
        exit 1
    fi
    [ ! -s "$calls" ]
}

case "$1" in
    targets)
        mkdir -p "$tmp/boot" "$tmp/lib/modules/stale"
        touch "$tmp/boot/vmlinuz-$old" "$tmp/boot/vmlinuz-$next" "$tmp/boot/initrd.img-unused"
        ln -s "vmlinuz-$next" "$tmp/boot/vmlinuz"
        ln -s gone "$tmp/boot/vmlinuz-missing"
        expected=$(printf '%s\n%s' "$old" "$next")
        [ "$(gaudi_kernel_targets "$old" "$tmp/boot")" = "$expected" ]
        [ "$(gaudi_kernel_targets "$old" "$tmp/absent")" = "$old" ]
        ;;
    healthy_current_missing_next)
        make_ready "$old"
        gaudi_ensure_kernel_drivers "$version" 0 "$old" "$next"
        expected=$(printf 'dkms build %s\ndkms install %s\ndepmod %s' "$next" "$next" "$next")
        [ "$(cat "$calls")" = "$expected" ]
        gaudi_kernel_driver_ready "$old" "$version"
        gaudi_kernel_driver_ready "$next" "$version"
        ;;
    all_ready|verify_ready)
        make_ready "$old"
        make_ready "$next"
        mode=0
        [ "$1" != verify_ready ] || mode=1
        gaudi_ensure_kernel_drivers "$version" "$mode" "$old" "$next"
        [ ! -s "$calls" ]
        ;;
    verify_missing)
        make_ready "$old"
        if gaudi_ensure_kernel_drivers "$version" 1 "$old" "$next"; then exit 1; fi
        [ ! -s "$calls" ]
        ;;
    build_failure)
        BUILD_FAIL=1
        if gaudi_ensure_kernel_drivers "$version" 0 "$old" "$next"; then exit 1; fi
        [ "$(cat "$calls")" = "dkms build $old" ]
        ;;
    install_failure)
        INSTALL_FAIL=1
        if gaudi_ensure_kernel_drivers "$version" 0 "$old" "$next"; then exit 1; fi
        [ "$(cat "$calls")" = "$(printf 'dkms build %s\ndkms install %s' "$old" "$old")" ]
        ;;
    post_install_failure)
        BROKEN_INSTALL=1
        if gaudi_ensure_kernel_drivers "$version" 0 "$old" "$next"; then exit 1; fi
        [ ! -f "$tmp/$next.installed" ]
        ;;
    headers)
        mkdir -p "$tmp/modules/$old/build" "$tmp/modules/$next/build"
        touch "$tmp/modules/$old/build/Makefile"
        if gaudi_check_kernel_headers "$tmp/modules" "$old" "$next"; then exit 1; fi
        [ ! -s "$calls" ]
        touch "$tmp/modules/$next/build/Makefile"
        gaudi_check_kernel_headers "$tmp/modules" "$old" "$next"
        ;;
    missing_aux|empty_module|stock_module|wrong_vermagic|missing_alias|missing_patch|wrong_version|status_failure)
        make_ready "$old"
        case "$1" in
            missing_aux) rm "$tmp/lib/modules/$old/updates/dkms/habanalabs_ib.ko" ;;
            empty_module) : > "$tmp/lib/modules/$old/updates/dkms/habanalabs.ko" ;;
            stock_module) STOCK_MODULE=1 ;;
            wrong_vermagic) VERMAGIC=$next ;;
            missing_alias) NO_ALIAS=1 ;;
            missing_patch) dd if=/dev/zero of="$tmp/lib/modules/$old/updates/dkms/habanalabs.ko" bs=12000 count=1 2>/dev/null ;;
            wrong_version) printf '1.24.1-482\n' > "$tmp/$old.installed" ;;
            status_failure) STATUS_FAIL=1 ;;
        esac
        expect_not_ready
        ;;
    initramfs_all)
        gaudi_update_kernel_initramfs "$old" "$next"
        [ "$(cat "$calls")" = "$(printf 'initramfs %s\ninitramfs %s' "$old" "$next")" ]
        ;;
    initramfs_failure)
        INITRAMFS_FAIL=$old
        if gaudi_update_kernel_initramfs "$old" "$next"; then exit 1; fi
        [ "$(cat "$calls")" = "initramfs $old" ]
        ;;
    *) exit 1 ;;
esac
