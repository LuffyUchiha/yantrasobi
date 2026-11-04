# Party relay: a single self-contained binary, no state on disk.
FROM dart:stable AS build
WORKDIR /src
COPY pubspec.yaml ./
RUN dart pub get --no-precompile || true
COPY . .
RUN dart pub get --offline && dart compile exe bin/relay.dart -o /relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /relay /relay
ENV PORT=8787
EXPOSE 8787
ENTRYPOINT ["/relay"]
