# Artifactory OSS dla Railway.
#
# Railway buduje z kontekstem = korzeń repozytorium, a ten plik wskazujesz
# zmienną serwisu:
#
#     RAILWAY_DOCKERFILE_PATH=railway/artifactory.Dockerfile
#
# Wersja jest przypięta świadomie. `latest` potrafi z dnia na dzień zmienić
# wymagania (tak zniknęło wsparcie dla bazy Derby), a wtedy deploy pada bez
# ostrzeżenia. 7.161.20 to wersja zweryfikowana lokalnie z PostgreSQL.
FROM releases-docker.jfrog.io/jfrog/artifactory-oss:7.161.20

# Port platformy JFrog (UI + REST API). W ustawieniach serwisu na Railwayu
# ustaw Target Port na 8082 - Artifactory nie czyta $PORT.
EXPOSE 8082
