/**
 * Resolver + formatter for Claude Hosted MCP bundle configuration.
 *
 * This class does not implement the configurator. It finds the Draft quote and
 * bundle parent line the user means, then loads option groups from the product
 * catalog (ProductComponentGroup / ProductRelatedComponent) and persists picks
 * through Place Sales Transaction. Hosted MCP cannot call Configurator HTTP or
 * mint a Visualforce API session, so this path never uses those.
 */
public with sharing class RLM_MCP_BundleConfigService {
    private static final Integer MAX_CANDIDATES = 50;

    public class Request {
        public String quoteId;
        public String quoteName;
        public String accountName;
        public String productName;
        public String selectedProducts;
        public String unselectedProducts;
        public String attributePicksJson;
        public String quantitiesJson;
    }

    public class Response {
        public Boolean isSuccess;
        public Boolean needsDisambiguation;
        public String quoteId;
        public String quoteName;
        public String quoteLineItemId;
        public String productName;
        public String configurationDisplay;
        public String candidateSummariesDisplay;
        public String errorMessage;
        public Response() {
            this.isSuccess = false;
            this.needsDisambiguation = false;
        }
    }

    public interface Engine {
        RLM_RampConfiguratorAction.ConfigResult load(String quoteId, String quoteLineItemId);
        RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        );
    }

    public class LiveEngine implements Engine {
        public RLM_RampConfiguratorAction.ConfigResult load(String quoteId, String quoteLineItemId) {
            return RLM_RampConfiguratorAction.loadCatalogConfiguration(quoteId, quoteLineItemId);
        }
        public RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        ) {
            return RLM_RampConfiguratorAction.saveCatalogConfiguration(
                quoteId, quoteLineItemId, selectionJson);
        }
    }

    @TestVisible
    static Engine engine = new LiveEngine();

    public static Response describe(Request input) {
        return run(input, false);
    }

    public static Response configure(Request input) {
        return run(input, true);
    }

    private static Response run(Request input, Boolean persist) {
        Response out = new Response();
        try {
            if (input == null) {
                out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
                return out;
            }
            Quote quote = resolveQuote(input, out);
            if (quote == null) {
                return out;
            }
            out.quoteId = quote.Id;
            out.quoteName = quote.Name;
            QuoteLineItem line = resolveBundleLine(quote.Id, input.productName, out);
            if (line == null) {
                return out;
            }
            out.quoteLineItemId = line.Id;
            out.productName = line.Product2 == null ? null : line.Product2.Name;

            RLM_RampConfiguratorAction.ConfigResult loaded =
                engine.load(String.valueOf(quote.Id), String.valueOf(line.Id));
            if (loaded == null || loaded.success != true) {
                out.errorMessage = loaded == null || String.isBlank(loaded.message)
                    ? 'Configurator could not load this bundle.'
                    : loaded.message;
                return out;
            }
            if (persist == true) {
                String applyError = applyPicks(loaded, input);
                if (applyError != null) {
                    out.errorMessage = applyError;
                    out.configurationDisplay = formatDisplay(quote, line, loaded);
                    return out;
                }
                RLM_RampConfiguratorAction.ConfigResult saved = engine.save(
                    String.valueOf(quote.Id),
                    String.valueOf(line.Id),
                    toSelectionJson(loaded)
                );
                if (saved == null || saved.success != true) {
                    out.errorMessage = saved == null || String.isBlank(saved.message)
                        ? 'Configurator could not save this bundle.'
                        : saved.message;
                    out.configurationDisplay = formatDisplay(quote, line, loaded);
                    return out;
                }
                loaded = saved;
            }
            out.isSuccess = true;
            out.configurationDisplay = formatDisplay(quote, line, loaded);
            return out;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
            return out;
        }
    }

    private static Quote resolveQuote(Request input, Response out) {
        if (String.isNotBlank(input.quoteId)) {
            Id qid = toQuoteId(input.quoteId);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id: ' + input.quoteId;
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, Status, LineItemCount, Account.Name
                FROM Quote
                WHERE Id = :qid
                WITH USER_MODE
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for Id ' + qid + '.';
                return null;
            }
            return byId[0];
        }

        String nameTerm = blankToNull(input.quoteName);
        String acctTerm = blankToNull(input.accountName);
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
            return null;
        }
        List<Quote> matches = findDraftQuotes(nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No draft quote found matching "'
                + (nameTerm != null ? nameTerm : acctTerm) + '".';
            return null;
        }
        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote match : matches) {
                if (match.Name != null && match.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(match);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildQuoteCandidates(matches);
        out.errorMessage = 'Multiple draft quotes match. Ask the user which one to configure.';
        return null;
    }

    private static List<Quote> findDraftQuotes(String nameTerm, String acctTerm) {
        String nameLike = nameTerm == null ? null : '%' + nameTerm + '%';
        String acctLike = acctTerm == null ? null : '%' + acctTerm + '%';
        if (nameLike != null && acctLike != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, Account.Name
                FROM Quote
                WHERE Status = 'Draft'
                AND (Name LIKE :nameLike OR Account.Name LIKE :nameLike)
                AND Account.Name LIKE :acctLike
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (nameLike != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, Account.Name
                FROM Quote
                WHERE Status = 'Draft'
                AND (Name LIKE :nameLike OR Account.Name LIKE :nameLike)
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, Status, LineItemCount, Account.Name
            FROM Quote
            WHERE Status = 'Draft'
            AND Account.Name LIKE :acctLike
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static QuoteLineItem resolveBundleLine(Id quoteId, String productName, Response out) {
        String term = blankToNull(productName);
        List<QuoteLineItem> lines;
        if (term == null) {
            lines = [
                SELECT Id, Product2.Name, Product2.StockKeepingUnit, Product2.Type, Quantity
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                AND ParentQuoteLineItemId = null
                AND Product2.Type = 'Bundle'
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
            if (lines.isEmpty()) {
                out.errorMessage = 'No bundle parent line is on this quote. Add QuantumBit Complete (or another bundle) first.';
                return null;
            }
        } else {
            String likeTerm = '%' + term + '%';
            lines = [
                SELECT Id, Product2.Name, Product2.StockKeepingUnit, Product2.Type, Quantity
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                AND ParentQuoteLineItemId = null
                AND (
                    Product2.Name LIKE :likeTerm
                    OR Product2.StockKeepingUnit LIKE :likeTerm
                )
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
            if (lines.isEmpty()) {
                out.errorMessage = 'No parent line matching "' + term
                    + '" is on this quote. Add that product first.';
                return null;
            }
            List<QuoteLineItem> exact = new List<QuoteLineItem>();
            for (QuoteLineItem line : lines) {
                if (nameOrSkuEquals(line, term)) {
                    exact.add(line);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
            if (!exact.isEmpty()) {
                lines = exact;
            }
        }
        if (lines.size() == 1) {
            return lines[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildLineCandidates(lines);
        out.errorMessage = 'Multiple bundle lines match. Ask the user which product to configure.';
        return null;
    }

    private static String applyPicks(
        RLM_RampConfiguratorAction.ConfigResult loaded,
        Request input
    ) {
        List<String> selected = splitTerms(input.selectedProducts);
        List<String> unselected = splitTerms(input.unselectedProducts);
        Map<String, Decimal> quantities = parseQuantities(input.quantitiesJson);
        if (quantities == null) {
            return 'quantitiesJson must be a JSON object of product name or SKU to quantity.';
        }
        Map<String, String> attributes = parseStringMap(input.attributePicksJson);
        if (attributes == null) {
            return 'attributePicksJson must be a JSON object of attribute name to value.';
        }
        for (String term : selected) {
            RLM_RampConfiguratorAction.ConfigGroup optionGroup = null;
            RLM_RampConfiguratorAction.ConfigComponent component = findComponent(loaded, term);
            if (component == null) {
                return 'No option matching "' + term + '". ' + availableOptions(loaded);
            }
            optionGroup = groupFor(loaded, component);
            if (optionGroup != null && optionGroup.selectionMode == 'single' && optionGroup.components != null) {
                for (RLM_RampConfiguratorAction.ConfigComponent other : optionGroup.components) {
                    if (other.required == true) {
                        other.selected = true;
                    } else {
                        other.selected = other === component;
                    }
                }
            } else {
                component.selected = true;
            }
            if (quantities.containsKey(term.toLowerCase())) {
                component.quantity = quantities.get(term.toLowerCase());
            }
        }
        for (String term : unselected) {
            RLM_RampConfiguratorAction.ConfigComponent component = findComponent(loaded, term);
            if (component == null) {
                return 'No option matching "' + term + '" to remove.';
            }
            if (component.required == true) {
                return component.name + ' is required and cannot be removed.';
            }
            component.selected = false;
        }
        for (String qtyKey : quantities.keySet()) {
            Boolean applied = false;
            for (String selectedTerm : selected) {
                if (selectedTerm.toLowerCase() == qtyKey) {
                    applied = true;
                    break;
                }
            }
            if (applied) {
                continue;
            }
            RLM_RampConfiguratorAction.ConfigComponent component = findComponent(loaded, qtyKey);
            if (component == null) {
                return 'No option matching "' + qtyKey + '" for quantity.';
            }
            component.quantity = quantities.get(qtyKey);
            component.selected = true;
        }
        for (String attrKey : attributes.keySet()) {
            RLM_RampConfiguratorAction.ConfigAttribute attr = findAttribute(loaded, attrKey);
            if (attr == null) {
                return 'No attribute matching "' + attrKey + '".';
            }
            String value = attributes.get(attrKey);
            attr.value = value;
            attr.picklistValueId = picklistIdFor(attr, value);
            if (attr.options != null && !attr.options.isEmpty() && String.isBlank(attr.picklistValueId)) {
                return '"' + value + '" is not a valid value for ' + attr.label + '.';
            }
        }
        return null;
    }

    @TestVisible
    static String formatDisplay(
        Quote quote,
        QuoteLineItem line,
        RLM_RampConfiguratorAction.ConfigResult config
    ) {
        List<String> lines = new List<String>();
        String product = line.Product2 == null ? 'Bundle' : line.Product2.Name;
        String sku = line.Product2 == null ? null : line.Product2.StockKeepingUnit;
        String title = '**' + product + '**';
        if (String.isNotBlank(sku)) {
            title += ' (' + sku + ')';
        }
        title += ' on quote **' + quote.Name + '**';
        if (quote.Account != null && String.isNotBlank(quote.Account.Name)) {
            title += ' (' + quote.Account.Name + ')';
        }
        lines.add(title);
        if (hasSelectedComponents(config)) {
            lines.add(
                'Checked items ([x]) are already chosen for this bundle. '
                + 'Required options must stay selected. '
                + 'Catalog defaults are the product’s starting mix; optional defaults can be turned off. '
                + 'Already on this quote means a child line was saved. '
                + 'Unchecked items are available to add. Explain this to the user; do not treat defaults as a prior custom configuration.'
            );
        }
        if (config.messages != null) {
            for (RLM_RampConfiguratorAction.ConfigMessage msg : config.messages) {
                if (msg == null || String.isBlank(msg.text)) {
                    continue;
                }
                String kind = String.isBlank(msg.messageType) ? 'info' : msg.messageType;
                lines.add('- ' + kind + ': ' + msg.text);
            }
        }
        if (config.groups != null) {
            for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : config.groups) {
                if (optionGroup == null) {
                    continue;
                }
                String header = '### ' + optionGroup.name;
                if (String.isNotBlank(optionGroup.rangeLabel)) {
                    header += ' (' + optionGroup.rangeLabel + ')';
                }
                lines.add(header);
                if (optionGroup.components == null) {
                    continue;
                }
                for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                    if (component == null) {
                        continue;
                    }
                    String mark = component.selected == true ? '[x]' : '[ ]';
                    String row = '- ' + mark + ' ' + component.name;
                    if (String.isNotBlank(component.sku)) {
                        row += ' (' + component.sku + ')';
                    }
                    if (component.selected == true && component.quantity != null && component.quantity != 1) {
                        row += ', qty ' + String.valueOf(component.quantity);
                    }
                    String why = selectionReason(component);
                    if (String.isNotBlank(why)) {
                        row += ' — ' + why;
                    }
                    lines.add(row);
                }
            }
        }
        if (config.attributes != null && !config.attributes.isEmpty()) {
            lines.add('### Attributes');
            for (RLM_RampConfiguratorAction.ConfigAttribute attr : config.attributes) {
                if (attr == null) {
                    continue;
                }
                String label = String.isNotBlank(attr.label) ? attr.label : attr.attributeName;
                String row = '- ' + label + ': '
                    + (String.isBlank(attr.value) ? '(not set)' : attr.value);
                if (attr.required == true) {
                    row += ' — required';
                }
                if (attr.options != null && !attr.options.isEmpty()) {
                    List<String> optionLabels = new List<String>();
                    for (RLM_RampConfiguratorAction.ConfigPicklistOption option : attr.options) {
                        if (option != null && String.isNotBlank(option.label)) {
                            optionLabels.add(option.label);
                        }
                    }
                    if (!optionLabels.isEmpty()) {
                        row += '. Options: ' + String.join(optionLabels, ', ');
                    }
                }
                lines.add(row);
            }
        }
        if ((config.groups == null || config.groups.isEmpty())
            && (config.attributes == null || config.attributes.isEmpty())) {
            lines.add('This line has no option groups or attributes to configure.');
        }
        return String.join(lines, '\n');
    }

    static Boolean hasSelectedComponents(RLM_RampConfiguratorAction.ConfigResult config) {
        if (config == null || config.groups == null) {
            return false;
        }
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : config.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component != null && component.selected == true) {
                    return true;
                }
            }
        }
        return false;
    }

    static String selectionReason(RLM_RampConfiguratorAction.ConfigComponent component) {
        if (component == null || component.selected != true) {
            return null;
        }
        List<String> parts = new List<String>();
        if (component.required == true) {
            parts.add('required; must stay selected');
        } else if (String.isNotBlank(component.quoteLineItemId)) {
            parts.add('already on this quote');
        } else if (component.defaulted == true) {
            parts.add('catalog default (pre-selected by the bundle)');
        } else {
            parts.add('selected');
        }
        return parts.isEmpty() ? null : String.join(parts, '; ');
    }

    @TestVisible
    static String toSelectionJson(RLM_RampConfiguratorAction.ConfigResult config) {
        Map<String, Object> root = new Map<String, Object>();
        root.put('transactionContextId', config.transactionContextId);
        List<Object> components = new List<Object>();
        if (config.groups != null) {
            for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : config.groups) {
                if (optionGroup == null || optionGroup.components == null) {
                    continue;
                }
                for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                    if (component == null || component.selected != true
                        || String.isBlank(component.product2Id)) {
                        continue;
                    }
                    components.add(new Map<String, Object>{
                        'product2Id' => component.product2Id,
                        'pricebookEntryId' => component.pricebookEntryId,
                        'productSellingModelId' => component.productSellingModelId,
                        'sellingModelType' => component.sellingModelType,
                        'unitPrice' => component.unitPrice,
                        'quantity' => component.quantity == null ? 1 : component.quantity,
                        'productRelatedComponentId' => component.productRelatedComponentId,
                        'productRelationshipTypeId' => component.productRelationshipTypeId,
                        'includedInBundle' => component.includedInBundle == true,
                        'quoteLineItemId' => component.quoteLineItemId
                    });
                }
            }
        }
        root.put('components', components);
        List<Object> attributes = new List<Object>();
        if (config.attributes != null) {
            for (RLM_RampConfiguratorAction.ConfigAttribute attr : config.attributes) {
                if (attr == null) {
                    continue;
                }
                if (String.isBlank(attr.attributeKey) && String.isBlank(attr.attributeName)) {
                    continue;
                }
                if (String.isBlank(attr.value) && String.isBlank(attr.picklistValueId)) {
                    continue;
                }
                attributes.add(new Map<String, Object>{
                    'attributeKey' => attr.attributeKey,
                    'attributeName' => attr.attributeName,
                    'attributeRecordId' => attr.attributeRecordId,
                    'value' => attr.value,
                    'picklistValueId' => attr.picklistValueId
                });
            }
        }
        root.put('attributes', attributes);
        return JSON.serialize(root);
    }

    private static RLM_RampConfiguratorAction.ConfigComponent findComponent(
        RLM_RampConfiguratorAction.ConfigResult loaded,
        String term
    ) {
        if (loaded == null || loaded.groups == null || String.isBlank(term)) {
            return null;
        }
        String needle = term.trim();
        RLM_RampConfiguratorAction.ConfigComponent exact = null;
        List<RLM_RampConfiguratorAction.ConfigComponent> contains = new List<RLM_RampConfiguratorAction.ConfigComponent>();
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : loaded.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component == null) {
                    continue;
                }
                if (equalsIgnore(component.name, needle) || equalsIgnore(component.sku, needle)) {
                    exact = component;
                } else if (containsIgnore(component.name, needle) || containsIgnore(component.sku, needle)) {
                    contains.add(component);
                }
            }
        }
        if (exact != null) {
            return exact;
        }
        return contains.size() == 1 ? contains[0] : null;
    }

    private static RLM_RampConfiguratorAction.ConfigGroup groupFor(
        RLM_RampConfiguratorAction.ConfigResult loaded,
        RLM_RampConfiguratorAction.ConfigComponent target
    ) {
        if (loaded == null || loaded.groups == null || target == null) {
            return null;
        }
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : loaded.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component === target) {
                    return optionGroup;
                }
            }
        }
        return null;
    }

    private static RLM_RampConfiguratorAction.ConfigAttribute findAttribute(
        RLM_RampConfiguratorAction.ConfigResult loaded,
        String term
    ) {
        if (loaded == null || loaded.attributes == null || String.isBlank(term)) {
            return null;
        }
        String needle = term.trim();
        for (RLM_RampConfiguratorAction.ConfigAttribute attr : loaded.attributes) {
            if (attr == null) {
                continue;
            }
            if (equalsIgnore(attr.label, needle)
                || equalsIgnore(attr.attributeName, needle)
                || equalsIgnore(attr.attributeKey, needle)) {
                return attr;
            }
        }
        return null;
    }

    private static String picklistIdFor(
        RLM_RampConfiguratorAction.ConfigAttribute attr,
        String value
    ) {
        if (attr == null || attr.options == null || String.isBlank(value)) {
            return null;
        }
        for (RLM_RampConfiguratorAction.ConfigPicklistOption option : attr.options) {
            if (option == null) {
                continue;
            }
            if (equalsIgnore(option.label, value) || equalsIgnore(option.value, value)
                || equalsIgnore(option.picklistValueId, value)) {
                return option.picklistValueId;
            }
        }
        return null;
    }

    private static String availableOptions(RLM_RampConfiguratorAction.ConfigResult loaded) {
        List<String> names = new List<String>();
        if (loaded == null || loaded.groups == null) {
            return 'No options are available.';
        }
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : loaded.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component == null) {
                    continue;
                }
                String label = component.name;
                if (String.isNotBlank(component.sku)) {
                    label += ' (' + component.sku + ')';
                }
                names.add(label);
            }
        }
        return names.isEmpty()
            ? 'No options are available.'
            : 'Available: ' + String.join(names, ', ') + '.';
    }

    private static String buildQuoteCandidates(List<Quote> quotes) {
        List<String> lines = new List<String>();
        lines.add('Multiple draft quotes match. Which one should I configure?');
        Integer ordinal = 1;
        for (Quote quote : quotes) {
            String row = ordinal + '. **' + quote.Name + '**';
            if (quote.Account != null && String.isNotBlank(quote.Account.Name)) {
                row += ' (' + quote.Account.Name + ')';
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open', 'Quote', quote.Id);
            if (String.isNotBlank(quoteLink)) {
                row += ' · ' + quoteLink;
            }
            lines.add(row);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static String buildLineCandidates(List<QuoteLineItem> lines) {
        List<String> rows = new List<String>();
        rows.add('Multiple bundle lines match. Which product should I configure?');
        Integer ordinal = 1;
        for (QuoteLineItem line : lines) {
            String name = line.Product2 == null ? 'Line' : line.Product2.Name;
            String sku = line.Product2 == null ? null : line.Product2.StockKeepingUnit;
            String row = ordinal + '. **' + name + '**';
            if (String.isNotBlank(sku)) {
                row += ' (' + sku + ')';
            }
            rows.add(row);
            ordinal++;
        }
        return String.join(rows, '\n');
    }

    private static List<String> splitTerms(String raw) {
        List<String> terms = new List<String>();
        if (String.isBlank(raw)) {
            return terms;
        }
        for (String part : raw.split('[,\n;]')) {
            String trimmed = part == null ? null : part.trim();
            if (String.isNotBlank(trimmed)) {
                terms.add(trimmed);
            }
        }
        return terms;
    }

    private static Map<String, Decimal> parseQuantities(String raw) {
        Map<String, String> asText = parseStringMap(raw);
        if (asText == null) {
            return null;
        }
        Map<String, Decimal> quantities = new Map<String, Decimal>();
        for (String key : asText.keySet()) {
            try {
                quantities.put(key.toLowerCase(), Decimal.valueOf(asText.get(key)));
            } catch (Exception e) {
                return null;
            }
        }
        return quantities;
    }

    private static Map<String, String> parseStringMap(String raw) {
        Map<String, String> values = new Map<String, String>();
        if (String.isBlank(raw)) {
            return values;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            return null;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            return null;
        }
        Map<String, Object> root = (Map<String, Object>) parsed;
        for (String key : root.keySet()) {
            Object value = root.get(key);
            values.put(key, value == null ? null : String.valueOf(value));
        }
        return values;
    }

    private static Boolean nameOrSkuEquals(QuoteLineItem line, String term) {
        if (line.Product2 == null) {
            return false;
        }
        return equalsIgnore(line.Product2.Name, term)
            || equalsIgnore(line.Product2.StockKeepingUnit, term);
    }

    private static Boolean equalsIgnore(String left, String right) {
        return left != null && right != null && left.equalsIgnoreCase(right);
    }

    private static Boolean containsIgnore(String left, String right) {
        return left != null && right != null && left.toLowerCase().contains(right.toLowerCase());
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
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
