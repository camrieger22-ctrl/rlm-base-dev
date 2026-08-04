/**
 * Invocable: asset commercial price history for an amendment quote (optional product filter).
 * Backs Quinn AmendmentStudio → Get_Asset_Price_History. Read-only.
 *
 * Display is plain-text and sales-oriented: short answer first (latest price),
 * then a simple story, then today's footprint. No markdown/HTML — Agentforce
 * often shows those markers literally when the output is echoed as chat text.
 */
public with sharing class RLM_AI_AssetPriceHistoryService {

    private static final Integer MAX_ASSETS = 8;
    private static final Integer MAX_EVENTS_PER_ASSET = 10;

    public class HistoryInput {
        @InvocableVariable(required=true label='Quote Id'
            description='18-character Quote Id (0Q0...) whose Account footprint history should be loaded.')
        public String quoteId;

        @InvocableVariable(label='Product Name'
            description='Optional. When set, only assets whose name contains this product string are included.')
        public String productName;
    }

    public class HistoryOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='History Display'
            description='Plain-text, sales-friendly price story for the rep. Render with show_command as-is.')
        public String historyDisplay;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        public HistoryOutput() {
            this.isSuccess = false;
            this.historyDisplay = '';
        }
    }

    @InvocableMethod(
        label='Get Asset Price History'
        description='Returns names-only commercial price history for assets on the amendment quote Account. Optionally filter by product name. Read-only; for pricing context, not a price write. Display is a plain-text sales brief — render as-is via show_command.'
    )
    public static List<HistoryOutput> getHistory(List<HistoryInput> inputs) {
        List<HistoryOutput> results = new List<HistoryOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (HistoryInput input : inputs) {
            results.add(build(input));
        }
        return results;
    }

    private static HistoryOutput build(HistoryInput input) {
        HistoryOutput out = new HistoryOutput();
        if (input == null || String.isBlank(input.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        Id quoteId = RLM_AI_ConfigServiceUtils.toIdOrNull(input.quoteId);
        if (quoteId == null || !RLM_AI_ConfigServiceUtils.hasPrefix(input.quoteId, RLM_AI_ConfigServiceUtils.QUOTE_PREFIX)) {
            out.errorMessage = 'Invalid quote Id.';
            return out;
        }

        RLM_AmendDifferenceService.HistoryResponse history;
        try {
            history = RLM_AmendDifferenceService.getHistoryForQuote(quoteId);
        } catch (Exception e) {
            out.errorMessage = 'Could not load asset history for that quote.';
            return out;
        }
        if (history == null || history.assets == null || history.assets.isEmpty()) {
            out.isSuccess = true;
            out.historyDisplay =
                'No installed-asset price history was found for this quote\'s account.';
            return out;
        }

        String filter = String.isBlank(input.productName) ? null : input.productName.trim().toLowerCase();
        List<RLM_AmendDifferenceService.AssetHistoryCard> cards =
            new List<RLM_AmendDifferenceService.AssetHistoryCard>();
        for (RLM_AmendDifferenceService.AssetHistoryCard card : history.assets) {
            if (card == null || String.isBlank(card.assetName)) {
                continue;
            }
            if (filter != null && !card.assetName.toLowerCase().contains(filter)) {
                continue;
            }
            cards.add(card);
        }
        if (cards.isEmpty()) {
            out.isSuccess = true;
            out.historyDisplay =
                'No assets matched'
                + (filter != null ? ' "' + input.productName.trim() + '"' : '')
                + '.';
            return out;
        }

        out.isSuccess = true;
        out.historyDisplay = render(cards);
        return out;
    }

    private static String render(List<RLM_AmendDifferenceService.AssetHistoryCard> cards) {
        List<String> parts = new List<String>();
        Integer assetCount = 0;
        for (RLM_AmendDifferenceService.AssetHistoryCard card : cards) {
            assetCount++;
            if (assetCount > MAX_ASSETS) {
                parts.add('More assets in Amendment Studio.');
                break;
            }
            if (assetCount > 1) {
                parts.add('');
            }
            parts.addAll(renderAsset(card));
        }
        return String.join(parts, '\n').trim();
    }

    /**
     * Mirrors the sales "price card" mockup in plain text (Agentforce cannot
     * render colors/badges/HTML cards). Structure:
     *   Latest price accepted + discount
     *   Times purchased / Avg discount / Discount trend
     *   Purchase history (oldest first, bullet key-details)
     *   For your conversation tip
     */
    private static List<String> renderAsset(RLM_AmendDifferenceService.AssetHistoryCard card) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(card.assetName)) {
            parts.add(card.assetName);
            parts.add('');
        }

        List<RLM_AmendDifferenceService.HistoryRow> oldestFirst =
            (card.timeline == null)
                ? new List<RLM_AmendDifferenceService.HistoryRow>()
                : orderOldestFirst(card.timeline);

        if (oldestFirst.isEmpty()) {
            parts.add('Latest price accepted');
            parts.add('No buy history on file for this product.');
            return parts;
        }

        RLM_AmendDifferenceService.HistoryRow lastRow = lastPricedRow(oldestFirst);
        RLM_AmendDifferenceService.HistoryRow firstRow = firstPricedRow(oldestFirst);
        Decimal lastNet = lastNet(oldestFirst);
        Decimal avgDisc =
            card.summary != null ? card.summary.averageDiscountPercent : null;
        Integer purchaseCount = countPricedRows(oldestFirst);

        // --- Hero: latest price ---
        parts.add('Latest price accepted');
        if (lastNet != null) {
            parts.add(money(lastNet) + ' per unit');
        }
        String latestDisc = discountPhrase(lastRow);
        if (String.isNotBlank(latestDisc)) {
            parts.add(latestDisc);
        }

        // --- Stats ---
        parts.add('');
        parts.add('Times purchased: ' + String.valueOf(purchaseCount));
        if (avgDisc != null && avgDisc != 0) {
            parts.add('Avg discount: ' + percent(avgDisc) + ' off list');
        } else {
            parts.add('Avg discount: none');
        }
        String trend = discountTrend(firstRow, lastRow);
        if (String.isNotBlank(trend)) {
            parts.add('Discount trend: ' + trend);
        }

        // --- Purchase history (oldest first, one bullet per event) ---
        parts.add('');
        parts.add('Purchase history');
        Integer shown = 0;
        Integer hidden = 0;
        Boolean wroteEvent = false;
        for (RLM_AmendDifferenceService.HistoryRow row : oldestFirst) {
            if (row == null) {
                continue;
            }
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net == null && row.quantity == null) {
                continue;
            }
            shown++;
            if (shown > MAX_EVENTS_PER_ASSET) {
                hidden++;
                continue;
            }
            if (wroteEvent) {
                parts.add(''); // blank line between transactions
            }
            parts.addAll(formatHistoryEvent(row, row == firstRow));
            wroteEvent = true;
        }
        if (hidden > 0) {
            parts.add('+' + String.valueOf(hidden) + ' more in Amendment Studio');
        }

        // --- Conversation tip + discount offer ---
        if (lastNet != null) {
            parts.add('');
            parts.add('For your conversation');
            String tip =
                'Anchor around ' + money(lastNet)
                + ', the last price they accepted';
            if (String.isNotBlank(latestDisc)) {
                tip += ', at ' + latestDisc;
            }
            parts.add(tip + '.');
        }
        // Discount choices are offered by the agent as clickable radios (not
        // plain-text bullets — Agentforce does not make dash lists selectable).
        return parts;
    }

    /**
     * One event header + a bullet per data point:
     *   Jul 30, 2026 - Initial
     *   - Qty: 1,000
     *   - List: $149.99
     *   - Net unit: $134.99
     *   - Disc: 10%
     *   - Line ARR: $134,991
     */
    private static List<String> formatHistoryEvent(
        RLM_AmendDifferenceService.HistoryRow row,
        Boolean isFirst
    ) {
        String whenLabel = row.actionDate != null
            ? row.actionDate.format('MMM d, yyyy')
            : '-';
        Decimal qtyVal = historyQty(row);
        Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
        Decimal disc = resolvedDiscount(row);
        Decimal lineArr = row.arr;
        if (lineArr == null && net != null && qtyVal != null) {
            lineArr = (net * qtyVal).setScale(2, RoundingMode.HALF_UP);
        }

        List<String> lines = new List<String>();
        lines.add(whenLabel + ' - ' + compactKind(row, isFirst));
        lines.add('- Qty: ' + qty(qtyVal));
        lines.add('- List: ' + money(row.listPrice));
        lines.add('- Net unit: ' + money(net));
        lines.add('- Disc: ' + (disc != null ? percent(disc) : '-'));
        lines.add('- Line ARR: ' + moneyWhole(lineArr));
        return lines;
    }

    /** Prefer delta qty on adds when present; otherwise period quantity. */
    private static Decimal historyQty(RLM_AmendDifferenceService.HistoryRow row) {
        String kind = String.isNotBlank(row.changeKind) ? row.changeKind.toLowerCase() : '';
        if (kind == 'add' && row.quantityChange != null && row.quantityChange != 0) {
            return row.quantityChange;
        }
        if (row.quantity != null) {
            return row.quantity;
        }
        return row.quantityChange;
    }

    /** Compact labels for the bullet line: Initial / Add / Decrease / Renewal. */
    private static String compactKind(
        RLM_AmendDifferenceService.HistoryRow row,
        Boolean isFirst
    ) {
        String kind = String.isNotBlank(row.changeKind) ? row.changeKind.toLowerCase() : '';
        if (isFirst || kind == 'initial') {
            return 'Initial';
        }
        if (kind == 'add') {
            return 'Add';
        }
        if (kind == 'decrease') {
            return 'Decrease';
        }
        if (kind == 'renew') {
            return 'Renewal';
        }
        return String.isNotBlank(row.changeKind) ? row.changeKind : safe(row.actionType);
    }

    /** e.g. "10% -> 20%" when discount deepened; null if not useful. */
    private static String discountTrend(
        RLM_AmendDifferenceService.HistoryRow firstRow,
        RLM_AmendDifferenceService.HistoryRow lastRow
    ) {
        Decimal firstDisc = resolvedDiscount(firstRow);
        Decimal lastDisc = resolvedDiscount(lastRow);
        if (firstDisc == null || lastDisc == null) {
            return null;
        }
        if (firstDisc == lastDisc) {
            return percent(firstDisc) + ' (flat)';
        }
        return percent(firstDisc) + ' -> ' + percent(lastDisc);
    }

    /** e.g. "20% off list" or null when unknown / effectively zero. */
    private static String discountPhrase(RLM_AmendDifferenceService.HistoryRow row) {
        Decimal disc = resolvedDiscount(row);
        if (disc == null || disc == 0) {
            return null;
        }
        return percent(disc) + ' off list';
    }

    private static Decimal resolvedDiscount(RLM_AmendDifferenceService.HistoryRow row) {
        if (row == null) {
            return null;
        }
        if (row.discountPercent != null) {
            return row.discountPercent.setScale(1, RoundingMode.HALF_UP);
        }
        if (row.listPrice != null && row.listPrice != 0) {
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net != null) {
                return (((row.listPrice - net) / row.listPrice) * 100)
                    .setScale(1, RoundingMode.HALF_UP);
            }
        }
        return null;
    }

    private static RLM_AmendDifferenceService.HistoryRow firstPricedRow(
        List<RLM_AmendDifferenceService.HistoryRow> oldestFirst
    ) {
        for (RLM_AmendDifferenceService.HistoryRow row : oldestFirst) {
            if (row == null) {
                continue;
            }
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net != null) {
                return row;
            }
        }
        return null;
    }

    private static RLM_AmendDifferenceService.HistoryRow lastPricedRow(
        List<RLM_AmendDifferenceService.HistoryRow> oldestFirst
    ) {
        RLM_AmendDifferenceService.HistoryRow last = null;
        for (RLM_AmendDifferenceService.HistoryRow row : oldestFirst) {
            if (row == null) {
                continue;
            }
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net != null) {
                last = row;
            }
        }
        return last;
    }

    private static Integer countPricedRows(
        List<RLM_AmendDifferenceService.HistoryRow> rows
    ) {
        Integer n = 0;
        for (RLM_AmendDifferenceService.HistoryRow row : rows) {
            if (row == null) {
                continue;
            }
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net != null || row.quantity != null) {
                n++;
            }
        }
        return n;
    }

    private static Decimal lastNet(List<RLM_AmendDifferenceService.HistoryRow> ordered) {
        Decimal last = null;
        for (RLM_AmendDifferenceService.HistoryRow row : ordered) {
            if (row == null) {
                continue;
            }
            Decimal net = row.netUnitPrice != null ? row.netUnitPrice : row.unitPrice;
            if (net != null) {
                last = net;
            }
        }
        return last;
    }

    private static List<RLM_AmendDifferenceService.HistoryRow> orderOldestFirst(
        List<RLM_AmendDifferenceService.HistoryRow> timeline
    ) {
        List<RLM_AmendDifferenceService.HistoryRow> copy =
            new List<RLM_AmendDifferenceService.HistoryRow>();
        for (RLM_AmendDifferenceService.HistoryRow row : timeline) {
            if (row != null) {
                copy.add(row);
            }
        }
        for (Integer i = 1; i < copy.size(); i++) {
            RLM_AmendDifferenceService.HistoryRow key = copy[i];
            Integer j = i - 1;
            while (j >= 0 && isAfter(copy[j].actionDate, key.actionDate)) {
                copy[j + 1] = copy[j];
                j--;
            }
            copy[j + 1] = key;
        }
        return copy;
    }

    private static Boolean isAfter(Datetime a, Datetime b) {
        if (a == null && b == null) {
            return false;
        }
        if (a == null) {
            return true;
        }
        if (b == null) {
            return false;
        }
        return a > b;
    }

    private static String money(Decimal value) {
        if (value == null) {
            return '-';
        }
        return '$' + value.setScale(2, RoundingMode.HALF_UP).format();
    }

    private static String moneyWhole(Decimal value) {
        if (value == null) {
            return '-';
        }
        return '$' + value.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String qty(Decimal value) {
        if (value == null) {
            return '-';
        }
        return value.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String percent(Decimal value) {
        if (value == null) {
            return '-';
        }
        return value.setScale(1, RoundingMode.HALF_UP).format() + '%';
    }

    private static String safe(String value) {
        return String.isBlank(value) ? '-' : value;
    }
}
