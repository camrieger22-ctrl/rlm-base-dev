/**
 * Lightning record URLs for Hosted MCP replies. Claude Desktop has no native
 * Salesforce record card, so invocables return markdown-ready links instead.
 */
public inherited sharing class RLM_MCP_RecordLinks {
    public static String lightningUrl(String objectApiName, Id recordId) {
        if (recordId == null || String.isBlank(objectApiName)) {
            return null;
        }
        return URL.getOrgDomainUrl().toExternalForm()
            + '/lightning/r/'
            + objectApiName
            + '/'
            + String.valueOf(recordId)
            + '/view';
    }

    public static String markdown(String label, String objectApiName, Id recordId) {
        String url = lightningUrl(objectApiName, recordId);
        if (String.isBlank(url) || String.isBlank(label)) {
            return null;
        }
        return '[' + label + '](' + url + ')';
    }

    public static Id toId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Id.valueOf(raw.trim());
        } catch (Exception e) {
            return null;
        }
    }
}
