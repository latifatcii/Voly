package dev.voly.agent;

import android.app.Application;
import android.os.Process;
import android.util.Base64;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Map;

/**
 * The agent's entry point. Voly attaches a small JVMTI library to a
 * debuggable app (`adb shell cmd activity attach-agent`); that library
 * loads this class from memory and calls `start` with the options Voly
 * passed.
 *
 * From then on the agent listens on a Unix socket only the device's shell
 * (and therefore `adb forward`) can be pointed at, and refuses every
 * command until a handshake carries the session token Voly chose.
 */
public final class Bootstrap {
    private Bootstrap() {}

    private static final Object LOCK = new Object();
    private static volatile Session current;
    /**
     * One for the life of the process, whichever host session is talking:
     * view ids handed out earlier stay valid when Voly reconnects.
     */
    private static Dispatcher dispatcher;

    /** Main thread only. */
    private static Dispatcher dispatcher() {
        if (dispatcher == null) {
            dispatcher = new Dispatcher(event -> {
                Session session = current;
                if (session != null) session.sendEvent(event);
            });
        }
        return dispatcher;
    }

    /**
     * @param options `key=value` pairs separated by `,`:
     *   `socket` — name of the abstract Unix socket to listen on;
     *   `token`  — session token the host must present;
     *   `info`   — file name (in the app's cache directory) to write the
     *              agent's details to once it is listening.
     */
    public static void start(String options) {
        final Map<String, String> parsed = parse(options);
        final String socket = parsed.get("socket");
        final String token = parsed.get("token");
        if (socket == null || socket.isEmpty() || token == null || token.isEmpty()) {
            Log.w("started without a socket name or token; not listening");
            return;
        }
        // Attaching again (Voly restarted) replaces the previous session.
        Ui.MAIN.post(() -> {
            synchronized (LOCK) {
                if (current != null) current.stop();
                current = new Session(socket, token, parsed.get("info"));
                current.start(0);
            }
        });
    }

    private static Map<String, String> parse(String options) {
        Map<String, String> result = new HashMap<>();
        if (options == null) return result;
        for (String pair : options.split(",")) {
            int equals = pair.indexOf('=');
            if (equals > 0) result.put(pair.substring(0, equals).trim(), pair.substring(equals + 1).trim());
        }
        return result;
    }

    /** One host connection's worth of state: the socket, the token, who has authenticated. */
    private static final class Session implements WebSocketServer.Listener {
        private final String socketName;
        private final String token;
        private final String infoFileName;
        private final WebSocketServer server;
        private volatile long authenticatedConnection = -1;
        private volatile boolean stopped;

        Session(String socketName, String token, String infoFileName) {
            this.socketName = socketName;
            this.token = token;
            this.infoFileName = infoFileName;
            this.server = new WebSocketServer(socketName, this);
        }

        void start(int attempt) {
            if (stopped) return;
            Application app = Ui.application();
            if (app == null && attempt < 100) {
                // Attached before the Application exists: wait for it.
                Ui.MAIN.postDelayed(() -> start(attempt + 1), 50);
                return;
            }
            try {
                server.start();
            } catch (Throwable e) {
                Log.e("could not listen on " + socketName, e);
                return;
            }
            Log.i("listening on localabstract:" + socketName + " in pid " + Process.myPid());
            writeInfo(app);
        }

        void stop() {
            stopped = true;
            server.stop();
            dispatcher().reset();
        }

        /** The Android counterpart of the iOS agent's port file: tells Voly the agent is up, and who it is. */
        private void writeInfo(Application app) {
            if (app == null || infoFileName == null || infoFileName.isEmpty() || infoFileName.contains("/")) return;
            try {
                File directory = app.getCacheDir();
                File[] stale = directory.listFiles();
                if (stale != null) {
                    for (File file : stale) {
                        if (file.getName().startsWith("voly-agent-") && file.getName().endsWith(".json")) file.delete();
                    }
                }
                JSONObject info = Json.object();
                Json.put(info, "protocolVersion", Dispatcher.PROTOCOL_VERSION);
                Json.put(info, "agentVersion", Dispatcher.AGENT_VERSION);
                Json.put(info, "pid", Process.myPid());
                Json.put(info, "package", app.getPackageName());
                Json.put(info, "label", ScreenDescriber.appName(app));
                Json.put(info, "socket", socketName);
                File file = new File(directory, infoFileName);
                try (FileOutputStream out = new FileOutputStream(file)) {
                    out.write(info.toString().getBytes(StandardCharsets.UTF_8));
                }
            } catch (Throwable e) {
                Log.e("could not write " + infoFileName, e);
            }
        }

        // MARK: WebSocketServer.Listener

        @Override
        public void onMessage(String text, long connectionId) {
            final long id;
            final JSONObject command;
            try {
                JSONObject envelope = new JSONObject(text);
                if (!"command".equals(envelope.optString("kind"))) return;
                id = envelope.optLong("id");
                byte[] payload = Base64.decode(envelope.optString("payload"), Base64.DEFAULT);
                command = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            } catch (Throwable e) {
                Log.w("unreadable message: " + e);
                return;
            }

            // A connection has to open with a handshake that carries the token.
            if (command.has("handshake")) {
                JSONObject request = command.optJSONObject("handshake");
                JSONObject values = request != null ? request.optJSONObject("_0") : null;
                String presented = values != null && !values.isNull("authToken") ? values.optString("authToken", null) : null;
                if (presented == null || !constantTimeEquals(presented, token)) {
                    respond(id, Dispatcher.errorResponse(AgentError.unauthorized()), connectionId);
                    Log.w("handshake with a wrong or missing token; dropping the connection");
                    server.closeAfterSending(connectionId);
                    return;
                }
                authenticatedConnection = connectionId;
            } else if (authenticatedConnection != connectionId) {
                respond(id, Dispatcher.errorResponse(AgentError.unauthorized()), connectionId);
                return;
            }

            Ui.MAIN.post(() -> {
                if (stopped) return;
                dispatcher().handle(command, response -> respond(id, response, connectionId));
            });
        }

        @Override
        public void onClosed(long connectionId) {
            if (authenticatedConnection != connectionId) return;
            authenticatedConnection = -1;
            // The host is gone: don't leave the app in pick mode with nobody to leave it.
            Ui.MAIN.post(() -> {
                if (authenticatedConnection == -1 && !stopped) dispatcher().reset();
            });
        }

        private void respond(long id, JSONObject response, long connectionId) {
            server.send(envelope(id, "response", response), connectionId);
        }

        private void sendEvent(JSONObject event) {
            long connection = authenticatedConnection;
            if (connection >= 0) server.send(envelope(0, "event", event), connection);
        }

        /** `MessageEnvelope`: the payload is the encoded message, as base64 `Data`. */
        private static String envelope(long id, String kind, JSONObject payload) {
            JSONObject envelope = Json.object();
            Json.put(envelope, "id", id);
            Json.put(envelope, "kind", kind);
            Json.put(envelope, "payload",
                Base64.encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
            return envelope.toString();
        }

        private static boolean constantTimeEquals(String a, String b) {
            return MessageDigest.isEqual(a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
        }
    }
}
