/**
 * Chat-only gate after a bundle parent is added with no children.
 * Claude must describe, wait, then configure. Never Gmail this note.
 */
public inherited sharing class RLM_MCP_BundleCoach {
    @TestVisible
    static Set<Id> configuredParentIdsOverride;

    public class Result {
        public Boolean needsAction;
        public String promptDisplay;
        public Result() {
            this.needsAction = false;
        }
    }

    public static String append(String existing, Id quoteId) {
        Result gate = forQuote(quoteId);
        return append(existing, gate);
    }

    public static String append(String existing, Result gate) {
        if (gate == null || String.isBlank(gate.promptDisplay)) {
            return existing;
        }
        if (String.isBlank(existing)) {
            return gate.promptDisplay;
        }
        return existing + '\n\n' + gate.promptDisplay;
    }

    public static Result forQuote(Id quoteId) {
        Result out = new Result();
        if (quoteId == null) {
            return out;
        }
        List<QuoteLineItem> parents = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit, QuoteLineGroup.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND ParentQuoteLineItemId = null
            AND Product2.Type = 'Bundle'
            WITH USER_MODE
            LIMIT 50
        ];
        if (parents.isEmpty()) {
            return out;
        }
        Set<Id> parentIds = new Set<Id>();
        for (QuoteLineItem parent : parents) {
            parentIds.add(parent.Id);
        }
        Set<Id> configured = new Set<Id>();
        if (configuredParentIdsOverride != null) {
            configured.addAll(configuredParentIdsOverride);
        } else {
            for (QuoteLineItem child : [
                SELECT ParentQuoteLineItemId
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                AND ParentQuoteLineItemId IN :parentIds
                WITH USER_MODE
                LIMIT 200
            ]) {
                configured.add(child.ParentQuoteLineItemId);
            }
        }
        List<QuoteLineItem> open = new List<QuoteLineItem>();
        for (QuoteLineItem parent : parents) {
            if (!configured.contains(parent.Id)) {
                open.add(parent);
            }
        }
        if (open.isEmpty()) {
            return out;
        }
        out.needsAction = true;
        List<String> lines = new List<String>{
            'AE note (chat only, never the customer email): A bundle was added as a parent only. Instant Pricing on the parent is not a finished configuration.',
            'Call describeRevenueCloudBundleConfiguration now (pass quoteId and quoteLineItemId). Render the numbered picker from configurationDisplay. Wait. Then configureRevenueCloudBundle with those picks.',
            'Never insert child QuoteLineItem rows. Never skip constraints. Required options stay selected. If several ramp years have this SKU, configure one line — the same mix is copied to the other years unless they ask for a different mix.',
            'Unconfigured bundles:'
        };
        Integer n = 1;
        for (QuoteLineItem parent : open) {
            String name = parent.Product2 == null || String.isBlank(parent.Product2.Name)
                ? 'Bundle' : parent.Product2.Name;
            String sku = parent.Product2 == null ? null : parent.Product2.StockKeepingUnit;
            String seg = parent.QuoteLineGroup == null || String.isBlank(parent.QuoteLineGroup.Name)
                ? '' : ' on ' + parent.QuoteLineGroup.Name;
            String row = String.valueOf(n) + '. Describe ' + name;
            if (String.isNotBlank(sku)) {
                row += ' (' + sku + ')';
            }
            row += seg + ' — quoteLineItemId ' + String.valueOf(parent.Id);
            lines.add(row);
            n++;
        }
        lines.add('Which bundle? Click a suggestion or reply with a number. Then wait for their component picks.');
        out.promptDisplay = String.join(lines, '\n');
        return out;
    }
}
