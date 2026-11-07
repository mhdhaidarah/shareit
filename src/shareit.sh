#!/usr/bin/env bash
# ShareIT: share the current folder on the internet with a real link, until you close it.
#   curl -fsSL https://dl.securytik.com/shareit | bash
# It asks what to share. To skip the question (after the first run the command "shareit" also works):
#   shareit files [folder]            download page for this folder, or for [folder]
#   shareit website 3000              your app on this machine, port 3000
#   shareit website 192.168.1.5:8080  an app at a local address
#   shareit files --force             allow a folder ShareIT refuses by default, such as your home folder
# Open source: https://github.com/mhdhaidarah/shareit
set -u

main() {
  local FORCE=0 FOLDER="" MODE="" TARGET="" a
  for a in "$@"; do
    case "$a" in
      --force) FORCE=1 ;;
      -h|--help) usage; return 0 ;;
      file|files) MODE=files ;;
      website|site|url|port) MODE=website ;;
      *) if [ "$MODE" = website ]; then TARGET=$a; else FOLDER=$a; fi ;;
    esac
  done
  if [ -z "$MODE" ]; then
    if [ -n "$FOLDER" ] || ! { : </dev/tty; } 2>/dev/null; then
      MODE=files
    else
      echo "What do you want to share?"
      echo "  1) Files in this folder ($PWD): people get a download page"
      echo "  2) A website or app running on a local port"
      printf 'Choose 1 or 2: '
      read -r a </dev/tty
      case "$a" in 2) MODE=website ;; *) MODE=files ;; esac
    fi
  fi
  if [ "$MODE" = website ]; then
    share_website "$TARGET"
    return $?
  fi
  FOLDER=$(cd "${FOLDER:-.}" 2>/dev/null && pwd -P) || { say_err "That folder does not exist."; return 1; }

  case "$FOLDER" in
    /|/root|/home|/etc|/usr|/var|/boot|/bin|/sbin|/lib|/opt|/proc|/sys|/dev|"${HOME:-/root}")
      if [ "$FORCE" != 1 ]; then
        say_err "ShareIT will not put $FOLDER on the internet: it may hold private files."
        echo "  Go to the folder you want to share and paste the command there."
        return 1
      fi ;;
  esac

  need_nginx || return 1
  need_tools || return 1

  WORK=$(mktemp -d /tmp/shareit.XXXXXX) || return 1
  trap cleanup EXIT
  trap 'exit 0' INT TERM HUP
  chmod 755 "$WORK"

  local TOKEN PORT=8765 USERLINE="" OWNER
  TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  while (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do PORT=$((PORT + 1)); done

  build_page "$FOLDER" "$WORK/index.html" || return 1

  if [ "$(id -u)" = 0 ]; then
    OWNER=$(stat -c %U "$FOLDER"); USERLINE="user $OWNER;"
  fi
  local MIME=""
  [ -f /etc/nginx/mime.types ] && MIME="include /etc/nginx/mime.types;"
  cat > "$WORK/nginx.conf" <<CONF
$USERLINE
worker_processes 1;
pid $WORK/nginx.pid;
error_log $WORK/error.log;
events { worker_connections 512; }
http {
  $MIME
  default_type application/octet-stream;
  access_log off;
  server_tokens off;
  sendfile on;
  client_body_temp_path $WORK/t1;
  proxy_temp_path $WORK/t2;
  fastcgi_temp_path $WORK/t3;
  uwsgi_temp_path $WORK/t4;
  scgi_temp_path $WORK/t5;
  server {
    listen 127.0.0.1:$PORT;
    location = /$TOKEN/ { default_type text/html; root $WORK; try_files /index.html =404; add_header Cache-Control no-store; }
    location ~ ^/$TOKEN/(.*/)?\\. { return 404; }
    location /$TOKEN/ {
      alias "$FOLDER/";
      autoindex off;
      disable_symlinks on;
      add_header Content-Disposition attachment;
      add_header X-Content-Type-Options nosniff;
      limit_except GET { deny all; }
    }
    location / { return 404; }
  }
}
CONF
  nginx -e "$WORK/error.log" -p "$WORK" -c "$WORK/nginx.conf" </dev/null >/dev/null 2>"$WORK/start.log" || {
    say_err "nginx could not start:"; cat "$WORK/start.log" "$WORK/error.log" 2>/dev/null | tail -5; return 1; }

  : > "$WORK/empty.yml"
  cloudflared tunnel --config "$WORK/empty.yml" --no-autoupdate --url "http://127.0.0.1:$PORT" </dev/null >"$WORK/tunnel.log" 2>&1 &
  CF=$!

  URL=$(wait_for_link) || return 1
  wait_until_live "$URL/$TOKEN/"
  show_link "$URL/$TOKEN/" "Sharing: $FOLDER  ($FILES files, $TOTAL)" "Anyone with this link can download these files."
  stay_open
}

usage() {
  cat <<'USAGE'
ShareIT: share a folder or a local website with a real link, until you close it.
  shareit                           asks what to share
  shareit files [folder]            download page for this folder, or for [folder]
  shareit website 3000              your app on this machine, port 3000
  shareit website 192.168.1.5:8080  an app at a local address
USAGE
}

# "3000", "localhost:3000", "192.168.1.5:8080", "http://localhost:3000", "https://localhost:8443"
parse_target() {
  local t=$1 scheme=http
  case "$t" in https://*) scheme=https; t=${t#https://} ;; http://*) t=${t#http://} ;; esac
  t=${t%%/*}
  case "$t" in
    *[!0-9]*) ;;
    *) t="localhost:$t" ;;
  esac
  case "$t" in
    *:[0-9]*) T_HOST=${t%:*}; T_PORT=${t##*:} ;;
    *) return 1 ;;
  esac
  case "$T_PORT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$T_PORT" -ge 1 ] && [ "$T_PORT" -le 65535 ] && [ -n "$T_HOST" ] || return 1
  case "$T_HOST" in *[!A-Za-z0-9.-]*) return 1 ;; esac
  T_SCHEME=$scheme
}

share_website() {
  local target=$1
  if [ -z "$target" ]; then
    { : </dev/tty; } 2>/dev/null || { say_err "Give the address, for example: shareit website 3000"; return 1; }
    echo
    echo "Enter the address of your app. Examples:"
    echo "  3000                  port 3000 on this machine"
    echo "  localhost:8080        the same, port 8080"
    echo "  192.168.1.5:8080      another machine on your network"
    printf 'Address: '
    read -r target </dev/tty
  fi
  parse_target "$target" || { say_err "\"$target\" is not an address. Examples: 3000, localhost:8080, 192.168.1.5:8080"; return 1; }
  if ! (exec 3<>"/dev/tcp/$T_HOST/$T_PORT") 2>/dev/null; then
    say_err "Nothing is answering on $T_HOST:$T_PORT. Start your app first, then paste the command again."
    return 1
  fi
  need_tools || return 1
  WORK=$(mktemp -d /tmp/shareit.XXXXXX) || return 1
  trap cleanup EXIT
  trap 'exit 0' INT TERM HUP
  : > "$WORK/empty.yml"
  # the app sees its own address as the host, so dev servers that check the name still answer
  cloudflared tunnel --config "$WORK/empty.yml" --no-autoupdate --no-tls-verify --http-host-header "$T_HOST:$T_PORT" \
    --url "$T_SCHEME://$T_HOST:$T_PORT" </dev/null >"$WORK/tunnel.log" 2>&1 &
  CF=$!
  URL=$(wait_for_link) || return 1
  wait_until_live "$URL/"
  show_link "$URL" "Sharing: your app at $T_SCHEME://$T_HOST:$T_PORT" "Anyone with this link can open your app, so do not leave private data on it."
  stay_open
}

wait_for_link() {
  local i url=""
  echo "Creating your link..." >&2
  for i in $(seq 1 60); do
    url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$WORK/tunnel.log" | grep -v '^https://api\.' | head -1)
    [ -n "$url" ] && break
    kill -0 "$CF" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$url" ]; then
    say_err "Cloudflare did not give a link. Check the internet connection and try again."
    tail -4 "$WORK/tunnel.log" | cut -c1-160 >&2
    return 1
  fi
  printf '%s' "$url"
}

# ready once Cloudflare answers with anything but its own "not ready" errors
wait_until_live() {
  local i code
  for i in $(seq 1 45); do
    code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null)
    case "$code" in 000|502|503|530) sleep 2 ;; *) return 0 ;; esac
  done
}

show_link() {
  local B="" G="" Y="" R=""
  if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[0m'; fi
  echo
  echo "${G}Your link is ready${R}"
  echo
  echo "  ${B}$1${R}"
  echo
  echo "  $2"
  echo "  $3"
  echo
  echo "${Y}Close this window, or press Ctrl+C, to end the link.${R}"
}

stay_open() {
  while kill -0 "$CF" 2>/dev/null; do sleep 2; done
  say_err "The Cloudflare connection stopped, so the link has ended. Paste the command again for a new link."
  return 1
}

say_err() { printf '%s\n' "ShareIT: $*" >&2; }

cleanup() {
  trap - EXIT INT TERM HUP
  [ -n "${CF:-}" ] && kill "$CF" 2>/dev/null
  [ -f "${WORK:-}/nginx.pid" ] && kill "$(cat "$WORK/nginx.pid")" 2>/dev/null
  sleep 0.3
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  [ -n "${WORK:-}" ] && echo && echo "The link has ended. nginx and the tunnel are off; nothing was uninstalled."
}

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

need_nginx() {
  if ! command -v nginx >/dev/null 2>&1 || [ ! -x "$(command -v nginx)" ]; then
    command -v apt-get >/dev/null 2>&1 || { say_err "Please install nginx first; this system has no apt-get."; return 1; }
    echo "Installing nginx (first run only)..."
    # the package would start a web server of its own on port 80: ShareIT runs its own copy and leaves that one off
    local mine=0
    if ! as_root test -e /usr/sbin/policy-rc.d; then
      printf '#!/bin/sh\nexit 101\n' | as_root tee /usr/sbin/policy-rc.d >/dev/null && as_root chmod +x /usr/sbin/policy-rc.d && mine=1
    fi
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq </dev/null >/dev/null 2>&1
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq nginx curl </dev/null >/dev/null 2>&1
    [ "$mine" = 1 ] && as_root rm -f /usr/sbin/policy-rc.d
    command -v systemctl >/dev/null 2>&1 && as_root systemctl disable --now nginx </dev/null >/dev/null 2>&1
    PATH=$PATH:/usr/sbin:/sbin; hash -r
    command -v nginx >/dev/null 2>&1 || { say_err "Installing nginx failed."; return 1; }
  fi
  PATH=$PATH:/usr/sbin:/sbin
}

need_tools() {
  local arch
  command -v curl >/dev/null 2>&1 || as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl </dev/null >/dev/null 2>&1
  if ! command -v cloudflared >/dev/null 2>&1; then
    case "$(uname -m)" in
      x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=arm ;;
      *) say_err "No Cloudflare tunnel program for $(uname -m)."; return 1 ;;
    esac
    echo "Installing the Cloudflare tunnel program (first run only)..."
    as_root curl -fsSL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" </dev/null \
      && as_root chmod 755 /usr/local/bin/cloudflared || { say_err "Downloading cloudflared failed."; return 1; }
  fi
  if ! command -v shareit >/dev/null 2>&1; then
    as_root curl -fsSL -o /usr/local/bin/shareit https://dl.securytik.com/shareit </dev/null >/dev/null 2>&1 && as_root chmod 755 /usr/local/bin/shareit
  fi
  return 0
}

html() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }

urlpath() {
  local LC_ALL=C s=$1 i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~/-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=${c: -3} ;;
    esac
  done
  printf '%s' "$out"
}

human() {
  awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++} printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'
}

build_page() {
  local folder=$1 out=$2 rel size ext dir base rows="" count=0 sum=0 body
  while IFS= read -r -d '' rel; do
    rel=${rel#./}
    size=$(stat -c %s -- "$folder/$rel" 2>/dev/null || echo 0)
    count=$((count + 1)); sum=$((sum + size))
    base=${rel##*/}; ext=${base##*.}; [ "$ext" = "$base" ] && ext=file; ext=${ext:0:5}
    dir=""; [ "$rel" != "$base" ] && dir="<span class=\"dir\">$(html "${rel%/*}")</span>"
    FIRST_REL=${FIRST_REL:-$rel}
    rows+="<li><a href=\"$(urlpath "$rel")\" download><span class=\"ext\">$(html "$ext")</span><span class=\"name\" dir=\"auto\">$(html "$base")$dir</span><span class=\"size\">$(human "$size")</span><span class=\"get\">Download</span></a></li>"
    [ "$count" -ge 5000 ] && break
  done < <(cd "$folder" && find . -type f -not -path '*/.*' -print0 2>/dev/null | LC_ALL=C sort -z)
  [ "$count" -gt 0 ] || { say_err "This folder has no files to share."; return 1; }
  FILES=$count; TOTAL=$(human "$sum")
  local title; title=$(html "${folder##*/}")
  if [ "$count" = 1 ]; then
    base=${FIRST_REL##*/}; ext=${base##*.}; [ "$ext" = "$base" ] && ext=file
    body="<div class=\"one\"><div class=\"ext\">$(html "${ext:0:5}")</div><h2 dir=\"auto\">$(html "$base")</h2><p>$TOTAL</p><a class=\"btn\" href=\"$(urlpath "$FIRST_REL")\" download>Download</a></div>"
  else
    body="<div class=\"head\"><div><h1 dir=\"auto\">$title</h1><p>$count files · $TOTAL</p></div></div><div class=\"bar\"><input class=\"find\" id=\"find\" type=\"search\" placeholder=\"Find a file\" aria-label=\"Find a file\"></div><ul>$rows</ul><div class=\"none\" id=\"none\">No file with that name.</div>"
  fi
  PAGE_TITLE=$title PAGE_BODY=$body write_template "$out"
}

write_template() {
  local page
  page=$(cat <<'PAGE'
@@PAGE@@
PAGE
)
  local logo
  logo=$(cat <<'LOGO'
@@LOGO@@
LOGO
)
  page=${page//__TITLE__/$PAGE_TITLE}
  page=${page//__LOGO__/$logo}
  page=${page//__BODY__/$PAGE_BODY}
  printf '%s\n' "$page" > "$1"
}

main "$@"
