#!/usr/bin/env bash
# ============================================================================
#  smoke-test.sh - sprawdza, ze podzial "publikacja z poswiadczeniami /
#  odczyt anonimowy tylko do czytania" faktycznie dziala.
#
#  Oczekiwane wyniki:
#    admin na 8082:     PUT 201, GET 200, DELETE 204
#    anonim na 8082:    GET 401/403        (upstream jest chroniony)
#    zle haslo na 8082: GET 401
#    anonim na 8083:    GET 200            (proxy doklada poswiadczenia)
#    anonim na 8083:    PUT/DELETE 405     (port jest tylko do odczytu)
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

ART="http://localhost:${ARTIFACTORY_PORT:-8082}/artifactory"
PROXY="http://localhost:${READ_PROXY_PORT:-8083}/artifactory"
REPO="${REPO_KEY:-generic-local}"
PATH_IN_REPO="smoke-test/hello.txt"
TESTFILE="$(mktemp)"; echo "smoke test $(date)" > "$TESTFILE"
FAILED=0

# uzyj hasla, ktore faktycznie dziala (OSS moze wciaz miec domyslne)
ADMIN_PASS="$ADMIN_PASSWORD"
if [ "$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASSWORD}" "${ART}/api/system/version")" != "200" ]; then
  if [ "$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:password" "${ART}/api/system/version")" = "200" ]; then
    ADMIN_PASS="password"
    printf '\033[33m  [uwaga]\033[0m uzywam domyslnego hasla admina - w .env masz inne\n'
  fi
fi

hit() { # hit METHOD URL [curl args...]
  local m="$1" u="$2"; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$m" "$u" "$@"
}
check() { # check LABEL EXPECTED ACTUAL
  if [ "$3" = "$2" ]; then
    printf '\033[32m  PASS\033[0m  %-48s HTTP %s\n' "$1" "$3"
  else
    printf '\033[31m  FAIL\033[0m  %-48s HTTP %s (oczekiwano %s)\n' "$1" "$3" "$2"
    FAILED=1
  fi
}
check_any() { # check_any LABEL "kod1 kod2" ACTUAL
  for want in $2; do
    if [ "$3" = "$want" ]; then
      printf '\033[32m  PASS\033[0m  %-48s HTTP %s\n' "$1" "$3"; return
    fi
  done
  printf '\033[31m  FAIL\033[0m  %-48s HTTP %s (oczekiwano jednego z: %s)\n' "$1" "$3" "$2"
  FAILED=1
}

TARGET="${ART}/${REPO}/${PATH_IN_REPO}"
PROXY_TARGET="${PROXY}/${REPO}/${PATH_IN_REPO}"

echo
echo "Publikacja: ${ART}/${REPO}    Odczyt anonimowy: ${PROXY}/${REPO}"
echo "--------------------------------------------------------------------------------"

check     "admin: upload (PUT)"                    201 "$(hit PUT "$TARGET" -u "${ADMIN_USER}:${ADMIN_PASS}" -T "$TESTFILE")"
check     "admin: download (GET)"                  200 "$(hit GET "$TARGET" -u "${ADMIN_USER}:${ADMIN_PASS}")"
check     "zle haslo -> 401"                       401 "$(hit GET "$TARGET" -u "${ADMIN_USER}:zupelnie-zle-haslo")"
check_any "anonim na porcie publikacji: brak dostepu" "401 403" "$(hit GET "$TARGET")"

check     "proxy: anonimowy download (GET)"        200 "$(hit GET "$PROXY_TARGET")"
check     "proxy: ping bez poswiadczen"            200 "$(hit GET "${PROXY}/api/system/ping")"
check     "proxy: upload zablokowany (PUT)"        405 "$(hit PUT "${PROXY}/${REPO}/hack.txt" -T "$TESTFILE")"
check     "proxy: delete zablokowany"              405 "$(hit DELETE "$PROXY_TARGET")"
check     "proxy: POST zablokowany"                405 "$(hit POST "${PROXY}/${REPO}/hack.txt" --data x)"

check     "admin: delete (porzadki)"               204 "$(hit DELETE "$TARGET" -u "${ADMIN_USER}:${ADMIN_PASS}")"

echo "--------------------------------------------------------------------------------"
rm -f "$TESTFILE"

if [ "$FAILED" = "0" ]; then
  printf '\033[32m  Wszystkie testy przeszly.\033[0m\n\n'
else
  printf '\033[31m  Czesc testow nie przeszla - patrz README, sekcja "Rozwiazywanie problemow".\033[0m\n\n'
  exit 1
fi
