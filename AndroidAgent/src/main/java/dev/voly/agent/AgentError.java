package dev.voly.agent;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * A failure the host understands: one case of `InspectorError` on the Swift
 * side, in the JSON shape Swift's synthesized `Codable` gives an enum.
 */
final class AgentError extends Exception {
    private final String kind;
    private final Object value;

    private AgentError(String kind, Object value, String message) {
        super(message);
        this.kind = kind;
        this.value = value;
    }

    static AgentError objectGone(long id) {
        return new AgentError("objectGone", id, "Object " + id + " is gone");
    }

    static AgentError unsupportedProperty(String name) {
        return new AgentError("unsupportedProperty", name, "Unsupported property " + name);
    }

    static AgentError unsupportedValue() {
        return new AgentError("unsupportedValue", null, "Unsupported value");
    }

    static AgentError invalidCommand(String detail) {
        return new AgentError("invalidCommand", detail, detail);
    }

    static AgentError internal(String detail) {
        return new AgentError("internal", detail, detail);
    }

    static AgentError unauthorized() {
        return new AgentError("unauthorized", null, "Unauthorized");
    }

    static AgentError unavailable(String detail) {
        return new AgentError("unavailable", detail, detail);
    }

    boolean isUnauthorized() {
        return "unauthorized".equals(kind);
    }

    /** `{"objectGone":{"_0":12}}`, `{"unsupportedValue":{}}`, … */
    JSONObject toJson() throws JSONException {
        JSONObject payload = new JSONObject();
        if (value != null) payload.put("_0", value);
        return new JSONObject().put(kind, payload);
    }
}
