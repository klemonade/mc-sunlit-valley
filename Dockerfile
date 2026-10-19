FROM eclipse-temurin:17-jre-jammy

# Run as root so Dokploy named volumes mount with writable permissions for the server process.
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /data

COPY start.sh variables.txt server.properties server-icon.png ./
COPY mods ./mods
COPY config ./config
COPY defaultconfigs ./defaultconfigs
COPY kubejs ./kubejs
COPY patchouli_books ./patchouli_books
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /data/start.sh

EXPOSE 25565 25575
ENTRYPOINT ["/entrypoint.sh"]
