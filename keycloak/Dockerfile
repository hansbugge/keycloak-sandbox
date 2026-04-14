FROM curlimages/curl:latest AS downloader
RUN curl -fSL -o /tmp/keycloak-magic-link.jar \
    https://repo1.maven.org/maven2/io/phasetwo/keycloak/keycloak-magic-link/0.43/keycloak-magic-link-0.43.jar

FROM quay.io/keycloak/keycloak:latest
COPY --from=downloader /tmp/keycloak-magic-link.jar /opt/keycloak/providers/keycloak-magic-link.jar
