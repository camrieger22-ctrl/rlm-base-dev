/**
 * AE coaching for derived-price products on a quote (e.g. Software
 * Maintenance at 20% of contributing SKUs). Chat only — never customer email.
 * Numbered options so Claude can wait for the rep; do not auto-add.
 */
public inherited sharing class RLM_MCP_DerivedPriceCoach {
    @TestVisible
    static Map<Id, List<Id>> contributorsByProductOverride;
    @TestVisible
    static Map<Id, List<String>> bundleNamesByDerivedOverride;

    private class BundleOffer {
        Id parentId;
        String name;
    }

    public static String append(String existing, Id quoteId) {
        String note = forQuote(quoteId);
        if (String.isBlank(note)) {
            return existing;
        }
        return String.isBlank(existing) ? note : existing + '\n\n' + note;
    }

    public static String forQuote(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        Map<Id, String> nameByProduct = new Map<Id, String>();
        Set<Id> onQuote = new Set<Id>();
        Set<Id> standaloneIds = new Set<Id>();
        for (QuoteLineItem line : [
            SELECT Product2Id, Product2.Name, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND Product2Id != null
            WITH USER_MODE
        ]) {
            onQuote.add(line.Product2Id);
            nameByProduct.put(line.Product2Id, line.Product2.Name);
            if (line.ParentQuoteLineItemId == null) {
                standaloneIds.add(line.Product2Id);
            }
        }
        if (onQuote.isEmpty()) {
            return null;
        }
        Map<Id, List<Id>> contributorsByProduct = loadContributors(onQuote);
        if (contributorsByProduct.isEmpty()) {
            return null;
        }
        Set<Id> neededIds = new Set<Id>();
        for (List<Id> contributorIds : contributorsByProduct.values()) {
            neededIds.addAll(contributorIds);
        }
        neededIds.removeAll(onQuote);
        if (!neededIds.isEmpty()) {
            for (Product2 product : [
                SELECT Id, Name
                FROM Product2
                WHERE Id IN :neededIds
                WITH USER_MODE
            ]) {
                nameByProduct.put(product.Id, product.Name);
            }
        }
        Map<Id, Set<Id>> missingIdsByDerived = new Map<Id, Set<Id>>();
        Map<Id, List<String>> missingNamesByDerived = new Map<Id, List<String>>();
        for (Id productId : contributorsByProduct.keySet()) {
            if (!onQuote.contains(productId)) {
                continue;
            }
            Set<String> missingNames = new Set<String>();
            Set<Id> missingContributorIds = new Set<Id>();
            Boolean anyPresent = false;
            for (Id contributorId : contributorsByProduct.get(productId)) {
                if (onQuote.contains(contributorId)) {
                    anyPresent = true;
                } else if (String.isNotBlank(nameByProduct.get(contributorId))) {
                    missingNames.add(nameByProduct.get(contributorId));
                    missingContributorIds.add(contributorId);
                }
            }
            if (anyPresent || missingNames.isEmpty()) {
                continue;
            }
            List<String> needed = new List<String>(missingNames);
            needed.sort();
            missingIdsByDerived.put(productId, missingContributorIds);
            missingNamesByDerived.put(productId, needed);
        }
        Map<Id, List<BundleOffer>> bundlesByDerived = loadBundles(missingIdsByDerived);
        List<String> notes = new List<String>();
        for (Id productId : missingNamesByDerived.keySet()) {
            notes.add(
                buildChoiceNote(
                    nameByProduct.get(productId),
                    missingNamesByDerived.get(productId),
                    bundlesByDerived.get(productId),
                    onQuote,
                    nameByProduct,
                    hasOtherStandalone(productId, standaloneIds)
                )
            );
        }
        if (notes.isEmpty()) {
            return null;
        }
        return 'AE note (chat only, never the customer email): '
            + String.join(notes, '\n\n');
    }

    static Boolean hasOtherStandalone(Id derivedId, Set<Id> standaloneIds) {
        if (standaloneIds == null) {
            return false;
        }
        for (Id productId : standaloneIds) {
            if (productId != derivedId) {
                return true;
            }
        }
        return false;
    }

    static String buildChoiceNote(
        String derivedName,
        List<String> needed,
        List<BundleOffer> bundles,
        Set<Id> onQuote,
        Map<Id, String> nameByProduct,
        Boolean otherStandalone
    ) {
        List<String> lines = new List<String>{
            '**'
            + derivedName
            + '** derives its price from **'
            + String.join(needed, '** or **')
            + '**. Those SKUs are not on this quote, so it stays $0 and Instant Pricing will warn. One contributor is enough; both only if they want maintenance on each.',
            'Ask the rep (do not add yet):'
        };
        Integer n = 1;
        for (String name : needed) {
            lines.add(String.valueOf(n) + '. Add ' + name);
            n++;
        }
        if (needed.size() > 1) {
            lines.add(String.valueOf(n) + '. Add both as individual lines');
            n++;
        }
        if (bundles != null) {
            for (BundleOffer bundle : bundles) {
                if (bundle == null || String.isBlank(bundle.name)) {
                    continue;
                }
                if (bundleAlreadyOnQuote(bundle, onQuote, nameByProduct)) {
                    lines.add(
                        String.valueOf(n)
                        + '. Configure '
                        + bundle.name
                        + ' to include those SKUs'
                    );
                    n++;
                } else if (otherStandalone != true) {
                    lines.add(
                        String.valueOf(n)
                        + '. Add '
                        + bundle.name
                        + ' (includes those as components)'
                    );
                    n++;
                }
            }
        }
        lines.add(String.valueOf(n) + '. Leave ' + derivedName + ' at $0');
        lines.add('Which option? Click a suggestion or reply with a number.');
        return String.join(lines, '\n');
    }

    static Boolean bundleAlreadyOnQuote(
        BundleOffer bundle,
        Set<Id> onQuote,
        Map<Id, String> nameByProduct
    ) {
        if (bundle.parentId != null) {
            return onQuote != null && onQuote.contains(bundle.parentId);
        }
        if (onQuote == null || nameByProduct == null || String.isBlank(bundle.name)) {
            return false;
        }
        for (Id productId : onQuote) {
            if (bundle.name == nameByProduct.get(productId)) {
                return true;
            }
        }
        return false;
    }

    static Map<Id, List<BundleOffer>> loadBundles(Map<Id, Set<Id>> missingIdsByDerived) {
        Map<Id, List<BundleOffer>> byDerived = new Map<Id, List<BundleOffer>>();
        if (missingIdsByDerived == null || missingIdsByDerived.isEmpty()) {
            return byDerived;
        }
        if (bundleNamesByDerivedOverride != null) {
            for (Id derivedId : missingIdsByDerived.keySet()) {
                List<BundleOffer> offers = new List<BundleOffer>();
                List<String> names = bundleNamesByDerivedOverride.get(derivedId);
                if (names != null) {
                    for (String name : names) {
                        BundleOffer offer = new BundleOffer();
                        offer.name = name;
                        offers.add(offer);
                    }
                }
                byDerived.put(derivedId, offers);
            }
            return byDerived;
        }
        Set<Id> childIds = new Set<Id>(missingIdsByDerived.keySet());
        for (Set<Id> missingIds : missingIdsByDerived.values()) {
            if (missingIds != null) {
                childIds.addAll(missingIds);
            }
        }
        Map<Id, Set<Id>> childrenByParent = new Map<Id, Set<Id>>();
        Map<Id, String> parentName = new Map<Id, String>();
        for (ProductRelatedComponent row : [
            SELECT ParentProductId, ParentProduct.Name, ChildProductId
            FROM ProductRelatedComponent
            WHERE ChildProductId IN :childIds
            AND ParentProductId != null
            WITH USER_MODE
        ]) {
            if (!childrenByParent.containsKey(row.ParentProductId)) {
                childrenByParent.put(row.ParentProductId, new Set<Id>());
                parentName.put(row.ParentProductId, row.ParentProduct.Name);
            }
            childrenByParent.get(row.ParentProductId).add(row.ChildProductId);
        }
        for (Id derivedId : missingIdsByDerived.keySet()) {
            List<BundleOffer> offers = new List<BundleOffer>();
            Set<Id> missingContributorIds = missingIdsByDerived.get(derivedId);
            for (Id parentId : childrenByParent.keySet()) {
                Set<Id> children = childrenByParent.get(parentId);
                if (!children.contains(derivedId)) {
                    continue;
                }
                Boolean sharesContributor = false;
                if (missingContributorIds != null) {
                    for (Id contributorId : missingContributorIds) {
                        if (children.contains(contributorId)) {
                            sharesContributor = true;
                            break;
                        }
                    }
                }
                if (!sharesContributor) {
                    continue;
                }
                BundleOffer offer = new BundleOffer();
                offer.parentId = parentId;
                offer.name = parentName.get(parentId);
                if (String.isNotBlank(offer.name)) {
                    offers.add(offer);
                }
            }
            byDerived.put(derivedId, offers);
        }
        return byDerived;
    }

    static Map<Id, List<Id>> loadContributors(Set<Id> productIds) {
        if (contributorsByProductOverride != null) {
            return contributorsByProductOverride;
        }
        Map<Id, List<Id>> byProduct = new Map<Id, List<Id>>();
        if (productIds == null || productIds.isEmpty()) {
            return byProduct;
        }
        for (PricebookEntryDerivedPrice row : [
            SELECT ProductId, ContributingProductId
            FROM PricebookEntryDerivedPrice
            WHERE ProductId IN :productIds
            AND ContributingProductId != null
            WITH USER_MODE
        ]) {
            if (!byProduct.containsKey(row.ProductId)) {
                byProduct.put(row.ProductId, new List<Id>());
            }
            if (!byProduct.get(row.ProductId).contains(row.ContributingProductId)) {
                byProduct.get(row.ProductId).add(row.ContributingProductId);
            }
        }
        return byProduct;
    }
}
