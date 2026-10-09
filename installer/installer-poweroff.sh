#!/bin/sh
# Wait after install.sh, then power off. Invoked by obake-installer.service.
# Args: <interactive|delay> [seconds]
set -eu

mode="${1:?usage: installer-poweroff.sh interactive|delay [seconds]}"
delay="${2:-10}"

case "$mode" in
interactive)
	printf '[install] Press Enter to shut down...\n'
	# Stdin is the installer console (see ExecStart redirect).
	read -r _
	;;
delay)
	case "$delay" in
	'' | *[!0-9]*)
		printf '[install] error: invalid poweroff delay: %s\n' "$delay" >&2
		delay=10
		;;
	esac
	if [ "$delay" -gt 0 ]; then
		printf '[install] Shutting down in %s seconds...\n' "$delay"
		sleep "$delay"
	fi
	;;
*)
	printf '[install] error: unknown poweroff mode: %s\n' "$mode" >&2
	;;
esac

exec /usr/bin/systemctl poweroff -f
