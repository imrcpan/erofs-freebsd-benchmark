#!/bin/sh
# Make the erofs file system available on the FreeBSD machine.
#
# EROFS_MODE=module  build erofs.ko from an erofs-freebsd source tree against
#                    the running system and load it (default).
# EROFS_MODE=kernel  use erofs of the running kernel: built in, or the erofs.ko
#                    that ships with that kernel (release kernel), loaded from
#                    the module path of the running kernel.
#
# module mode inputs:
#   EROFS_KO   path of a prebuilt erofs.ko, used as is; or
#   EROFS_SRC  erofs-freebsd source tree, only sys/ is used.

# __FreeBSD_version of a source tree, from sys/sys/param.h.
src_osrel() {
	awk '/^#define[ \t]+__FreeBSD_version/ {print $3; exit}' "$1/sys/sys/param.h"
}

erofs_build_module() {
	[ -f "$EROFS_SRC/sys/modules/erofs/Makefile" ] ||
	    die "EROFS_SRC has no sys/modules/erofs: $EROFS_SRC"
	need_cmd make
	need_cmd cc
	srcver=$(src_osrel "$EROFS_SRC")
	sysver=$(uname -U)
	log "erofs source __FreeBSD_version=$srcver, running system=$sysver"
	if [ "$srcver" != "$sysver" ] && [ -z "$EROFS_FORCE" ]; then
		die "source and running system differ; module mode needs the same version (set EROFS_FORCE=1 to override)"
	fi
	objdir=$WORK/erofs-obj
	rm -rf "$objdir"
	mkdir -p "$objdir"
	log "building erofs.ko"
	(cd "$EROFS_SRC/sys/modules/erofs" &&
	    env MAKEOBJDIR="$objdir" SRCTOP="$EROFS_SRC" SYSDIR="$EROFS_SRC/sys" \
	    make -j"$(sysctl -n hw.ncpu)" all) >"$WORK/erofs-build.log" 2>&1 ||
	    die "erofs.ko build failed, see $WORK/erofs-build.log"
	EROFS_KO=$(find "$objdir" "$EROFS_SRC/sys/modules/erofs" -name erofs.ko -type f 2>/dev/null | head -n 1)
	[ -n "$EROFS_KO" ] || die "erofs.ko not found after build"
}

erofs_load_module() {
	# A module that is already loaded may be another build; replace it.
	if kldstat -q -n erofs.ko 2>/dev/null; then
		log "unloading the loaded erofs module"
		kldunload erofs || die "cannot unload the loaded erofs module"
	fi
	kldload "$EROFS_KO" || die "kldload $EROFS_KO failed"
}

erofs_setup() {
	EROFS_MODE=${EROFS_MODE:-module}
	case $EROFS_MODE in
	module)
		if [ -z "$EROFS_KO" ]; then
			[ -n "$EROFS_SRC" ] || die "module mode needs -s <erofs-freebsd tree> or -k <erofs.ko>"
			erofs_build_module
		fi
		[ -f "$EROFS_KO" ] || die "no such module: $EROFS_KO"
		erofs_load_module
		;;
	kernel)
		kldstat -q -m erofs || kldload erofs ||
		    die "erofs is not in the running kernel and kldload erofs failed (kernel mode)"
		;;
	*)
		die "unknown erofs mode: $EROFS_MODE"
		;;
	esac
	kldstat -q -m erofs || die "erofs is not available after setup"
	log "erofs ready (mode $EROFS_MODE)"
}
