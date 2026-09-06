#!/usr/bin/env bash
# ============================================================================
#  bootstrap.sh - konfiguracja lokalnego Artifactory OSS
#
#  Co robi (tylko to, co OSS przepuszcza przez REST):
#   1. czeka, az Artifactory wystartuje
#   2. rozpoznaje edycje i sprawdza poswiadczenia admina
#   3. tworzy repozytorium generic-local
#   4. sprawdza, czy read-proxy odpowiada
#
#  Czego NIE robi i dlaczego: Artifactory OSS odrzuca cale API bezpieczenstwa
#  (uzytkownicy, grupy, permission targety, zmiana hasla) komunikatem
#  "This REST API is available only in Artifactory Pro". Dlatego lokalnie
#  pracuje jedno konto - admin - a anonimowy odczyt dla Spec Kita zapewnia
#  read-proxy. Na licencjonowanej instancji rozdzielasz role normalnie;
#  patrz docs/ARTIFACTORY.md w rbal-speckit-toolkit.
#
#  Skrypt jest idempotentny.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "BLAD: brak pliku .env (skopiuj .env.example)" >&2; exit 1; }

# .env dostarcza wartosci domyslne, ale NIE nadpisuje tego, co juz jest
# w srodowisku - dzieki temu ten sam skrypt dziala lokalnie i przeciw
# zdalnej instancji:
#   ARTIFACTORY_BASE_URL=https://... READ_TOKEN=... ./bootstrap.sh
load_env() {
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "${!key+set}" ] || export "$key=$val"
  done < "$1"
}

load_env .env

# Lokalnie budowane z portow z .env; dla wdrozenia zdalnego (Railway) podaj
# pelne adresy w ARTIFACTORY_BASE_URL / READ_BASE_URL - w .env albo w srodowisku.
BASE="${ARTIFACTORY_BASE_URL:-http://localhost:${ARTIFACTORY_PORT:-8082}}"
PROXY="${READ_BASE_URL:-http://localhost:${READ_PROXY_PORT:-8083}}"
BASE="${BASE%/}"; PROXY="${PROXY%/}"
ART="${BASE}/artifactory"
WAIT_SECONDS="${WAIT_SECONDS:-900}"

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

BODY=""
req() { # req METHOD URL [curl args...]
  local method="$1" url="$2"; shift 2
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" "$url" "$@" || echo 000)"
  BODY="$(cat "$tmp")"; rm -f "$tmp"
  echo "$code"
}

# ---------------------------------------------------------------------------
step "1/4 Czekam na start Artifactory (${BASE})"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until curl -fsS "${ART}/api/system/ping" >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    c_err "Artifactory nie wystartowal w ciagu ${WAIT_SECONDS}s."
    c_err "docker compose logs --tail=100 artifactory"
    c_err "Jesli widzisz 'DbTypeNotAllowedException' - patrz README, sekcja o PostgreSQL."
    exit 1
  fi
  printf '.'
  sleep 5
done
echo; c_ok "[OK] /api/system/ping odpowiada"

# ---------------------------------------------------------------------------
step "2/4 Edycja i poswiadczenia admina"
auth_works() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:$1" "${ART}/api/system/version")" = "200" ]
}

ADMIN_PASS=""
if auth_works "${ADMIN_PASSWORD}"; then
  ADMIN_PASS="${ADMIN_PASSWORD}"
elif auth_works "password"; then
  ADMIN_PASS="password"
  c_warn "[uwaga] dziala domyslne haslo 'password', a w .env masz inne."
  c_warn "        OSS nie pozwala zmienic hasla przez REST - zrob to w UI"
  c_warn "        (${BASE}/ui/) i wpisz nowe do .env jako ADMIN_PASSWORD."
else
  c_err "Nie moge zalogowac sie jako ${ADMIN_USER} ani haslem z .env, ani domyslnym 'password'."
  c_err "Wpisz aktualne haslo do .env (ADMIN_PASSWORD) i uruchom ponownie."
  exit 1
fi
AUTH=(-u "${ADMIN_USER}:${ADMIN_PASS}")
JSON=(-H 'Content-Type: application/json')

VERSION_JSON="$(curl -s "${AUTH[@]}" "${ART}/api/system/version")"
EDITION="$(printf '%s' "$VERSION_JSON" | sed -n 's/.*"license"[^"]*"\([^"]*\)".*/\1/p')"
ART_VERSION="$(printf '%s' "$VERSION_JSON" | sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p')"
c_ok "[OK] ${EDITION:-nieznana edycja} ${ART_VERSION:-}"

case "$EDITION" in
  *OSS*)
    echo "     OSS: API bezpieczenstwa jest zablokowane - pracujemy na jednym koncie admina,"
    echo "     a anonimowy odczyt dla Spec Kita idzie przez read-proxy (${PROXY})." ;;
  "")  c_warn "[uwaga] nie odczytalem edycji z /api/system/version" ;;
  *)   c_warn "[uwaga] to nie OSS (${EDITION}). Na tej edycji mozesz zalozyc konta"
       c_warn "        reader/deployer i wydac token - patrz docs/ARTIFACTORY.md." ;;
esac

# ---------------------------------------------------------------------------
step "3/4 Repozytorium ${REPO_KEY}"
if [ "$(req GET "${ART}/api/repositories/${REPO_KEY}" "${AUTH[@]}")" = "200" ]; then
  c_ok "[OK] ${REPO_KEY} juz istnieje"
else
  code=$(req PUT "${ART}/api/repositories/${REPO_KEY}" "${AUTH[@]}" "${JSON[@]}" -d "{
    \"key\": \"${REPO_KEY}\",
    \"rclass\": \"local\",
    \"packageType\": \"generic\",
    \"repoLayoutRef\": \"simple-default\",
    \"description\": \"Presety, bundle i katalogi Spec Kita\",
    \"blackedOut\": false
  }")
  if [[ "$code" =~ ^2 ]]; then
    c_ok "[OK] ${REPO_KEY} utworzone (HTTP $code)"
  else
    c_err "Blad tworzenia repozytorium (HTTP $code): ${BODY:0:300}"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
step "4/4 Read-proxy (${PROXY})"
PROXY_AUTH=()
[ -n "${READ_TOKEN:-}" ] && PROXY_AUTH=(-H "Authorization: Bearer ${READ_TOKEN}")
if [ "$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_AUTH[@]}" "${PROXY}/artifactory/api/system/ping")" = "200" ]; then
  if [ -n "${READ_TOKEN:-}" ]; then
    c_ok "[OK] read-proxy odpowiada (chroniony tokenem READ_TOKEN)"
  else
    c_ok "[OK] read-proxy odpowiada i czyta Artifactory bez poswiadczen"
  fi
else
  c_warn "[uwaga] read-proxy nie odpowiada pod ${PROXY}."
  c_warn "        Lokalnie:  docker compose ps read-proxy && docker compose logs read-proxy"
  c_warn "        Railway:   sprawdz READ_TOKEN po obu stronach i logi serwisu read-proxy"
fi

# ---------------------------------------------------------------------------
cat <<SUMMARY

$(c_ok "==================== GOTOWE ====================")

  UI / publikacja :  ${BASE}
  admin           :  ${ADMIN_USER} / ${ADMIN_PASS}
  repozytorium    :  ${REPO_KEY}

  Anonimowy odczyt (dla Spec Kita) :  ${PROXY}
  Publikacja (CI, release.py)      :  ${BASE}/artifactory  jako ${ADMIN_USER}

  Weryfikacja:  ./smoke-test.sh

SUMMARY
