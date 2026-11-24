#!/usr/bin/env bash

### set errexit + nounset + xtrace + pipefail

set -euxo pipefail

### do our checks

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be ran as root."
    exit 1
elif [[ -z ${1:-} ]]; then
    echo -e "You need to specify an OCI image.\nExample: docker.io/archlinux/archlinux:latest"
    exit 1
elif [[ -z ${2:-} ]]; then
    echo -e "You need to specify an output directory.\nExample: ./out"
    exit 1
elif [[ -z ${3:-} ]]; then
    echo -e "You need to specify an ISO name.\nExample: latest-stable"
    exit 1
elif ! which podman rsync &>/dev/null; then
    echo -e "This script requires both podman and rsync to run. Please install the missing packages via your system's package manager, and then run this script again."
    exit 1
fi

### set global vars

squashfs_ctr_img=$1

### set constants

REPO_DIR=$(dirname "$0")/..
OUT_DIR=$2
ISO_NAME=$3

readonly {REPO,OUT}_DIR ISO_NAME

### utilities

gstep_start() {
    echo "::group::$*"
}

gstep_end() {
    echo "::endgroup::"
}

fail_invalid_image() {
    echo -e "\nThe image \"${squashfs_ctr_img}\" failed to be pulled."
    exit 1
}

ctr_exec(){
    local command="$1"

    podman run --rm -it --privileged \
        --no-hostname --no-hosts \
        --security-opt label=type:unconfined_t \
        --tmpfs /tmp:rw \
        --tmpfs /run:rw \
        --volume "$REPO_DIR":/app \
        --rootfs "$container_mntpoint" \
        /usr/bin/bash -c "$command"
}

### iso container build

iso_container_create() {
    gstep_start "Pull/Create Tartaria container from GHCR"

    podman image exists "${squashfs_ctr_img}" || podman pull "${squashfs_ctr_img}" || fail_invalid_image

    container_id=$(podman create "${squashfs_ctr_img}")

    trap 'echo -e "Cleaning up podman images\n" && podman rm -f "${container_id}"' EXIT

    container_mntpoint=$(podman mount "${container_id}")

    gstep_end
}

iso_container_sysconf() {
    gstep_start "Modify container system"

    ctr_exec 'pacman -Rns --noconfirm gnome-keyring valent flatpak cups cups-browsed samba smbclient tuned tuned-ppd ddcutil fprintd gpu-screen-recorder ttf-arphic-uming ttf-baekmuk wqy-microhei ttf-croscore ttf-droid gnu-free-fonts powertop libva-intel-driver bazaar flatseal >/dev/null'
    ctr_exec 'pacman -S --noconfirm --needed firefox fuse-overlayfs parted ninja meson blueprint-compiler mutter go >/dev/null'

    ctr_exec 'mkdir -p /etc/bootc-installer'

    ctr_exec 'rm -rf /usr/lib/subsystem/rootfs/rootfs.dsk /usr/lib/flatpak-sysapps/flatpak-sysapps.dsk'

    ctr_exec 'ln -sf /usr/share/zoneinfo/UTC /etc/localtime && mkdir -p /var/tmp'

    ctr_exec 'rsync -rltDxv /app/files/ /'

    if [[ "$ISO_NAME" == *saffron || "$ISO_NAME" == *maraska ]]; then
        ctr_exec 'cp /app/config/settings.json /usr/share/tartaria/cherries/dot_config/dms/'
    else
        ctr_exec 'cp /app/config/settings.toml /usr/share/tartaria/cherries/dot_local/state/noctalia/settings.toml'
    fi

    gstep_end
}

iso_container_userconf() {
    gstep_start "Create container users"

    ctr_exec 'mkdir -p /var/home && useradd -d /buildhome -U builder && useradd -mUG wheel liveuser && echo "liveuser:tartaria" | chpasswd'
    ctr_exec 'mkdir -p /etc/sudoers.d && echo "liveuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/liveuser && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder'
    ctr_exec 'mkdir -p /buildhome && chown builder:builder /buildhome'

    ctr_exec 'sed -i "/vt = 1/a \\\n[initial_session]\ncommand = \"niri-session\"\nuser = \"liveuser\"" /etc/greetd/config.toml'
    ctr_exec "echo 'polkit.addRule(function(action, subject) { if (subject.user == \"liveuser\") { return polkit.Result.YES; } });' | tee /etc/polkit-1/rules.d/49-liveuser.rules > /dev/null"
    ctr_exec "sed -i '1i spawn-sh-at-startup \"bootc-installer\"' /usr/share/tartaria/cherries/dot_config/niri/config.kdl"

    gstep_end
}

iso_container_installconf() {
    gstep_start "Build/Install bootc-installer/fisherman"

    ctr_exec 'runuser -u builder -- bash -c "git clone --quiet --recurse-submodules --depth 1 --revision f1f62e464dc2ab6dfac61267c63f2245b7049bed https://github.com/tuna-os/bootc-installer /buildhome/bootc-installer"'
    ctr_exec 'cd /buildhome/bootc-installer && cp /usr/share/pixmaps/tartaria-logo.svg bootc_installer/assets/tartaria-logo.svg && sed -i "/<file>assets\/unsupported.svg<\/file>/a\\    <file preprocess=\"xml-stripblanks\" alias=\"images/tartaria-logo.svg\">assets/tartaria-logo.svg</file>" bootc_installer/bootc-installer.gresource.xml'
    ctr_exec 'runuser -u builder -- bash -c "cd /buildhome/bootc-installer && git apply /app/patches/bc*.patch && meson setup build --prefix=/usr --reconfigure && ninja -C build && sudo ninja -C build install"'

    ctr_exec 'runuser -u builder -- bash -c "git clone --quiet --depth 1 --revision 5a98ec827fa370d48da69ecf4af3200f20980ce2 https://github.com/tuna-os/fisherman /buildhome/fisherman && cd /buildhome/fisherman && git apply /app/patches/fm*.patch"'
    ctr_exec 'runuser -u builder -- bash -c "cd /buildhome/fisherman/fisherman && GOCACHE=/buildhome/gocache GOPATH=/buildhome/gopath GOPROXY=off go build -o /buildhome/fisherman/fisherman-bin ./cmd/fisherman && sudo install -Dm755 /buildhome/fisherman/fisherman-bin /usr/local/bin/fisherman"'
    sudo rm -f "$container_mntpoint"/usr/bin/fisherman # doesn't work if executed in the container for whatever reason

    ctr_exec 'userdel builder && rm -rf /buildhome /etc/sudoers.d/builder'
    ctr_exec 'pacman -Rns --noconfirm ninja meson blueprint-compiler go'

    ctr_exec "sed -i 's/TAG/stable-${ISO_NAME#*-}/g' /etc/bootc-installer/recipe.json"

    if [[ "$ISO_NAME" == *saffron || "$ISO_NAME" == *maraska ]]; then
        ctr_exec "sed -i 's/BLDR/systemd/g' /etc/bootc-installer/recipe.json"
        ctr_exec "sed -i 's/CFS/true/g' /etc/bootc-installer/recipe.json"
    else
        ctr_exec "sed -i 's/BLDR/grub2/g' /etc/bootc-installer/recipe.json"
        ctr_exec "sed -i 's/CFS/false/g' /etc/bootc-installer/recipe.json"
    fi

    gstep_end
}

iso_container_servconf() {
    gstep_start "Configure container services"

    ctr_exec 'systemctl --global disable udiskie.service'

    ctr_exec 'systemctl enable systemd-resolved.service'
    ctr_exec 'echo "L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf" | tee /usr/lib/tmpfiles.d/resolved.conf'

    ctr_exec 'echo "# Disabled for live sessions" > /usr/lib/systemd/zram-generator.conf'
    ctr_exec 'echo "# Disabled for live sessions" > /etc/systemd/zram-generator.conf'

    gstep_end
}

### actual iso build stuff

iso_prebuild_loadref() {
    gstep_start "Load Tartaria into container"

    podman unmount "$container_id"

    podman commit "$container_id" iso-base:latest

    podman rm "$container_id"
    podman rmi "$squashfs_ctr_img"

    squashfs_ctr_img="iso-base:latest"
    container_id=$(podman create "$squashfs_ctr_img")
    container_mntpoint=$(podman mount "$container_id")

    ctr_exec "podman pull ghcr.io/tartaria-dev/tartaria:stable-${ISO_NAME#*-}"

    gstep_end
}

iso_prebuild_geninit() {
    gstep_start "Generate container initramfs"

    ctr_exec "[ -d /var/roothome ] || mkdir -p /var/roothome"

    ctr_exec 'DRACUT_NO_XATTR=1 dracut \
        --kver="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -V | tail -n 1)" \
        --zstd \
        --reproducible \
        --no-hostonly \
        --no-hostonly-cmdline \
        --add "dmsquash-live dmsquash-live-autooverlay" \
        --filesystems "iso9660 vfat" \
        --force-drivers "usb_storage uas xhci_pci ahci" \
        --force \
        /live-initramfs.img'

    gstep_end
}

iso_prebuild_handoff() {
    ctr_exec "rm -rf /var/tmp/*"

    mkdir -p "$OUT_DIR"

    podman run \
        --rm \
        -it \
        --privileged \
        --security-opt label=type:unconfined_t \
        --env ISO_ENVIRONMENT=true \
        --env GRUB_FILE_PATH=/grub.cfg \
        --env ISO_NAME="$ISO_NAME" \
        -v "$REPO_DIR"/config/grub.cfg:/grub.cfg:ro \
        -v "$REPO_DIR"/scripts/01-build.sh:/build_iso.sh:ro \
        -v "$OUT_DIR":/out \
        -v "$container_mntpoint":/rootfs \
        quay.io/fedora/fedora:42 /build_iso.sh
}

### main logic

main() {
    iso_container_create
    iso_container_sysconf
    iso_container_userconf
    iso_container_installconf
    iso_container_servconf

    iso_prebuild_loadref
    iso_prebuild_geninit
    iso_prebuild_handoff
}

main
