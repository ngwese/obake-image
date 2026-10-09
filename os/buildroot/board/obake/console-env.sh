# Shared console selection for the installer medium and installed OS UKIs.
#
# Caller must set serial_cons to the board's serial TTY (e.g. ttyS0, ttyAMA0,
# ttyS2). Source this file; it reads CONSOLE (default serial) and sets:
#   console_mode, cmdline_console, getty_unit, service_cons
#
# serial: kernel + getty on the serial TTY.
# local:  kernel on tty0 (plus serial fallback); getty/service on tty1.

console_mode="${CONSOLE:-serial}"
case "$console_mode" in
serial)
	service_cons="$serial_cons"
	cmdline_console="console=$serial_cons"
	getty_unit="serial-getty@$serial_cons.service"
	;;
local)
	# systemd's TTYPath needs a concrete VT, so local uses tty1, not tty0.
	service_cons=tty1
	cmdline_console="console=tty0 console=$serial_cons"
	getty_unit="getty@tty1.service"
	;;
*)
	printf '[console] error: invalid CONSOLE %s; use serial or local\n' \
		"$console_mode" >&2
	exit 1
	;;
esac
