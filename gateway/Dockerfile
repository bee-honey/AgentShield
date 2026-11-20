FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN ./mvnw -q -B dependency:go-offline
COPY src src
# Tests run in CI / `make test` (they need Docker for Testcontainers).
RUN ./mvnw -q -B package -DskipTests

FROM eclipse-temurin:21-jre
RUN useradd --uid 10001 --no-create-home gateway
WORKDIR /app
COPY --from=build /src/target/gateway-*.jar /app/gateway.jar
USER gateway
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/gateway.jar"]
