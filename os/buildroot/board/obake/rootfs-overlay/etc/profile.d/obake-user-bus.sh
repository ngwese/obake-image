# Point login shells at the lingering systemd user runtime / session bus.
# systemd is built without PAM, so pam_systemd does not set these.
# Only apply when the runtime dir already exists (linger / user@ active).
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	_obake_uid="$(id -u 2>/dev/null)" || _obake_uid=
	if [ -n "$_obake_uid" ] && [ -d "/run/user/$_obake_uid" ]; then
		[ -n "${XDG_RUNTIME_DIR:-}" ] ||
			export XDG_RUNTIME_DIR="/run/user/$_obake_uid"
		[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] ||
			export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
	fi
	unset _obake_uid
fi
