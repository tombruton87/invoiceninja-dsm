    echo "ADMIN_EMAIL='$(printf '%s' "${wizard_admin_email:-}" | tr -cd 'A-Za-z0-9._+@-' | head -c 120)'"
    echo "ADMIN_NAME='$(printf '%s' "${wizard_admin_name:-Admin}" | tr -cd 'A-Za-z0-9 ._@-' | sed 's/^ *//; s/ *$//' | tr -s ' ' '+' | head -c 60)'"
    echo "TLS='$(if [ "${wizard_tls_dsm:-false}" = true ]; then echo dsm; elif [ "${wizard_tls_self:-false}" = true ]; then echo self; else echo off; fi)'"
