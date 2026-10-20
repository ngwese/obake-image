The image starts PipeWire and WirePlumber as systemd user services for
`obake`. `obake-linger.service` starts that user manager at boot, so the
graph is up without a login.

Factory config is on the read-only image:

- `/usr/share/pipewire/pipewire.conf.d/10-obake-clock.conf` — 48000 Hz,
  quantum 128
- `/usr/share/pipewire/pipewire.conf.d/10-obake-rt.conf` and
  `/usr/share/wireplumber/wireplumber.conf.d/10-obake-rt.conf` — disable
  RTKit and the realtime portal; realtime comes from unit rlimits
- `/usr/share/wireplumber/wireplumber.conf.d/10-obake-alsa.conf` — ALSA
  period 128, three periods, for card ids ADAT, II, and USBPre2
- `/usr/lib/systemd/user/pipewire.service.d/10-obake-rt.conf` and
  `/usr/lib/systemd/user/wireplumber.service.d/10-obake-rt.conf` —
  realtime limits on both user services

Interactive SSH/login sessions get matching `@audio` rtprio 95 and unlimited
memlock through PAM (`pam_limits` reading
`/etc/security/limits.d/obake-audio.conf`) and pick up the lingering user
runtime via `pam_systemd`. Audio services still rely on the unit `Limit*`
drop-ins above; PAM covers login shells and processes started from them.

`obake` cannot write `/etc`. Overrides that survive an update go under
`/home/obake/.config/pipewire/` and `/home/obake/.config/wireplumber/`.

The daemon socket is `/run/user/<uid>/pipewire-0`. A Singularity process
running as `obake` reaches it by bind-mounting `/run/user/<uid>`.

udev still runs `usb_modeswitch` when a MixPre in UAC1 mode is attached.
WirePlumber opens the card after it re-enumerates. No udev rule starts
an audio server.
