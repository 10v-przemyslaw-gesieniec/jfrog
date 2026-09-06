# Artifactory na Railway — kroki manualne

Railway **nie uruchamia `docker-compose.yml`**. Każda usługa z compose staje się
osobnym serwisem Railwaya, `depends_on` nie istnieje, a wolumeny i domeny
konfiguruje się w UI. Dlatego repo zawiera dwa Dockerfile'e w `railway/`,
a poniżej masz listę rzeczy, które musisz wyklikać sam.

Efekt końcowy — trzy serwisy w jednym projekcie:

```
┌─ Postgres        (managed, Railway)              baza Artifactory
├─ artifactory     railway/artifactory.Dockerfile  UI + REST + PUBLIKACJA   (publiczna domena)
└─ read-proxy      railway/read-proxy.Dockerfile   ODCZYT dla Spec Kita      (publiczna domena)
                                                    wymaga Bearer READ_TOKEN
```

---

## 0. Zanim zaczniesz — trzy rzeczy, które trzeba wiedzieć

**Plan.** Wolumen na Free/Trial to **0,5 GB** — za mało na Artifactory.
Potrzebujesz **Hobby (5 GB)** albo wyżej. Volume można powiększyć bez przestoju,
ale **nie da się zmniejszyć**.

**Koszt.** Artifactory to nie jest lekki serwis: JVM z `-Xmx2g` plus kilka
mikroserwisów, realnie 3–4 GB RAM działające non‑stop. Railway rozlicza zużycie,
więc to rząd wielkości kilkudziesięciu dolarów miesięcznie. Jeśli to ma być
tylko demo, rozważ wyłączanie serwisu między sesjami.

**Wszystko będzie publiczne.** Artifactory dostanie publiczną domenę z hasłem
`password`. **Zmiana hasła admina to krok 4 i nie wolno go pominąć** — to nie
jest kosmetyka, tylko jedyna rzecz chroniąca instancję.

---

## 1. Wypchnij repo

```bash
cd ~/Desktop/rbal/jfrog
git add -A
git commit -m "feat: konfiguracja pod Railway"
git push
```

Railway zbuduje pierwszy serwis automatycznie i **prawdopodobnie mu się nie
uda** — bo nie ma jeszcze bazy ani zmiennych. To normalne, poprawimy to w
kolejnych krokach.

---

## 2. PostgreSQL

W projekcie: **New → Database → Add PostgreSQL**.

Nic więcej nie konfigurujesz. Serwis nazwie się `Postgres` — ta nazwa jest
używana w referencjach w kroku 3, więc jeśli nazwiesz go inaczej, podmień ją
wszędzie.

---

## 3. Serwis `artifactory`

Jeśli Railway utworzył już serwis z Twojego repo — użyj go i zmień nazwę na
`artifactory`. Jeśli nie: **New → GitHub Repo →** `10v-przemyslaw-gesieniec/jfrog`.

### 3a. Variables

**Settings → Variables → Raw Editor** i wklej:

```
RAILWAY_DOCKERFILE_PATH=railway/artifactory.Dockerfile
RAILWAY_RUN_UID=0
JF_SHARED_NODE_ID=artifactory-railway
JF_SHARED_DATABASE_TYPE=postgresql
JF_SHARED_DATABASE_DRIVER=org.postgresql.Driver
JF_SHARED_DATABASE_URL=jdbc:postgresql://${{Postgres.PGHOST}}:${{Postgres.PGPORT}}/${{Postgres.PGDATABASE}}
JF_SHARED_DATABASE_USERNAME=${{Postgres.PGUSER}}
JF_SHARED_DATABASE_PASSWORD=${{Postgres.PGPASSWORD}}
JF_SHARED_EXTRAJAVAOPTS=-Xms512m -Xmx2g
```

Dwie z nich są nieoczywiste i bez nich to nie wstanie:

* **`RAILWAY_DOCKERFILE_PATH`** — bez tego Railway szuka `Dockerfile` w korzeniu
  repo i nie znajdzie żadnego. Kontekst budowania zostaje korzeniem repo, dzięki
  czemu `read-proxy.Dockerfile` widzi `read-proxy.py`.
* **`RAILWAY_RUN_UID=0`** — wolumeny Railwaya są montowane jako root, a obraz
  Artifactory chodzi jako uid 1030. Bez tego kontener nie zapisze do
  `/var/opt/jfrog/artifactory`. To udokumentowane obejście Railwaya, nie hack.

`${{Postgres.PGHOST}}` to referencja do serwisu bazy — Railway podstawi wartości
sam i będzie je aktualizował, gdy baza się zmieni.

### 3b. Volume

**Settings → Volumes → New Volume**

| Pole | Wartość |
|---|---|
| Mount path | `/var/opt/jfrog/artifactory` |
| Rozmiar | min. 5 GB |

Ścieżka musi być dokładnie taka — to `JF_PRODUCT_DATA_INTERNAL` obrazu.

### 3c. Networking

**Settings → Networking → Public Networking → Generate Domain**

| Pole | Wartość |
|---|---|
| Target Port | **8082** |

Artifactory **nie czyta `$PORT`** — słucha na 8082 na sztywno, dlatego port
trzeba wskazać ręcznie.

### 3d. Healthcheck

**Settings → Deploy → Healthcheck Path: zostaw puste.**

Pierwszy start (tworzenie schematu w Postgresie) trwa 3–5 minut. Healthcheck
z domyślnym timeoutem ubiłby deploy w połowie. Jeśli chcesz go mieć, ustaw
ścieżkę `/artifactory/api/system/ping` i **timeout 600 s**.

### 3e. Deploy i weryfikacja

Zrób **Deploy** i obserwuj logi. Szukasz:

```
Artifactory successfully started
```

Czego **nie** powinieneś zobaczyć:

| W logach | Znaczenie |
|---|---|
| `DbTypeNotAllowedException: DB Type derby is not allowed` | zmienne `JF_SHARED_DATABASE_*` nie doszły — sprawdź literówki i nazwę serwisu bazy |
| `Master key is missing` w pętli | to skutek powyższego, nie osobny problem |
| `Permission denied` przy `/var/opt/jfrog/artifactory` | brakuje `RAILWAY_RUN_UID=0` |
| `no space left on device` | wolumen za mały |

Gdy wstanie, otwórz `https://<twoja-domena>.up.railway.app/ui/`.

---

## 4. ZMIEŃ HASŁO ADMINA

Zaloguj się jako `admin` / `password` i przejdź kreator, ustawiając mocne hasło.

To jest moment, w którym instancja przestaje być otwarta dla każdego, kto zgadnie
adres. Nie odkładaj tego na później — publiczna domena z domyślnym hasłem to
gotowy incydent.

Hasła **nie zmienisz przez REST** — Artifactory OSS blokuje to API (Pro-only).
Tylko UI.

Zapisz nowe hasło; potrzebujesz go w krokach 5, 6 i 8.

---

## 5. Utwórz repozytorium — z laptopa

`bootstrap.sh` umie działać przeciw zdalnej instancji: adresy podane w środowisku
mają pierwszeństwo przed `.env`.

```bash
cd ~/Desktop/rbal/jfrog
ARTIFACTORY_BASE_URL="https://<artifactory>.up.railway.app" \
ADMIN_PASSWORD="<nowe hasło>" \
./bootstrap.sh
```

Krok „4/4 Read-proxy" zgłosi ostrzeżenie — proxy jeszcze nie istnieje. To
w porządku, wracamy do tego w kroku 7.

---

## 6. Wygeneruj token odczytu

```bash
openssl rand -hex 32
```

Zapisz go. To jedyna rzecz chroniąca Twoje artefakty przed internetem —
`read-proxy` bez tokenu wystawiłby całą zawartość repozytorium publicznie.

---

## 7. Serwis `read-proxy`

**New → GitHub Repo →** to samo repo. Nazwij serwis `read-proxy`.

### 7a. Variables

```
RAILWAY_DOCKERFILE_PATH=railway/read-proxy.Dockerfile
UPSTREAM=https://artifactory-production.up.railway.app
ART_USER=admin
ART_PASSWORD=<hasło admina z kroku 4>
READ_TOKEN=<token z kroku 6>
LISTEN_ADDR=0.0.0.0
```

Proxy łączy się z Artifactory po **publicznej domenie**, a nie przez sieć
prywatną. To celowe: prywatna sieć Railwaya jest IPv6‑only i wymaga, żeby usługa
docelowa nasłuchiwała na `::` — czego nie zweryfikowałem dla obrazu Artifactory.
Ruch po publicznym HTTPS jest odrobinę wolniejszy, ale przewidywalny.

Jeśli chcesz spróbować sieci prywatnej, podmień na
`UPSTREAM=http://artifactory.railway.internal:8082` i ustaw `LISTEN_ADDR=::`.
Gdy proxy zacznie zwracać `502 upstream unreachable` — wróć do wersji publicznej.

Portu **nie ustawiasz**: proxy czyta `$PORT` wstrzyknięty przez Railway.

### 7b. Networking

**Generate Domain.** Target Port zostaw na autodetekcji (proxy słucha na `$PORT`).

### 7c. Weryfikacja

```bash
PROXY="https://<read-proxy>.up.railway.app"
TOKEN="<token z kroku 6>"

curl -s -o /dev/null -w 'bez tokenu:      %{http_code}\n' "$PROXY/artifactory/api/system/ping"
curl -s -o /dev/null -w 'z tokenem:       %{http_code}\n' -H "Authorization: Bearer $TOKEN" "$PROXY/artifactory/api/system/ping"
curl -s -o /dev/null -w 'PUT z tokenem:   %{http_code}\n' -X PUT --data x -H "Authorization: Bearer $TOKEN" "$PROXY/artifactory/generic-local/hack.txt"
```

Oczekiwane: **401**, **200**, **405**.

Pełny test:

```bash
cd ~/Desktop/rbal/jfrog
ARTIFACTORY_BASE_URL="https://<artifactory>.up.railway.app" \
READ_BASE_URL="https://<read-proxy>.up.railway.app" \
READ_TOKEN="<token>" \
ADMIN_PASSWORD="<hasło admina>" \
./smoke-test.sh
```

---

## 8. Developer i CI

### Developer (raz na maszynę)

```bash
export SPECKIT_READ_TOKEN="<token z kroku 6>"     # dopisz do ~/.zshrc
cd ~/Desktop/rbal/rbal-speckit-toolkit
tooling/setup-machine.sh \
  --url https://<read-proxy>.up.railway.app/artifactory \
  --repo speckit-local \
  --token-env SPECKIT_READ_TOKEN
```

Od tej chwili w dowolnym projekcie działa `specify bundle install speckit-rbal-android`.

### GitHub Actions

W repozytorium `rbal-speckit-toolkit` podmień:

| Typ | Nazwa | Wartość |
|---|---|---|
| variable | `ARTIFACTORY_URL` | `https://<artifactory>.up.railway.app/artifactory` |
| variable | `ARTIFACTORY_PUBLIC_URL` | `https://<read-proxy>.up.railway.app/artifactory` |
| variable | `ARTIFACTORY_REPO` | `speckit-local` |
| variable | `SPECKIT_RUNNER` | **usuń tę zmienną** |
| secret | `ARTIFACTORY_USER` | `admin` |
| secret | `ARTIFACTORY_PASSWORD` | hasło admina |

Usunięcie `SPECKIT_RUNNER` to konkretny zysk: Artifactory jest teraz publiczny,
więc **self-hosted runner przestaje być potrzebny** i pipeline wraca na
`ubuntu-latest`.

---

## Checklista

- [ ] plan Hobby lub wyżej (wolumen ≥ 5 GB)
- [ ] serwis `Postgres` dodany
- [ ] `artifactory`: `RAILWAY_DOCKERFILE_PATH`, `RAILWAY_RUN_UID=0`, pięć `JF_SHARED_DATABASE_*`, `JF_SHARED_EXTRAJAVAOPTS`
- [ ] `artifactory`: wolumen na `/var/opt/jfrog/artifactory`
- [ ] `artifactory`: domena + **Target Port 8082**, healthcheck pusty
- [ ] w logach `Artifactory successfully started`
- [ ] **hasło admina zmienione w UI**
- [ ] `bootstrap.sh` przeciw zdalnemu adresowi utworzył `generic-local`
- [ ] `READ_TOKEN` wygenerowany i zapisany
- [ ] `read-proxy`: zmienne + domena; `curl` daje 401 / 200 / 405
- [ ] `smoke-test.sh` przeciw zdalnym adresom przechodzi
- [ ] `setup-machine.sh` u developera; `specify bundle install` działa
- [ ] GitHub: zmienne i sekrety podmienione, `SPECKIT_RUNNER` usunięty

---

## Bezpieczeństwo — co realnie jest wystawione

| Serwis | Kto widzi | Czym chronione |
|---|---|---|
| `artifactory` | cały internet | hasło admina — **jedyna bariera**, dlatego krok 4 |
| `read-proxy` | cały internet | `READ_TOKEN` (Bearer); bez niego 401, zapisy zawsze 405 |
| `Postgres` | tylko sieć prywatna projektu | hasło generowane przez Railway |

`READ_TOKEN` to **jeden współdzielony sekret**. Nie da się go unieważnić dla
jednej osoby — rotacja to zmiana zmiennej w serwisie `read-proxy`, restart
i rozesłanie nowego tokenu. Jeśli potrzebujesz per-osobowych poświadczeń
i odbierania dostępu pojedynczym ludziom, to jest moment na Artifactory
Pro — tam zakładasz prawdziwe konta i tokeny, a `read-proxy` znika z układanki.

Nie wystawiaj `read-proxy` bez `READ_TOKEN`. Proxy startuje wtedy z ostrzeżeniem
w logach, ale nikogo nie zatrzyma.

---

## Czego nie zweryfikowałem

Nie mam dostępu do Railwaya ani do Dockera, więc **żaden z tych kroków nie został
wykonany na żywym wdrożeniu**. Zweryfikowane lokalnie jest natomiast to, co
faktycznie robi kod: `read-proxy` z tokenem (401 bez, 200 z, 405 na zapis),
`bootstrap.sh` i `smoke-test.sh` przeciw adresom podanym w środowisku, oraz
`specify bundle install` przez proxy chronione tokenem.

Trzy miejsca, w których spodziewam się problemów, i co wtedy zrobić:

1. **Uprawnienia do wolumenu.** Gdyby `RAILWAY_RUN_UID=0` nie wystarczyło
   (log: `Permission denied` na `/var/opt/jfrog/artifactory`), trzeba dołożyć
   wrapper entrypointu robiącego `chown -R 1030:1030` na wolumenie przed startem.
   Napiszę go, jak zobaczę log.
2. **Tag obrazu.** `artifactory.Dockerfile` przypina `7.161.20` — to wersja,
   którą masz lokalnie. Jeśli build powie `manifest unknown`, zamień na `latest`
   i wróć do przypięcia po sprawdzeniu, co faktycznie się pobrało.
3. **Autodetekcja portu dla `read-proxy`.** Jeśli Railway nie wykryje portu,
   ustaw Target Port ręcznie i dołóż `LISTEN_PORT` o tej samej wartości.

Wklej mi logi z każdego z tych przypadków, to poprawię pliki.
