# Invoice Ninja's CGI checks (sourced by chassis/tests/test-api.sh).
expect "userpw" 202 "$(post "$me" userpw 'action=userpw&email=ada%40example.com')"; request_is "userpw request" "ACTION='userpw'
EMAIL='ada@example.com'
BY='$me'"
expect "userpw bad" 400 "$(post "$me" userpw 'action=userpw&email=ada')"
expect "overdue" 202 "$(post "$me" overdue 'action=overdue&on=0')"; rm -f "$CHASSIS_VAR/request"
expect "mailset good" 202 "$(post "$me" mailset 'action=mailset&host=smtp.example.com&port=587&enc=tls&from=invoices%40example.com&name=Ada%20%26%20Co&user=me&pass=p%40ss')"
grep -q "^MAIL_FROM_NAME_B64='QWRhICYgQ28'$" "$CHASSIS_VAR/request" && { (( pass++ )); echo "  ok   the From name travels base64url"; } || { (( fail++ )); echo "  FAIL mailset request: $(tr '\n' ' ' < "$CHASSIS_VAR/request")"; }
rm -f "$CHASSIS_VAR/request"
expect "mailset bad host" 400 "$(post "$me" mailset 'action=mailset&host=smtp%3Bx&port=587&enc=tls&from=invoices%40example.com')"
expect "mailset off" 202 "$(post "$me" mailset 'action=mailset&host=')"; rm -f "$CHASSIS_VAR/request"
