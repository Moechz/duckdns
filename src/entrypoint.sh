#!/bin/sh
# ===========================================================================
# DuckDNS for TOS 7 - non-root entrypoint (uid 1000, no s6, no root)
#
# Why a wrapper exists at all:
#   * the upstream image starts s6-overlay as root and switches to its
#     internal "abc" user; inside a container already running as uid 1000 that
#     is impossible, so this wrapper bypasses s6 and calls the image's own
#     /app/duck.sh directly (the update logic is *not* reimplemented here);
#   * the image ships no web server, while a TOS Docker application must open
#     a page. The page below is served by the busybox `nc` that is already
#     part of the image - no extra container, no extra image, nothing is
#     installed at runtime.
#
# Everything this script writes lives in the mounted /config volume:
#   duckdns.conf  settings (subdomains, token, IP mode, interval) - mode 600
#   duckdns.log   last update output, rotated to 200 lines
#   status        state / timestamp / IP / message of the last run
#   www/          the small status+setup page and its request handler
# ===========================================================================
set -u

CONF=/config/duckdns.conf
LOG=/config/duckdns.log
STATUS=/config/status
TRIGGER=/config/.update-now
WWW=/config/www
HANDLER=$WWW/handler.sh
PORT=8080
export APP_VERSION=${APP_VERSION:-dev}

export HOME=/config
export TZ=${TZ:-Asia/Shanghai}

umask 077
mkdir -p "$WWW" /tmp/duckdns

# ---------------------------------------------------------------- settings --
# Seeded once and never overwritten: it is the user's file (the page writes it
# too, always atomically through a temporary file).
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'CFG'
# DuckDNS settings - the web page edits this file, hand editing works too.
# SUBDOMAINS : comma separated names, without ".duckdns.org" (e.g. mynas,home)
# TOKEN      : the token from your DuckDNS account (keep it secret)
# UPDATE_IP  : auto | ipv4 | ipv6 | both
# INTERVAL   : minutes between checks (1-1440)
SUBDOMAINS=
TOKEN=
UPDATE_IP=auto
INTERVAL=5
CFG
  chmod 600 "$CONF"
fi

: >> "$LOG"
if [ ! -f "$STATUS" ]; then
  printf 'STATE=UNCONFIGURED\nWHEN=\nIP=\nMSG=Waiting for the subdomain and token\n' > "$STATUS"
fi

# ------------------------------------------------------------- tiny helper --
cfg() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

write_status() {
  {
    printf 'STATE=%s\n' "$1"
    printf 'WHEN=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'IP=%s\n' "$2"
    printf 'MSG=%s\n' "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-200)"
  } > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}

# ------------------------------------------------------------- updater loop --
# Runs the upstream client. Output goes to the log and is summarised into
# /config/status; a DuckDNS outage never stops the container or the page.
run_update() {
  local subs tok umode out state ip msg
  subs=$(cfg "$CONF" SUBDOMAINS)
  tok=$(cfg "$CONF" TOKEN)
  umode=$(cfg "$CONF" UPDATE_IP)
  [ -n "$umode" ] || umode=auto
  if [ -z "$subs" ] || [ -z "$tok" ]; then
    write_status UNCONFIGURED "" "Waiting for the subdomain and token"
    return 0
  fi
  printf '\n=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
  out=$(SUBDOMAINS="$subs" TOKEN="$tok" UPDATE_IP="$umode" LOG_FILE=false \
        bash /app/duck.sh 2>&1)
  printf '%s\n' "$out" >> "$LOG"
  if [ "$(wc -l < "$LOG")" -gt 400 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
  state=ERROR
  case "$out" in
    *"Your IP was updated"*)  state=UPDATED ;;
    *"IP(s) unchanged"*)      state=NOCHANGE ;;
    *"Something went wrong"*) state=ERROR ;;
  esac
  ip=$(printf '%s\n' "$out" | sed -n 's/.*IPv4: \([0-9.]*\).*/\1/p' | tail -n 1)
  if [ "$state" = UPDATED ] || [ "$state" = NOCHANGE ]; then
    msg=$(printf '%s\n' "$out" | grep -F -e 'Your IP was updated' -e 'IP(s) unchanged' | head -n 1)
  else
    detail=$(printf '%s\n' "$out" | sed -n '/The response returned was:/{n;p;}' | head -n 1)
    [ -n "$detail" ] || detail=$(printf '%s\n' "$out" | tail -n 1)
    msg="Update failed: ${detail:-no response from DuckDNS}"
  fi
  write_status "$state" "$ip" "$msg"
}

# --------------------------------------------------------------- the page ----
# A self-contained request handler. busybox nc -e runs it once per connection
# with the socket on stdin/stdout, so it reads one request and exits.
cat > "$HANDLER" <<'HANDLER_EOF'
#!/bin/sh
set -u

CONF=/config/duckdns.conf
LOG=/config/duckdns.log
STATUS=/config/status
TRIGGER=/config/.update-now
APP_VERSION=${APP_VERSION:-dev}

cfg() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# HTML-escape user-controlled values before they reach the page
h() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# send CODE CONTENT-TYPE BODY [LOCATION]
send() {
  local b n
  b=$(mktemp /tmp/duckdns-resp.XXXXXX) || exit 0
  printf '%s' "$3" > "$b"
  n=$(wc -c < "$b")
  printf 'HTTP/1.1 %s\r\n' "$1"
  printf 'Content-Type: %s\r\n' "$2"
  printf 'Content-Length: %s\r\n' "$n"
  [ -n "${4:-}" ] && printf 'Location: %s\r\n' "$4"
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'Connection: close\r\n\r\n'
  [ "$method" = HEAD ] || cat "$b"
  rm -f "$b"
  exit 0
}

method=GET
IFS= read -r line || exit 0
line=$(printf '%s' "$line" | tr -d '\r')
method=${line%% *}
rest=${line#* }
target=${rest%% *}
case "$target" in /*) ;; *) target=/ ;; esac
path=${target%%\?*}
query=
case "$target" in *\?*) query=${target#*\?} ;; esac

cl=0
accept=
host=
origin=
while IFS= read -r line; do
  line=$(printf '%s' "$line" | tr -d '\r')
  [ -z "$line" ] && break
  case "$line" in
    [Cc]ontent-[Ll]ength:*) cl=$(printf '%s' "${line#*:}" | tr -d ' ') ;;
    [Aa]ccept-[Ll]anguage:*) accept=${line#*:} ;;
    [Hh]ost:*) host=$(printf '%s' "${line#*:}" | tr -d ' ') ;;
    [Oo]rigin:*) origin=$(printf '%s' "${line#*:}" | tr -d ' ') ;;
  esac
done

body=
if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
  [ "$cl" -le 8192 ] || send 413 text/plain "request too large"
  body=$(dd bs=1 count="$cl" 2>/dev/null)
fi

lang=en
case "$accept" in *zh*) lang=zh ;; esac

if [ "$lang" = zh ]; then
  T_TAGLINE="为 NAS 提供免费动态域名"
  T_STATUS="状态"
  T_UPDATED="更新成功"
  T_NOCHANGE="已是最新，IP 未变化"
  T_ERROR="最近一次更新失败"
  T_UNCONFIGURED="尚未配置"
  T_DOMAIN="域名"
  T_LAST="最近检查"
  T_IP="公网 IP"
  T_MESSAGE="消息"
  T_SETTINGS="设置"
  T_SUBS="子域名"
  T_SUBS_HINT="逗号分隔，不含 .duckdns.org，例如 mynas,home"
  T_TOKEN="Token"
  T_TOKEN_HINT="在 DuckDNS 账户中获取，仅保存在 NAS 上；留空则保持当前 Token。"
  T_MODE="IP 检测方式"
  T_MODE_AUTO="DuckDNS 自动检测"
  T_MODE_IPV4="Cloudflare IPv4"
  T_MODE_IPV6="IPv6"
  T_MODE_BOTH="IPv4 + IPv6"
  T_INTERVAL="检查间隔（分钟）"
  T_SAVE="保存并立即更新"
  T_NOW="立即更新"
  T_LOG="最近日志"
  T_HELP="还没有域名？到 duckdns.org 免费创建"
  T_SAVED="已保存，几秒内开始更新。"
  T_BAD="输入不合法：子域名只能包含字母、数字、连字符和逗号；Token 为 8-64 位字母、数字或连字符。"
  T_FOOTER="以非 root 容器运行。设置文件：/config/duckdns.conf"
else
  T_TAGLINE="Free dynamic DNS for your NAS"
  T_STATUS="Status"
  T_UPDATED="Updated successfully"
  T_NOCHANGE="Up to date - IP unchanged"
  T_ERROR="Last update failed"
  T_UNCONFIGURED="Not configured yet"
  T_DOMAIN="Domain"
  T_LAST="Last check"
  T_IP="Public IP"
  T_MESSAGE="Message"
  T_SETTINGS="Settings"
  T_SUBS="Subdomains"
  T_SUBS_HINT="Comma separated, without .duckdns.org - e.g. mynas,home"
  T_TOKEN="Token"
  T_TOKEN_HINT="From your DuckDNS account. Stored on the NAS only; leave blank to keep the current token."
  T_MODE="IP detection"
  T_MODE_AUTO="DuckDNS auto-detect"
  T_MODE_IPV4="Cloudflare IPv4"
  T_MODE_IPV6="IPv6"
  T_MODE_BOTH="IPv4 + IPv6"
  T_INTERVAL="Check every (minutes)"
  T_SAVE="Save and update now"
  T_NOW="Update now"
  T_LOG="Recent log"
  T_HELP="Need a domain? Create one free at duckdns.org"
  T_SAVED="Saved. The update starts within a few seconds."
  T_BAD="Invalid input: subdomains may contain letters, digits, hyphen and comma; the token must be 8-64 letters, digits or hyphens."
  T_FOOTER="Runs as a non-root container. Settings: /config/duckdns.conf"
fi

# ---------------------------------------------------------------- POST data --
form() {
  printf '%s' "$body" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

urldecode() {
  case "$1" in *\\*) return 1 ;; esac
  printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
}

if [ "$path" = /save ]; then
  [ "$method" = POST ] || send 405 text/plain "POST only"
  # A browser always sends Origin on a POST; refuse a foreign one so another
  # site cannot silently replace the DuckDNS settings through the LAN address.
  if [ -n "$origin" ]; then
    case "$origin" in
      "http://$host"|"https://$host") ;;
      *) send 403 text/plain "cross-origin request refused" ;;
    esac
  fi
  action=$(urldecode "$(form action)" 2>/dev/null || true)
  if [ "$action" = now ]; then
    touch "$TRIGGER"
    send 303 text/html "" "/?saved=1"
  fi
  subs=$(urldecode "$(form subdomains)" 2>/dev/null || true)
  tok=$(urldecode "$(form token)" 2>/dev/null || true)
  umode=$(urldecode "$(form mode)" 2>/dev/null || true)
  every=$(urldecode "$(form interval)" 2>/dev/null || true)
  subs=$(printf '%s' "$subs" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')
  tok=$(printf '%s' "$tok" | tr -d ' \t\r\n')
  case "$subs" in
    ''|,*|*,|*,,) bad=1 ;;
    *[!a-z0-9.,-]*) bad=1 ;;
    *) bad=0 ;;
  esac
  [ "${#subs}" -le 200 ] || bad=1
  if [ -n "$tok" ]; then
    case "$tok" in *[!A-Za-z0-9-]*) bad=1 ;; esac
    [ "${#tok}" -ge 8 ] || bad=1
    [ "${#tok}" -le 64 ] || bad=1
  fi
  if [ -z "$tok" ]; then
    tok=$(cfg "$CONF" TOKEN)
  fi
  case "$umode" in auto|ipv4|ipv6|both) ;; *) umode=auto ;; esac
  case "$every" in ''|*[!0-9]*) every=5 ;; esac
  [ "$every" -ge 1 ] 2>/dev/null || every=5
  [ "$every" -le 1440 ] 2>/dev/null || every=1440
  [ "$bad" = 1 ] && send 303 text/html "" "/?error=1"
  {
    printf '# DuckDNS settings - written by the setup page\n'
    printf 'SUBDOMAINS=%s\n' "$subs"
    printf 'TOKEN=%s\n' "$tok"
    printf 'UPDATE_IP=%s\n' "$umode"
    printf 'INTERVAL=%s\n' "$every"
  } > "$CONF.tmp" && chmod 600 "$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
  touch "$TRIGGER"
  send 303 text/html "" "/?saved=1"
fi

if [ "$path" = /healthz ]; then
  send 200 text/plain "ok"
fi

# ------------------------------------------------------------------ /status --
state=UNCONFIGURED; when=; ip=; smsg=
if [ -f "$STATUS" ]; then
  state=$(cfg "$STATUS" STATE); when=$(cfg "$STATUS" WHEN)
  ip=$(cfg "$STATUS" IP); smsg=$(cfg "$STATUS" MSG)
fi
[ -n "$state" ] || state=UNCONFIGURED
subs=$(cfg "$CONF" SUBDOMAINS)
tok=$(cfg "$CONF" TOKEN)
umode=$(cfg "$CONF" UPDATE_IP); [ -n "$umode" ] || umode=auto
every=$(cfg "$CONF" INTERVAL); [ -n "$every" ] || every=5

if [ "$path" = /status.json ]; then
  send 200 application/json "{\"state\":\"$(h "$state")\",\"when\":\"$(h "$when")\",\"ip\":\"$(h "$ip")\",\"subdomains\":\"$(h "$subs")\"}"
fi

case "$path" in
  /|/index.html) ;;
  *) send 404 text/plain "not found" ;;
esac

case "$state" in
  UPDATED)   st_class=ok;   st_text=$T_UPDATED ;;
  NOCHANGE)  st_class=ok;   st_text=$T_NOCHANGE ;;
  ERROR)     st_class=bad;  st_text=$T_ERROR ;;
  *)         st_class=idle; st_text=$T_UNCONFIGURED ;;
esac

domains=-; [ -n "$subs" ] && domains=$(printf '%s' "$subs" | tr ',' '\n' | sed 's/$/.duckdns.org/' | tr '\n' ' ' | sed 's/ $//')
[ -n "$when" ] || when=-
[ -n "$ip" ] || ip=-
[ -n "$smsg" ] || smsg=-

sel_auto=; sel_v4=; sel_v6=; sel_both=
case "$umode" in
  ipv4) sel_v4=selected ;;
  ipv6) sel_v6=selected ;;
  both) sel_both=selected ;;
  *) sel_auto=selected ;;
esac

banner=
case "$query" in
  *saved=1*) banner="<div class=\"banner ok\">$(h "$T_SAVED")</div>" ;;
  *error=1*) banner="<div class=\"banner bad\">$(h "$T_BAD")</div>" ;;
esac

logtxt=$(tail -n 12 "$LOG" 2>/dev/null)
[ -n "$logtxt" ] || logtxt="-"

page=$(cat <<HTML
<!DOCTYPE html>
<html lang="$( [ "$lang" = zh ] && echo zh-CN || echo en )">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DuckDNS</title>
<style>
*{box-sizing:border-box}
body{margin:0;font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;background:#f4f5f7;color:#1f2328}
main{max-width:720px;margin:0 auto;padding:30px 20px 44px}
header{display:flex;align-items:center;gap:12px;margin-bottom:20px}
.logo{width:46px;height:46px;border-radius:12px;background:#ffd60a;display:flex;align-items:center;justify-content:center;font-size:26px;font-weight:800;color:#1f2328;flex:none}
h1{font-size:24px;margin:0;letter-spacing:-.01em}
.tagline{color:#656d76;font-size:13px;margin-top:2px}
.card{background:#fff;border:1px solid #d8dee4;border-radius:12px;padding:18px 20px;margin-bottom:16px;box-shadow:0 1px 2px rgba(31,35,40,.04)}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:#656d76;margin:0 0 12px}
.badge{display:inline-block;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600}
.ok{background:#dafbe1;color:#116329}
.bad{background:#ffebe9;color:#a40e26}
.idle{background:#eaeef2;color:#57606a}
dl{display:grid;grid-template-columns:max-content 1fr;gap:7px 16px;margin:0}
dt{color:#656d76}
dd{margin:0;word-break:break-all}
label{display:block;font-weight:600;margin:14px 0 4px;font-size:14px}
input,select{width:100%;padding:8px 10px;border:1px solid #d0d7de;border-radius:8px;font:inherit;background:#fff;color:inherit}
input:focus,select:focus{outline:2px solid #0969da33;border-color:#0969da}
.hint{color:#656d76;font-size:12px;margin-top:3px}
.actions{display:flex;gap:10px;margin-top:18px;flex-wrap:wrap}
button{padding:9px 16px;border-radius:8px;border:1px solid #d0d7de;background:#f6f8fa;font:inherit;font-weight:600;cursor:pointer}
button.primary{background:#1f883d;border-color:#1f883d;color:#fff}
button.primary:hover{background:#1a7f37}
.banner{padding:10px 14px;border-radius:8px;margin-bottom:16px;font-size:14px;border:1px solid transparent}
.banner.ok{border-color:#aceebb}
.banner.bad{border-color:#ffcecb}
pre{background:#f6f8fa;border:1px solid #d8dee4;border-radius:8px;padding:10px;overflow:auto;font-size:12px;margin:0;white-space:pre-wrap;word-break:break-all;max-height:230px}
footer{color:#8c959f;font-size:12px;text-align:center;margin-top:24px}
a{color:#0969da}
</style>
</head>
<body>
<main>
<header>
  <div class="logo">D</div>
  <div>
    <h1>DuckDNS</h1>
    <div class="tagline">$(h "$T_TAGLINE")</div>
  </div>
</header>
$banner
<div class="card">
  <h2>$(h "$T_STATUS")</h2>
  <p style="margin:0 0 14px"><span class="badge $st_class">$(h "$st_text")</span></p>
  <dl>
    <dt>$(h "$T_DOMAIN")</dt><dd id="domains">$(h "$domains")</dd>
    <dt>$(h "$T_LAST")</dt><dd>$(h "$when")</dd>
    <dt>$(h "$T_IP")</dt><dd>$(h "$ip")</dd>
    <dt>$(h "$T_MESSAGE")</dt><dd>$(h "$smsg")</dd>
  </dl>
</div>
<form class="card" method="post" action="/save">
  <h2>$(h "$T_SETTINGS")</h2>
  <label for="subdomains">$(h "$T_SUBS")</label>
  <input id="subdomains" name="subdomains" value="$(h "$subs")" autocomplete="off" spellcheck="false" placeholder="mynas,home">
  <div class="hint">$(h "$T_SUBS_HINT")</div>
  <label for="token">$(h "$T_TOKEN")</label>
  <input id="token" name="token" type="password" value="" autocomplete="off" spellcheck="false" placeholder="********">
  <div class="hint">$(h "$T_TOKEN_HINT")</div>
  <label for="mode">$(h "$T_MODE")</label>
  <select id="mode" name="mode">
    <option value="auto" $sel_auto>$(h "$T_MODE_AUTO")</option>
    <option value="ipv4" $sel_v4>$(h "$T_MODE_IPV4")</option>
    <option value="ipv6" $sel_v6>$(h "$T_MODE_IPV6")</option>
    <option value="both" $sel_both>$(h "$T_MODE_BOTH")</option>
  </select>
  <label for="interval">$(h "$T_INTERVAL")</label>
  <input id="interval" name="interval" type="number" min="1" max="1440" value="$(h "$every")">
  <div class="actions">
    <button class="primary" type="submit" name="action" value="save">$(h "$T_SAVE")</button>
    <button type="submit" name="action" value="now">$(h "$T_NOW")</button>
  </div>
</form>
<div class="card">
  <h2>$(h "$T_LOG")</h2>
  <pre>$(h "$logtxt")</pre>
</div>
<p style="text-align:center;font-size:13px;margin:0 0 6px"><a href="https://www.duckdns.org/" target="_blank" rel="noopener noreferrer">$(h "$T_HELP")</a></p>
<footer>DuckDNS client v$(h "$APP_VERSION") &middot; $(h "$T_FOOTER")</footer>
</main>
</body>
</html>
HTML
)
send 200 "text/html; charset=utf-8" "$page"
HANDLER_EOF
chmod 755 "$HANDLER"

# ------------------------------------------------------------ start the loop --
UPDATER=
(
  last=0
  first=1
  while :; do
    every=$(cfg "$CONF" INTERVAL)
    case "$every" in ''|*[!0-9]*) every=5 ;; esac
    [ "$every" -ge 1 ] 2>/dev/null || every=5
    [ "$every" -le 1440 ] 2>/dev/null || every=1440
    now=$(date +%s)
    if [ "$first" = 1 ] || [ -f "$TRIGGER" ]; then
      rm -f "$TRIGGER"
      first=0
      last=$now
      run_update
    elif [ $((now - last)) -ge $((every * 60)) ]; then
      last=$now
      run_update
    fi
    sleep 5
  done
) &
UPDATER=$!
trap 'kill "$UPDATER" 2>/dev/null; exit 0' TERM INT

echo "duckdns: serving the setup/status page on 0.0.0.0:$PORT (uid $(id -u))"
exec busybox nc -lk -p "$PORT" -e "$HANDLER"
