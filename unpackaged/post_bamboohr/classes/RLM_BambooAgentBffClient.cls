/**
 * HTTP client for BambooHR Agentforce actions → Get Pricing BFF.
 * Base URL: Custom Label RLM_Bamboo_Get_Pricing_Bff_Url (must be public HTTPS
 * reachable from Salesforce — not 127.0.0.1). Pair with Remote Site Setting
 * BambooHR_Get_Pricing_BFF (updated by scripts/bamboohr/set_get_pricing_bff_url.py).
 */
public inherited sharing class RLM_BambooAgentBffClient {
    public class CalloutException extends Exception {
    }

    public class Response {
        public Integer statusCode;
        public String body;
        public Map<String, Object> jsonMap;
        public Boolean transportOk;
        public String error;
    }

    @TestVisible
    static String baseUrlOverride;

    public static String baseUrl() {
        String raw = String.isNotBlank(baseUrlOverride)
            ? baseUrlOverride
            : Label.RLM_Bamboo_Get_Pricing_Bff_Url;
        if (String.isBlank(raw)) {
            throw new CalloutException(
                'Custom Label RLM_Bamboo_Get_Pricing_Bff_Url is empty. ' +
                'Set a public HTTPS BFF URL (Cloudflare tunnel or hosted).'
            );
        }
        return raw.trim().removeEnd('/');
    }

    public static Response get(String pathAndQuery) {
        return send('GET', pathAndQuery, null);
    }

    public static Response post(String path, Map<String, Object> body) {
        return send('POST', path, body == null ? '{}' : JSON.serialize(body));
    }

    public static Response postRaw(String path, String bodyJson) {
        return send('POST', path, String.isBlank(bodyJson) ? '{}' : bodyJson);
    }

    private static Response send(String method, String path, String bodyJson) {
        Response out = new Response();
        out.transportOk = false;
        if (String.isBlank(path) || !path.startsWith('/')) {
            out.error = 'BFF path must start with /';
            return out;
        }
        HttpRequest req = new HttpRequest();
        req.setMethod(method);
        req.setEndpoint(baseUrl() + path);
        req.setTimeout(120000);
        req.setHeader('Accept', 'application/json');
        if (method == 'POST') {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(bodyJson);
        }
        try {
            HttpResponse res = new Http().send(req);
            out.statusCode = res.getStatusCode();
            out.body = res.getBody();
            out.transportOk = true;
            if (String.isNotBlank(out.body)) {
                Object parsed = JSON.deserializeUntyped(out.body);
                if (parsed instanceof Map<String, Object>) {
                    out.jsonMap = (Map<String, Object>) parsed;
                }
            }
            if (out.statusCode < 200 || out.statusCode >= 300) {
                out.error = extractError(out.jsonMap, out.body, out.statusCode);
            }
        } catch (Exception e) {
            out.error = e.getMessage();
        }
        return out;
    }

    public static String extractError(
        Map<String, Object> jsonMap,
        String body,
        Integer statusCode
    ) {
        if (jsonMap != null) {
            Object err = jsonMap.get('error');
            if (err != null && String.isNotBlank(String.valueOf(err))) {
                return String.valueOf(err);
            }
        }
        if (String.isNotBlank(body) && body.length() < 400) {
            return 'HTTP ' + statusCode + ': ' + body;
        }
        return 'HTTP ' + statusCode + ' from Get Pricing BFF';
    }

    public static Boolean isOk(Map<String, Object> jsonMap) {
        if (jsonMap == null) {
            return false;
        }
        Object ok = jsonMap.get('ok');
        return ok == true || ok == 'true';
    }

    public static Boolean http2xx(Response http) {
        return http != null &&
            http.transportOk == true &&
            http.statusCode != null &&
            http.statusCode >= 200 &&
            http.statusCode < 300;
    }

    public static Boolean isConflict(Response http) {
        return http != null && http.statusCode == 409;
    }

    public static Map<String, Object> asMap(Object value) {
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        return null;
    }

    public static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    public static String firstNonBlank(String a, String b) {
        if (String.isNotBlank(a)) {
            return a.trim();
        }
        if (String.isNotBlank(b)) {
            return b.trim();
        }
        return null;
    }

    public static Decimal asDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        }
        if (value instanceof Double) {
            return Decimal.valueOf((Double) value);
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    public static Integer asInteger(Object value) {
        Decimal d = asDecimal(value);
        return d == null ? null : d.intValue();
    }

    public static List<String> splitCsv(String csv) {
        List<String> out = new List<String>();
        if (String.isBlank(csv)) {
            return out;
        }
        for (String part : csv.split(',')) {
            String s = part == null ? '' : part.trim();
            if (String.isNotBlank(s)) {
                out.add(s);
            }
        }
        return out;
    }

    public static String joinWarnings(Object warningsObj) {
        if (!(warningsObj instanceof List<Object>)) {
            return null;
        }
        List<String> bits = new List<String>();
        for (Object w : (List<Object>) warningsObj) {
            if (w != null && String.isNotBlank(String.valueOf(w))) {
                bits.add(String.valueOf(w));
            }
        }
        return bits.isEmpty() ? null : String.join(bits, ' ');
    }

    public static Boolean isAcquisitionDraftName(String name) {
        if (String.isBlank(name)) {
            return false;
        }
        String low = name.trim().toLowerCase();
        String compact = low.replace(' ', '').replace('_', '').replace('-', '');
        if (compact.contains('selfserve')) {
            return true;
        }
        if (low.startsWith('get pricing')) {
            return true;
        }
        return Pattern.compile('(?i)\\d+-day trial').matcher(name).find();
    }

    public static String money(String currencyCode, Decimal amount) {
        if (amount == null) {
            return 'n/a';
        }
        String cur = String.isBlank(currencyCode) ? '' : currencyCode + ' ';
        return cur + String.valueOf(amount.setScale(2));
    }
}
