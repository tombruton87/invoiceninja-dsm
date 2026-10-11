# Invoice Ninja's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# Makes a client and invoices through Invoice Ninja's own API, and catches mail with Mailpit on its network.
app_e2e_answers() { printf "ADMIN_EMAIL='ada@example.com'\nADMIN_NAME='Ada+Admin'\nTLS='off'\n"; }
NET=invoiceninja_default
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "users") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
token() {   # url email password → an API token (empty when the sign-in fails)
  curl -sk -X POST -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' -d "$(jq -cn --arg e "$2" --arg p "$3" '{email: $e, password: $p}')" "$1/api/v1/login" | jq -r '.data[0].token.token // empty'
}
api() { curl -sk -X "$2" -H "X-API-TOKEN: $TOK" -H 'X-Requested-With: XMLHttpRequest' -H 'Content-Type: application/json' ${4:+-d "$4"} "$1/api/v1/$3"; }
app_e2e_act() {
  local fail=0 url="http://127.0.0.1:$PORT" pw pw2 cid inv1 inv2 i
  log "invoiceninja"
  echo "  (health: $(curl -s "$url/health" | jq -c .), version $(jq -r .version "$VAR/status.json"))"
  pw=$(secret)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  TOK=$(token "$url" ada@example.com "$pw"); [[ -n "$TOK" ]] && echo "  ok   ada@example.com signs in with it" || { echo "  FAIL sign-in"; fail=1; }
  [[ -z "$(docker exec invoiceninja-app printenv IN_PASSWORD)" ]] && echo "  ok   the first start's throwaway password is gone from the environment" || { echo "  FAIL IN_PASSWORD still set"; fail=1; }
  wait_for '.app.users | length == 1 and .[0].name == "Ada Admin" and .[0].owner' 20 && echo "  ok   the window shows the owner" || { echo "  FAIL users: $(jq -c .app.users "$VAR/status.json")"; fail=1; }
  # A client with two invoices: one overdue, one not yet due. DSM hears of the overdue one.
  for i in $(seq 1 120); do [[ -e "$VAR/.overdue-seen" ]] && break; touch "$VAR/watching"; sleep 1; done
  cid=$(api "$url" POST clients '{"name":"Acme & Sons Ltd"}' | jq -r '.data.id')
  inv1=$(api "$url" POST invoices "$(jq -cn --arg c "$cid" --arg d "$(date -d '3 days ago' +%F)" '{client_id: $c, due_date: $d, line_items: [{product_key: "Work", notes: "Shelves", cost: 120, quantity: 1}]}')" | jq -r '.data.id')
  inv2=$(api "$url" POST invoices "$(jq -cn --arg c "$cid" --arg d "$(date -d '20 days' +%F)" '{client_id: $c, due_date: $d, line_items: [{product_key: "Work", notes: "Doors", cost: 80, quantity: 1}]}')" | jq -r '.data.id')
  api "$url" POST invoices/bulk "$(jq -cn --arg a "$inv1" --arg b "$inv2" '{action: "mark_sent", ids: [$a, $b]}')" >/dev/null
  wait_for '.app.clients == 1 and .app.open == 2 and (.app.overdue | length) == 1 and .app.overdue[0].client == "Acme & Sons Ltd" and .app.overdue[0].balance == 120' 60 \
    && echo "  ok   owed: $(jq -c .app.outstanding "$VAR/status.json"), overdue: $(jq -r '.app.overdue[0] | "\(.number) \(.client) \(.balance) \(.currency)"' "$VAR/status.json")" || { echo "  FAIL business: $(jq -c '.app | {clients, open, outstanding, overdue}' "$VAR/status.json")"; fail=1; }
  docker run --rm -v "$VAR:/v" --entrypoint sh invoiceninja-setup:local -c 'rm -f /v/.overdue-check'
  for i in $(seq 1 90); do grep -qE "notification \(invoiceoverdue\)|told DSM: invoiceoverdue" "$VAR/package.log" && break; touch "$VAR/watching"; sleep 1; done
  grep -qE "notification \(invoiceoverdue\)|told DSM: invoiceoverdue" "$VAR/package.log" && echo "  ok   the overdue invoice went to DSM's notifications (only attempted: no DSM here)" || { echo "  FAIL no DSM notification"; fail=1; }
  api "$url" POST payments "$(jq -cn --arg c "$cid" --arg i "$inv1" '{client_id: $c, amount: 120, invoices: [{invoice_id: $i, amount: 120}]}')" >/dev/null
  wait_for '(.app.overdue | length) == 0 and ([.app.paid30[]] | add) == 120' 60 && echo "  ok   paid: nothing overdue, $(jq -c .app.paid30 "$VAR/status.json") in the last 30 days" || { echo "  FAIL payment: $(jq -c '.app | {overdue, paid30}' "$VAR/status.json")"; fail=1; }
  # Users.
  request "ACTION='userpw'" "EMAIL='ada@example.com'" || fail=1; pw2=$(secret)
  [[ -n "$(token "$url" ada@example.com "$pw2")" && -z "$(token "$url" ada@example.com "$pw")" ]] && echo "  ok   a new password works, the old one doesn't" || { echo "  FAIL userpw"; fail=1; }
  request "ACTION='usermfa'" "EMAIL='ada@example.com'" || fail=1
  # Mail: refused without a server; through Mailpit once set.
  docker rm -f invoiceninja-e2e-mailpit >/dev/null 2>&1; docker run -d --name invoiceninja-e2e-mailpit --network "$NET" --network-alias mailpit axllent/mailpit >/dev/null
  request "ACTION='mailtest'" "EMAIL='you@example.com'" >/dev/null && { echo "  FAIL mail test without a server"; fail=1; } || echo "  ok   no mail server: $(jq -r .last.message "$VAR/status.json" | cut -c1-60)…"
  request "ACTION='mailset'" "MAIL_HOST='mailpit'" "MAIL_PORT='1025'" "MAIL_ENC='none'" "MAIL_FROM='invoices@example.com'" "MAIL_FROM_NAME_B64='$(printf 'Ada & Co (Joinery)' | base64 -w0 | tr '+/' '-_' | tr -d '=')'" "MAIL_USER_B64=''" "MAIL_PASS_B64=''" || fail=1
  request "ACTION='mailtest'" "EMAIL='you@example.com'" || fail=1
  [[ "$(docker exec invoiceninja-e2e-mailpit wget -qO- http://127.0.0.1:8025/api/v1/messages 2>/dev/null | jq -r '.messages[0] | "\(.To[0].Address)|\(.From.Name)"')" == 'you@example.com|Ada & Co (Joinery)' ]] && echo "  ok   the test email arrived, from Ada & Co (Joinery) (Mailpit)" || { echo "  FAIL test email: $(docker exec invoiceninja-e2e-mailpit wget -qO- http://127.0.0.1:8025/api/v1/messages 2>/dev/null | jq -c '.messages[0] | {To, From}')"; fail=1; }
  docker rm -f invoiceninja-e2e-mailpit >/dev/null 2>&1
  # HTTPS through nginx in front.
  request "ACTION='settings'" "TLS='self'" || fail=1
  [[ "$(curl -sk "https://127.0.0.1:$PORT/health" | jq -r .status)" == ok && "$(docker exec invoiceninja-app printenv REQUIRE_HTTPS)" == true ]] && echo "  ok   HTTPS self: https answers, Invoice Ninja knows its links are https" || { echo "  FAIL https"; fail=1; }
  [[ -n "$(token "https://127.0.0.1:$PORT" ada@example.com "$pw2")" ]] && echo "  ok   sign-in over HTTPS" || { echo "  FAIL https sign-in"; fail=1; }
  request "ACTION='settings'" "TLS='off'" || fail=1
  [[ "$(curl -s "$url/health" | jq -r .status)" == ok ]] && echo "  ok   back to plain HTTP" || { echo "  FAIL http again"; fail=1; }
  (( fail )) && { echo "  invoiceninja: something FAILED"; return 1; }; echo "  invoiceninja: all passed"
}
