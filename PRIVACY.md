# Privacy Policy — DuckDNS for TOS 7

Last updated: 2026-11-14

This policy covers the TOS application package `duckdnsdocker` (this repository)
and the local DuckDNS client it runs on your TerraMaster NAS.

## What data the app handles

- The DuckDNS subdomain(s) and the DuckDNS token that you enter on the app page
  (or in `duckdns.conf`).
- The public IP address that DuckDNS detects for your connection.
- A local update log and status file (`duckdns.log`, `status`).

All of it is stored on your NAS, under
`/Volume1/DockerAppData/duckdnsdocker/`, readable only by the application user
(uid 1000). The token file has mode 600.

## Network connections

- The app calls the DuckDNS update endpoint
  `https://www.duckdns.org/update` and sends the configured subdomain(s), your
  DuckDNS token and the detected public IP address. DuckDNS uses this to update
  the DNS record you asked for; see <https://www.duckdns.org/>.
- In the optional `ipv4` / `ipv6` / `both` modes, the app first asks Cloudflare's
  DNS resolver (`1.1.1.1` and `2606:4700:4700::1111`) for the public address.
  Only the DNS query is sent; no other data is included.
- The package itself sends no telemetry, analytics or usage data to Moechz,
  TerraMaster, LinuxServer.io or any third party.
- The app is served over plain HTTP on your local network; no cloud service is
  involved.

## Data sharing

- No data is sold or shared by this package.
- DuckDNS and Cloudflare process the requests described above as independent
  services under their own policies. The app sends only what is needed for the
  DNS update or the address lookup.

## Retention and deletion

- Data stays on the NAS until you delete
  `/Volume1/DockerAppData/duckdnsdocker/` or uninstall the application with data
  removal in the TOS App Center.
- You can remove the token at any time by clearing it on the app page or by
  deleting `duckdns.conf`; you can also revoke the token in your DuckDNS account.
- Uninstalling without data removal keeps the folder so a later reinstall can
  reuse the settings.

## Your rights

You can view and edit your data in `duckdns.conf` on the NAS, export it by
copying the config folder, and delete it as described above. Because the app
runs entirely on your NAS, the developer does not hold a copy of your data.

## Contact

- Package issues: <https://github.com/Moechz/duckdns/issues>
- Upstream client: <https://github.com/linuxserver/docker-duckdns>
- DuckDNS service: <https://www.duckdns.org/>
