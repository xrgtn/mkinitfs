#!/bin/sh

TMPOUT="/tmp/mkinitfs-$$"

# Accepts 1 or 2 arguments:
#   die [errcode] message
# Prints error message and exits with errcode (or 1):
die() {
    E=1
    if [ 0 -lt $# ] && expr "z$1" : 'z[0-9][0-9]*$' >/dev/null ; then
	E="$1"
	shift
    fi
    if [ 0 -lt $# ] ; then
	echo "ERROR:" "$@" 1>&2
    fi
    rm -f "$TMPOUT"
    exit "$E"
}

# Print USAGE: message and exit:
usage() {
    echo "USAGE: $0 [-k kernel_version] target_directory"
    exit 0
}

# Create a directory if it doesn't exist:
mkdir_if_doesnt_exist() {
    if [ -e "$1" ] ; then
	if ! [ -d "$1" ] ; then
	    if ! rm "$1" ; then
		die "$1 exists but is not a directory"
	    fi
	fi
    fi
    if ! [ -d "$1" ] && ! mkdir -p "$1" ; then
	die "mkdir $1 failed"
    fi
}

# Parse commandline arguments:
OPT=""
ARGNO=0
INITFSDIR=""
for A in "$@" ; do
    V=0
    if [ "z$OPT" = "z" ] ; then
	case "$A" in
	    -?*) OPT="$A";;
	    *)  # Parse non-option arguments here:
		ARGNO=`expr 1 + "$ARGNO"`
		case "$ARGNO" in
		    1) INITFSDIR="$A";;
		esac
		;;
	esac
	case "$OPT" in
	    -?=*) OPTVAL="${A#-k=}"; V=1;;
	    -??*) OPTVAL="${A#-k}"; V=1;;
	esac
    else
	OPTVAL="$A"; V=1
    fi
    # "Parse" option when option value is available:
    if [ "z$V" = "z1" ] ; then
	case "$OPT" in
	    -k*) KERN="$OPTVAL";;
	    -*)  die "invalid option $OPT";;
	esac
	OPT=""
    fi
done
if [ "z$OPT" != "z" ] ; then
    die "missing $OPT value"
fi
if [ "z$ARGNO" != "z1" ] ; then
    usage
fi
if [ "z$KERN" = "z" ] ; then
    KERN="`uname -r`"
fi
INITFSDIRNOTRAILINGSLASH="$INITFSDIR"
case "$INITFSDIR" in
    /) ;;
    */)INITFSDIRNOTRAILINGSLASH="${INITFSDIR%/}";;
    *) INITFSDIR="$INITFSDIR/";;
esac
echo "${0##*/}: $INITFSDIR"

# Support adding modules for several kernels to initrd:
for k in "$KERN" ; do
    # Create subdirectories for ATA/SCSI/USB drivers,
    # filesystem and library modules:
    while read subdir mods ; do
	d="${INITFSDIR}lib/modules/$k/$subdir"
	mkdir_if_doesnt_exist "$d"
	for m in $mods ; do
	    case "$m" in
		^*) M="${m#^}*";;
		*)  M="*$m*";;
	    esac
	    find "/lib/modules/$k/$subdir" -type f -name "$M" \
		-exec cp --preserve=mode,timestamps \{\} "$d/" \; \
		2>/dev/null
	done
    done <<EOF
kernel/crypto          aes cbc fish lrw rmd serpent sha tgr wp xts gf128 crct10dif_common
kernel/drivers/ata     ahci gen legacy piix lib pcmcia sata
kernel/drivers/cdrom   ^cdrom.ko
kernel/drivers/hid     usbhid generic ^hid.ko
kernel/drivers/input   ^input.ko atkbd serio.ko libps2 i8042
kernel/drivers/md      dm-crypt dm-mod
kernel/drivers/pcmcia  core pcmcia.ko
kernel/drivers/scsi    sd_mod sr_mod scsi_mod scsi_tgt ufshcd
kernel/drivers/usb     [eoux]hci-hcd hci*pci ^usbcore ^hid.ko usbhid common storage ums uas.ko
kernel/fs              ext2 ext3 ext4 xfs isofs ufs jfs reiserfs mbcache jbd2 fscrypto
kernel/lib             crc16 crc32 crc-itu-t crc-t10dif zlib_inflate
EOF
    # Copy modules.order and modules.builtin files for /sbin/depmod:
    for i in order builtin ; do
	s="/lib/modules/$k/modules.$i"
	t="${INITFSDIR}lib/modules/$k/modules.$i"
	if ! [ -e "$t" ] ; then
	    cp --preserve=mode,timestamps "$s" "$t"
	fi
    done
    # Generate depmod files for initrd subset of kernel modules:
    if ! /sbin/depmod -b"${INITFSDIRNOTRAILINGSLASH}" \
	    -eF"/boot/System.map-$k" "$k" >"$TMPOUT" 2>&1 ; then
	E="$?"
	cat "$TMPOUT" >&2
	die "$E" "depmod failed"
    fi
    if grep WARNING "$TMPOUT" >/dev/null ; then
	cat "$TMPOUT" >&2
	die "depmod found missing dependencies"
    fi
    rm -f "$TMPOUT"
done

# Create all other directories besides /lib/modules/xxx:
for d in bin sbin etc/lvm dev proc sys mnt/root ; do
    mkdir_if_doesnt_exist "${INITFSDIR}$d"
done
##mknod "${INITFSDIR}dev/null" c 1 3
##mknod "${INITFSDIR}dev/random" c 1 8
##mknod "${INITFSDIR}dev/urandom" c 1 9
##mknod "${INITFSDIR}dev/console" c 5 1
##mknod "${INITFSDIR}dev/tty" c 5 0
##mknod "${INITFSDIR}dev/tty1" c 4 1

# Add busybox and its symlinks:
cp --preserve=mode,timestamps /bin/busybox "${INITFSDIR}bin/"
/bin/busybox --list | while read b ; do
    ln -s busybox "${INITFSDIR}bin/$b"
done

# Add cryptsetup/lvm:
cp --preserve=mode,timestamps /sbin/lvm.static "${INITFSDIR}sbin/lvm"
if ldd /sbin/cryptsetup >/dev/null ; then
    ldd /sbin/cryptsetup
fi
cp --preserve=mode,timestamps /sbin/cryptsetup "${INITFSDIR}sbin/"
cat >"${INITFSDIR}etc/lvm/lvm.conf" <<EOF
activation {
    # Disable udev synchronisation (there's no udev in initrd)
    udev_sync=0
    udev_rules=0
}
EOF

# Add initscript (cut the appropriate tail of $0 script):
sed '1,/^# XXX:.*\/init script:/d' <"$0" >"${INITFSDIR}init"
chmod 0755 "${INITFSDIR}init"
touch -r "$0" "${INITFSDIR}init"

exit

# XXX: initrd's /init script:
#!/bin/busybox sh

# Load modules.
modules() {
    for m in "$@" ; do busybox modprobe "$m" >/dev/null 2>&1 ; done
}

# Load crypto modules.
ciphers() {
    ifs0="$IFS" ; IFS="-"
    for m in $1 ; do modules "${m#essiv:}" ; done
    IFS="$ifs0"
}

# Recovery shell.
recovery() {
    PS1='(recovery) \w \$ ' busybox sh
	### </dev/tty0 >/dev/tty0 2>/dev/tty0
}

# Decrypt the volume using current cipher/size/hash parameters.
decrypt() {
    cryptdev="`busybox findfs "$1" 2>/dev/null`"
    if [ "z$cryptdev" != "z" ] ; then
	vname="${cryptdev##*/}-decrypted"
	if ! [ -e /dev/mapper/control ] ; then
	    # create /dev/mapper/control:
	    lvm vgscan --mknodes >/dev/null 2>&1
	fi
	# Disable kernel messages on console:
	printk0="`busybox cat /proc/sys/kernel/printk`"
	echo 0 >/proc/sys/kernel/printk
	# Decrypt the crypto-volume:
	if cryptsetup isLuks "$cryptdev" ; then
	    # TODO: query necessary ciphers from LUKS header
	    ciphers "aes-xts-plain64"
	    cryptsetup luksOpen "$cryptdev" "$vname"
	else
	    # Plain volumes don't store information about the
	    # ciphers used, so we need the $crypt_csh hint:
	    ifs0="$IFS" ; IFS="/" ; read c s h <<EOF
$crypt_csh
EOF
	    IFS="$ifs0"
	    if [ "z$c" != "z" ] ; then C="--cipher=$c" ; fi
	    if [ "z$s" != "z" ] ; then S="--key-size=$s" ; fi
	    if [ "z$h" != "z" ] ; then H="--hash=$h" ; fi
	    ciphers "${c:-aes-cbc-essiv:sha265}"
	    echo cryptsetup $C $S $H create "$vname" "$cryptdev"
	    cryptsetup $C $S $H create "$vname" "$cryptdev"
	fi
	# Enable kernel messages back:
	busybox cat >/proc/sys/kernel/printk <<EOF
$printk0
EOF
	# Activate logical volumes in the decrypted volume:
	lvm vgchange -aly >/dev/null 2>&1
    fi
}

# Mount a filesystem mentioned in fstab file in read-only mode.
#   USAGE: mount_fstab_ro /path/to/fstab /orig/mnt /new/mnt
#   example: mount_fstab_ro /mnt/root/etc/fstab /usr /mnt/root/usr
mount_fstab_ro() {
    for f in "$1" "$3" ; do
	if ! [ -e "$f" ] ; then
	    echo "$f doesn't exist" >&2
	    return 1
	fi
    done
    if ! [ -d "$3" ] ; then
	echo "$3 is not a directory" >&2
	return 1
    fi
    mnt=""
    while read dev mnt typ opts dump pass rest ; do
	if [ "z$mnt" = "z$2" ] ; then break ; fi
    done <"$1"
    if [ "z$mnt" = "z$2" ] ; then
	ropts="ro"
	oa=""
	oe=""
	os=""
	od=""
	ifs0="$IFS" ; IFS=","
	for o in $opts ; do
	    case "$o" in
		ro|rw|auto|noauto|nouser) o="";;
		group|owner)
		    os=",nosuid"
		    od=",nodev"
		    o=""
		    ;;
		user|users)
		    oe=",noexec"
		    os=",nosuid"
		    od=",nodev"
		    o=""
		    ;;
		defaults)
		    oa=",async"
		    oe=",exec"
		    os=",suid"
		    od=",dev"
		    o=""
		    ;;
		async)   oa=",async";   o="";;
		sync)    oa=",sync";    o="";;
		exec)    oe=",exec";    o="";;
		noexec)  oe=",noexec";  o="";;
		suid)    os=",suid";    o="";;
		nosuid)  os=",nosuid";  o="";;
		dev)     od=",dev";     o="";;
		nodev)   od=",nodev";   o="";;
	    esac
	    case "$o" in ?) ropts="$ropts,$o";; esac
	done
	ropts="$ropts$oa$oe$os$od"
	IFS="$ifs0"
	echo busybox mount -t "$typ" -o "$ropts" "$dev" "$3"
	busybox mount -t "$typ" -o "$ropts" "$dev" "$3"
    else
	echo "$2 fs not found in $1" >&2
	return 1
    fi
}

# Add /bin and /sbin to PATH:
path0="$PATH"
for p in /bin /sbin ; do
    case "$PATH" in
	*:$p:*|$p:*|*:$p) ;;
	?*) PATH="$p:$PATH" ;;
	*) PATH="$p" ;;
    esac
done
if [ "z$PATH" != "z$path0" ] ; then
    export PATH
fi

# Don't mount /dev if it's already mounted by e.g.
# CONFIG_DEVTMPFS_MOUNT=y:
if ! busybox mountpoint -q /dev ; then
    busybox mount -t devtmpfs none /dev
fi
# Mount /proc and /sys:
busybox mount -t proc none /proc
busybox mount -t sysfs none /sys

# We need support for scsi/ata/usb/lvm/crypt block devices
# (TODO: detect/load ATA modules besides ata_piix):
modules scsi_mod usb-common usbcore usb-storage uas \
    xhci-hcd xhci-pci ehci-hcd ehci-pci ohci-hcd ohci-pci uhci-hcd \
    libata ata_piix dm-mod dm-crypt sd_mod cdrom sr_mod
# We need keyboard support (i8042/atkbd/usb/hid) for reading
# dm-crypt passphrase:
modules libps2 serio atkbd i8042 hid hid-generic hidp usbhid

# Parse kernel commandline to find root volume ID or device
# and to find out which volumes to decrypt:
for a in `cat /proc/cmdline` ; do
    case "$a" in
	recovery) recovery=1;;
	root=?*) root="${a#root=}";;
	crypt_csh=*) crypt_csh="${a#crypt_csh=}";;
	crypt_root=?*) decrypt "${a#crypt_root=}";;
	rd.luks.uuid=?*) decrypt "UUID=${a#rd.luks.uuid=}";;
    esac
done

# Search for root volume and mount it:
rootdev="`busybox findfs "$root" 2>/dev/null`"

# Start recovery shell if root volume can not be found or mounted, or
# recovery is explicitly requested:
modules ext3 ; # TODO: detect filesystem on rootdev
if [ "z$rootdev" = "z" ] \
|| ! busybox mount -o ro "$rootdev" /mnt/root \
|| [ "z$recovery" = "z1" ] ; then
    recovery
fi

# Mount /usr filesystem (needed for udev?):
if [ -e /mnt/root/etc/fstab ] && [ -d /mnt/root/usr ] \
&& ! [ -e /mnt/root/usr/bin/md5sum ] \
&& grep '/usr.*must.*mount.*by.*initr' \
/mnt/root/lib/rc/sh/init.sh >/dev/null 2>&1 ; then
    # XXX: don't mount /usr from initrd because this prevents
    # "fsck /usr" later:
    # mount_fstab_ro /mnt/root/etc/fstab /usr /mnt/root/usr
    busybox true
fi

# Unmount /sys, /proc, /dev and switch to new root:
busybox umount /sys
busybox umount /proc
busybox umount /dev
cd /mnt/root
exec busybox switch_root /mnt/root /sbin/init

# vi:set filetype=sh sw=4 noet ts=8 tw=71:
