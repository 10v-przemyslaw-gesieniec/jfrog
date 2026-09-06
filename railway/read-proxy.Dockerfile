# Anonimowa, tylko-do-odczytu furtka przed Artifactory - wersja dla Railway.
#
# Kontekst budowania to korzeń repozytorium, więc COPY widzi read-proxy.py.
# Wskaż ten plik zmienną serwisu:
#
#     RAILWAY_DOCKERFILE_PATH=railway/read-proxy.Dockerfile
#
# Na Railwayu ten serwis jest publiczny, więc READ_TOKEN jest OBOWIĄZKOWY -
# bez niego wystawiasz swoje artefakty całemu internetowi.
FROM python:3.12-alpine

WORKDIR /app
COPY read-proxy.py /app/read-proxy.py

# Bez zależności zewnętrznych - proxy używa wyłącznie biblioteki standardowej.
USER nobody

# Port bierze z $PORT wstrzykniętego przez Railway.
CMD ["python3", "/app/read-proxy.py"]
