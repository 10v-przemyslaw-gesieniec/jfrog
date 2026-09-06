# JFrog Artifactory OSS lokalnie (Docker) + upload artefaktów przez REST API

Lokalna instancja Artifactory dla toolkitu Spec Kita. Trzy kontenery:

| Usługa | Port | Rola |
|---|---|---|
| `artifactory` | **8082** | UI, REST API, **publikacja** — wymaga poświadczeń |
| `read-proxy` | **8083** | **anonimowy odczyt** dla Spec Kita — tylko `GET`/`HEAD` |
| `postgres` | (wewn.) | baza Artifactory |

Jedno konto: **`admin`**. Hasło trzymasz w `.env` (świeża instancja: `password`).

---

## Dlaczego jedno konto i dlaczego proxy

Pierwotny plan zakładał dwa konta — `reader` i `deployer` — zakładane skryptem
przez REST API. **Na Artifactory OSS to niewykonalne.** Sprawdzone na żywej
instancji 7.161.20:

| Endpoint | Odpowiedź |
|---|---|
| `GET/PUT /api/security/users`, `/groups`, `/permissions`, `/api/v2/security/permissions` | `400` — *„This REST API is available only in Artifactory Pro"* |
| `POST /api/security/users/authentication/changePassword` | `400` — to samo |
| `/access/api/v1|v2/...` (Access API, tokeny) | `401` — *„Unsupported authentication method Basic"*, a tokenu nie wydasz, bo endpoint tokenów sam wymaga tokenu |
| `GET /api/repositories`, `PATCH /api/system/configuration` | `200` — **działa** |

Do tego Spec Kit w `~/.specify/auth.json` przyjmuje wyłącznie `Bearer <token>`
albo Basic z **pustą nazwą użytkownika** — nie ma pola na „user + hasło".
Włączenie `anonAccessEnabled: true` też nie wystarcza: anonim zaczyna dostawać
`403` zamiast `401`, bo jest rozpoznawany, ale nie ma permission targetu z prawem
odczytu — a permission targety są Pro-only.

Stąd `read-proxy`: ~120 linii Pythona, które przyjmują anonimowe `GET`/`HEAD`
i przekazują je wyżej z nagłówkiem `Authorization: Basic` admina. Zapisy odbija
z `405`, więc anonimowy port niczego nie zmieni. Spec Kit nie wie o jego
istnieniu — dostaje zwykły URL HTTP i tyle.

**Na firmowym Artifactory (Pro/Enterprise) proxy jest zbędne** — tam zakładasz
prawdziwe konto read-only i wydajesz token. Podział ról wraca wtedy sam;
szczegóły w `docs/ARTIFACTORY.md` w repozytorium `rbal-speckit-toolkit`.

---

> **Chcesz to wystawić w chmurze?** Railway nie uruchamia `docker-compose.yml` —
> każdy serwis konfiguruje się osobno. Komplet kroków: [`railway/README.md`](railway/README.md).

## 1. Wymagania

- Docker Desktop (uruchomiony)
- **min. 6 GB RAM dla Dockera** (Artifactory `-Xmx2g` + PostgreSQL)
- `curl` i `bash`
- ~3 GB miejsca

> **PostgreSQL jest obowiązkowy.** Artifactory 7.16x+ nie startuje na wbudowanej
> bazie Derby — odmawia z `DB Type derby is not allowed: Cannot start the
> application with a database other than PostgreSQL`. Objawem jest serwis Access,
> który nie wstaje, nie tworzy `master.key`, i logi zapętlone na
> `Master key is missing`.

## 2. Uruchomienie

```bash
docker compose up -d
./bootstrap.sh      # czeka na start, tworzy generic-local, sprawdza proxy
./smoke-test.sh     # dowód, że podział publikacja/odczyt działa
```

Pierwszy start to 3–5 minut (tworzenie schematu w Postgresie).

- **UI:** http://localhost:8082/ui/ — `admin` / hasło z `.env`
- **Publikacja:** `http://localhost:8082/artifactory/generic-local/...`
- **Odczyt anonimowy:** `http://localhost:8083/artifactory/generic-local/...`

### Zmiana hasła admina

Tylko przez UI (REST jest Pro-only). Zaloguj się na http://localhost:8082/ui/,
przejdź kreator, a nowe hasło wpisz do `.env` jako `ADMIN_PASSWORD`.
`bootstrap.sh` i `smoke-test.sh` same wykryją, którego hasła użyć.

---

## 3. Upload artefaktów przez REST API

Publikacja zawsze idzie na **8082** z poświadczeniami admina.

### 3.1 Podstawowy upload

```bash
curl -u admin:password \
     -T ./app-1.0.0.jar \
     "http://localhost:8082/artifactory/generic-local/com/example/app/1.0.0/app-1.0.0.jar"
```

`201 Created` + JSON z `downloadUri`, `size` i `checksums`. Katalogi na ścieżce
tworzą się same.

### 3.2 Z weryfikacją sumy kontrolnej (zalecane w CI)

```bash
SHA256=$(shasum -a 256 app-1.0.0.jar | cut -d' ' -f1)
curl -u admin:password \
     -H "X-Checksum-Sha256: ${SHA256}" \
     -T ./app-1.0.0.jar \
     "http://localhost:8082/artifactory/generic-local/app/app-1.0.0.jar"
```

Artifactory odrzuci plik, jeśli treść nie zgadza się z nagłówkiem.

### 3.3 Properties (metadane)

Matrix parameters w ścieżce:

```bash
curl -u admin:password -T ./app-1.0.0.jar \
  "http://localhost:8082/artifactory/generic-local/app/app-1.0.0.jar;build.number=42;git.commit=a1b2c3d"
```

Na istniejącym artefakcie:

```bash
curl -u admin:password -X PUT \
  "http://localhost:8082/artifactory/api/storage/generic-local/app/app-1.0.0.jar?properties=env=prod"
```

### 3.4 Archiwum z rozpakowaniem

```bash
tar -czf dist.tar.gz -C ./dist .
curl -u admin:password -H "X-Explode-Archive: true" -T ./dist.tar.gz \
  "http://localhost:8082/artifactory/generic-local/releases/1.0.0/"
```

`X-Explode-Archive-Atomic: true` robi to transakcyjnie. Formaty: zip, tar, tar.gz, tgz.

### 3.5 Checksum deploy (bez przesyłania treści)

```bash
curl -u admin:password -X PUT \
  -H "X-Checksum-Deploy: true" \
  -H "X-Checksum-Sha1: 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12" \
  "http://localhost:8082/artifactory/generic-local/app/copy.jar"
```

`404`, jeśli takiej sumy nie ma w storage.

### 3.6 Wiele plików

```bash
BASE="http://localhost:8082/artifactory/generic-local/releases/1.0.0"
for f in ./dist/*; do
  curl -sS -u admin:password -T "$f" "${BASE}/$(basename "$f")" \
    -o /dev/null -w "%{http_code}  $(basename "$f")\n"
done
```

### 3.7 Python

```python
import hashlib, requests

BASE, REPO = "http://localhost:8082/artifactory", "generic-local"
AUTH = ("admin", "password")

def upload(local_path: str, remote_path: str, **props):
    data = open(local_path, "rb").read()
    url = f"{BASE}/{REPO}/{remote_path}" + "".join(f";{k}={v}" for k, v in props.items())
    r = requests.put(url, data=data, auth=AUTH, timeout=120, headers={
        "X-Checksum-Sha256": hashlib.sha256(data).hexdigest(),
    })
    r.raise_for_status()
    return r.json()["downloadUri"]
```

### 3.8 JFrog CLI

```bash
brew install jfrog-cli
jf c add local --url=http://localhost:8082 --user=admin --password='password' --interactive=false
jf rt upload "dist/*.zip" "generic-local/releases/1.0.0/"
```

---

## 4. Odczyt

Dwa równoważne wejścia — różni je tylko to, czy trzeba się uwierzytelnić:

```bash
# z poświadczeniami, port publikacji
curl -u admin:password -O "http://localhost:8082/artifactory/generic-local/app/app-1.0.0.jar"

# anonimowo, przez read-proxy - tego używa Spec Kit
curl -O "http://localhost:8083/artifactory/generic-local/app/app-1.0.0.jar"
```

Pozostałe operacje (na 8082, jako admin):

| Operacja | Komenda |
|---|---|
| Metadane pliku | `curl -u admin:password "$ART/api/storage/generic-local/app/app-1.0.0.jar"` |
| Lista repo | `curl -u admin:password "$ART/api/storage/generic-local/?list&deep=1"` |
| Szukanie po nazwie | `curl -u admin:password "$ART/api/search/artifact?name=app&repos=generic-local"` |
| Szukanie po property | `curl -u admin:password "$ART/api/search/prop?env=dev&repos=generic-local"` |
| Usunięcie | `curl -u admin:password -X DELETE "$ART/generic-local/app/app-1.0.0.jar"` |
| Health check | `curl "$ART/api/system/ping"` |

AQL:

```bash
curl -u admin:password -X POST "http://localhost:8082/artifactory/api/search/aql" \
  -H "Content-Type: text/plain" \
  -d 'items.find({"repo":"generic-local","name":{"$match":"*.zip"}}).include("name","path","size")'
```

---

## 5. Zarządzanie kontenerami

```bash
docker compose ps                          # status trzech usług
docker compose logs -f artifactory         # logi Artifactory
docker compose logs -f read-proxy          # kto co czyta przez proxy
docker compose restart read-proxy          # po zmianie hasła admina w .env
docker compose down                        # stop (dane zostają)
docker compose down -v                     # stop + USUNIĘCIE danych i bazy
```

> Po zmianie `ADMIN_PASSWORD` w `.env` **zrestartuj `read-proxy`** — poświadczenia
> wstrzykuje przy starcie.

---

## 6. Rozwiązywanie problemów

**Pętla `Master key is missing` / `Connection refused` na 8046**
Na dole stack trace'a szukaj przyczyny:
```bash
docker compose logs artifactory 2>&1 | grep -A3 "DbTypeNotAllowedException"
```
`DB Type derby is not allowed` = brak PostgreSQL. Sprawdź `docker compose ps`
i po naprawie zrób pełny reset: `docker compose down -v && docker compose up -d`.
Master key nie jest przyczyną — tworzy go Access po połączeniu z bazą.

**`This REST API is available only in Artifactory Pro`**
Trafiłeś w API bezpieczeństwa. Na OSS użytkownicy, grupy, permission targety
i zmiana hasła są dostępne tylko przez UI. To nie jest błąd konfiguracji.

**`smoke-test.sh`: proxy zwraca 401 zamiast 200**
Hasło admina w `.env` rozjechało się z rzeczywistym. Popraw `.env`
i `docker compose restart read-proxy`.

**`smoke-test.sh`: anonim na 8082 zwraca 200 zamiast 401/403**
Ktoś włączył anonimowy odczyt bezpośrednio na Artifactory. Wyłącz:
```bash
curl -u admin:password -X PATCH "http://localhost:8082/artifactory/api/system/configuration" \
  -H 'Content-Type: application/yaml' --data-binary 'security:
  anonAccessEnabled: false
'
```

**`postgres`: `FATAL: password authentication failed`**
Wolumen pamięta hasło z pierwszego startu. Po zmianie `DB_PASSWORD`:
`docker compose down -v`.

**Port zajęty**
Zmień `ARTIFACTORY_PORT` lub `READ_PROXY_PORT` w `.env`, potem
`docker compose up -d --force-recreate`. Skrypty czytają ten sam plik.

---

## 7. Pliki

| Plik | Rola |
|---|---|
| `docker-compose.yml` | Artifactory + PostgreSQL + read-proxy |
| `read-proxy.py` | anonimowa furtka tylko do odczytu (~120 linii, stdlib) |
| `.env` | porty, hasła, klucz repozytorium (**nie commituj**) |
| `.env.example` | wzorzec do repo |
| `bootstrap.sh` | czeka na start, tworzy repo, sprawdza proxy |
| `smoke-test.sh` | dowód, że publikacja wymaga poświadczeń, a odczyt nie |
| `railway/` | wdrożenie tego samego układu na Railway — Dockerfile'e i **kroki manualne** ([railway/README.md](railway/README.md)) |
