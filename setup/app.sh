# Invoice Ninja's hooks for the chassis core (sourced by run-core.sh). The
# core gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, notify, fresh, now, wait_ready, MSG, VAR, APP, LOG, PKG_NAME,
# PKG_TITLE, and the tls_* helpers (chassis tls.sh).
#
# The image makes its first account only from IN_USER_EMAIL/IN_PASSWORD in its
# environment, and won't start without them. So the first start gets a
# throwaway password; straight after, the package sets your real one through
# Invoice Ninja's own models (setup/in.php piped to PHP, password on stdin),
# shows it once, and takes the throwaway out of the environment. The window
# reads MariaDB; nginx in front serves the site, and HTTPS.

IA=""; IW=""; ID=""; INPHP=/pkg/setup/in.php

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    ADMIN_EMAIL|EMAIL|MAIL_FROM) [[ "$2" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ;;
    ADMIN_NAME) [[ "$2" =~ ^[A-Za-z0-9._@+-]+$ ]] && (( ${#2} <= 60 )) ;;   # spaces arrive as +
    TLS)        [[ "$2" =~ ^(dsm|self|off)$ ]] ;;
    MAIL_HOST)  [[ "$2" =~ ^[A-Za-z0-9.-]{0,253}$ ]] ;;
    MAIL_PORT)  [[ "$2" =~ ^[0-9]{2,5}$ ]] ;;
    MAIL_ENC)   [[ "$2" =~ ^(tls|ssl|none)$ ]] ;;
    *_B64)      [[ "$2" =~ ^[A-Za-z0-9_-]*$ ]] && (( ${#2} <= 700 )) ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ talking to Invoice Ninja
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
env_set_q() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}; env_set "$1" "\"$v\""; }
env_get_q() { local v; v=$(env_get "$1"); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}"; }
in_php() {   # action [arg-json] → in.php's JSON line in IN_OUT; 0 when it says ok
  local a=$1 arg=${2:-"{}"}
  IN_OUT=$({ printf '<?php $ACT = %s; $ARG_B64 = %s; ?>' "$(jq -Rn --arg v "$a" '$v')" "$(jq -Rn --arg v "$(printf '%s' "$arg" | base64 -w0)" '$v')"; cat "$INPHP"; } \
    | docker exec -i -u www-data -w /var/www/html "$IA" php 2>>"$LOG" | tail -n 1)
  jq -e '.ok == true' <<< "$IN_OUT" >/dev/null 2>&1
}
in_msg() { jq -r '.msg // empty' <<< "${IN_OUT:-}" 2>/dev/null | head -c 300; }
dbq() {   # sql → rows, as the ninja user (password on stdin, never in argv); times in UTC as Laravel keeps them
  printf '[client]\nuser=ninja\npassword=%s\n' "$(env_get DB_PASSWORD)" | docker exec -i "$ID" mariadb --defaults-extra-file=/dev/stdin ninja -N -B -e "SET time_zone = '+00:00'; $1" 2>/dev/null
}
scheme() { [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]] && echo https || echo http; }
in_url() { echo "$(scheme)://127.0.0.1:$(env_get HTTP_PORT)"; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
unplus() { tr '+' ' ' <<< "$1"; }

# ------------------------------------------------------------ HTTPS: nginx in front (PHP behind it on app:9000)
web_conf() {   # mode → nginx's config on stdout (the web volume is /etc/nginx/conf.d)
  cat <<'EOF'
# Written by the Invoice Ninja package; edits are overwritten on the next start.
client_max_body_size 50M;
client_body_buffer_size 10M;
server_tokens off;
fastcgi_buffers 32 16K;
gzip on; gzip_comp_level 2; gzip_min_length 1k; gzip_proxied any; gzip_types text/css application/javascript application/json image/svg+xml;
map $http_x_forwarded_proto $in_proto { "" $scheme; default $http_x_forwarded_proto; }
server {
EOF
  if [[ "$1" == off ]]; then echo "  listen 8080 default_server;"; else cat <<'EOF'
  listen 8080 ssl default_server;
  http2 on;
  ssl_certificate /etc/nginx/conf.d/tls/fullchain.pem;
  ssl_certificate_key /etc/nginx/conf.d/tls/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:in:5m;
EOF
  fi
  cat <<'EOF'
  server_name _;
  root /var/www/html/public;
  index index.php;
  charset utf-8;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-Content-Type-Options "nosniff";
  resolver 127.0.0.11 valid=10s;
  location / { try_files $uri $uri/ /index.php?$query_string; }
  location = /favicon.ico { access_log off; log_not_found off; }
  location = /robots.txt  { access_log off; log_not_found off; }
  error_page 404 /index.php;
  location ~ \.php$ {
    set $in_up app:9000;
    fastcgi_pass $in_up;
    fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
    fastcgi_param HTTPS $https if_not_empty;
    fastcgi_param HTTP_X_FORWARDED_PROTO $in_proto;
    fastcgi_read_timeout 300s;
    include fastcgi_params;
  }
  location ~ /\.(?!well-known).* { deny all; }
}
EOF
}
setup_web() {   # certificate and config for TLS=dsm|self|off (every start, and when the setting changes)
  tls_fix_scheme || true
  tls_prepare web || return 1
  web_conf "$(env_get TLS_SOURCE)" | in_volume web rw -- 'cat > /vol/invoiceninja.conf.tmp && mv /vol/invoiceninja.conf.tmp /vol/invoiceninja.conf' 2>>"$LOG" \
    || { MSG="nginx's config couldn't be written — see the log."; return 1; }
  env_set REQUIRE_HTTPS "$([[ "$(env_get APP_URL)" == https://* ]] && echo true || echo false)"
}
reload_web() { svc_up web && { docker exec "$IW" nginx -s reload >> "$LOG" 2>&1 || true; }; true; }

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set IN_IMAGE invoiceninja/invoiceninja-debian:5; env_set WEB_IMAGE nginx:stable-alpine; env_set DB_IMAGE mariadb:11.4
  env_set DB_PASSWORD "$(rand 32)"; env_set DB_ROOT_PASSWORD "$(rand 32)"
  env_set APP_KEY "base64:$(openssl rand -base64 32)"
  env_set ADMIN_EMAIL "${ADMIN_EMAIL:-admin@example.com}"; env_set ADMIN_NAME "${ADMIN_NAME:-Admin}"
  env_set MAIL_MAILER log; env_set MAIL_PORT 587; env_set MAIL_ENCRYPTION tls; env_set DSM_ALERTS 1; env_set TLS "${TLS:-off}"
  # The image's first start needs an account in its environment: a throwaway password, replaced as soon as Invoice Ninja is up.
  env_set IN_USER_EMAIL "$(env_get ADMIN_EMAIL)"; env_set IN_PASSWORD "$(rand 40)"
  tls_fix_scheme || true
  touch "$VAR/.needs-account"
}
app_load_env() { IA=$(cname app); IW=$(cname web); ID=$(cname db); }
app_before_up() {
  [[ -n "$(env_get TLS)" ]] || env_set TLS off
  setup_web || say "✗ HTTPS couldn't be set up: $MSG"
}
app_health() { [[ "$(curl -sk --max-time 10 "$(in_url)/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" == ok ]]; }
app_version() { docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IA" 2>/dev/null | sed -E 's/-d$//' | tr -cd '0-9A-Za-z.-' | head -c 30; }
app_after_up() { make_account 300; }   # the first start migrates and seeds the database: minutes
account_made() { [[ "$(dbq "SELECT COUNT(*) FROM users WHERE email = '$(env_get ADMIN_EMAIL)'")" =~ ^[1-9] ]]; }
make_account() {   # [tries] — the first time: your real password replaces the throwaway, then the throwaway leaves the environment
  [[ -f "$VAR/.needs-account" ]] || return 0
  local i pw email name
  email=$(env_get ADMIN_EMAIL); name=$(unplus "$(env_get ADMIN_NAME)")
  for i in $(seq 1 "${1:-1}"); do app_health && account_made && break; sleep 2; done
  account_made || { say "Invoice Ninja is still setting up its database — your account is finished when it's done"; return 0; }
  pw=$(strong_password)
  in_php setpw "$(jq -cn --arg e "$email" --arg p "$pw" --arg n "$name" '{email: $e, password: $p, name: $n}')" || { say "✗ your Invoice Ninja password couldn't be set: $(in_msg) — trying again shortly"; return 0; }
  leave_secret "Invoice Ninja ($email)" "$pw" users; rm -f "$VAR/.needs-account"
  env_set IN_USER_EMAIL ""; env_set IN_PASSWORD ""
  compose up -d app >> "$LOG" 2>&1 || true   # the throwaway leaves the container's environment too
  say "first start: your Invoice Ninja account $email is ready; the password is shown once in the window"
}

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up app && svc_up db || { echo '{"up": false}'; return 0; }
  local data
  data=$(dbq "SELECT JSON_OBJECT(
    'company', (SELECT JSON_UNQUOTE(JSON_EXTRACT(settings, '\$.name')) FROM companies ORDER BY id LIMIT 1),
    'clients', (SELECT COUNT(*) FROM clients WHERE is_deleted = 0),
    'open', (SELECT COUNT(*) FROM invoices WHERE is_deleted = 0 AND status_id IN (2, 3) AND balance > 0),
    'drafts', (SELECT COUNT(*) FROM invoices WHERE is_deleted = 0 AND status_id = 1),
    'outstanding', (SELECT JSON_OBJECTAGG(code, total) FROM (SELECT cur.code, ROUND(SUM(i.balance), 2) total FROM invoices i JOIN clients c ON c.id = i.client_id JOIN companies co ON co.id = i.company_id
                      JOIN currencies cur ON cur.id = COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(c.settings, '\$.currency_id')), ''), JSON_UNQUOTE(JSON_EXTRACT(co.settings, '\$.currency_id')))
                      WHERE i.is_deleted = 0 AND i.status_id IN (2, 3) AND i.balance > 0 GROUP BY cur.code) o),
    'paid30', (SELECT JSON_OBJECTAGG(code, total) FROM (SELECT cur.code, ROUND(SUM(p.amount - p.refunded), 2) total FROM payments p JOIN currencies cur ON cur.id = p.currency_id
                      WHERE p.is_deleted = 0 AND p.date >= CURDATE() - INTERVAL 30 DAY GROUP BY cur.code) p),
    'overdue', (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', id, 'number', number, 'client', client, 'balance', balance, 'currency', code, 'due', due)) FROM (
                  SELECT i.id, i.number, COALESCE(NULLIF(c.name, ''), 'a client') client, ROUND(i.balance, 2) balance, cur.code, UNIX_TIMESTAMP(i.due_date) due
                  FROM invoices i JOIN clients c ON c.id = i.client_id JOIN companies co ON co.id = i.company_id
                  JOIN currencies cur ON cur.id = COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(c.settings, '\$.currency_id')), ''), JSON_UNQUOTE(JSON_EXTRACT(co.settings, '\$.currency_id')))
                  WHERE i.is_deleted = 0 AND i.status_id IN (2, 3) AND i.balance > 0 AND i.due_date IS NOT NULL AND i.due_date < CURDATE()
                  ORDER BY i.due_date LIMIT 25) od),
    'users', (SELECT JSON_ARRAYAGG(JSON_OBJECT('email', email, 'name', name, 'owner', owner, 'admin', admin, 'mfa', mfa, 'last', last)) FROM (
                  SELECT u.email, TRIM(CONCAT(COALESCE(u.first_name, ''), ' ', COALESCE(u.last_name, ''))) name, COALESCE(MAX(cu.is_owner), 0) owner, COALESCE(MAX(cu.is_admin), 0) admin,
                         u.google_2fa_secret IS NOT NULL mfa, UNIX_TIMESTAMP(u.last_login) last
                  FROM users u LEFT JOIN company_user cu ON cu.user_id = u.id AND cu.deleted_at IS NULL WHERE u.is_deleted = 0 GROUP BY u.id ORDER BY u.id) us))")
  [[ "$data" == \{* ]] || data='{}'
  [[ -s "$VAR/cert.json" ]] || tls_info web
  jq -c --arg url "$(env_get APP_URL)" --arg me "$(env_get ADMIN_EMAIL)" --arg alerts "$(env_get DSM_ALERTS)" \
     --arg mail_driver "$(env_get MAIL_MAILER)" --arg mail_host "$(env_get MAIL_HOST)" --arg mail_port "$(env_get MAIL_PORT)" --arg mail_enc "$(env_get MAIL_ENCRYPTION)" \
     --arg mail_from "$(env_get MAIL_FROM)" --arg mail_name "$(env_get_q MAIL_FROM_NAME)" --arg mail_user "$(env_get_q MAIL_USERNAME)" \
     --arg tls "$(env_get TLS)" --arg tls_source "$(env_get TLS_SOURCE)" --argjson cert "$(cat "$VAR/cert.json" 2>/dev/null || echo null)" \
     '. + {up: true, url: $url, me: $me, alerts: ($alerts == "1"), overdue: (.overdue // []), users: ((.users // []) | map(.owner = ((.owner | tostring) == "1") | .admin = ((.admin | tostring) == "1") | .mfa = ((.mfa | tostring) == "1" or (.mfa | tostring) == "true"))),
           outstanding: (.outstanding // {}), paid30: (.paid30 // {}),
           mail: {on: ($mail_driver == "smtp"), host: $mail_host, port: $mail_port, enc: $mail_enc, from: $mail_from, name: $mail_name, user: $mail_user},
           tls: {mode: $tls, source: $tls_source, cert: $cert}}' <<< "$data" 2>/dev/null || echo '{"up": true}'
}

# ------------------------------------------------------------ an invoice goes overdue → DSM
check_overdue() {   # invoices that weren't overdue at the last check: one DSM notification each (a summary when there are many)
  local rows seen new n
  rows=$(dbq "SELECT CONCAT(i.id, '\t', i.number, '\t', COALESCE(NULLIF(c.name, ''), 'a client')) FROM invoices i JOIN clients c ON c.id = i.client_id
              WHERE i.is_deleted = 0 AND i.status_id IN (2, 3) AND i.balance > 0 AND i.due_date IS NOT NULL AND i.due_date < CURDATE()") || return 0
  seen="$VAR/.overdue-seen"
  if [[ ! -f "$seen" ]]; then cut -f1 <<< "$rows" > "$seen"; return 0; fi   # a new install or a restore: what's overdue now isn't news
  new=$(awk -F'\t' 'NR == FNR { s[$1] = 1; next } $1 != "" && !($1 in s)' "$seen" - <<< "$rows")
  cut -f1 <<< "$rows" > "$seen.tmp" && mv "$seen.tmp" "$seen"
  n=$(grep -c . <<< "$new" || true); (( n )) || return 0
  [[ "$(env_get DSM_ALERTS)" == 1 ]] || return 0
  if (( n > 3 )); then notify invoicesoverdue 0 "$n"; return 0; fi
  while IFS=$'\t' read -r _ num client; do notify invoiceoverdue 0 "$num" "$client"; done <<< "$new"
}
app_tick() {
  make_account 1
  svc_up app || return 0
  fresh "$VAR/.overdue-check" 3600 || { touch "$VAR/.overdue-check"; check_overdue || true; }
  fresh "$VAR/.cert-check" 86400 && return 0; touch "$VAR/.cert-check"
  tls_refresh_dsm web
  [[ "$CERT_REFRESH" == changed ]] && reload_web
  return 0
}

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() {   # HTTPS; links your clients get follow the address
  [[ -n "${TLS:-}" ]] && env_set TLS "$TLS"
  setup_web || return 1
  reload_web
  return 0
}
app_after_settings() { reload_web; docker exec -u www-data "$IA" php artisan optimize >> "$LOG" 2>&1 || true; }
app_logs() { :; }
app_storage() {
  in_volume storage ro -- 'cd /vol; for d in app logs framework; do [ -e "$d" ] && printf "%s\t%s\n" "$d" "$(du -sm "$d" 2>/dev/null | cut -f1)"; done; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — a consistent dump of the database, and the uploaded files (logos, documents)
  printf '[client]\nuser=ninja\npassword=%s\n' "$(env_get DB_PASSWORD)" | docker exec -i "$ID" mariadb-dump --defaults-extra-file=/dev/stdin --single-transaction --routines --default-character-set=utf8mb4 ninja 2>>"$LOG" | gzip > "$1/db.sql.gz"
  gzip -dc "$1/db.sql.gz" 2>/dev/null | tail -n 1 | grep -q 'Dump completed' || { say "✗ the database dump didn't finish"; return 1; }
  # The cache, sessions and compiled views are left out, but not their folders: the image's start-up clears the cache and stops if the folder is missing.
  in_volume storage ro -- 'tar -C /vol -czf - --exclude="./logs/*" --exclude="./framework/cache/data/*" --exclude="./framework/sessions/*" --exclude="./framework/views/*" .' > "$1/storage.tar.gz" 2>>"$LOG" </dev/null \
    && tar -tzf "$1/storage.tar.gz" >/dev/null 2>&1 || { say "✗ Invoice Ninja's files didn't tar"; return 1; }
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/db.sql.gz" && -f "$1/storage.tar.gz" ]] || { MSG="That backup has no database dump or files."; return 1; }
  in_volume storage rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf - && mkdir -p /vol/logs /vol/framework/cache/data /vol/framework/sessions /vol/framework/views /vol/app/public && chown -R 33:33 /vol' < "$1/storage.tar.gz" 2>>"$LOG" || { MSG="Invoice Ninja's files didn't unpack."; return 1; }
  compose up -d db >> "$LOG" 2>&1; local i; for i in $(seq 1 60); do dbq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  { echo "DROP DATABASE IF EXISTS ninja; CREATE DATABASE ninja CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; USE ninja;"; gzip -dc "$1/db.sql.gz"; } \
    | docker exec -i "$ID" sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' 2>>"$LOG" || { MSG="The database didn't load."; return 1; }
  rm -f "$VAR/.overdue-seen" "$VAR/.needs-account"; env_set IN_USER_EMAIL ""; env_set IN_PASSWORD ""
}
app_report() {
  echo "== business: $(dbq "SELECT CONCAT(COUNT(*), ' clients') FROM clients WHERE is_deleted = 0"), $(dbq "SELECT CONCAT(COUNT(*), ' invoices') FROM invoices WHERE is_deleted = 0")"
  echo "== overdue: $(dbq "SELECT COUNT(*) FROM invoices WHERE is_deleted = 0 AND status_id IN (2, 3) AND balance > 0 AND due_date < CURDATE()")"
  echo "== users: $(dbq "SELECT COUNT(*) FROM users WHERE is_deleted = 0"), with 2FA: $(dbq "SELECT COUNT(*) FROM users WHERE is_deleted = 0 AND google_2fa_secret IS NOT NULL")"
  echo "== mail: $(env_get MAIL_MAILER) $(env_get MAIL_HOST):$(env_get MAIL_PORT) $(env_get MAIL_ENCRYPTION)"
  echo; echo "== HTTPS"; echo "mode $(env_get TLS), in use: $(env_get TLS_SOURCE)"; jq -c 'del(.names)' "$VAR/cert.json" 2>/dev/null
  echo; echo "== queue"; dbq "SELECT CONCAT(COUNT(*), ' jobs waiting, ', (SELECT COUNT(*) FROM failed_jobs), ' failed') FROM jobs"
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local pw
  case "$1" in
    userpw)
      pw=$(strong_password)
      in_php setpw "$(jq -cn --arg e "$EMAIL" --arg p "$pw" '{email: $e, password: $p}')" || { MSG=$(in_msg); return 1; }
      leave_secret "Invoice Ninja ($EMAIL)" "$pw" users; MSG="A new password for $EMAIL is shown below, once." ;;
    usermfa) in_php mfaoff "$(jq -cn --arg e "$EMAIL" '{email: $e}')" || { MSG=$(in_msg); return 1; }; MSG="Two-step sign-in is off for $EMAIL; they can turn it on again in Invoice Ninja." ;;
    overdue) env_set DSM_ALERTS "${ON:-0}"; MSG=$([[ "${ON:-0}" == 1 ]] && echo "DSM tells administrators when an invoice goes overdue." || echo "No DSM notifications about overdue invoices.") ;;
    mailset)
      if [[ "${MAIL_HOST:-}" == "" ]]; then env_set MAIL_MAILER log; MSG="Mail is off: Invoice Ninja writes emails to its log instead of sending them."
      else
        env_set MAIL_MAILER smtp; env_set MAIL_HOST "$MAIL_HOST"; env_set MAIL_PORT "${MAIL_PORT:-587}"; env_set MAIL_FROM "${MAIL_FROM:-invoices@example.com}"
        env_set MAIL_ENCRYPTION "$([[ "${MAIL_ENC:-tls}" == none ]] && echo "" || echo "${MAIL_ENC:-tls}")"
        env_set_q MAIL_FROM_NAME "$(b64d "${MAIL_FROM_NAME_B64:-}" | tr -d '\000-\037' | cut -c1-80)"
        env_set_q MAIL_USERNAME "$(b64d "${MAIL_USER_B64:-}")"
        [[ -n "${MAIL_PASS_B64:-}" ]] && env_set_q MAIL_PASSWORD "$(b64d "$MAIL_PASS_B64")"   # blank: keep the stored one
        MSG="Invoices go out through $MAIL_HOST:${MAIL_PORT:-587}. Send a test to check it."
      fi
      compose up -d app >> "$LOG" 2>&1 && wait_ready 300 || { MSG="Invoice Ninja didn't come back — see the log."; return 1; } ;;
    mailtest)
      [[ "$(env_get MAIL_MAILER)" == smtp ]] || { MSG="Mail isn't set up yet — fill in the mail server first."; return 1; }
      in_php mailtest "$(jq -cn --arg e "$EMAIL" '{to: $e}')" && MSG="A test email went to $EMAIL through $(env_get MAIL_HOST)." || { MSG="The test email didn't go: $(in_msg)"; return 1; } ;;
    refreshcert)
      tls_refresh_dsm web; setup_web || return 1; reload_web
      MSG=$([[ "$(env_get TLS_SOURCE)" == dsm ]] && echo "DSM's certificate was read again." || echo "A new self-signed certificate is in use.") ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
