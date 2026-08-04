/**
 * BambooHR volume-ladder resolver and QLI stamp helper.
 *
 * Mirrors datasets/sfdmu/bamboohr/.../PriceAdjustmentTier.csv for plans +
 * add-ons (BAMBOO-* except BAMBOO-PKG-*). Used by the before-trigger stamp
 * and the Volume Tier Coach LWC.
 */
public inherited sharing class RLM_BambooVolumeTiers {

    public static final String SKU_PREFIX = 'BAMBOO-';
    public static final String PACKAGE_SKU_PREFIX = 'BAMBOO-PKG-';

    /** One rung on the demo volume ladder (qty bounds inclusive on lower). */
    public class LadderTier {
        @AuraEnabled public Integer lowerBound;
        @AuraEnabled public Integer upperBound; // null = open-ended
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public String bandLabel;
    }

    public class TierResult {
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public String band;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public String nextTierHint;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Integer unitsToNext;
        @AuraEnabled public Decimal nextDiscountPercent;
        @AuraEnabled public String nextBand;
    }

    public class LineCoach {
        @AuraEnabled public Id lineId;
        @AuraEnabled public String productName;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public String band;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public String nextTierHint;
        @AuraEnabled public Integer unitsToNext;
        @AuraEnabled public Decimal nextDiscountPercent;
        @AuraEnabled public String nextBand;
    }

    public class CoachPayload {
        @AuraEnabled public List<LadderTier> ladder;
        @AuraEnabled public List<LineCoach> lines;
        @AuraEnabled public String message;
    }

    /** Canonical Bamboo demo ladder — keep in sync with bh-pricing PAT CSV. */
    public static List<LadderTier> ladder() {
        List<LadderTier> tiers = new List<LadderTier>();
        tiers.add(tier(25, 75, 5, '25–75'));
        tiers.add(tier(76, 150, 10, '76–150'));
        tiers.add(tier(151, 300, 15, '151–300'));
        tiers.add(tier(301, 500, 20, '301–500'));
        tiers.add(tier(501, null, 25, '501+'));
        return tiers;
    }

    public static Boolean isEligibleSku(String sku) {
        if (String.isBlank(sku)) {
            return false;
        }
        String upper = sku.toUpperCase();
        return upper.startsWith(SKU_PREFIX) && !upper.startsWith(PACKAGE_SKU_PREFIX);
    }

    public static TierResult resolve(Decimal quantity, String sku) {
        TierResult result = new TierResult();
        result.eligible = isEligibleSku(sku);
        result.quantity = quantity == null ? 0 : Integer.valueOf(quantity.intValue());
        result.discountPercent = null;
        result.band = null;
        result.nextTierHint = null;
        result.unitsToNext = null;
        result.nextDiscountPercent = null;
        result.nextBand = null;

        if (!result.eligible) {
            return result;
        }

        Integer qty = result.quantity;
        List<LadderTier> tiers = ladder();

        if (qty < tiers[0].lowerBound) {
            Integer need = tiers[0].lowerBound - qty;
            result.band = 'Below volume';
            result.discountPercent = 0;
            result.unitsToNext = need;
            result.nextDiscountPercent = tiers[0].discountPercent;
            result.nextBand = tiers[0].bandLabel;
            result.nextTierHint =
                'Add ' + need + ' → ' + formatPct(tiers[0].discountPercent) +
                '% at ' + tiers[0].bandLabel;
            return result;
        }

        for (Integer i = 0; i < tiers.size(); i++) {
            LadderTier t = tiers[i];
            Boolean inBand =
                qty >= t.lowerBound &&
                (t.upperBound == null || qty <= t.upperBound);
            if (!inBand) {
                continue;
            }
            result.band = t.bandLabel;
            result.discountPercent = t.discountPercent;
            if (i + 1 < tiers.size()) {
                LadderTier next = tiers[i + 1];
                Integer need = next.lowerBound - qty;
                result.unitsToNext = need;
                result.nextDiscountPercent = next.discountPercent;
                result.nextBand = next.bandLabel;
                result.nextTierHint =
                    'Add ' + need + ' → ' + formatPct(next.discountPercent) +
                    '% at ' + next.bandLabel;
            } else {
                result.nextTierHint = 'Top volume tier';
            }
            return result;
        }

        // Defensive fallback — should not hit with a contiguous ladder.
        LadderTier last = tiers[tiers.size() - 1];
        result.band = last.bandLabel;
        result.discountPercent = last.discountPercent;
        result.nextTierHint = 'Top volume tier';
        return result;
    }

    /**
     * Stamp volume-tier fields on QLI rows in-memory (before insert/update).
     * Non-Bamboo / package lines clear the coach fields.
     */
    public static void stampLines(List<QuoteLineItem> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }

        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem line : lines) {
            if (line.Product2Id != null) {
                productIds.add(line.Product2Id);
            }
        }

        Map<Id, String> skuByProduct = new Map<Id, String>();
        if (!productIds.isEmpty()) {
            for (Product2 p : [
                SELECT Id, StockKeepingUnit
                FROM Product2
                WHERE Id IN :productIds
                WITH USER_MODE
            ]) {
                skuByProduct.put(p.Id, p.StockKeepingUnit);
            }
        }

        for (QuoteLineItem line : lines) {
            String sku = skuByProduct.get(line.Product2Id);
            TierResult resolved = resolve(line.Quantity, sku);
            if (!resolved.eligible) {
                line.RLM_Volume_Tier_Band__c = null;
                line.RLM_Volume_Tier_Discount__c = null;
                line.RLM_Volume_Tier_Next__c = null;
                continue;
            }
            line.RLM_Volume_Tier_Band__c = resolved.band;
            line.RLM_Volume_Tier_Discount__c = resolved.discountPercent;
            line.RLM_Volume_Tier_Next__c = resolved.nextTierHint;
        }
    }

    @AuraEnabled(cacheable=true)
    public static CoachPayload getCoachForQuote(Id quoteId) {
        CoachPayload payload = new CoachPayload();
        payload.ladder = ladder();
        payload.lines = new List<LineCoach>();

        if (quoteId == null) {
            payload.message = 'No quote selected.';
            return payload;
        }

        Id qId;
        try {
            qId = Id.valueOf(String.valueOf(quoteId));
        } catch (Exception e) {
            payload.message = 'Invalid quote Id.';
            return payload;
        }

        List<QuoteLineItem> qlis = [
            SELECT
                Id,
                Quantity,
                Product2.Name,
                Product2.StockKeepingUnit,
                RLM_Volume_Tier_Band__c,
                RLM_Volume_Tier_Discount__c,
                RLM_Volume_Tier_Next__c
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY Product2.Name, Id
        ];

        for (QuoteLineItem qli : qlis) {
            String sku = qli.Product2 != null ? qli.Product2.StockKeepingUnit : null;
            if (!isEligibleSku(sku)) {
                continue;
            }
            TierResult resolved = resolve(qli.Quantity, sku);
            LineCoach row = new LineCoach();
            row.lineId = qli.Id;
            row.productName = qli.Product2 != null ? qli.Product2.Name : 'Product';
            row.sku = sku;
            row.quantity = qli.Quantity;
            row.band = String.isNotBlank(qli.RLM_Volume_Tier_Band__c)
                ? qli.RLM_Volume_Tier_Band__c
                : resolved.band;
            row.discountPercent = qli.RLM_Volume_Tier_Discount__c != null
                ? qli.RLM_Volume_Tier_Discount__c
                : resolved.discountPercent;
            row.nextTierHint = String.isNotBlank(qli.RLM_Volume_Tier_Next__c)
                ? qli.RLM_Volume_Tier_Next__c
                : resolved.nextTierHint;
            row.unitsToNext = resolved.unitsToNext;
            row.nextDiscountPercent = resolved.nextDiscountPercent;
            row.nextBand = resolved.nextBand;
            payload.lines.add(row);
        }

        if (payload.lines.isEmpty()) {
            payload.message =
                'Add a BambooHR plan or add-on line to see volume tiers.';
        }
        return payload;
    }

    private static LadderTier tier(
        Integer lowerBound,
        Integer upperBound,
        Decimal discountPercent,
        String bandLabel
    ) {
        LadderTier t = new LadderTier();
        t.lowerBound = lowerBound;
        t.upperBound = upperBound;
        t.discountPercent = discountPercent;
        t.bandLabel = bandLabel;
        return t;
    }

    private static String formatPct(Decimal pct) {
        if (pct == null) {
            return '0';
        }
        return String.valueOf(pct.setScale(0));
    }
}
