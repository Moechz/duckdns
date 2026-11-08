# Changelog

All notable user-visible changes to the DuckDNS TOS application package.

## 2026.11.2-1 — 2026-11-08

### Added
- First release: the official LinuxServer.io DuckDNS client
  (`linuxserver/duckdns:aad9dc1f-ls96`, Docker Hub, used unmodified) packaged as
  a TOS 7 Docker application.
- Non-root container (`user: "1000:1000"`): the entrypoint bypasses the
  upstream s6-overlay (which requires root) and runs the image's own
  `/app/duck.sh` directly.
- Local status and setup page on port 8013: enter the DuckDNS subdomain(s) and
  token, choose the IP-detection mode, see the last check/result/public IP and
  the recent log. The page is served by the busybox `nc` already in the image,
  so no extra container or image is added.
- The updater runs every 5 minutes by default (1-1440 configurable), plus an
  immediate run after saving or pressing "Update now".
- Persistent data under `/Volume1/DockerAppData/duckdnsdocker/config`
  (`duckdns.conf` mode 600, `duckdns.log`, `status`); the update log is rotated
  to the last 200 lines.
- Health check on `/healthz`; it stays healthy while unconfigured or after a
  failed update, so a DuckDNS outage cannot get the app disabled.
- 23-language store metadata (English, Simplified Chinese and Traditional
  Chinese translated; the remaining languages fall back to English, which the
  official guide allows).
