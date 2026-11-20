package dev.agentshield.gateway;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.testcontainers.postgresql.PostgreSQLContainer;

@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("dev")
class GatewayApplicationTests {

    @Autowired JdbcTemplate jdbc;          // connected as the app role
    @Autowired PostgreSQLContainer pg;
    @LocalServerPort int port;

    private final HttpClient http = HttpClient.newHttpClient();

    @Test
    void migrationsAndDevSeedAreApplied() {
        assertThat(jdbc.queryForObject("SELECT count(*) FROM agent", Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM agent_grant WHERE agent_id = 'support-agent' AND tool_name = 'read_employee_records'",
                Integer.class))
                .as("support agent must not hold the HR permission")
                .isZero();
        assertThat(jdbc.queryForObject("SELECT last_hash FROM audit_chain_head", String.class))
                .isEqualTo("0".repeat(64));
    }

    @Test
    void appRoleCanAppendAuditEventsButNotRewriteThem() {
        long seq = 1_000_000 + (long) (Math.random() * 1_000_000);
        jdbc.update("""
                INSERT INTO audit_event (seq, event_id, occurred_at, event_type, prev_hash, hash)
                VALUES (?, ?, now(), 'test', 'p', ?)
                """, seq, UUID.randomUUID(), "h-" + seq);

        assertThatThrownBy(() -> jdbc.update("UPDATE audit_event SET event_type = 'x' WHERE seq = ?", seq))
                .rootCause().hasMessageContaining("permission denied");
        assertThatThrownBy(() -> jdbc.update("DELETE FROM audit_event WHERE seq = ?", seq))
                .rootCause().hasMessageContaining("permission denied");
    }

    @Test
    void appRoleHasNoDdlRights() {
        assertThatThrownBy(() -> jdbc.execute("CREATE TABLE sneaky (id int)"))
                .rootCause().hasMessageContaining("permission denied");
    }

    @Test
    void evenTheOwnerCannotRewriteAuditHistory() throws Exception {
        try (Connection owner = DriverManager.getConnection(
                TestcontainersConfiguration.jdbcUrl(pg), "agentshield_owner", TestcontainersConfiguration.OWNER_PASSWORD);
             Statement st = owner.createStatement()) {
            st.executeUpdate("""
                    INSERT INTO audit_event (seq, event_id, occurred_at, event_type, prev_hash, hash)
                    VALUES (42, gen_random_uuid(), now(), 'test', 'p', 'h-owner')
                    """);
            assertThatThrownBy(() -> st.executeUpdate("UPDATE audit_event SET event_type = 'x' WHERE seq = 42"))
                    .hasMessageContaining("append-only");
            assertThatThrownBy(() -> st.executeUpdate("DELETE FROM audit_event WHERE seq = 42"))
                    .hasMessageContaining("append-only");
            assertThatThrownBy(() -> st.executeUpdate("TRUNCATE audit_event"))
                    .hasMessageContaining("append-only");
        }
    }

    @Test
    void healthIsPublicButEverythingElseNeedsAToken() throws Exception {
        assertThat(get("/actuator/health").statusCode()).isEqualTo(200);
        assertThat(get("/mcp").statusCode()).isEqualTo(401);
    }

    private HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create("http://localhost:" + port + path)).build(),
                HttpResponse.BodyHandlers.ofString());
    }
}
