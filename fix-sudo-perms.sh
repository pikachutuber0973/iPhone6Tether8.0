#!/bin/bash
#
# fix-sudo-perms.sh
#
# Repairs the classic "sudo: error in /etc/sudo.conf, line 0 while loading
# plugin 'sudoers_policy' / must be only be writable by owner" failure.
#
# Cause: sudo refuses to load its policy plugin if the plugin file, its
# containing directories, /etc/sudo.conf, or /etc/sudoers are writable by
# anyone other than root. This commonly happens after an unclean shutdown,
# a botched fsck, or a package install interrupted mid-write, which leaves
# some of these files/dirs group- or world-writable.
#
# Must be run as root (you're already root in initramfs/rescue shell,
# so no sudo needed here).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "== Sudo permission repair =="

# Find the sudoers plugin .so wherever this distro/arch put it.
# Common locations: /usr/lib/sudo/, /usr/lib/x86_64-linux-gnu/sudo/,
# /usr/libexec/sudo/
PLUGIN_PATH=""
for p in /usr/lib/sudo/sudoers.so \
         /usr/lib/*/sudo/sudoers.so \
         /usr/libexec/sudo/sudoers.so; do
    for match in $p; do
        if [ -f "$match" ]; then
            PLUGIN_PATH="$match"
            break 2
        fi
    done
done

if [ -z "$PLUGIN_PATH" ]; then
    echo "!! Could not locate sudoers.so automatically." >&2
    echo "   Run: find / -xdev -name 'sudoers.so' 2>/dev/null" >&2
    echo "   and fix that path manually with chown root:root + chmod 644." >&2
else
    echo "-- Found plugin: $PLUGIN_PATH"
    PLUGIN_DIR="$(dirname "$PLUGIN_PATH")"

    echo "-- Fixing $PLUGIN_PATH (root:root, 644)"
    chown root:root "$PLUGIN_PATH"
    chmod 644 "$PLUGIN_PATH"

    echo "-- Fixing $PLUGIN_DIR (root:root, 755)"
    chown root:root "$PLUGIN_DIR"
    chmod 755 "$PLUGIN_DIR"
fi

# /etc/sudo.conf itself
if [ -f /etc/sudo.conf ]; then
    echo "-- Fixing /etc/sudo.conf (root:root, 644)"
    chown root:root /etc/sudo.conf
    chmod 644 /etc/sudo.conf
fi

# /etc/sudoers and /etc/sudoers.d
if [ -f /etc/sudoers ]; then
    echo "-- Fixing /etc/sudoers (root:root, 440)"
    chown root:root /etc/sudoers
    chmod 440 /etc/sudoers
fi

if [ -d /etc/sudoers.d ]; then
    echo "-- Fixing /etc/sudoers.d (root:root, 750, files 440)"
    chown root:root /etc/sudoers.d
    chmod 750 /etc/sudoers.d
    find /etc/sudoers.d -maxdepth 1 -type f -exec chown root:root {} \; \
                                          -exec chmod 440 {} \;
fi

# The sudo binary itself needs the setuid bit
SUDO_BIN="$(command -v sudo || echo /usr/bin/sudo)"
if [ -f "$SUDO_BIN" ]; then
    echo "-- Fixing $SUDO_BIN (root:root, 4755 setuid)"
    chown root:root "$SUDO_BIN"
    chmod 4755 "$SUDO_BIN"
fi

echo "== Done. Validating syntax with visudo -c =="
if command -v visudo >/dev/null 2>&1; then
    visudo -c || echo "!! visudo reported a problem above — check /etc/sudoers manually."
fi

echo "== Test: running 'sudo -l' as root should now work without plugin errors =="
sudo -l >/dev/null 2>&1 && echo "OK: sudo is functional again." \
    || echo "Still failing — re-run with 'bash -x fix-sudo-perms.sh' and check the output."
