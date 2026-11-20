package dev.agentshield.gateway;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistrar;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;
import org.testcontainers.utility.MountableFile;

/**
 * Postgres provisioned with the same role setup as the Compose stack
 * ({@code deploy/postgres/init-roles.sh}): a schema owner for Flyway and a
 * least-privilege app role for runtime.
 */
@TestConfiguration(proxyBeanMethods = false)
class TestcontainersConfiguration {

    static final String OWNER_PASSWORD = "owner-test";
    static final String APP_PASSWORD = "app-test";

    @Bean
    PostgreSQLContainer postgresContainer() {
        return new PostgreSQLContainer(DockerImageName.parse("postgres:16.6-alpine"))
                .withEnv("AGENTSHIELD_OWNER_PASSWORD", OWNER_PASSWORD)
                .withEnv("AGENTSHIELD_APP_PASSWORD", APP_PASSWORD)
                .withCopyFileToContainer(
                        MountableFile.forHostPath("../deploy/postgres/init-roles.sh", 0755),
                        "/docker-entrypoint-initdb.d/10-init-roles.sh");
    }

    @Bean
    DynamicPropertyRegistrar postgresProperties(PostgreSQLContainer pg) {
        return registry -> {
            registry.add("spring.datasource.url", () -> jdbcUrl(pg));
            registry.add("spring.datasource.username", () -> "agentshield_app");
            registry.add("spring.datasource.password", () -> APP_PASSWORD);
            registry.add("spring.flyway.user", () -> "agentshield_owner");
            registry.add("spring.flyway.password", () -> OWNER_PASSWORD);
        };
    }

    static String jdbcUrl(PostgreSQLContainer pg) {
        return "jdbc:postgresql://" + pg.getHost() + ":" + pg.getMappedPort(5432) + "/agentshield";
    }
}
