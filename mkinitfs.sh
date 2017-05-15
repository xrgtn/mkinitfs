#!/bin/sh

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
kernel/drivers/scsi    sd_mod sr_mod scsi_mod scsi_tgt transport_sas libsas ufshcd
kernel/drivers/usb     [eoux]hci-hcd hci*pci ^usbcore ^hid.ko usbhid common storage ums uas.ko
kernel/fs              ext2 ext3 ext4 xfs isofs ufs jfs reiserfs mbcache jbd2 fscrypto
kernel/lib             crc16 crc32 crc-itu-t crc-t10dif zlib_inflate
EOF
    # XXX: create modules.order and modules.builtin symlinks for
    # /sbin/depmod:
    for i in order builtin ; do
	t="${INITFSDIR}lib/modules/$k/modules.$i"
	s="/lib/modules/$k/modules.$i"
	if ! [ -e "$t" ] ; then
	    ln -s "$s" "$t"
	fi
    done
    /sbin/depmod -b"${INITFSDIRNOTRAILINGSLASH}" \
	-eF"/boot/System.map-$k" "$k"
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

# Add initscript:
cp --preserve=mode,timestamps "${0%/*}"/init "${INITFSDIR}"

# vi:set sw=4 noet ts=8 tw=71:
