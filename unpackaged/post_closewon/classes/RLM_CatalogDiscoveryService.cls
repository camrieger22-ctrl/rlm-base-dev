/**
 * Product Discovery / catalog browse & search for Amendment Studio.
 * OOTB Discovery invocables only — no curated QuantumBit SKU seed list.
 */
public with sharing class RLM_CatalogDiscoveryService {

    public class CatalogProductHit {
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Id sellingModelId;
        @AuraEnabled public String sellingModelName;
        @AuraEnabled public String label;
        /** True when returned from Discovery browse (getProducts), not typed search. */
        @AuraEnabled public Boolean isCommon;
        /** Discovery | PriceBook — where the hit came from. */
        @AuraEnabled public String source;
    }

    public class CatalogTaxonomyNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public Integer childCount;
    }

    public class CatalogBrowseContext {
        @AuraEnabled public List<CatalogTaxonomyNode> catalogs;
        @AuraEnabled public List<CatalogTaxonomyNode> categories;
        @AuraEnabled public Id defaultCatalogId;
        @AuraEnabled public String message;
    }

    @TestVisible
    private static final Integer CATALOG_SEARCH_LIMIT = 12;

    public static CatalogBrowseContext getCatalogBrowseContext(Id quoteId) {
        CatalogBrowseContext ctx = new CatalogBrowseContext();
        ctx.catalogs = new List<CatalogTaxonomyNode>();
        ctx.categories = new List<CatalogTaxonomyNode>();
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            ctx.message = 'Quote required.';
            return ctx;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        ctx.catalogs = listDiscoveryCatalogs(qId);
        ctx.defaultCatalogId = pickDefaultCatalogId(ctx.catalogs);
        if (ctx.defaultCatalogId != null) {
            ctx.categories = listDiscoveryCategories(qId, ctx.defaultCatalogId);
        }
        return ctx;
    }

    public static List<CatalogTaxonomyNode> getCatalogCategories(Id quoteId, Id catalogId) {
        if (
            quoteId == null ||
            quoteId.getSObjectType() != Quote.SObjectType ||
            catalogId == null
        ) {
            return new List<CatalogTaxonomyNode>();
        }
        return listDiscoveryCategories(
            Id.valueOf(String.valueOf(quoteId)),
            Id.valueOf(String.valueOf(catalogId))
        );
    }

    /**
     * - Catalog/category + blank (&lt; 2 chars) → getProducts browse.
     * - No catalog/category + blank → empty (no curated SKU seed).
     * - 2+ chars → findProducts, then price-book name LIKE fallback.
     */
    public static List<CatalogProductHit> searchCatalogProducts(
        Id quoteId,
        String searchTerm,
        Id catalogId,
        Id categoryId
    ) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return new List<CatalogProductHit>();
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        List<Quote> quotes = [
            SELECT Id, Pricebook2Id
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Pricebook2Id == null) {
            return new List<CatalogProductHit>();
        }
        Id pricebookId = quotes[0].Pricebook2Id;
        String trimmed = searchTerm == null ? '' : searchTerm.trim();
        if (trimmed.length() < 2) {
            if (catalogId != null || categoryId != null) {
                return browseViaProductDiscovery(qId, pricebookId, catalogId, categoryId);
            }
            return new List<CatalogProductHit>();
        }
        List<CatalogProductHit> discoveryHits = searchViaProductDiscovery(
            qId,
            pricebookId,
            trimmed,
            catalogId,
            categoryId
        );
        if (!discoveryHits.isEmpty()) {
            return discoveryHits;
        }
        return searchCatalogProductsByName(pricebookId, trimmed);
    }

    private static List<CatalogProductHit> searchViaProductDiscovery(
        Id quoteId,
        Id pricebookId,
        String searchTerm,
        Id catalogId,
        Id categoryId
    ) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('findProducts');
            action.setInvocationParameter('searchTerm', searchTerm);
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('priceBookId', String.valueOf(pricebookId));
            action.setInvocationParameter('limit', CATALOG_SEARCH_LIMIT);
            action.setInvocationParameter('enablePricing', true);
            action.setInvocationParameter('enableQualification', false);
            if (catalogId != null) {
                action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            }
            if (categoryId != null) {
                action.setInvocationParameter('categoryId', String.valueOf(categoryId));
            }
            return invokeDiscoveryProductList(action);
        } catch (Exception e) {
            return new List<CatalogProductHit>();
        }
    }

    private static List<CatalogProductHit> browseViaProductDiscovery(
        Id quoteId,
        Id pricebookId,
        Id catalogId,
        Id categoryId
    ) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getProducts');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('priceBookId', String.valueOf(pricebookId));
            action.setInvocationParameter('limit', CATALOG_SEARCH_LIMIT);
            action.setInvocationParameter('enablePricing', true);
            action.setInvocationParameter('enableQualification', false);
            if (catalogId != null) {
                action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            }
            if (categoryId != null) {
                action.setInvocationParameter('categoryId', String.valueOf(categoryId));
            }
            List<CatalogProductHit> hits = invokeDiscoveryProductList(action);
            for (CatalogProductHit hit : hits) {
                hit.isCommon = true;
            }
            return hits;
        } catch (Exception e) {
            return new List<CatalogProductHit>();
        }
    }

    private static List<CatalogProductHit> invokeDiscoveryProductList(Invocable.Action action) {
        List<Invocable.Action.Result> actionResults = action.invoke();
        if (actionResults == null || actionResults.isEmpty()) {
            return new List<CatalogProductHit>();
        }
        Invocable.Action.Result res = actionResults[0];
        if (!res.isSuccess()) {
            return new List<CatalogProductHit>();
        }
        Map<String, Object> outMap = res.getOutputParameters();
        if (outMap == null) {
            return new List<CatalogProductHit>();
        }
        return mapDiscoveryResults(outMap.get('results'));
    }

    private static List<CatalogTaxonomyNode> listDiscoveryCatalogs(Id quoteId) {
        List<CatalogTaxonomyNode> nodes = new List<CatalogTaxonomyNode>();
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getCatalogs');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('limit', 20);
            List<Invocable.Action.Result> actionResults = action.invoke();
            if (actionResults == null || actionResults.isEmpty() || !actionResults[0].isSuccess()) {
                return nodes;
            }
            Map<String, Object> outMap = actionResults[0].getOutputParameters();
            Object raw = outMap != null ? outMap.get('resultCatalogList') : null;
            for (Map<String, Object> row : asObjectMaps(raw)) {
                CatalogTaxonomyNode node = new CatalogTaxonomyNode();
                if (row.get('id') == null) {
                    continue;
                }
                try {
                    node.id = Id.valueOf(String.valueOf(row.get('id')));
                } catch (Exception e) {
                    continue;
                }
                node.name = row.get('name') != null ? String.valueOf(row.get('name')) : 'Catalog';
                node.code = row.get('catalogCode') != null
                    ? String.valueOf(row.get('catalogCode'))
                    : null;
                if (row.get('numberOfCategories') != null) {
                    try {
                        node.childCount = Integer.valueOf(String.valueOf(row.get('numberOfCategories')));
                    } catch (Exception e) {
                        node.childCount = null;
                    }
                }
                nodes.add(node);
            }
        } catch (Exception e) {
            return nodes;
        }
        return nodes;
    }

    private static List<CatalogTaxonomyNode> listDiscoveryCategories(Id quoteId, Id catalogId) {
        List<CatalogTaxonomyNode> nodes = new List<CatalogTaxonomyNode>();
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getCategories');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            action.setInvocationParameter('limit', 50);
            List<Invocable.Action.Result> actionResults = action.invoke();
            if (actionResults == null || actionResults.isEmpty() || !actionResults[0].isSuccess()) {
                return nodes;
            }
            Map<String, Object> outMap = actionResults[0].getOutputParameters();
            Object raw = outMap != null ? outMap.get('resultCategoryList') : null;
            for (Map<String, Object> row : asObjectMaps(raw)) {
                CatalogTaxonomyNode node = new CatalogTaxonomyNode();
                if (row.get('id') == null) {
                    continue;
                }
                try {
                    node.id = Id.valueOf(String.valueOf(row.get('id')));
                } catch (Exception e) {
                    continue;
                }
                node.name = row.get('name') != null ? String.valueOf(row.get('name')) : 'Category';
                nodes.add(node);
            }
        } catch (Exception e) {
            return nodes;
        }
        return nodes;
    }

    private static Id pickDefaultCatalogId(List<CatalogTaxonomyNode> catalogs) {
        if (catalogs == null || catalogs.isEmpty()) {
            return null;
        }
        for (CatalogTaxonomyNode n : catalogs) {
            if (n.code != null && n.code.equalsIgnoreCase('CAT-QB-SFT')) {
                return n.id;
            }
        }
        for (CatalogTaxonomyNode n : catalogs) {
            if (n.name != null && n.name.toLowerCase().contains('software')) {
                return n.id;
            }
        }
        return catalogs[0].id;
    }

    private static List<Map<String, Object>> asObjectMaps(Object raw) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (raw == null) {
            return rows;
        }
        try {
            Object parsed = JSON.deserializeUntyped(JSON.serialize(raw));
            if (!(parsed instanceof List<Object>)) {
                return rows;
            }
            for (Object item : (List<Object>) parsed) {
                if (item instanceof Map<String, Object>) {
                    rows.add((Map<String, Object>) item);
                }
            }
        } catch (Exception e) {
            return rows;
        }
        return rows;
    }

    @TestVisible
    public static List<CatalogProductHit> mapDiscoveryResults(Object rawResults) {
        List<CatalogProductHit> hits = new List<CatalogProductHit>();
        if (rawResults == null) {
            return hits;
        }
        List<Object> items;
        try {
            Object parsed = JSON.deserializeUntyped(JSON.serialize(rawResults));
            if (!(parsed instanceof List<Object>)) {
                return hits;
            }
            items = (List<Object>) parsed;
        } catch (Exception e) {
            return hits;
        }
        Set<Id> seenPbe = new Set<Id>();
        for (Object rawItem : items) {
            if (!(rawItem instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> product = (Map<String, Object>) rawItem;
            String productName = product.get('name') != null
                ? String.valueOf(product.get('name'))
                : 'Product';
            String productCode = product.get('productCode') != null
                ? String.valueOf(product.get('productCode'))
                : null;
            String description = product.get('description') != null
                ? String.valueOf(product.get('description'))
                : null;
            Id productId = null;
            if (product.get('id') != null) {
                try {
                    productId = Id.valueOf(String.valueOf(product.get('id')));
                } catch (Exception e) {
                    productId = null;
                }
            }
            List<Object> prices = new List<Object>();
            if (product.get('prices') instanceof List<Object>) {
                prices = (List<Object>) product.get('prices');
            }
            if (prices.isEmpty()) {
                continue;
            }
            List<Object> chosen = new List<Object>();
            for (Object rawPrice : prices) {
                if (!(rawPrice instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> price = (Map<String, Object>) rawPrice;
                if (price.get('isDefault') == true) {
                    chosen.add(price);
                }
            }
            if (chosen.isEmpty()) {
                chosen.addAll(prices);
            }
            for (Object rawPrice : chosen) {
                Map<String, Object> price = (Map<String, Object>) rawPrice;
                if (price.get('priceBookEntryId') == null) {
                    continue;
                }
                Id pbeId;
                try {
                    pbeId = Id.valueOf(String.valueOf(price.get('priceBookEntryId')));
                } catch (Exception e) {
                    continue;
                }
                if (seenPbe.contains(pbeId)) {
                    continue;
                }
                seenPbe.add(pbeId);
                CatalogProductHit hit = new CatalogProductHit();
                hit.pricebookEntryId = pbeId;
                hit.productId = productId;
                hit.productName = productName;
                hit.productCode = productCode;
                hit.description = description;
                hit.isCommon = false;
                hit.source = 'Discovery';
                if (price.get('price') != null) {
                    try {
                        hit.listPrice = Decimal.valueOf(String.valueOf(price.get('price')));
                    } catch (Exception e) {
                        hit.listPrice = null;
                    }
                }
                Map<String, Object> model = null;
                if (price.get('pricingModel') instanceof Map<String, Object>) {
                    model = (Map<String, Object>) price.get('pricingModel');
                }
                if (model != null) {
                    if (model.get('id') != null) {
                        try {
                            hit.sellingModelId = Id.valueOf(String.valueOf(model.get('id')));
                        } catch (Exception e) {
                            hit.sellingModelId = null;
                        }
                    }
                    hit.sellingModelName = model.get('name') != null
                        ? String.valueOf(model.get('name'))
                        : null;
                }
                hit.label = String.isNotBlank(hit.sellingModelName)
                    ? hit.productName + ' · ' + hit.sellingModelName
                    : hit.productName;
                hits.add(hit);
                if (hits.size() >= CATALOG_SEARCH_LIMIT) {
                    return hits;
                }
            }
        }
        return hits;
    }

    private static List<CatalogProductHit> searchCatalogProductsByName(
        Id pricebookId,
        String searchTerm
    ) {
        List<CatalogProductHit> hits = new List<CatalogProductHit>();
        String term = '%' + searchTerm + '%';
        for (PricebookEntry pbe : [
            SELECT
                Id,
                UnitPrice,
                Product2Id,
                Product2.Name,
                Product2.ProductCode,
                Product2.Description,
                ProductSellingModelId,
                ProductSellingModel.Name
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.Name LIKE :term
            WITH USER_MODE
            ORDER BY Product2.Name ASC
            LIMIT :CATALOG_SEARCH_LIMIT
        ]) {
            CatalogProductHit hit = toCatalogHit(pbe, false);
            hit.source = 'PriceBook';
            hits.add(hit);
        }
        return hits;
    }

    private static CatalogProductHit toCatalogHit(PricebookEntry pbe, Boolean isCommon) {
        CatalogProductHit hit = new CatalogProductHit();
        hit.pricebookEntryId = pbe.Id;
        hit.productId = pbe.Product2Id;
        hit.productName = pbe.Product2 != null ? pbe.Product2.Name : 'Product';
        if (pbe.Product2 != null) {
            hit.productCode = pbe.Product2.ProductCode;
            hit.description = pbe.Product2.Description;
        }
        hit.listPrice = pbe.UnitPrice;
        hit.sellingModelId = pbe.ProductSellingModelId;
        hit.sellingModelName =
            pbe.ProductSellingModel != null ? pbe.ProductSellingModel.Name : null;
        hit.label = String.isNotBlank(hit.sellingModelName)
            ? hit.productName + ' · ' + hit.sellingModelName
            : hit.productName;
        hit.isCommon = isCommon == true;
        hit.source = 'PriceBook';
        return hit;
    }
}