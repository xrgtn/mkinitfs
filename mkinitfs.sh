#!/bin/sh

TDIR="/tmp/tmp-mkinitfs-$$"
if ! mkdir -m 0750 "$TDIR" ; then
    E="$?"
    echo "ERROR: mkdir $TDIR" 1>&2
    exit "$E"
fi
rm_rf_tdir() {
    rm -rf "$TDIR"
}
trap rm_rf_tdir EXIT

TMPOUT="$TDIR/out"
TMPOUT2="$TDIR/out-2"
MODLIST_PL="$TDIR/modlist.pl"

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
    #rm -f "$TMPOUT"
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

# Create a helper modlist.pl script:
cat >"$MODLIST_PL" <<'EOS'
#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Std;

my (%o, $u);
$u = (not getopts("dhk:m:rs", \%o) or scalar(@ARGV) < 1) ? 2
    : (defined $o{h}) ? 1 : 0;
if ($u) {
    print STDERR <<EOF;
USAGE: $0 [opts] MODULE1 [MODULE2 ...]
e.g.:  $0 -rsk 4.19.44-gentoo kernel/fs/ext4/ext4.ko
 opts:
  -d       print out internal \$dep, \$alias etc maps
  -h       print this usage message
  -k KVER  specify kernel version (e.g. 5.15.11-gentoo)
  -m FILE  filename/pathname of modules.dep file
  -r       print reverse dependencies after each module
  -s       include softdeps (modules.builtin and modules.aliases will be
	   used to resolve dependencies from modules.softdep). For
	   softdep a single "generic" implementaion is chosen if it
	   exists, otherwise all alternatives will be added. If the
	   "generic" alternative is built into kernel, softdep will be
	   considered "satisfied".
 args:
  MODULEn  pathname/filename of a kernel module
           or '-' to indicate reading modlist from STDIN
 output:
  $0 produces sequence of modules to be loaded to satisfy
  dependencies for the specified arguments. The output
  doesn't contain duplicates and is sorted by dependency
  and order of arguments (including lines read from STDIN).
  When there are duplicates on cmdline, only the first one
  is listed, the rest are omitted.
EOF
    exit --$u;
};
require Data::Dumper if $o{d};
# Get modules.dep filename/pathname:
if (not defined($o{k}) and not defined $o{m}) {
    open my $fh, "<", "/proc/version" or die "/proc/version: $!";
    my $v = <$fh>;
    my @a = split /\s+/, $v, 4;
    $o{k} = $a[2];
    close $fh;
};
$o{m} = "/lib/modules/$o{k}/modules.dep" if not defined $o{m};

# Get modules.alias, modules.softdep and modules.builtin
# filenames/pathnames:
(my $modulesdeppfx = $o{m}) =~ s/\.dep\z//;
$o{alias}   = $modulesdeppfx.".alias";
$o{softdep} = $modulesdeppfx.".softdep";
$o{builtin} = $modulesdeppfx.".builtin";

# Basename to fullname[s] map:
# {"mod.ko" => {"path1/to/mod.ko"=>1, "path2/mod.ko"=>1,...}};
my $fullname = {};

# Get shortname of a file (strip .ko extension and directory prefix if
# possible):
sub shortname($) {
   return ($_[0] =~ m%\A(?:.*/)?([^/]+)\z%is ? $1 : $_[0])
       =~ s/\.ko\z//ir;
};

# Add filename $f to $fullname map:
sub add_fullname($$) {
    my ($f, $fullname) = @_;
    if ($f =~ m%\A(?:.*/)?([^/]+)\z%is) {
	$fullname->{$1}->{$f} = 1;
    } else {
	return 0;
    };
};

# Dependency and reverse dependency maps:
my $dep1 = {};	# 1st-level (immediate) dependencies.
		# If $dep1->{A}->{B} exists, then A depends on B.
my $dep  = {};	# Complete (transitive) dependencies map. E.g.:
		# * keys(%{$dep->{A}) - all dependencies of node A;
		# * $dep->{A}->{Z} == dependency path from A to Z
		#   (as string, like "A => F => Z");
my $rdep = {};	# Full/transitive reverse dependencies. E.g. if
		# $rdep->{Y}->{B} exists, then node B depends on Y
		# ("Y <= A <= C <= B");

# add_dep($m, $d, $dep1, $dep, $rdep): add "$m => $d" dependency
# into $dep1, $dep and $rdep maps:
sub add_dep($$$$$) {
    my ($m, $d, $dep1, $dep, $rdep) = @_;
    $dep1->{$m}->{$d} = 1;
    # Some asserts:
    die "$m => $d exists but $d <= $m doesn't\n"
	if exists($dep->{$m}->{$d})
	and not exists $rdep->{$d}->{$m};
    die "$d <= $m exists but $m => $d doesn't\n"
	if exists($rdep->{$d}->{$m})
	and not exists $dep->{$m}->{$d};
    if (not exists $dep->{$m}->{$d}
    or not exists $rdep->{$d}->{$m}) {
	foreach my $a (($m, exists($rdep->{$m}) ?
	keys(%{$rdep->{$m}}) : ())) {
	    foreach my $z (($d, exists($dep->{$d}) ?
	    keys(%{$dep->{$d}}) : ())) {
		$dep->{$a}->{$z} =
			($a eq $m ? $m : $dep->{$a}->{$m})
			." => ".
			($d eq $z ? $d : $dep->{$d}->{$z})
		    if not exists $dep->{$a}->{$z};
		$rdep->{$z}->{$a} =
			($z eq $d ? $d : $rdep->{$z}->{$d})
			." => ".
			($m eq $a ? $m : $rdep->{$m}->{$a})
		    if not exists $rdep->{$z}->{$a};
	    };
	};
    };
};

# Read modules.dep file, fill in $dep/$rdep & $fullname maps:
open my $fh, "<", $o{m} or die "$o{m}: $!";
while (<$fh>) {
    s/\A[:\s]+//;
    s/[:\s]+\z//;
    my @a = split /[:\s]+/;
    next if scalar(@a) < 1;
    my $m = shift @a;
    next if not add_fullname $m, $fullname;
    foreach my $d (@a) {
	next if not add_fullname $d, $fullname;
	add_dep $m, $d, $dep1, $dep, $rdep;
    };
};
close $fh;

my $builtin = {};	# builtin modules
my $alias = {};		# alias map
# Read modules.builtin file if -s option has been specified, add
# names to $builtin and $fullname maps:
if ($o{s}) {
    open my $fh, "<", $o{builtin} or die "$o{builtin}: $!";
    while (<$fh>) {
	if (/\A\s* ([^#\s](?:\V*\S)?) \s*\z/x) {
	    my $m = $1;
	    next if not add_fullname $m, $fullname;
	    $builtin->{$m} = 1;
	    # Builtin modules don't declare the finctionality they
	    # implement (in form of aliases) in modules.alias file. E.g.
	    # kernel/crypto/sha256_generic.ko should have alias "sha256"
	    # but it's stated nowhere.
	    if ($m =~ /[_-]generic/i) {
		# If module is named xxx_generic, then it most probably
		# implements "xxx" (without asm or hw optimizations):
		my $a = $m;
		$a =~ s/\A.*\///s;	# strip dirname
		$a =~ s/\.ko\z//i;	# strip suffix
		$a =~ s/[_-]generic//i	# strip -generic/_generic
		and $alias->{$a}->{$m} = 1;
	    };
	};
    };
    close $fh;
};
print Data::Dumper::Dumper($fullname) if $o{d};
print Data::Dumper::Dumper($builtin) if $o{d};

# Read alias map if -s option has been specified:
if ($o{s}) {
    open my $fh, "<", $o{alias} or die "$o{alias}: $!";
    while (<$fh>) {
	s/\A[:\s]+//;
	s/[:\s]+\z//;
	my @a = split /\s+/;
	next if scalar(@a) < 3 or shift(@a) ne "alias";
	my $a = shift @a;
	foreach (@a) {
	    # search for variants of $_ filename in $fullname map:
	    my (@v1, @v2, $v);
	    push @v1, $_;
	    push @v1, $_.".ko" if $_ !~ /\.ko\z/i;
	    foreach (@v1) {
		push @v2, $v if ($v = $_) =~ tr/-/_/;
		push @v2, $v if ($v = $_) =~ tr/_/-/;
	    };
	    foreach (@v1, @v2) {
		if (exists $fullname->{$_}) {
		    # Basename may match to several filenames:
		    foreach my $f (keys %{$fullname->{$_}}) {
			$alias->{$a}->{$f} = 1;
		    };
		    last;
		};
	    };
	};
    };
    close $fh;
    print Data::Dumper::Dumper($alias) if $o{d};
};

# Return list of filenames matching modname $n, or empty list if
# modname's not found.
sub findmodule($$) {
    my ($mn, $fullname) = @_;
    my (%r, @v1, $v, $mko);
    push @v1, $mn;
    push @v1, $v if ($v = $mn) =~ tr{-}{_};
    push @v1, $v if ($v = $mn) =~ tr{_}{-};
    if ($mn !~ /\.ko\z/i) {
	my $m2 = $mn.".ko";
	push @v1, $m2;
	push @v1, $v if ($v = $m2) =~ tr{-}{_};
	push @v1, $v if ($v = $m2) =~ tr{_}{-};
    };
    foreach (@v1) {
	return keys %{$fullname->{$_}} if exists $fullname->{$_};
    };
    return ();
};

# Return list of modules matching alias $n, or empty list if no modules
# match.
sub findalias($$$) {
    my ($an, $alias, $fullname) = @_;
    my (%r, @v1, $v);
    push @v1, $an;
    push @v1, $v if ($v = $an) =~ tr{-}{_};
    push @v1, $v if ($v = $an) =~ tr{_}{-};
    foreach $v (@v1) {
	if (exists $alias->{$v}) {
	    $r{$_} = 1 for keys %{$alias->{$v}};
	    last;
	};
    };
    # Prefer "generic" and shorter modules (move them to the front):
    my @r = sort {
	($a =~ /generic/i)
	    ? ($b =~ /generic/i ?
		(length($a) <=> length($b) or $a cmp $b) : -1)
	    : ($b =~ /generic/i ?
		1 : (length($a) <=> length($b) or $a cmp $b))
	;
    } keys %r;
    # If alias was found:
    if (scalar(@r)) {
	# For alias, only the 1st implementation is if it's generic.
        @r = ($r[0]) if $r[0] =~ /generic/i;
    } else {
	# When alias not found, look up modname in $fullname map:
	@r = findmodule $an, $fullname;
    };
    return @r;
};

# Read softdep map if -s flag has been given, and add softdeps to
# dep/rdep maps:
if ($o{s}) {
    open my $fh, "<", $o{softdep} or die "$o{softdep}: $!";
    while (<$fh>) {
	if (/\A\s* softdep \s+ (\S+) \s+ (pre|post) \s*:\s*
		(\S(?:\V*\S)?) \s*\z/imsx) {
	    my ($g1, $t, $g2) = ($1, lc($2), $3);
	    my (%m1, %m2);
	    $m1{$_} = 1 foreach findmodule $g1, $fullname;
	    foreach my $an (split /\s+/, $g2) {
		$m2{$_} = 1 foreach findalias $an, $alias, $fullname;
	    };
	    print STDERR $g1." (".(join ",", keys %m1).")".
		    ($t eq "post" ? " <~ " : " ~> ").
		    $g2." (".(join ",", keys %m2).")\n"
		if $o{d};
	    my ($smods, $sdeps) = ($t eq "post") ? (\%m2, \%m1)
		: (\%m1, \%m2);
	    foreach my $m (keys %$smods) {
		foreach my $d (keys %$sdeps) {
		    # Add dep for non-builtin modules $m => $d:
		    add_dep $m, $d, $dep1, $dep, $rdep
			if not exists($builtin->{$m})
			    and not exists $builtin->{$d};
		};
	    };
	};
    };
    close $fh;
};

print Data::Dumper::Dumper($dep) if $o{d};

# Get set of modules from cmdline and/or STDIN:
my %inmods;	# 'input' mods
foreach my $a (@ARGV) {
    if ($a eq "-") {
	while (<STDIN>) {
	    s/\A\s+//;
	    s/\s+\z//;
	    s/\A\.\///;
	    $inmods{$_} = 1;
	};
    } else {
	$a =~ s/\A\.\///;
	$inmods{$a} = 1;
    };
};

# Returns list of module+requisites.
sub modlist($$$$);
sub modlist($$$$) {
    my ($m, $dep1, $parents, $pn) = @_;
    if (exists $pn->{$m}) {
	die "circular dependency: ".join(" => ",
	    (@{$parents}[$pn->{$m}..$#{$parents}], $m)).
	    "\n";
    };
    my (@mlist, %mlisted);
    my @pa2 = (@$parents, $m);		# copy parents array and append
    my %pn2 = %$pn; $pn2{$m} = $#pa2;	# copy pn hash and insert
    foreach my $c (sort keys %{$dep1->{$m}}) {
	my @clist = modlist $c, $dep1, \@pa2, \%pn2;
	foreach my $d (@clist) {
	    next if exists $mlisted{$d};
	    $mlisted{$d} = $c;
	    push @mlist, $d;
	};
    };
    push @mlist, $m;
    return @mlist;
};

# Add requisite modules:
my (@outmods, %outmap);
foreach my $a (sort keys %inmods) {
    my @a = modlist $a, $dep1, [], {};
    foreach my $m (@a) {
	if (not exists $outmap{$m}) {
	    push @outmods, $m;
	    $outmap{$m} = 1;
	};
    };
};

# Print modules+requisites with relevant subset of reverse dependencies:
foreach my $m (@outmods) {
    use integer;
    my $tn = 5 - length($m) / 8;
    no integer;
    $tn = 1 if $tn < 1;
    print STDOUT $m;
    if (defined($o{r})) {
	my $i = 0;
	foreach my $r (keys %{$rdep->{$m}}) {
	    if (exists $outmap{$r}) {
		print STDOUT ($i++ ? " " : "\t" x $tn).shortname($r);
	    };
	};
    };
    print "\n";
};

# vi:set sw=4 noet ts=8 tw=72:
EOS
# NOTE: chmod is avoided for fear of "noexec" mount option :)
#chmod u+x "$MODLIST_PL"

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
for K in "$KERN" ; do
    KSRC="/lib/modules/$K/"
    KDST="${INITFSDIR}lib/modules/$K/"
    # Create list of required modules at KSRC directory:
    mkdir_if_doesnt_exist "$KDST"
    rm -f "$TMPOUT"
    pushd "$KSRC" >/dev/null
    while read MODS ; do
        for M in $MODS; do
	    if [ "z$M" != "z" ] ; then
		find "./" -type f -name "$M.ko" >>"$TMPOUT"
	    fi
	done
    done <<EOF
aes_generic anubis arc4 blowfish_generic twofish_generic
camellia_generic cast5_generic cast6_generic des_generic dh_generic
khazad rsa_generic serpent_generic tgr192
adiantum aead cbc pcbc cfb ccm ctr cts ecb gcm keywrap lrw ofb xts
echainiv geniv essiv seqiv
blake2b_generic cmac hmac vmac md4 md5 rmd128 rmd160 rmd256 rmd320
sha1_generic sha256_generic sha512_generic sha3_generic wp256 wp384
wp512 xcbc xxhash_generic
crc32_generic crc32c_generic crct10dif_generic lz4_decompress xz_dec

btrfs ext2 ext3 ext4 fscrypto isofs jbd2 jfs mbcache msdos reiserfs
squashfs ufs vfat xfs
nls_ascii nls_cp437 nls_euc-jp nls_iso8859-1 nls_iso8859-15 nls_utf8

scsi_mod usb-storage uas xhci-hcd xhci-pci ehci-hcd ehci-pci ohci-hcd
ohci-pci uhci-hcd ata_piix ata_generic ahci ahci_platform pata_acpi
sata_nv dm-mod dm-crypt sd_mod cdrom sr_mod

libps2 serio atkbd i8042 hid hid-generic hidp usbhid input-leds

aes_ti aesni-intel ccp-crypto crc32-pclmul crc32c-intel geode-aes
serpent-sse2-i586 twofish-i586
algif_skcipher algif_hash algif_rng algif_aead
EOF
    popd >/dev/null
    # Add dependecies of the required modules:
    perl "$MODLIST_PL" -rsm"${KSRC}modules.dep" - \
	<"$TMPOUT" >"${KDST}modlist.rdep"
    E="$?"
    rm -f "$MODLIST_PL"
    if [ "z$E" != "z0" ] ; then
	die "$E" "modlist.pl failed"
    fi
    # Copy modules to KDST directory, creating subdirectories as
    # necessary:
    while read M RDEPS; do
	case "$M" in
	    */*) mkdir_if_doesnt_exist "$KDST${M%/*}";;
	esac
	echo "+ $M"
	cp --preserve=mode,timestamps "$KSRC$M" "$KDST$M"
    done <"${KDST}modlist.rdep"
    rm -f "$TMPOUT"
    # Copy modules.order, modules.builtin and modules.builtin.modinfo
    # files for /sbin/depmod:
    for SFX in order builtin builtin.modinfo ; do
	S="${KSRC}modules.$SFX"
	T="${KDST}modules.$SFX"
	if ! [ -e "$T" ] ; then
	    cp --preserve=mode,timestamps "$S" "$T"
	fi
    done
    # Generate depmod files for initrd subset of kernel modules:
    if ! /sbin/depmod -b"${INITFSDIRNOTRAILINGSLASH}" \
	    -eF"/boot/System.map-$K" "$K" >"$TMPOUT" 2>&1 ; then
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
for D in bin sbin etc/lvm dev proc sys mnt/root run/cryptsetup ; do
    mkdir_if_doesnt_exist "${INITFSDIR}$D"
done
##mknod "${INITFSDIR}dev/null" c 1 3
##mknod "${INITFSDIR}dev/random" c 1 8
##mknod "${INITFSDIR}dev/urandom" c 1 9
##mknod "${INITFSDIR}dev/console" c 5 1
##mknod "${INITFSDIR}dev/tty" c 5 0
##mknod "${INITFSDIR}dev/tty1" c 4 1

# Add busybox and its symlinks:
if ! cp --preserve=mode,timestamps \
	/bin/busybox "${INITFSDIR}bin/" ; then
    die "$?" "cannot copy busybox to ${INITFSDIR}bin/"
fi
/bin/busybox --list-full | while read L ; do
    case "$L" in
	bin/busybox) ;; # don't symlink busybox to itself
	*/*/*) echo "WARNING: skipping busybox link $L" 1>&2 ;;
	bin/*|sbin/*)
	    # If dest file is a symlink, remove it before
	    # symlinking again to busybox:
	    if [ -h "${INITFSDIR}$L" ] ; then rm -f "${INITFSDIR}$L"; fi
	    case "$L" in
		bin/*) ln -s busybox "${INITFSDIR}$L" ;;
		sbin/*) ln -s ../bin/busybox "${INITFSDIR}$L" ;;
	    esac
	    ;;
    esac
done

# Add cryptsetup/lvm:
if ! cp --preserve=mode,timestamps \
	/sbin/lvm.static "${INITFSDIR}sbin/lvm" ; then
    die "$?" "cannot copy lvm.static to ${INITFSDIR}sbin/lvm"
fi
if ldd /sbin/cryptsetup >/dev/null 2>/dev/null ; then
    ldd /sbin/cryptsetup
    die "/sbin/cryptsetup isn't statically linked"
fi
if ! cp --preserve=mode,timestamps \
	/sbin/cryptsetup "${INITFSDIR}sbin/" ; then
    die "$?" "cannot copy cryptsetup to ${INITFSDIR}sbin/lvm"
fi
cat >"${INITFSDIR}etc/lvm/lvm.conf" <<EOF
activation {
    # Disable udev synchronisation (there's no udev in initrd):
    udev_sync=0
    udev_rules=0
}
devices {
    # No idea what the list but no chance in hell there will be udev
    # in my custom initrd, so don't even try:
    obtain_device_list_from_udev=0
}
global {
    # No lvmetad nor dbus here either, Sherlock!
    use_lvmetad=0
    notify_dbus=0
}
log {
    # Same shit with syslog:
    syslog=0
}
EOF

# Add 915resolution if present:
for P in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin \
/bin ; do
    if [ -x "$P/915resolution" ] ; then
	cp --preserve=mode,timestamps "$P/915resolution" \
	    "${INITFSDIR}sbin/"
	break
    fi
done

# Add initscript (cut the appropriate part of $0 script):
echo '#!/bin/busybox sh' >"${INITFSDIR}init" ; # prepend shebang
chown 0:0  "${INITFSDIR}init"
chmod 0755 "${INITFSDIR}init"
sed -n '/^# XXX: \/init start/,/^# XXX: \/init end/p' <"$0" \
    >>"${INITFSDIR}init" ; # cut from '/init start' to '/init end'
touch -r "$0" "${INITFSDIR}init" ; # copy timestamp from mkinitfs.sh

# Dump current keyboard map to use at boot time:
KMAP="kmap"
KBDMODE="`busybox kbd_mode -C /dev/tty1 2>/dev/null`"
if [ "z$?" = "z0" ]; then
	case "z$KBDMODE" in
	z*ASCII*) KMAP="$KMAP-a";;
	z*UTF*)   KMAP="$KMAP-u";;
	esac
fi
if busybox dumpkmap >"${INITFSDIR}$KMAP"; then
	echo "dumped current keymap to $KMAP"
else
	rm -f "${INITFSDIR}$KMAP"
fi

# Exit mkinitfs.sh:
exit

# XXX: /init start:

# Load module with deps:
modprobe2() {
   if [ "z$KVER" != "z" ] \
   && [ -f /lib/modules/"$KVER"/modlist.rdep ] ; then
       MOD="${1%.ko}"
       while read M RDEPS ; do
	   M="${M##*/}"
	   M="${M%.ko}"
	   if [ "z$M" = "z$MOD" ] ; then
	       busybox modprobe "$MOD" >/dev/null 2>&1
	       return 0
	   fi
	   for R in $RDEPS ; do
	       R="${R##*/}"
	       R="${R%.ko}"
	       if [ "z$R" = "z$MOD" ] ; then
		   busybox modprobe "$M" >/dev/null 2>&1
	       fi
	   done
       done </lib/modules/"$KVER"/modlist.rdep
   fi
   busybox modprobe "$1" >/dev/null 2>&1
}

# Load modules.
modules() {
    for M in "$@"; do modprobe2 "$M"; done
}

# Load crypto modules.
ciphers() {
    IFS0="$IFS" ; IFS="-:"
    for M in $1 ; do
	case "$M" in
	serpent)
	    # somehow serpent requires algif_skcipher interface:
	    modules algif_skcipher \
		serpent_generic serpent-sse2-i586 "$M"
	    ;;
	xts)
	    # If ecb.ko is not loaded for aes-xts-plain64, cryptsetup
	    # fails with ioctl error:
	    #   device-mapper: table: 254:0: crypt: Error allocating
	    #     crypto tfm (-ENOENT)
	    #   device-mapper: ioctl: error adding target to table
	    modules xts ecb
	    ;;
	plain64)
	    # ignore
	    ;;
	*)
	    modules "$M"
	    ;;
	esac
    done
    IFS="$IFS0"
}

# Recovery shell.
recovery() {
    # Typically /init script is run on /dev/tty1...
    CTTY=console		# /dev/console
    while [ -f /sys/class/tty/$CTTY/active ] ; do
	read CTTY </sys/class/tty/$CTTY/active
	CTTY="${CTTY##* }"	# last one in the list
    done
    CTTY="/dev/$CTTY"
    cat <<EOF
/init: starting (recovery) shell. If you want to continue booting, set
up root volume manually, mount root filesystem with "ro" option on
/mnt/root and exit. E.g.:
$ cryptsetup luksOpen /dev/sdb2 sdb2-decrypted
$ lvm vgchange -a y vg_gentoo
$ mount -o ro /dev/mapper/vg_gentoo-root /mnt/root
$ exit
EOF
    PS1='(recovery) \w \$ ' busybox setsid -c busybox sh \
	0<>"$CTTY" 1<>"$CTTY" 2<>"$CTTY"
}

# Decrypt the volume using current cipher/size/hash parameters.
decrypt() {
    CRYPTDEV="`busybox findfs "$1" 2>/dev/null`"
    E="$?"
    if [ "z$CRYPTDEV" = "z" ] ; then
	printf "%s: crypt vol %s not found!\n" "$0" "$1"
	return "$E"
    else
	printf "%s: decrypt %s (%s):\n" "$0" "$CRYPTDEV" "$1"
	VNAME="${CRYPTDEV##*/}-decrypted"
	if ! [ -e /dev/mapper/control ] ; then
	    # create /dev/mapper/control:
	    lvm vgscan --mknodes >/dev/null 2>&1
	fi
	modules dm-crypt
	# Prepare for disabling kernel messages on console:
	PRINTK0="`busybox cat /proc/sys/kernel/printk`"
	echo 0 >/proc/sys/kernel/printk
	# Decrypt the crypto-volume:
	if cryptsetup isLuks "$CRYPTDEV" ; then
	    C0="aes-xts-plain64"	# default cipher
	    while read A B C; do
		case "$A$B" in [Cc]ipher:[a-zA-Z0-9_]*)
		    C0="$B"; break;;	# LUKS vol cipher
		esac
	    done <<EOF
`cryptsetup luksDump "$CRYPTDEV"`
EOF
	    ciphers "$C0"
	    # Disabe kernel messages on console:
	    echo 0 >/proc/sys/kernel/printk
	    cryptsetup luksOpen "$CRYPTDEV" "$VNAME"
	else
	    # Plain volumes don't store information about the
	    # ciphers used, so we need the $CRYPT_CSH hint:
	    IFS0="$IFS" ; IFS="/" ; read C0 S0 H0 <<EOF
$CRYPT_CSH
EOF
	    IFS="$IFS0"
	    C="";  S=""; H="";
	    if [ "z$C0" != "z" ] ; then C="--cipher=$C0" ; fi
	    if [ "z$S0" != "z" ] ; then S="--key-size=$S0" ; fi
	    if [ "z$H0" != "z" ] ; then H="--hash=$H0" ; fi
	    ciphers "${C0:-aes-cbc-essiv:sha256}"
	    echo cryptsetup $C $S $H open --type plain \
		"$CRYPTDEV" "$VNAME"
	    # Disabe kernel messages on console:
	    echo 0 >/proc/sys/kernel/printk
	    cryptsetup $C $S $H open --type plain \
		"$CRYPTDEV" "$VNAME"
	fi
	# Re-enable kernel messages on console:
	busybox cat >/proc/sys/kernel/printk <<EOF
$PRINTK0
EOF
	# Activate logical volumes in the decrypted volume:
	lvm vgchange -aly >/dev/null 2>&1
    fi
}

# Mount a filesystem mentioned in fstab file in read-only mode.
#   USAGE: mount_fstab_ro /path/to/fstab /orig/mnt /new/mnt
#   example: mount_fstab_ro /mnt/root/etc/fstab /usr /mnt/root/usr
mount_fstab_ro() {
    for F in "$1" "$3" ; do
	if ! [ -e "$F" ] ; then
	    echo "$F doesn't exist" >&2
	    return 1
	fi
    done
    if ! [ -d "$3" ] ; then
	echo "$3 is not a directory" >&2
	return 1
    fi
    MNT=""
    while read DEV MNT TYP OPTS DUMP PASS REST ; do
	if [ "z$MNT" = "z$2" ] ; then break ; fi
    done <"$1"
    if [ "z$MNT" = "z$2" ] ; then
	ROPTS="ro"
	OA=""
	OE=""
	OS=""
	OD=""
	IFS0="$IFS" ; IFS=","
	for O in $OPTS ; do
	    case "$O" in
		ro|rw|auto|noauto|nouser) O="";;
		group|owner)
		    OS=",nosuid"
		    OD=",nodev"
		    O=""
		    ;;
		user|users)
		    OE=",noexec"
		    OS=",nosuid"
		    OD=",nodev"
		    O=""
		    ;;
		defaults)
		    OA=",async"
		    OE=",exec"
		    OS=",suid"
		    OD=",dev"
		    O=""
		    ;;
		async)   OA=",async";   O="";;
		sync)    OA=",sync";    O="";;
		exec)    OE=",exec";    O="";;
		noexec)  OE=",noexec";  O="";;
		suid)    OS=",suid";    O="";;
		nosuid)  OS=",nosuid";  O="";;
		dev)     OD=",dev";     O="";;
		nodev)   OD=",nodev";   O="";;
	    esac
	    case "$O" in ?) ROPTS="$ROPTS,$O";; esac
	done
	ROPTS="$ROPTS$OA$OE$OS$OD"
	IFS="$IFS0"
	echo busybox mount -t "$TYP" -o "$ROPTS" "$DEV" "$3"
	busybox mount -t "$TYP" -o "$ROPTS" "$DEV" "$3"
    else
	echo "$2 fs not found in $1" >&2
	return 1
    fi
}

set915resolution() {
    case "$1" in
	*:*x*)
	    if [ -x /sbin/915resolution ] ; then
		WH="${1#*:}"
		# Temporarily loosen iopl()/outb() restrictions:
		GRIOF="/proc/sys/kernel/grsecurity/disable_priv_io"
		GRIO=0
		if [ -f "$GRIOF" ] ; then read GRIO <"$GRIOF" ; fi
		[ "z$GRIO" != "z0" ] && echo 0 >"$GRIOF"
		# Set i915 resolution:
		echo "Setting mode 0x"${1%:*}"'s resolution to $WH"
		/sbin/915resolution "${1%:*}" "${WH%x*}" "${WH#*x}"
		# Restore iopl()/outb() restrictions:
		[ "z$GRIO" != "z0" ] && echo "$GRIO" >"$GRIOF"
	    fi
	    ;;
    esac
}

# Add /bin and /sbin to PATH:
PATH0="$PATH"
for P in /bin /sbin ; do
    case "$PATH" in
	*:$P:*|$P:*|*:$P) ;;
	?*) PATH="$P:$PATH" ;;
	*) PATH="$P" ;;
    esac
done
if [ "z$PATH" != "z$PATH0" ] ; then
    export PATH
fi

# Don't mount /dev if it's already mounted by e.g.
# CONFIG_DEVTMPFS_MOUNT=y:
if ! busybox mountpoint -q /dev ; then
    busybox mount -t devtmpfs -o nosuid dev /dev
fi
# Mount /proc and /sys:
busybox mount -t proc -o nodev,nosuid,noexec proc /proc
busybox mount -t sysfs -o nodev,nosuid,noexec sysfs /sys
# XXX: /run is needed for cryptestup isLuks/luksOpen, but we create
# /run/cryptsetup statically and it works OK, so tmpfs mount is not
# needed:
### busybox mount -t tmpfs -o nodev,nosuid,mode=0755 tmpfs /run

# Read kernel version (uname -r):
read A B KVER C </proc/version

# Load [basic] implementations for library/crypt modules, otherwise
# e.g. ext4 (which lists any crc32c implementation as softdep, cf
# /lib/modules/X.Y.Z-kernel/modules.softdep file), won't mount ext4
# volume at all:
#   EXT4-fs (dm-1): Cannot load crc32c driver.
#
# TODO: don't load crc32c_generic on kernels before 4.14.x
# TODO: resolve loading of library/crypto implementations via softdep
###modules blake2b_generic crc32_generic crc32c_generic \
###    crct10dif_generic xxhash_generic

# We need support for scsi/ata/usb/lvm/dmcrypt block devices
# (TODO: detect/load ATA modules besides ata_piix):
modules scsi_mod usb-common usbcore usb-storage uas \
    xhci-hcd xhci-pci ehci-hcd ehci-pci ohci-hcd ohci-pci uhci-hcd \
    libata ata_piix sata_nv ahci \
    dm-mod sd_common sd_mod cdrom sr_mod
# We need keyboard support (i8042/atkbd/usb/hid) for reading
# dm-crypt passphrase:
modules libps2 serio atkbd i8042 hid hid-generic hidp usbhid input-leds

# XXX: need to wait for mass-storage devices to be recognized
# after loading drivers:
printf "%s\n" "$0: waiting 3.5s for mass-storage devices..."
sleep 3.5

# Load kmap if supplied:
if [ -f "/kmap" ]; then
    printf "%s\n" "$0: loading kmap"
    busybox loadkmap <"/kmap"
elif [ -f "/kmap-a" ]; then
    printf "%s\n" "$0: loading ASCII kmap"
    busybox kbd_mode -a -C /dev/tty1
    busybox loadkmap <"/kmap-a"
elif [ -f "/kmap-u" ]; then
    printf "%s\n" "$0: loading Unicode kmap"
    busybox kbd_mode -u -C /dev/tty1
    busybox loadkmap <"/kmap-u"
fi

# Parse kernel commandline to find root volume ID or device
# and to find out which volumes to decrypt:
for A in `cat /proc/cmdline` ; do
    case "$A" in
	915resolution=?*) set915resolution "${A#915resolution=}";;
	resume=?*) RESUME="${A#resume=}";;
	recovery) RECOVERY=1;;
	root=?*) ROOT="${A#root=}";;
	single) SINGLE=1;;
	crypt_csh=*) CRYPT_CSH="${A#crypt_csh=}";;
	crypt_root=?*) decrypt "${A#crypt_root=}";;
	rd.luks.uuid=?*) decrypt "UUID=${A#rd.luks.uuid=}";;
    esac
done

# Try to resume from hibernate if there was resume= parameter:
if [ "z$RESUME" != "z" ] && [ -f /sys/power/resume ] ; then
    RESUMEDEV="`busybox findfs "$RESUME" 2>/dev/null`"
    if [ "z$RESUMEDEV" != "z" ] ; then
	MN="`busybox stat -L -c "%t:%T" "$RESUMEDEV"`"
	case "$MN" in
	    *:*)
		RESUMEDEV="`printf '%u:%u\n' "0x${MN%:*}" \
		    "0x${MN#*:}"`"
		if [ "z$RECOVERY" = "z1" ] ; then
		    echo "To resume do 'echo $RESUMEDEV" \
			">/sys/power/resume'"
		else
		    echo "resuming from $RESUMEDEV"
		    echo "$RESUMEDEV" >/sys/power/resume
		fi
		;;
	esac
    fi
fi

# Search for root volume to mount:
ROOTDEV="`busybox findfs "$ROOT" 2>/dev/null`"

# TODO: detect filesystem on rootdev and load only necessary modules.
modules ext4 ext3 lz4_decompress xz_dec squashfs isofs

# Start recovery shell if root volume can not be found or mounted, or
# recovery is explicitly requested:
if [ "z$RECOVERY" = "z1" ] || [ "z$ROOTDEV" = "z" ] \
|| ! busybox mount -o ro "$ROOTDEV" /mnt/root ; then
    while : ; do
	recovery
	if ! busybox mountpoint -q /mnt/root ; then
	    echo "ERROR: /mnt/root hasn't been mounted" \
		' in recovery shell'
	    if busybox mountpoint -q /mnt ; then
		echo "NOTE: mount root on /mnt/root, not on /mnt"
		busybox umount /mnt
	    fi
	else
	    break
	fi
    done
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
if ! busybox umount /dev ; then
    echo /init: busybox umount /dev failed: "$?"
    sleep 4
fi
if busybox mountpoint -q /run ; then
    busybox umount /run
fi
cd /mnt/root
if [ -d /mnt/root/run ] ; then
    echo /init: busybox mount -t tmpfs -o nodev,nosuid,mode=755 \
	tmpfs /mnt/root/run
    busybox mount -t tmpfs -o nodev,nosuid,mode=755 tmpfs /mnt/root/run
fi
if [ -d /mnt/root/dev ] ; then
    echo /init: busybox mount -t devtmpfs -o nosuid dev /mnt/root/dev
    busybox mount -t devtmpfs -o nosuid dev /mnt/root/dev
fi
if [ "z$SINGLE" = "z1" ] ; then
    echo /init: exec busybox switch_root /mnt/root /sbin/init S
    exec busybox switch_root /mnt/root /sbin/init S
else
    echo /init: exec busybox switch_root /mnt/root /sbin/init
    exec busybox switch_root /mnt/root /sbin/init
fi

# XXX: /init end.
# vi:set filetype=sh sw=4 noet ts=8 tw=71:
