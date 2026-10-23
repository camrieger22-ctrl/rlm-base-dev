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
        prefetchOpenBundles(quoteId, parents);
        if (open.isEmpty()) {
            return out;
        }
        out.needsAction = true;
        if (open.size() == 1) {
            QuoteLineItem parent = open[0];
            String name = parent.Product2 == null || String.isBlank(parent.Product2.Name)
                ? 'Bundle' : parent.Product2.Name;
            out.promptDisplay = String.join(
                new List<String>{
                    'AE note (chat only): ' + name
                        + ' is a parent only. Instant Pricing is not a finished configuration.',
                    'Call describeRevenueCloudBundleConfiguration now with quoteId and quoteLineItemId '
                        + String.valueOf(parent.Id) + '.',
                    'Stock defaults: recap current picks, then one configure that keeps the current mix.',
                    'If they named changes, wait for those picks. If a Rule card is set, paste it and wait for a number.',
                    'Never insert child QuoteLineItem rows. Never skip constraints.'
                },
                '\n'
            );
            return out;
        }
        List<String> lines = new List<String>{
            'AE note (chat only): A bundle was added as a parent only. Instant Pricing is not a finished configuration.',
            'Call describeRevenueCloudBundleConfiguration now. Stock defaults: keep the current mix and configure once. Named changes: wait. Never insert child QuoteLineItem rows.',
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
        lines.add('Which bundle? Reply with a number.');
        out.promptDisplay = String.join(lines, '\n');
        return out;
    }

    static void prefetchOpenBundles(Id quoteId, List<QuoteLineItem> open) {
        if (Test.isRunningTest() || quoteId == null || open == null) {
            return;
        }
        for (QuoteLineItem parent : open) {
            if (parent != null && parent.Id != null) {
                RLM_RampConfiguratorAction.prefetchConfigurationForMcp(
                    String.valueOf(quoteId),
                    String.valueOf(parent.Id)
                );
            }
        }
    }
}
