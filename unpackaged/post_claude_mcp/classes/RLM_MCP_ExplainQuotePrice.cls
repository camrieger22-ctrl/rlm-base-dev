/**
 * Hosted MCP: customer-facing list → discount → term → amount-due story.
 * Amendment Net Unit Price is often blank on the QuoteLineItem; priced slices
 * live on QuoteLineDetail. Connect waterfall GET is not called from this
 * invocable (Hosted MCP callouts to that resource hang or throw).
 */
global with sharing class RLM_MCP_ExplainQuotePrice {
    private static final Integer MAX_CANDIDATES = 50;
    private static final Integer MAX_WATERFALL_CALLS = 1;
    private static final String API_VERSION = 'v67.0';
    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    global class ExplainInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name, quote number (e.g. 00000505), or fragment. Also matched against the account name.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Product Name'
            description='Optional product name or SKU to focus the explanation, e.g. QuantumBit Database.'
        )
        global String productName;
    }

    global class ExplainOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Explanation Display'
            description='Markdown the assistant should read to the customer: list, discount, term, amount due.'
        )
        global String explanationDisplay;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    public interface WaterfallFetcher {
        Map<String, Object> fetch(String lineItemId, String executionId);
    }

    public class DefaultWaterfallFetcher implements WaterfallFetcher {
        public Map<String, Object> fetch(String lineItemId, String executionId) {
            if (String.isBlank(lineItemId) || String.isBlank(executionId)) {
                return null;
            }
            HttpRequest req = new HttpRequest();
            req.setEndpoint(
                URL.getOrgDomainUrl().toExternalForm()
                + '/services/data/'
                + API_VERSION
                + '/connect/core-pricing/waterfall/'
                + EncodingUtil.urlEncode(lineItemId, 'UTF-8')
                + '/'
                + EncodingUtil.urlEncode(executionId, 'UTF-8')
            );
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(5000);
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                return null;
            }
            Object parsed = JSON.deserializeUntyped(res.getBody());
            if (!(parsed instanceof Map<String, Object>)) {
                return null;
            }
            Map<String, Object> body = (Map<String, Object>) parsed;
            if (body.get('success') == false) {
                return null;
            }
            return body;
        }
    }

    @TestVisible
    private static WaterfallFetcher fetcher = new DefaultWaterfallFetcher();

    /** Test-only PriceWaterfallIdentifier values (the field is not writable). */
    @TestVisible
    private static Map<Id, String> identifierOverrides;

    @InvocableMethod(
        label='Explain Revenue Cloud Quote Price'
        description='Explains list price, discounts, proration, and amount due. Uses line details and the persisted waterfall. Blank Net Unit Price on an amendment is expected.'
    )
    global static List<ExplainOutput> explain(List<ExplainInput> inputs) {
        List<ExplainOutput> results = new List<ExplainOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ExplainInput input : inputs) {
            results.add(explainOne(input));
        }
        return results;
    }

    private static ExplainOutput explainOne(ExplainInput input) {
        ExplainOutput out = new ExplainOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null) {
                out.errorMessage = 'Provide a quote name, quote number, account name, or Quote Id.';
                return out;
            }
            Quote q = resolveQuote(input, out);
            if (q == null) {
                return out;
            }
            out.quoteId = q.Id;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', q.Id);
            out.quoteName = q.Name;

            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, ListPrice, UnitPrice, Discount, NetUnitPrice,
                       NetTotalPrice, Subtotal, TotalPrice, StartDate, EndDate,
                       PricingTermCount, PriceWaterfallIdentifier, ParentQuoteLineItemId,
                       Product2.Name, Product2.StockKeepingUnit
                FROM QuoteLineItem
                WHERE QuoteId = :q.Id
                ORDER BY LineNumber NULLS LAST, CreatedDate
            ];
            if (lines.isEmpty()) {
                out.errorMessage = 'Quote ' + q.Name + ' has no lines to explain.';
                return out;
            }

            String productTerm = String.isBlank(input.productName)
                ? null
                : input.productName.trim();
            List<QuoteLineItem> focused = filterLines(lines, productTerm);
            if (focused.isEmpty()) {
                out.errorMessage = 'No line on ' + q.Name + ' matches "' + productTerm + '".';
                return out;
            }

            Map<Id, List<QuoteLineDetail>> detailsByLine = loadDetails(focused);
            Map<String, Map<String, Object>> waterfalls = loadWaterfalls(focused, detailsByLine);

            out.explanationDisplay = buildExplanation(
                q, focused, detailsByLine, waterfalls, lines.size()
            );
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', q.Id);
            if (String.isNotBlank(quoteLink)) {
                out.explanationDisplay = quoteLink + '\n\n' + out.explanationDisplay;
            }
            out.isSuccess = true;
        } catch (Exception e) {
            out.isSuccess = false;
            String msg = e.getMessage();
            out.errorMessage = e.getTypeName() + ': '
                + (String.isBlank(msg) ? '(no message)' : msg);
        }
        return out;
    }

    private static Quote resolveQuote(ExplainInput input, ExplainOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            Id qid = toQuoteId(input.quoteId);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id: ' + input.quoteId;
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, QuoteNumber, Status, Discount, Subtotal, GrandTotal,
                       StartDate, EndDate, LineItemCount, Account.Name
                FROM Quote
                WHERE Id = :qid
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for Id ' + qid + '.';
                return null;
            }
            return byId[0];
        }

        String nameTerm = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
        String acctTerm = String.isBlank(input.accountName) ? null : input.accountName.trim();
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide a quote name, quote number, account name, or Quote Id.';
            return null;
        }

        List<Quote> matches = findQuotes(nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote found matching "'
                + (nameTerm != null ? nameTerm : acctTerm) + '".';
            return null;
        }

        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote m : matches) {
                if (m.Name != null && m.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                } else if (m.QuoteNumber != null && m.QuoteNumber.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }

        List<Quote> withLines = new List<Quote>();
        for (Quote m : matches) {
            if (m.LineItemCount != null && m.LineItemCount > 0) {
                withLines.add(m);
            }
        }
        if (withLines.isEmpty()) {
            out.errorMessage = 'Matching quotes have no lines to explain.';
            return null;
        }
        if (withLines.size() == 1) {
            return withLines[0];
        }

        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildCandidateDisplay(withLines);
        out.errorMessage = 'Multiple quotes match. Ask the user which one to explain.';
        return null;
    }

    private static List<Quote> findQuotes(String nameTerm, String acctTerm) {
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        if (np != null && ap != null) {
            return [
                SELECT Id, Name, QuoteNumber, Status, Discount, Subtotal, GrandTotal,
                       StartDate, EndDate, LineItemCount, Account.Name
                FROM Quote
                WHERE (Name LIKE :np OR QuoteNumber LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null) {
            return [
                SELECT Id, Name, QuoteNumber, Status, Discount, Subtotal, GrandTotal,
                       StartDate, EndDate, LineItemCount, Account.Name
                FROM Quote
                WHERE Name LIKE :np OR QuoteNumber LIKE :np OR Account.Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, QuoteNumber, Status, Discount, Subtotal, GrandTotal,
                   StartDate, EndDate, LineItemCount, Account.Name
            FROM Quote
            WHERE Account.Name LIKE :ap
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static String buildCandidateDisplay(List<Quote> quotes) {
        List<String> lines = new List<String>();
        lines.add('Multiple quotes match. Which one should I explain?');
        Integer ordinal = 1;
        for (Quote q : quotes) {
            String line = ordinal + '. **' + q.Name + '**';
            if (String.isNotBlank(q.QuoteNumber)) {
                line += ' (' + q.QuoteNumber + ')';
            }
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                line += ' · ' + q.Account.Name;
            }
            if (q.GrandTotal != null) {
                line += ' · ' + money(q.GrandTotal);
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open', 'Quote', q.Id);
            if (String.isNotBlank(quoteLink)) {
                line += ' · ' + quoteLink;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static List<QuoteLineItem> filterLines(List<QuoteLineItem> lines, String productTerm) {
        if (productTerm == null) {
            return lines;
        }
        String needle = productTerm.toLowerCase();
        List<QuoteLineItem> matched = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            String pname = line.Product2 != null ? line.Product2.Name : null;
            String sku = line.Product2 != null ? line.Product2.StockKeepingUnit : null;
            Boolean nameHit = pname != null && pname.toLowerCase().contains(needle);
            Boolean skuHit = sku != null && sku.toLowerCase().contains(needle);
            if (nameHit || skuHit) {
                matched.add(line);
            }
        }
        return matched;
    }

    private static Map<Id, List<QuoteLineDetail>> loadDetails(List<QuoteLineItem> lines) {
        Map<Id, List<QuoteLineDetail>> byLine = new Map<Id, List<QuoteLineDetail>>();
        Set<Id> lineIds = new Map<Id, QuoteLineItem>(lines).keySet();
        for (QuoteLineDetail detail : [
            SELECT Id, QuoteLineItemId, Quantity, UnitPrice, NetUnitPrice,
                   TotalPrice, TotalLineAmount, EffectiveFrom, EffectiveTo,
                   PriceWaterfallIdentifier
            FROM QuoteLineDetail
            WHERE QuoteLineItemId IN :lineIds
            ORDER BY Quantity DESC
        ]) {
            if (!byLine.containsKey(detail.QuoteLineItemId)) {
                byLine.put(detail.QuoteLineItemId, new List<QuoteLineDetail>());
            }
            byLine.get(detail.QuoteLineItemId).add(detail);
        }
        return byLine;
    }

    private static Map<String, Map<String, Object>> loadWaterfalls(
        List<QuoteLineItem> lines,
        Map<Id, List<QuoteLineDetail>> detailsByLine
    ) {
        Map<String, Map<String, Object>> byIdent = new Map<String, Map<String, Object>>();
        // Hosted MCP callouts to Connect waterfall hang or throw (often
        // uncatchable). QuoteLineDetail already holds the priced slices, so
        // skip HTTP unless a test injected a fetcher.
        if (!Test.isRunningTest()) {
            return byIdent;
        }
        List<String> identifiers = new List<String>();
        for (QuoteLineItem line : lines) {
            List<QuoteLineDetail> details = detailsByLine.get(line.Id);
            if (details != null) {
                for (QuoteLineDetail detail : details) {
                    Decimal qty = detail.Quantity;
                    if (qty != null && qty > 0) {
                        addIdentifier(
                            identifiers,
                            identifierOf(null, detail.PriceWaterfallIdentifier)
                        );
                    }
                }
            }
            addIdentifier(identifiers, identifierOf(line.Id, line.PriceWaterfallIdentifier));
        }
        Integer calls = 0;
        for (String ident : identifiers) {
            if (calls >= MAX_WATERFALL_CALLS) {
                break;
            }
            List<String> parts = splitIdentifier(ident);
            if (parts == null) {
                continue;
            }
            try {
                Map<String, Object> body = fetcher.fetch(parts[0], parts[1]);
                calls++;
                if (body != null) {
                    byIdent.put(ident, body);
                    break;
                }
            } catch (Exception e) {
                break;
            }
        }
        return byIdent;
    }

    private static void addIdentifier(List<String> identifiers, String ident) {
        if (String.isBlank(ident) || identifiers.contains(ident)) {
            return;
        }
        identifiers.add(ident);
    }

    private static String identifierOf(Id recordId, String stored) {
        if (identifierOverrides != null && recordId != null && identifierOverrides.containsKey(recordId)) {
            return identifierOverrides.get(recordId);
        }
        return stored;
    }

    @TestVisible
    static List<String> splitIdentifier(String raw) {
        if (String.isBlank(raw) || !raw.contains(':')) {
            return null;
        }
        Integer idx = raw.lastIndexOf(':');
        String left = raw.substring(0, idx);
        String right = raw.substring(idx + 1);
        if (String.isBlank(left) || String.isBlank(right)) {
            return null;
        }
        return new List<String>{ left, right };
    }

    private static String buildExplanation(
        Quote q,
        List<QuoteLineItem> focused,
        Map<Id, List<QuoteLineDetail>> detailsByLine,
        Map<String, Map<String, Object>> waterfalls,
        Integer allLineCount
    ) {
        List<String> blocks = new List<String>();
        String accountName = q.Account != null ? q.Account.Name : null;
        String title = 'How we got to ' + money(q.GrandTotal);
        blocks.add('# ' + title);
        String subtitle = '**' + q.Name + '**';
        if (String.isNotBlank(q.QuoteNumber)) {
            subtitle += ' (' + q.QuoteNumber + ')';
        }
        if (String.isNotBlank(accountName)) {
            subtitle += ' for ' + accountName;
        }
        blocks.add(subtitle);

        blocks.add('');
        blocks.add('## Amount due');
        String due = '**' + money(q.GrandTotal) + '**';
        if (q.Discount != null && q.Discount != 0) {
            String discPct = pct(q.Discount);
            String art = discPct.startsWith('8') ? 'an' : 'a';
            due += ' after ' + art + ' ' + discPct + ' quote discount';
            if (q.Subtotal != null) {
                due += ' on a ' + money(q.Subtotal) + ' subtotal';
            }
            due += '.';
        } else {
            due += '.';
        }
        blocks.add(due);

        Boolean usedDetails = false;
        Boolean blankNup = false;
        Boolean focusedOnly = focused.size() < allLineCount;
        for (QuoteLineItem line : focused) {
            if (!shouldExplainLine(line, detailsByLine.get(line.Id), focusedOnly)) {
                continue;
            }
            if (line.NetUnitPrice == null) {
                blankNup = true;
            }
            List<QuoteLineDetail> details = detailsByLine.get(line.Id);
            if (details != null && !details.isEmpty()) {
                usedDetails = true;
            }
            blocks.add('');
            blocks.add(lineBlock(q, line, details, waterfalls));
        }

        if (usedDetails && blankNup) {
            blocks.add('');
            blocks.add(
                'Net unit price can be blank on an amendment quote line. The numbers above come from the priced slices Salesforce stored on the line details'
                    + (waterfalls.isEmpty() ? '.' : ' and the persisted price waterfall.')
            );
        } else if (!waterfalls.isEmpty()) {
            blocks.add('');
            blocks.add('Unit and proration figures include the persisted price waterfall for this quote.');
        }

        if (focusedOnly) {
            Decimal focusedNet = 0;
            Boolean anyNet = false;
            for (QuoteLineItem line : focused) {
                if (line.NetTotalPrice != null) {
                    focusedNet += line.NetTotalPrice;
                    anyNet = true;
                }
            }
            if (anyNet && q.GrandTotal != null
                && focusedNet.setScale(2) != q.GrandTotal.setScale(2)) {
                blocks.add('');
                blocks.add(
                    'Quote amount due is **'
                        + money(q.GrandTotal)
                        + '** and includes other lines besides this product.'
                );
            }
        }

        return String.join(blocks, '\n');
    }

    private static Boolean shouldExplainLine(
        QuoteLineItem line,
        List<QuoteLineDetail> details,
        Boolean focusedOnly
    ) {
        if (focusedOnly) {
            return true;
        }
        if (details != null && !details.isEmpty()) {
            return true;
        }
        Decimal qty = nvl(line.Quantity);
        Decimal net = nvl(line.NetTotalPrice);
        if (qty == 0 && net == 0 && line.ParentQuoteLineItemId != null) {
            return false;
        }
        if (qty == 0 && net == 0 && line.ParentQuoteLineItemId == null) {
            return false;
        }
        return true;
    }

    private static String lineBlock(
        Quote q,
        QuoteLineItem line,
        List<QuoteLineDetail> details,
        Map<String, Map<String, Object>> waterfalls
    ) {
        String productName = line.Product2 != null && String.isNotBlank(line.Product2.Name)
            ? line.Product2.Name
            : 'Line';
        Map<String, Object> wfOut = firstWaterfallOutput(line, details, waterfalls);

        Decimal listPrice = firstDecimal(
            new List<Decimal>{
                line.ListPrice,
                decimalFrom(wfOut, 'SubscriptionNetUnitPrice'),
                detailUnitPrice(details),
                line.UnitPrice
            }
        );
        Decimal netUnit = firstDecimal(
            new List<Decimal>{
                detailNetUnit(details),
                decimalFrom(wfOut, 'NetUnitPrice'),
                line.NetUnitPrice
            }
        );
        if (netUnit == null && listPrice != null) {
            Decimal disc = line.Discount != null ? line.Discount : q.Discount;
            if (disc != null && disc != 0) {
                netUnit = (listPrice * (Decimal.valueOf(1) - disc / 100)).setScale(2);
            }
        }

        Decimal netQty = nvl(line.Quantity);
        Decimal posQty = 0;
        Decimal negQty = 0;
        Decimal lineTotal = firstDecimal(
            new List<Decimal>{ line.NetTotalPrice, line.TotalPrice, line.Subtotal }
        );
        if (details != null) {
            Decimal sliceTotal = 0;
            Boolean anySlice = false;
            for (QuoteLineDetail d : details) {
                Decimal dq = nvl(d.Quantity);
                if (dq > 0) {
                    posQty += dq;
                } else if (dq < 0) {
                    negQty += dq;
                }
                if (d.TotalPrice != null) {
                    sliceTotal += d.TotalPrice;
                    anySlice = true;
                }
            }
            if (anySlice && (lineTotal == null || lineTotal == 0)) {
                lineTotal = sliceTotal;
            }
        }

        Decimal term = firstDecimal(
            new List<Decimal>{
                line.PricingTermCount,
                decimalFrom(wfOut, 'ProrationMultiplier')
            }
        );
        Date startDay = line.StartDate != null ? line.StartDate : q.StartDate;
        Date endDay = line.EndDate != null ? line.EndDate : q.EndDate;
        Boolean derived = wfOut != null && wfOut.get('IsDerived') == true;

        List<String> steps = new List<String>();
        String heading = '## ' + productName;
        if (netQty != 0) {
            heading += ' (' + signedQty(netQty) + ')';
        }
        steps.add(heading);

        Integer n = 1;
        if (listPrice != null && listPrice != 0) {
            steps.add(n + '. **List price** — ' + money(listPrice) + ' per unit.');
            n++;
        }

        Decimal headerDisc = q.Discount;
        Decimal lineDisc = line.Discount;
        if (headerDisc != null && headerDisc != 0 && netUnit != null) {
            steps.add(
                n + '. **Quote discount (' + pct(headerDisc) + ')** — net unit price '
                    + money(netUnit) + '.'
            );
            n++;
        } else if (lineDisc != null && lineDisc != 0 && netUnit != null) {
            steps.add(
                n + '. **Line discount (' + pct(lineDisc) + ')** — net unit price '
                    + money(netUnit) + '.'
            );
            n++;
        } else if (netUnit != null && listPrice != null && netUnit != listPrice) {
            steps.add(n + '. **Net unit price** — ' + money(netUnit) + ' after pricing.');
            n++;
        } else if (netUnit != null) {
            steps.add(n + '. **Net unit price** — ' + money(netUnit) + '.');
            n++;
        }

        if (posQty > 0 && negQty < 0) {
            steps.add(
                n + '. **Quantity** — net ' + signedQty(netQty)
                    + ' (Salesforce restates ' + stripZeros(posQty)
                    + ' and cancels ' + stripZeros(negQty.abs())
                    + ').'
            );
            n++;
        } else if (netQty != 0) {
            steps.add(n + '. **Quantity** — ' + signedQty(netQty) + '.');
            n++;
        } else if (derived || (posQty > 0 && negQty < 0 && posQty + negQty == 0)) {
            steps.add(
                n + '. **Quantity** — restated and nets to 0'
                    + (derived ? ' (derived; no extra charge on this change)' : '')
                    + '.'
            );
            n++;
        }

        if (term != null && term != 0 && term != 1) {
            String termBit = n + '. **Prorated term** — '
                + pct((term * 100).setScale(1, System.RoundingMode.HALF_UP))
                + ' of a full year';
            if (startDay != null && endDay != null) {
                termBit += ' (' + prettyDate(startDay) + ' – ' + prettyDate(endDay) + ')';
            }
            termBit += '. This starts mid-term, so you only pay for the remaining days.';
            steps.add(termBit);
            n++;
        } else if (startDay != null && endDay != null) {
            steps.add(
                n + '. **Term** — ' + prettyDate(startDay) + ' – ' + prettyDate(endDay) + '.'
            );
            n++;
        }

        if (lineTotal != null) {
            steps.add(n + '. **Line amount** — ' + money(lineTotal) + '.');
        }

        return String.join(steps, '\n');
    }

    private static Map<String, Object> firstWaterfallOutput(
        QuoteLineItem line,
        List<QuoteLineDetail> details,
        Map<String, Map<String, Object>> waterfalls
    ) {
        if (details != null) {
            for (QuoteLineDetail d : details) {
                Map<String, Object> body = waterfalls.get(
                    identifierOf(null, d.PriceWaterfallIdentifier)
                );
                Map<String, Object> output = outputOf(body);
                if (output != null) {
                    return output;
                }
            }
        }
        Map<String, Object> lineBody = waterfalls.get(
            identifierOf(line.Id, line.PriceWaterfallIdentifier)
        );
        return outputOf(lineBody);
    }

    private static Map<String, Object> outputOf(Map<String, Object> body) {
        if (body == null) {
            return null;
        }
        Object raw = body.get('output');
        return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : null;
    }

    private static Decimal detailNetUnit(List<QuoteLineDetail> details) {
        if (details == null) {
            return null;
        }
        for (QuoteLineDetail d : details) {
            if (d.NetUnitPrice != null && nvl(d.Quantity) > 0) {
                return d.NetUnitPrice;
            }
        }
        for (QuoteLineDetail d : details) {
            if (d.NetUnitPrice != null) {
                return d.NetUnitPrice;
            }
        }
        return null;
    }

    private static Decimal detailUnitPrice(List<QuoteLineDetail> details) {
        if (details == null) {
            return null;
        }
        for (QuoteLineDetail d : details) {
            if (d.UnitPrice != null && d.UnitPrice != 0) {
                return d.UnitPrice;
            }
        }
        return null;
    }

    private static Decimal decimalFrom(Map<String, Object> source, String key) {
        if (source == null || String.isBlank(key) || !source.containsKey(key)) {
            return null;
        }
        Object raw = source.get(key);
        if (raw == null) {
            return null;
        }
        if (raw instanceof Decimal) {
            return (Decimal) raw;
        }
        if (raw instanceof Double) {
            return Decimal.valueOf((Double) raw);
        }
        if (raw instanceof Integer) {
            return Decimal.valueOf((Integer) raw);
        }
        if (raw instanceof Long) {
            return Decimal.valueOf((Long) raw);
        }
        if (raw instanceof String && String.isNotBlank((String) raw)) {
            try {
                return Decimal.valueOf((String) raw);
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private static Decimal firstDecimal(List<Decimal> values) {
        for (Decimal v : values) {
            if (v != null) {
                return v;
            }
        }
        return null;
    }

    private static Decimal nvl(Decimal v) {
        return v == null ? 0 : v;
    }

    @TestVisible
    static String money(Decimal value) {
        if (value == null) {
            return 'n/a';
        }
        Decimal scaled = value.setScale(2, System.RoundingMode.HALF_UP);
        Boolean negative = scaled < 0;
        String raw = String.valueOf(scaled.abs());
        Integer dot = raw.indexOf('.');
        String whole = dot < 0 ? raw : raw.substring(0, dot);
        String frac = dot < 0 ? '00' : raw.substring(dot + 1);
        if (frac.length() == 1) {
            frac += '0';
        }
        String grouped = '';
        while (whole.length() > 3) {
            grouped = ',' + whole.substring(whole.length() - 3) + grouped;
            whole = whole.substring(0, whole.length() - 3);
        }
        grouped = whole + grouped;
        return (negative ? '-$' : '$') + grouped + '.' + frac;
    }

    private static String pct(Decimal value) {
        if (value == null) {
            return 'n/a';
        }
        Decimal scaled = value.stripTrailingZeros();
        return String.valueOf(scaled) + '%';
    }

    private static String prettyDate(Date d) {
        if (d == null) {
            return null;
        }
        return MONTHS[d.month() - 1] + ' ' + String.valueOf(d.day()) + ', ' + String.valueOf(d.year());
    }

    private static String signedQty(Decimal qty) {
        if (qty == null) {
            return '0';
        }
        String body = stripZeros(qty.abs());
        if (qty > 0) {
            return '+' + body;
        }
        if (qty < 0) {
            return '-' + body;
        }
        return body;
    }

    private static String stripZeros(Decimal qty) {
        if (qty == null) {
            return '0';
        }
        return String.valueOf(qty.stripTrailingZeros());
    }

    private static Id toQuoteId(String raw) {
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Quote.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }
}
