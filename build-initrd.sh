#!/bin/sh

set -e

export FLASH_KERNEL_SKIP=1
export DEBIAN_FRONTEND=noninteractive
DEFAULTMIRROR="https://deb.debian.org/debian"
APT_COMMAND="apt -y"

usage() {
	echo "Usage:

-a|--arch	Architecture to create initrd for. Default armhf
-m|--mirror	Custom mirror URL to use. Must serve your arch.
"
}

echob() {
	echo "Builder: $@"
}

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-a | --arch)
		[ -n "$2" ] && ARCH=$2 shift || usage
		;;
	-m | --mirror)
		[ -n "$2" ] && MIRROR=$2 shift || usage
		;;
	esac
	shift
done

# Defaults for all arguments, so they can be set by the environment
[ -z $ARCH ] && ARCH="armhf"
[ -z $MIRROR ] && MIRROR=$DEFAULTMIRROR
[ -z $RELEASE ] && RELEASE="stable"
[ -z $ROOT ] && ROOT=./build/$ARCH
[ -z $OUT ] && OUT=./out

# list all packages needed for halium's initrd here
[ -z $INCHROOTPKGS ] && INCHROOTPKGS="initramfs-tools dctrl-tools e2fsprogs libc6-dev zlib1g-dev libssl-dev busybox-static ostree"

BOOTSTRAP_BIN="qemu-debootstrap --arch $ARCH --variant=minbase"

umount_chroot() {
	chroot $ROOT umount /sys >/dev/null 2>&1 || true
	chroot $ROOT umount /proc >/dev/null 2>&1 || true
	echo
}

do_chroot() {
	trap umount_chroot INT EXIT
	ROOT="$1"
	CMD="$2"
	echob "Executing \"$2\" in chroot"
	chroot $ROOT mount -t proc proc /proc
	chroot $ROOT mount -t sysfs sys /sys
	chroot $ROOT $CMD
	umount_chroot
	trap - INT EXIT
}

if [ ! -e $ROOT/.min-done ]; then

	[ -d $ROOT ] && rm -r $ROOT

	# create a plain chroot to work in
	echob "Creating chroot with arch $ARCH in $ROOT"
	mkdir build || true
	$BOOTSTRAP_BIN $RELEASE $ROOT $MIRROR || cat $ROOT/debootstrap/debootstrap.log

	#sed -i 's/main$/main universe/' $ROOT/etc/apt/sources.list
	sed -i 's,'"$DEFAULTMIRROR"','"$MIRROR"',' $ROOT/etc/apt/sources.list

	# make sure we do not start daemons at install time
	mv $ROOT/sbin/start-stop-daemon $ROOT/sbin/start-stop-daemon.REAL
	echo $START_STOP_DAEMON >$ROOT/sbin/start-stop-daemon
	chmod a+rx $ROOT/sbin/start-stop-daemon

	echo $POLICY_RC_D >$ROOT/usr/sbin/policy-rc.d

	# after the switch to systemd we now need to install upstart explicitly
	echo "nameserver 8.8.8.8" >$ROOT/etc/resolv.conf
	do_chroot $ROOT "$APT_COMMAND update"

	# We also need to install dpkg-dev in order to use dpkg-architecture.
	do_chroot $ROOT "$APT_COMMAND install dpkg-dev --no-install-recommends"

	touch $ROOT/.min-done
else
	echob "Build environment for $ARCH found, reusing."
fi

# install all packages we need to roll the generic initrd
do_chroot $ROOT "$APT_COMMAND update"
do_chroot $ROOT "$APT_COMMAND dist-upgrade"
do_chroot $ROOT "$APT_COMMAND install $INCHROOTPKGS --no-install-recommends"
DEB_HOST_MULTIARCH=$(chroot $ROOT dpkg-architecture -q DEB_HOST_MULTIARCH)

cp -a conf/halium ${ROOT}/usr/share/initramfs-tools/conf.d
cp -a scripts/* ${ROOT}/usr/share/initramfs-tools/scripts
cp -a hooks/* ${ROOT}/usr/share/initramfs-tools/hooks

VER="$ARCH"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/lib/$DEB_HOST_MULTIARCH"

do_chroot $ROOT "update-initramfs -tc -ktouch-$VER -v"

mkdir $OUT >/dev/null 2>&1 || true
cp $ROOT/boot/initrd.img-touch-$VER $OUT

# extract and create the external utils image
cat <<SHELL > ${ROOT}/binstub
#!/bin/sh

BASEDIR=\$(dirname "\$0")
BASENAME=\$(basename "\$0")

export LD_LIBRARY_PATH=\$BASEDIR/lib/$DEB_HOST_MULTIARCH:\$BASEDIR/usr/lib/$DEB_HOST_MULTIARCH
export PATH=\$BASEDIR/usr/bin:\$PATH

\$BASENAME \$@
SHELL

cat <<SHELL > ${ROOT}/extract-utils
#!/bin/bash
. /usr/share/initramfs-tools/hook-functions

DESTDIR='/opt/utils'
mkdir -p \$DESTDIR

copy_exec /usr/bin/ostree
cp /binstub \$DESTDIR/ostree
SHELL

chmod +x ${ROOT}/binstub
chmod +x ${ROOT}/extract-utils

do_chroot $ROOT /extract-utils

dd if=/dev/zero of=$OUT/initrd-utils.img seek=500K bs=4096 count=0
mkfs.ext4 -d $ROOT/opt/utils $OUT/initrd-utils.img
resize2fs -M $OUT/initrd-utils.img

cd $OUT
cd - >/dev/null 2>&1
