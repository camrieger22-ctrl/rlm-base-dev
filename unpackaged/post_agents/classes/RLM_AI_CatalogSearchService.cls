/**
 * Invocable: names-only catalog product search scoped to an amendment quote's price book.
 * Backs Quinn AmendmentStudio → Search_Catalog_Products. Read-only.
 */
public with sharing class RLM_AI_CatalogSearchService {

    private static final Integer DISPLAY_LIMIT = 8;

    public class SearchInput {
        @InvocableVariable(required=true label='Quote Id'
            description='18-character Quote Id (0Q0...) whose price book scopes the catalog search.')
        public String quoteId;

        @InvocableVariable(required=true label='Search Term'
            description='Product name or keywords to search (at least 2 characters).')
        public String searchTerm;
    }

    public class SearchOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Results Display'
            description='Names-only catalog hits for the rep.')
        public String resultsDisplay;

        @InvocableVariable(label='Needs Disambiguation')
        public Boolean needsDisambiguation;

        @InvocableVariable(label='Match Count')
        public Integer matchCount;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        public SearchOutput() {
            this.isSuccess = false;
            this.resultsDisplay = '';
            this.needsDisambiguation = false;
            this.matchCount = 0;
        }
    }

    @InvocableMethod(
        label='Search Catalog Products'
        description='Searches the Revenue Cloud catalog for products matching a term, scoped to the quote price book via Product Discovery (with price-book name fallback). Names-only. Read-only.'
    )
    public static List<SearchOutput> search(List<SearchInput> inputs) {
        List<SearchOutput> results = new List<SearchOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (SearchInput input : inputs) {
            results.add(build(input));
        }
        return results;
    }

    private static SearchOutput build(SearchInput input) {
        SearchOutput out = new SearchOutput();
        if (input == null || String.isBlank(input.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        if (input == null || String.isBlank(input.searchTerm)) {
            out.errorMessage = 'Search term is required.';
            return out;
        }
        Id quoteId = RLM_AI_ConfigServiceUtils.toIdOrNull(input.quoteId);
        if (quoteId == null || !RLM_AI_ConfigServiceUtils.hasPrefix(input.quoteId, RLM_AI_ConfigServiceUtils.QUOTE_PREFIX)) {
            out.errorMessage = 'Invalid quote Id.';
            return out;
        }
        String term = input.searchTerm.trim();
        if (term.length() < 2) {
            out.errorMessage = 'Search term must be at least 2 characters.';
            return out;
        }

        List<RLM_CatalogDiscoveryService.CatalogProductHit> hits;
        try {
            hits = RLM_CatalogDiscoveryService.searchCatalogProducts(quoteId, term, null, null);
        } catch (Exception e) {
            out.errorMessage = 'Catalog search failed. Try a different product name.';
            return out;
        }
        if (hits == null) {
            hits = new List<RLM_CatalogDiscoveryService.CatalogProductHit>();
        }

        out.isSuccess = true;
        out.matchCount = hits.size();
        out.needsDisambiguation = hits.size() > 1;
        out.resultsDisplay = render(term, hits);
        return out;
    }

    private static String render(
        String term,
        List<RLM_CatalogDiscoveryService.CatalogProductHit> hits
    ) {
        if (hits.isEmpty()) {
            return 'No catalog products matched "' + term + '" on this quote\'s price book.';
        }
        List<String> parts = new List<String>();
        parts.add('**Catalog matches for "' + term + '"** (' + hits.size() + ')');
        Integer shown = 0;
        for (RLM_CatalogDiscoveryService.CatalogProductHit hit : hits) {
            if (hit == null || String.isBlank(hit.productName)) {
                continue;
            }
            shown++;
            if (shown > DISPLAY_LIMIT) {
                parts.add('- ...more matches - narrow the search term');
                break;
            }
            String line = '- **' + hit.productName + '**';
            if (String.isNotBlank(hit.productCode)) {
                line += ' (' + hit.productCode + ')';
            }
            if (hit.listPrice != null) {
                line += ' - list $' + hit.listPrice.setScale(2, RoundingMode.HALF_UP).format();
            }
            if (String.isNotBlank(hit.sellingModelName)) {
                line += ' / ' + hit.sellingModelName;
            }
            parts.add(line);
        }
        if (hits.size() > 1) {
            parts.add('Say which product to add (or expand an existing line) when you are ready.');
        }
        return String.join(parts, '\n');
    }
}
