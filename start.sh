#!/usr/bin/env bash

_SCRIPTDIR=$(dirname "$0")
[ -f $_SCRIPTDIR/config.sh ] && source $_SCRIPTDIR/config.sh
SQUASHFS_CTR_IMG=${1:-$SQUASHFS_CTR_IMG}
OUT_DIR=${2:-./out}
ISO_NAME=${3:-${ISO_NAME:-tartaria}}

if [ "$EUID" -ne 0 ]; then
  echo "This script must be ran as root."
  exit 1
elif [ -z $1 ] && [ -z $SQUASHFS_CTR_IMG ]; then
  echo -e "You need to specify an OCI image.\nExample: ${0} docker.io/archlinux/archlinux:latest"
  exit 1
elif ! which podman rsync &>/dev/null; then
  echo -e "This script requires both podman and rsync to run. Please install the missing packages via your system's package manager, and then run this script again."
  exit 1
fi

set -euo pipefail

# debugging
# set -x
PS4='[$LINENO]+ '

# These 2 functions help group sections in github's CI
function github-step() {
  set -euo pipefail
  local command="$*"
  echo "::group::$*"
}
function github-step-end() {
  echo "::endgroup::"
}


fail_invalid_image() {
  echo -e "\nThe image \"${SQUASHFS_CTR_IMG}\" failed to be pulled."
  exit 1
}

# Make sure the image exists. If not, pull it
podman image exists "${SQUASHFS_CTR_IMG}" || podman pull "${SQUASHFS_CTR_IMG}" || fail_invalid_image

# Create container from image and mount it to modify its rootfs non-destructively
CONTAINER_ID=$(podman create "${SQUASHFS_CTR_IMG}")
  trap "echo -e 'Cleaning up podman images\n' && podman rm -f ${CONTAINER_ID}" EXIT
SQUASHFS_CTR_IMAGE_MOUNTPOINT=$(podman mount ${CONTAINER_ID})

# podman-chroot function to run commands within the OCI
function podman-chroot(){
  set -euo pipefail
  local command="$1"
  podman run --rm -it --privileged \
    --no-hostname --no-hosts \
    --security-opt label=type:unconfined_t \
    --tmpfs /tmp:rw \
    --tmpfs /run:rw \
    --volume $_SCRIPTDIR:/app \
    --rootfs $SQUASHFS_CTR_IMAGE_MOUNTPOINT \
    /usr/bin/bash -c "$command"
}

# Modified podman-chroot function that plays nice when piped into.
function podman-chroot-no-tty(){
  set -euo pipefail
  local command="$1"
  podman run --rm -i --privileged \
    --no-hostname --no-hosts \
    --security-opt label=type:unconfined_t \
    --tmpfs /tmp:rw \
    --tmpfs /run:rw \
    --volume $_SCRIPTDIR:/app \
    --rootfs $SQUASHFS_CTR_IMAGE_MOUNTPOINT \
    /usr/bin/bash -c "$command"
}

function custom_pre_hooks(){
  set -euo pipefail
  github-step "Custom Pre Hooks"

  # configure liveuser
  podman-chroot 'sed -i "/vt = 1/a \\\n[initial_session]\ncommand = \"niri-session\"\nuser = \"liveuser\"" /etc/greetd/config.toml'
  podman-chroot 'for f in /etc/pam.d/greetd /etc/pam.d/login /etc/pam.d/system-login; do [ -f "$f" ] && sed -i "/pam_gnome_keyring\.so/d" "$f"; done; mkdir -p /etc/systemd/user; for u in gnome-keyring-daemon.service gnome-keyring-daemon.socket; do ln -sf /dev/null "/etc/systemd/user/$u"; done; for f in gnome-keyring-pkcs11 gnome-keyring-secrets gnome-keyring-ssh; do rm -f "/etc/xdg/autostart/$f.desktop"; done'
  podman-chroot "echo 'polkit.addRule(function(action, subject) { if (subject.user == \"liveuser\") { return polkit.Result.YES; } });' | tee /etc/polkit-1/rules.d/49-liveuser.rules > /dev/null"
  podman-chroot "sed -i '1i spawn-sh-at-startup \"bootc-installer\"' /usr/share/tartaria/cherries/dot_config/niri/config.kdl && touch /usr/share/tartaria/cherries/dot_local/state/noctalia/.setup-complete"

  # create temp build user
  podman-chroot 'useradd -U builder'
  podman-chroot 'mkdir -p /etc/sudoers.d /buildhome && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder'
  podman-chroot 'chown builder:builder /buildhome'

  # install necessary build pkgs
  podman-chroot 'pacman -S --noconfirm --needed ninja meson blueprint-compiler mutter >/dev/null'
  
  # clone bootc-installer and install it
  podman-chroot 'runuser -u builder -- bash -c "git clone --quiet --recurse-submodules -b v3.0.16 --depth 1 https://github.com/projectbluefin/bootc-installer /buildhome/bootc-installer"'
  podman-chroot 'runuser -u builder -- bash -c "cd /buildhome/bootc-installer && for patch in /app/installer-patches/*.patch; do git apply \"\$patch\"; done"'
  podman-chroot 'runuser -u builder -- bash -c "cd /buildhome/bootc-installer && meson setup build --prefix=/usr --reconfigure && ninja -C build && sudo ninja -C build install"'
  podman-chroot 'userdel builder && rm -rf /buildhome /etc/sudoers.d'

  # create bootc-installer conf dir
  podman-chroot 'mkdir -p /etc/bootc-installer'

  # remove build pkgs
  podman-chroot 'pacman -Rns --noconfirm ninja meson blueprint-compiler'

  # remove unecessary files
  podman-chroot 'rm -rf /usr/lib/subsystem/rootfs/rootfs.dsk /usr/lib/flatpak-sysapps/flatpak-sysapps.dsk'

  # add installer recipe
  case "$ISO_NAME" in
    *arch*)
        podman-chroot 'cp /app/installer-recipes/arch /etc/bootc-installer/recipe.json'
        ;;
    *cachy*)
        podman-chroot 'cp /app/installer-recipes/cachy /etc/bootc-installer/recipe.json'
        ;;
  esac

  github-step-end
}

function custom_post_hooks(){
  set -euo pipefail
  github-step "Custom Post Hooks"

  github-step-end
}

# Run custom_pre_hooks before anything is done
custom_pre_hooks

github-step "Basic System Tweaks"

# Add contents from skel to /etc/skel
rsync -rltDxv $_SCRIPTDIR/skel/ $SQUASHFS_CTR_IMAGE_MOUNTPOINT/etc/skel/

# We create a /var/tmp directory that ISN'T a tmpfs, and we set podman's storage driver to vfs.
# We also set the timezone to UTC, and remove a possible existing /etc/machine-id to prevent any weirdness with systemd-firstboot.
podman-chroot 'ln -sf /usr/share/zoneinfo/UTC /etc/localtime && \
  [ -d /var/tmp ] || mkdir -p /var/tmp'

# Create tmpfiles.d entry for systemd-resolved, and enable it. 
# We will remove /etc/resolv.conf in build_iso.sh, as if we try to do so here, it won't let us. Podman currently manages /etc/resolv.conf through a mountpoint.
podman-chroot 'systemctl enable systemd-resolved.service'
podman-chroot 'cat > /usr/lib/tmpfiles.d/resolved.conf <<EOF
L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf
EOF'

# Disable zram-generator as zram breaks hard under an ISO environment
podman-chroot 'echo "# Disabled for live sessions" > /usr/lib/systemd/zram-generator.conf'
podman-chroot 'echo "# Disabled for live sessions" > /etc/systemd/zram-generator.conf'

github-step-end

if [ "$INCLUDE_CONTAINER_IN_ISO" = "yes" ]; then
  github-step "Include base container image in ISO"

  podman-chroot 'pacman -Sy --needed --noconfirm podman && \
    mkdir -p /var/lib/containers/storage && \
    mkdir -p /etc/containers'

  # Set storage driver to vfs to avoid needing fuse-overlayfs
  podman-chroot 'cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "vfs"
EOF
'

  # Load the container image into the ISO's system level podman container storage
  echo "Loading OCI Image onto the ISO"
  podman save $SQUASHFS_CTR_IMG | podman-chroot-no-tty "podman --storage-driver vfs load"

  github-step-end
fi

github-step "Install Sudo & Create Live User"

## Create liveuser & its home directory. Also install sudo and give liveuser sudo abilities
podman-chroot "pacman -Sy --needed --noconfirm sudo && \
  cat >> /etc/sudoers <<EOF
liveuser      ALL=(ALL:ALL) NOPASSWD: ALL
EOF
"

podman-chroot "useradd -UG wheel -d /var/home/liveuser liveuser && \
[ -d /var/home ] || mkdir -p /var/home && \
cp -r /etc/skel /var/home/liveuser && \
passwd -d liveuser"

# For some reason chowning /var/home/liveuser doesn't work here? We'll do it at boot with a systemd service
podman-chroot "cat > /usr/lib/systemd/system/liveuser-homedir.service <<EOF
[Unit]
Description=Ensure liveuser home directory has proper permissions

[Service]
Type=oneshot
ExecStart=chown -R liveuser:liveuser /var/home/liveuser

[Install]
WantedBy=sysinit.target
EOF
"
podman-chroot "systemctl enable liveuser-homedir.service"

github-step-end

github-step "Build liveiso's initramfs with dracut"

# Build an initramfs for the resulting ISO to use. We will need dracut.
# Your image should have a kernel inside of it. If it doesn't, you will need to install one using custom_pre_hooks. 
# It is recommended that you include a kernel inside of an image instead.
podman-chroot "pacman -Sy --needed --noconfirm dracut parted"
podman-chroot "[ -d /var/roothome ] || mkdir -p /var/roothome"
echo "Building initramfs"
podman-chroot 'kver=$(find /usr/lib/modules -maxdepth 1 -printf "%P" | head -1) DRACUT_NO_XATTR=1 && dracut \
    --kver="$kver" \
    --zstd \
    --reproducible \
    --no-hostonly \
    --no-hostonly-cmdline \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    --filesystems "iso9660 vfat" \
    --force-drivers "usb_storage uas xhci_pci ahci" \
    --force \
    /live-initramfs.img'

github-step-end

github-step "Cleanup"

# Since we created /var/tmp and it isn't a tmpfs, we need to remove everything inside of it.
podman-chroot "rm -rf /var/tmp/*"

github-step-end

# Run custom_post_hooks after everything is ran
custom_post_hooks

# Build the iso
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR" && \
podman run \
    --rm \
    -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    --env ISO_ENVIRONMENT=true \
    --env GRUB_FILE_PATH=/grub.cfg \
    --env ISO_NAME="${ISO_NAME}" \
    --env SQUASHFS_CTR_IMAGE_MOUNTPOINT="${SQUASHFS_CTR_IMAGE_MOUNTPOINT}" \
    -v "$_SCRIPTDIR"/grub.cfg:/grub.cfg:ro \
    -v "$_SCRIPTDIR"/build_iso.sh:/build_iso.sh:ro \
    -v "$OUT_DIR":/out \
    -v "${SQUASHFS_CTR_IMAGE_MOUNTPOINT}":/rootfs \
    quay.io/fedora/fedora:42 /build_iso.sh
