# Invoice Ninja's actions, validated by the CGI before they become a request file.
# Free text (SMTP usernames and passwords, the From name) travels base64url-encoded.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 e v host port enc from name user pass
  case "$a" in
    refreshcert) lines="ACTION='$a'" ;;
    userpw|usermfa|mailtest) e=$(decode "$(param email "$body")")
      [[ "$e" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || error "400 Bad Request" "An email address, like you@example.com."
      lines="ACTION='$a'
EMAIL='$e'" ;;
    overdue) v=$(param on "$body"); [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "On or off."; lines="ACTION='overdue'
ON='$v'" ;;
    mailset)
      host=$(decode "$(param host "$body")"); port=$(param port "$body"); enc=$(param enc "$body"); from=$(decode "$(param from "$body")")
      name=$(decode "$(param name "$body")"); user=$(decode "$(param user "$body")"); pass=$(decode "$(param pass "$body")")
      lines="ACTION='mailset'"
      if [[ -n "$host" ]]; then
        [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || error "400 Bad Request" "An SMTP server name, like smtp.example.com."
        [[ "$port" =~ ^[0-9]{2,5}$ ]] || error "400 Bad Request" "A port number, like 587."
        [[ "$enc" =~ ^(tls|ssl|none)$ ]] || error "400 Bad Request" "Pick the security."
        [[ "$from" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || error "400 Bad Request" "The From address, like invoices@example.com."
        (( ${#user} <= 200 && ${#pass} <= 200 && ${#name} <= 80 )) || error "400 Bad Request" "Too long."
        lines="$lines
MAIL_HOST='$host'
MAIL_PORT='$port'
MAIL_ENC='$enc'
MAIL_FROM='$from'
MAIL_FROM_NAME_B64='$(b64u "$name")'
MAIL_USER_B64='$(b64u "$user")'
MAIL_PASS_B64='$(b64u "$pass")'"
      fi ;;
  esac
}
app_cgi_settings() {   # body → appends TLS to $lines, or errors
  local tls; tls=$(param tls "$1")
  [[ -z "$tls" ]] && return 0
  [[ "$tls" =~ ^(dsm|self|off)$ ]] || error "400 Bad Request" "HTTPS is DSM's certificate, self-signed, or off."
  lines="$lines
TLS='$tls'"
}
