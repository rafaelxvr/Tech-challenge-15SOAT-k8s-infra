package com.oficina.iac;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.BufferedInputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.lang.reflect.InvocationTargetException;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;

/** Starts one real zero-argument FUN handler through a loopback-only Secrets Manager mock. */
public final class FunctionHandlerColdStart {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Set<String> ARN_SETTINGS = Set.of("DATABASE_SECRET_ARN", "CUSTOMER_SIGNING_SECRET_ARN", "AUTHORIZER_TRUST_SECRET_ARN", "RDS_CA_CERT_SECRET_ARN");
    private static final Set<String> DIRECT_SECRET_SETTINGS = Set.of("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "CUSTOMER_PRIVATE_KEY_B64", "CUSTOMER_PUBLIC_KEY_B64", "STAFF_HMAC_SECRET");
    private static final String AUTH_DATABASE_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:auth-db-i5-coldstart";
    private static final String NOTIFICATION_DATABASE_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:notification-db-i5-coldstart";
    private static final String CUSTOMER_SIGNING_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:customer-signing-i5-coldstart";
    private static final String AUTHORIZER_TRUST_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:authorizer-trust-i5-coldstart";
    private static final String RDS_CA_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-ca-i5-coldstart";
    private static final String CA_PATH = "/tmp/oficina/rds-ca.pem";

    private FunctionHandlerColdStart() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected handler class name and local mock port");
        Plan plan = Plan.forHandler(args[0]);
        assertArnEnvironment(plan);
        MockSecretsManager mock = new MockSecretsManager(plan, Integer.parseInt(args[1]));
        mock.start();
        try {
            Class<?> handlerType = Class.forName(args[0], true, FunctionHandlerColdStart.class.getClassLoader());
            Object handler;
            try { handler = handlerType.getConstructor().newInstance(); }
            catch (InvocationTargetException exception) {
                mock.assertNoFailure();
                throw new IllegalStateException("Handler construction failed after resolver request count " + mock.requestedCount(), exception.getCause());
            }
            if (!handlerType.isInstance(handler)) throw new IllegalStateException("Handler construction did not return its declared type");
            mock.assertExpectedRequests();
            mock.assertCaMaterialized();
            System.out.println("PASS: zero-argument ARN-resolver cold start " + handlerType.getName());
        } finally { mock.close(); }
    }

    private static void assertArnEnvironment(Plan plan) {
        Map<String, String> environment = System.getenv();
        for (String setting : ARN_SETTINGS) {
            String actual = environment.get(setting);
            String expected = plan.arnSettings().get(setting);
            if (expected == null && actual != null) throw new IllegalStateException("Unexpected secret ARN setting " + setting);
            if (expected != null && !expected.equals(actual)) throw new IllegalStateException("Incorrect secret ARN setting " + setting);
        }
        for (String direct : DIRECT_SECRET_SETTINGS) if (environment.containsKey(direct)) throw new IllegalStateException("Raw secret setting must not be injected: " + direct);
        if (plan.expectsCa() && !CA_PATH.equals(environment.get("DB_CA_PATH"))) throw new IllegalStateException("Unexpected RDS CA path");
    }

    private record Plan(Map<String, String> arnSettings, Map<String, Set<String>> schemas, boolean expectsCa) {
        static Plan forHandler(String handler) {
            return switch (handler) {
                case "com.oficina.functions.handler.CriarDesafioHandler" -> new Plan(Map.of("DATABASE_SECRET_ARN", AUTH_DATABASE_ARN, "RDS_CA_CERT_SECRET_ARN", RDS_CA_ARN), Map.of(AUTH_DATABASE_ARN, Set.of("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD")), true);
                case "com.oficina.functions.handler.VerificarDesafioHandler" -> new Plan(Map.of("DATABASE_SECRET_ARN", AUTH_DATABASE_ARN, "CUSTOMER_SIGNING_SECRET_ARN", CUSTOMER_SIGNING_ARN, "RDS_CA_CERT_SECRET_ARN", RDS_CA_ARN), Map.of(AUTH_DATABASE_ARN, Set.of("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"), CUSTOMER_SIGNING_ARN, Set.of("CUSTOMER_PRIVATE_KEY_B64")), true);
                case "com.oficina.functions.handler.AuthorizerHandler" -> new Plan(Map.of("AUTHORIZER_TRUST_SECRET_ARN", AUTHORIZER_TRUST_ARN), Map.of(AUTHORIZER_TRUST_ARN, Set.of("CUSTOMER_PUBLIC_KEY_B64", "STAFF_HMAC_SECRET")), false);
                case "com.oficina.functions.handler.NotificacaoHandler" -> new Plan(Map.of("DATABASE_SECRET_ARN", NOTIFICATION_DATABASE_ARN, "RDS_CA_CERT_SECRET_ARN", RDS_CA_ARN), Map.of(NOTIFICATION_DATABASE_ARN, Set.of("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD")), true);
                default -> throw new IllegalArgumentException("Unsupported handler " + handler);
            };
        }
    }

    private static final class MockSecretsManager implements AutoCloseable {
        private final Plan plan;
        private final ServerSocket server;
        private final Thread listener;
        private final Map<String, String> responses;
        private final Set<String> requested = ConcurrentHashMap.newKeySet();
        private final String certificatePem;
        private final AtomicReference<Throwable> failure = new AtomicReference<>();

        private MockSecretsManager(Plan plan, int port) throws Exception {
            this.plan = plan;
            this.certificatePem = pem();
            this.responses = responses(plan, certificatePem);
            this.server = new ServerSocket();
            this.server.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), port));
            this.listener = new Thread(this::serve, "i5-local-secrets-manager");
            this.listener.setDaemon(true);
        }
        void start() { listener.start(); }

        private void serve() {
            try {
                while (!server.isClosed()) {
                    try (Socket socket = server.accept()) { respond(socket); }
                }
            } catch (IOException exception) {
                if (!server.isClosed()) failure.compareAndSet(null, exception);
            } catch (RuntimeException exception) { failure.compareAndSet(null, exception); }
        }

        private void respond(Socket socket) throws IOException {
            try {
                BufferedInputStream input = new BufferedInputStream(socket.getInputStream());
                String headers = readHeaders(input);
                if (!headers.contains("X-Amz-Target: secretsmanager.GetSecretValue")) throw new IllegalArgumentException("Unexpected mock operation");
                Map<String, String> request = JSON.readValue(readBody(input, headers), new TypeReference<>() { });
                String arn = request.get("SecretId");
                String secret = responses.get(arn);
                if (secret == null) throw new IllegalArgumentException("Unexpected secret ARN");
                requested.add(arn);
                byte[] body = JSON.writeValueAsBytes(Map.of("ARN", arn, "Name", "local-i5-cold-start", "VersionId", UUID.randomUUID().toString(), "SecretString", secret));
                writeResponse(socket, 200, body);
            } catch (Exception exception) {
                byte[] body = "{\"__type\":\"InvalidRequestException\",\"message\":\"local mock rejected request\"}".getBytes(StandardCharsets.UTF_8);
                writeResponse(socket, 400, body);
            }
        }
        private static String readHeaders(BufferedInputStream input) throws IOException {
            StringBuilder headers = new StringBuilder();
            int previous = -1, current;
            while ((current = input.read()) != -1) {
                headers.append((char) current);
                if (previous == '\r' && current == '\n' && headers.toString().endsWith("\r\n\r\n")) return headers.toString();
                previous = current;
            }
            throw new IOException("Incomplete mock HTTP headers");
        }
        private static byte[] readBody(BufferedInputStream input, String headers) throws IOException {
            int marker = headers.toLowerCase(java.util.Locale.ROOT).indexOf("content-length:");
            if (marker < 0) throw new IOException("Missing mock request content length");
            int lineEnd = headers.indexOf("\r\n", marker);
            int length = Integer.parseInt(headers.substring(marker + "content-length:".length(), lineEnd).trim());
            byte[] body = input.readNBytes(length);
            if (body.length != length) throw new IOException("Incomplete mock request body");
            return body;
        }
        private static void writeResponse(Socket socket, int status, byte[] body) throws IOException {
            byte[] headers = ("HTTP/1.1 " + status + " Local Mock\r\nContent-Type: application/x-amz-json-1.1\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
            socket.getOutputStream().write(headers);
            socket.getOutputStream().write(body);
            socket.getOutputStream().flush();
        }

        private static Map<String, String> responses(Plan plan, String certificatePem) throws Exception {
            SecureRandom random = new SecureRandom();
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048, random);
            KeyPair keyPair = generator.generateKeyPair();
            Map<String, String> result = new LinkedHashMap<>();
            for (Map.Entry<String, Set<String>> entry : plan.schemas().entrySet()) {
                Map<String, String> fields = new LinkedHashMap<>();
                for (String field : entry.getValue()) fields.put(field, synthetic(field, keyPair, random));
                assertSchema(fields, entry.getValue());
                result.put(entry.getKey(), JSON.writeValueAsString(fields));
            }
            if (plan.expectsCa()) result.put(RDS_CA_ARN, certificatePem);
            return result;
        }
        private static String synthetic(String field, KeyPair keyPair, SecureRandom random) {
            return switch (field) {
                case "DB_HOST" -> "resolver-" + UUID.randomUUID() + ".invalid";
                case "DB_PORT" -> "5432";
                case "DB_NAME", "DB_USER" -> "resolver_" + UUID.randomUUID().toString().replace("-", "");
                case "DB_PASSWORD", "STAFF_HMAC_SECRET" -> Base64.getUrlEncoder().withoutPadding().encodeToString(random.generateSeed(32));
                case "CUSTOMER_PRIVATE_KEY_B64" -> Base64.getEncoder().encodeToString(keyPair.getPrivate().getEncoded());
                case "CUSTOMER_PUBLIC_KEY_B64" -> Base64.getEncoder().encodeToString(keyPair.getPublic().getEncoded());
                default -> throw new IllegalArgumentException("Unexpected field " + field);
            };
        }
        private static String pem() {
            byte[] content = new byte[256];
            new SecureRandom().nextBytes(content);
            return "-----BEGIN CERTIFICATE-----\n" + Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.US_ASCII)).encodeToString(content) + "\n-----END CERTIFICATE-----";
        }
        private static void assertSchema(Map<String, String> fields, Set<String> expected) {
            if (!fields.keySet().equals(expected) || fields.values().stream().anyMatch(value -> value == null || value.isBlank())) throw new IllegalStateException("Mock response schema differs from the FUN resolver contract");
        }
        void assertExpectedRequests() {
            assertNoFailure();
            if (!requested.equals(responses.keySet())) throw new IllegalStateException("Resolver requested ARNs outside the handler contract");
        }
        void assertNoFailure() {
            if (failure.get() != null) throw new IllegalStateException("Loopback Secrets Manager mock failed", failure.get());
        }
        int requestedCount() { return requested.size(); }
        void assertCaMaterialized() throws IOException {
            if (!plan.expectsCa()) return;
            Path path = Path.of(CA_PATH);
            if (!Files.isRegularFile(path) || !certificatePem.equals(Files.readString(path, StandardCharsets.US_ASCII))) throw new IllegalStateException("Resolver did not materialize the declared RDS CA PEM");
        }
        @Override public void close() throws IOException {
            server.close();
            try { listener.join(1000); } catch (InterruptedException exception) { Thread.currentThread().interrupt(); }
            if (plan.expectsCa()) Files.deleteIfExists(Path.of(CA_PATH));
        }
    }
}
