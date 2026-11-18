#!/usr/bin/env bash

### set errexit + nounset + xtrace + pipefail

set -euxo pipefail

### do our checks

if [[ "${ISO_ENVIRONMENT:-}" != true ]]; then
    echo "This script is not intended to be ran outside of the podman environment. Please use the 00-start.sh script that exists in the same folder."
    exit 1
fi

### set constants

SQUASHFS_CTR_IMG_ROOTFS=/rootfs
OUTPUT_ISO_FILE=/out/"$ISO_NAME".iso

readonly SQUASHFS_CTR_IMG_ROOTFS OUTPUT_ISO_FILE

### iso build stuff (slowed + reverb)

iso_build_getdeps() {
    dnf install --setopt=install_weak_deps=False -yq \
        grub2-efi \
        shim \
        xorriso \
        mtools \
        dosfstools \
        squashfs-tools >/dev/null
}

iso_build_modefi() {
    cp /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi # NOTE: remove this line if breaks bootloader
    # In reality, EFI/BOOT/BOOTX64.EFI its a copy of shim.efi, and the later will default to boot the grubx64.efi in the same directory.
    cp /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
}

iso_build_prepare() {
    mkdir -p /work
    cd /work

    mkdir -p iso_files/{boot,LiveOS}

    ln -sf ../run/systemd/resolve/stub-resolv.conf "$SQUASHFS_CTR_IMG_ROOTFS"/etc/resolv.conf
}

iso_build_modcore() {
    local kver

    kver=$(find "$SQUASHFS_CTR_IMG_ROOTFS/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)

    cp "$SQUASHFS_CTR_IMG_ROOTFS"/live-initramfs.img iso_files/boot/initramfs.img
    rm -f "$SQUASHFS_CTR_IMG_ROOTFS"/live-initramfs.img

    if [[ "$ISO_NAME" == *saffron || "$ISO_NAME" == *maraska ]]; then
        cp "$SQUASHFS_CTR_IMG_ROOTFS"/usr/share/split-kernel/"$kver"/vmlinuz iso_files/boot/vmlinuz
        rm -rf "$SQUASHFS_CTR_IMG_ROOTFS"/usr/share/split-kernel
    else
        cp "$SQUASHFS_CTR_IMG_ROOTFS"/usr/lib/modules/"$kver"/vmlinuz iso_files/boot/vmlinuz
    fi

    # We put the cfg file under EFI/fedora in the ISO 9660 filesystem
    # because grubx64.efi is hardcoded to point there.
    mkdir -p iso_files/EFI/fedora
    cp "$GRUB_FILE_PATH" iso_files/EFI/fedora/grub.cfg
}

### iso generation

iso_gen_fs() {
    mksquashfs "$SQUASHFS_CTR_IMG_ROOTFS" iso_files/LiveOS/squashfs.img -all-root -noappend

    truncate -s 500M uefi.img
    mkfs.fat -F32 uefi.img

    mcopy -vni uefi.img -s /boot/efi/EFI ::
    mcopy -vni uefi.img -s "iso_files/EFI" ::
}

iso_gen_iso() {
    mkdir -p "$(dirname "${OUTPUT_ISO_FILE}")"

    xorriso -as mkisofs \
        -R \
        -V "tartaria_boot" \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B ./uefi.img \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -iso-level 3 \
        -o "${OUTPUT_ISO_FILE}" \
        iso_files
}

### main

main() {
    iso_build_getdeps
    iso_build_modefi
    iso_build_prepare
    iso_build_modcore

    iso_gen_fs
    iso_gen_iso
}

main
