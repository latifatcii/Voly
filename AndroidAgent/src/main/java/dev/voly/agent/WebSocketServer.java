package dev.voly.agent;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicLong;

/**
 * A minimal WebSocket (RFC 6455) server on an abstract-namespace Unix
 * socket. The host reaches it through `adb forward tcp:N localabstract:…`,
 * so nothing listens on the device's network.
 *
 * Like the iOS agent it serves one client at a time: a new connection
 * replaces the previous one. Every connection gets an id, so an answer is
 * never delivered to a client that connected afterwards.
 */
final class WebSocketServer {
    interface Listener {
        /** Called on the connection's reader thread. */
        void onMessage(String text, long connectionId);

        void onClosed(long connectionId);
    }

    private static final String ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final int MAX_MESSAGE_BYTES = 64 * 1024 * 1024;

    private final String socketName;
    private final Listener listener;
    private final AtomicLong nextConnectionId = new AtomicLong(1);
    private volatile LocalServerSocket serverSocket;
    private volatile boolean stopped;

    private final Object connectionLock = new Object();
    private LocalSocket currentSocket;
    private OutputStream currentOutput;
    private long currentConnectionId;

    WebSocketServer(String socketName, Listener listener) {
        this.socketName = socketName;
        this.listener = listener;
    }

    void start() throws IOException {
        serverSocket = new LocalServerSocket(socketName);
        Thread thread = new Thread(this::acceptLoop, "VolyAgent-accept");
        thread.setDaemon(true);
        thread.start();
    }

    void stop() {
        stopped = true;
        try {
            LocalServerSocket socket = serverSocket;
            if (socket != null) socket.close();
        } catch (IOException ignored) {
        }
        synchronized (connectionLock) {
            closeQuietly(currentSocket);
            currentSocket = null;
            currentOutput = null;
        }
    }

    private void acceptLoop() {
        while (!stopped) {
            LocalSocket socket;
            try {
                socket = serverSocket.accept();
            } catch (IOException e) {
                if (!stopped) Log.w("accept failed: " + e);
                return;
            }
            long id = nextConnectionId.getAndIncrement();
            Thread thread = new Thread(() -> serve(socket, id), "VolyAgent-connection-" + id);
            thread.setDaemon(true);
            thread.start();
        }
    }

    private void serve(LocalSocket socket, long id) {
        try {
            InputStream in = socket.getInputStream();
            OutputStream out = socket.getOutputStream();
            if (!handshake(in, out)) {
                closeQuietly(socket);
                return;
            }
            synchronized (connectionLock) {
                closeQuietly(currentSocket);
                currentSocket = socket;
                currentOutput = out;
                currentConnectionId = id;
            }
            readLoop(in, id);
        } catch (IOException e) {
            // The peer went away; nothing to report.
        } catch (RuntimeException e) {
            Log.e("connection " + id + " failed", e);
        } finally {
            synchronized (connectionLock) {
                if (currentConnectionId == id) {
                    currentSocket = null;
                    currentOutput = null;
                }
            }
            closeQuietly(socket);
            listener.onClosed(id);
        }
    }

    // MARK: Opening handshake

    private boolean handshake(InputStream in, OutputStream out) throws IOException {
        String request = readHeaders(in);
        if (request == null) return false;
        String key = null;
        for (String line : request.split("\r\n")) {
            int colon = line.indexOf(':');
            if (colon <= 0) continue;
            if (line.substring(0, colon).trim().equalsIgnoreCase("Sec-WebSocket-Key")) {
                key = line.substring(colon + 1).trim();
            }
        }
        if (key == null) {
            out.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();
            return false;
        }
        String accept;
        try {
            MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
            byte[] digest = sha1.digest((key + ACCEPT_GUID).getBytes(StandardCharsets.US_ASCII));
            accept = Base64.encodeToString(digest, Base64.NO_WRAP);
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
        String response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";
        out.write(response.getBytes(StandardCharsets.US_ASCII));
        out.flush();
        return true;
    }

    private static String readHeaders(InputStream in) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int matched = 0;
        while (buffer.size() < 16 * 1024) {
            int b = in.read();
            if (b < 0) return null;
            buffer.write(b);
            // "\r\n\r\n"
            if ((matched % 2 == 0 && b == '\r') || (matched % 2 == 1 && b == '\n')) {
                matched++;
                if (matched == 4) return new String(buffer.toByteArray(), StandardCharsets.ISO_8859_1);
            } else {
                matched = b == '\r' ? 1 : 0;
            }
        }
        return null;
    }

    // MARK: Frames

    private void readLoop(InputStream in, long id) throws IOException {
        ByteArrayOutputStream message = new ByteArrayOutputStream();
        boolean messageIsText = false;
        while (true) {
            int first = readByte(in);
            int second = readByte(in);
            boolean fin = (first & 0x80) != 0;
            int opcode = first & 0x0F;
            boolean masked = (second & 0x80) != 0;
            long length = second & 0x7F;
            if (length == 126) {
                length = ((long) readByte(in) << 8) | readByte(in);
            } else if (length == 127) {
                length = 0;
                for (int i = 0; i < 8; i++) length = (length << 8) | readByte(in);
            }
            if (length < 0 || length > MAX_MESSAGE_BYTES || message.size() + length > MAX_MESSAGE_BYTES) {
                throw new IOException("frame too large");
            }
            byte[] mask = new byte[4];
            if (masked) readFully(in, mask);
            byte[] payload = new byte[(int) length];
            readFully(in, payload);
            if (masked) {
                for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
            }

            switch (opcode) {
                case 0x0: // continuation
                    message.write(payload);
                    break;
                case 0x1: // text
                case 0x2: // binary
                    message.reset();
                    messageIsText = true;
                    message.write(payload);
                    break;
                case 0x8: // close
                    writeFrame(0x8, payload.length >= 2 ? new byte[] {payload[0], payload[1]} : new byte[0], id);
                    return;
                case 0x9: // ping
                    writeFrame(0xA, payload, id);
                    continue;
                case 0xA: // pong
                    continue;
                default:
                    throw new IOException("unknown opcode " + opcode);
            }
            if (fin && messageIsText) {
                String text = new String(message.toByteArray(), StandardCharsets.UTF_8);
                message.reset();
                messageIsText = false;
                listener.onMessage(text, id);
            }
        }
    }

    /** Send one text message to the given connection, if it is still the current one. */
    boolean send(String text, long connectionId) {
        try {
            return writeFrame(0x1, text.getBytes(StandardCharsets.UTF_8), connectionId);
        } catch (IOException e) {
            return false;
        }
    }

    /** Close a connection, e.g. after a failed authentication. */
    void drop(long connectionId) {
        synchronized (connectionLock) {
            if (currentConnectionId != connectionId) return;
            closeQuietly(currentSocket);
            currentSocket = null;
            currentOutput = null;
        }
    }

    private boolean writeFrame(int opcode, byte[] payload, long connectionId) throws IOException {
        synchronized (connectionLock) {
            if (currentOutput == null || currentConnectionId != connectionId) return false;
            ByteArrayOutputStream header = new ByteArrayOutputStream(10);
            header.write(0x80 | opcode);
            if (payload.length < 126) {
                header.write(payload.length);
            } else if (payload.length <= 0xFFFF) {
                header.write(126);
                header.write(payload.length >>> 8);
                header.write(payload.length);
            } else {
                header.write(127);
                long length = payload.length;
                for (int shift = 56; shift >= 0; shift -= 8) header.write((int) (length >>> shift));
            }
            currentOutput.write(header.toByteArray());
            currentOutput.write(payload);
            currentOutput.flush();
            return true;
        }
    }

    private static int readByte(InputStream in) throws IOException {
        int b = in.read();
        if (b < 0) throw new EOFException();
        return b;
    }

    private static void readFully(InputStream in, byte[] buffer) throws IOException {
        int offset = 0;
        while (offset < buffer.length) {
            int read = in.read(buffer, offset, buffer.length - offset);
            if (read < 0) throw new EOFException();
            offset += read;
        }
    }

    private static void closeQuietly(LocalSocket socket) {
        if (socket == null) return;
        try {
            socket.shutdownInput();
        } catch (IOException ignored) {
        }
        try {
            socket.shutdownOutput();
        } catch (IOException ignored) {
        }
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}
