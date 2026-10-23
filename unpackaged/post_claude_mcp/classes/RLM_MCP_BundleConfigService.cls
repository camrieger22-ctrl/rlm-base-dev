/**
 * Resolver + formatter for Claude Hosted MCP bundle configuration.
 *
 * This class does not implement the configurator. It finds the Draft quote and
 * bundle parent line the user means, then loads and mutates the mix through
 * Lightning Configure (POST configure, executeConfigurationRules=true) so
 * Dual/Gold/qty/auto-add come from Constraint Rules Engine. Persist is Place
 * Sales Transaction of that CRE graph (Claude cannot save-instance). Lightning
 * uses session HTTP; REST/anonymous and the Hosted MCP Queueable use Named
 * Credential loopback (OAuth, no stored UserInfo session). Hosted MCP upserts
 * a Pending cache row and returns CRE_LOADING so Claude retries. A
 * record-triggered Flow async path enqueues the callout after that
 * transaction commits. Do not HTTP, enqueueJob, or EventBus.publish in the
 * Hosted MCP transaction.
 */
public with sharing class RLM_MCP_BundleConfigService {
    private static final Integer MAX_CANDIDATES = 50;

    public class Request {
        public String quoteId;
        public String quoteName;
        public String accountName;
        public String productName;
        public String quoteLineItemId;
        public String selectedProducts;
        public String unselectedProducts;
        public String attributePicksJson;
        public String quantitiesJson;
    }

    public class Response {
        public Boolean isSuccess;
        public Boolean needsAction;
        public Boolean needsDisambiguation;
        public String quoteId;
        public String quoteName;
        public String quoteLineItemId;
        public String productName;
        public String configurationDisplay;
        public String constraintCoachDisplay;
        public String candidateSummariesDisplay;
        public String errorMessage;
        public Response() {
            this.isSuccess = false;
            this.needsAction = false;
            this.needsDisambiguation = false;
        }
    }

    public interface Engine {
        RLM_RampConfiguratorAction.ConfigResult load(String quoteId, String quoteLineItemId);
        RLM_RampConfiguratorAction.ConfigResult applyAttributes(
            String quoteId,
            String quoteLineItemId,
            Map<String, String> attributeValues
        );
        RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        );
    }

    public class LiveEngine implements Engine {
        public RLM_RampConfiguratorAction.ConfigResult load(String quoteId, String quoteLineItemId) {
            return RLM_RampConfiguratorAction.loadConfigurationForMcp(quoteId, quoteLineItemId);
        }
        public RLM_RampConfiguratorAction.ConfigResult applyAttributes(
            String quoteId,
            String quoteLineItemId,
            Map<String, String> attributeValues
        ) {
            return RLM_RampConfiguratorAction.applyConfigurationAttributesForMcp(
                quoteId, quoteLineItemId, attributeValues);
        }
        public RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        ) {
            return RLM_RampConfiguratorAction.persistMcpConfiguration(
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
            QuoteLineItem line = resolveBundleLine(quote.Id, input, out);
            if (line == null) {
                return out;
            }
            out.quoteLineItemId = line.Id;
            out.productName = line.Product2 == null ? null : line.Product2.Name;

            RLM_RampConfiguratorAction.ConfigResult loaded =
                engine.load(String.valueOf(quote.Id), String.valueOf(line.Id));
            if (isCreLoading(loaded)) {
                markCreLoading(out, String.valueOf(line.Id));
                return out;
            }
            if (loaded == null || loaded.success != true) {
                applyFixError(
                    out,
                    loaded,
                    loaded == null || String.isBlank(loaded.message)
                        ? 'Configurator could not load this bundle.'
                        : loaded.message
                );
                return out;
            }
            if (persist == true) {
                Map<String, String> attributePicks = parseStringMap(input.attributePicksJson);
                if (attributePicks == null) {
                    out.errorMessage = 'attributePicksJson must be a JSON object of attribute name to value.';
                    out.needsAction = true;
                    out.configurationDisplay = formatDisplay(quote, line, loaded);
                    applyCoach(out, loaded);
                    return out;
                }
                RLM_RampConfiguratorAction.ConfigResult working = loaded;
                if (!attributePicks.isEmpty()) {
                    working = engine.applyAttributes(
                        String.valueOf(quote.Id),
                        String.valueOf(line.Id),
                        attributePicks
                    );
                    if (isCreLoading(working)) {
                        markCreLoading(out, String.valueOf(line.Id));
                        return out;
                    }
                    if (working == null || working.success != true) {
                        applyFixError(
                            out,
                            working,
                            working == null || String.isBlank(working.message)
                                ? 'Configurator could not apply those attributes.'
                                : working.message
                        );
                        out.needsAction = true;
                        out.configurationDisplay = formatDisplay(quote, line, working != null ? working : loaded);
                        applyCoach(out, working != null ? working : loaded);
                        return out;
                    }
                }
                String applyError = applyPicks(working, input);
                if (applyError != null) {
                    working.success = false;
                    working.message = applyError;
                    RLM_RampConfiguratorAction.attachFixGuidance(
                        working, confirmedAttributeKeys(input.attributePicksJson));
                    applyFixError(out, working, applyError);
                    out.needsAction = true;
                    out.configurationDisplay = formatDisplay(quote, line, working);
                    applyCoach(out, working);
                    return out;
                }
                String recap = recapEngineChanges(loaded, working);
                String selectionJson = toSelectionJson(working);
                RLM_RampConfiguratorAction.ConfigResult saved = engine.save(
                    String.valueOf(quote.Id),
                    String.valueOf(line.Id),
                    selectionJson
                );
                if (saved == null || saved.success != true) {
                    applyFixError(
                        out,
                        saved,
                        saved == null || String.isBlank(saved.message)
                            ? 'Configurator could not save this bundle.'
                            : saved.message
                    );
                    out.needsAction = true;
                    out.configurationDisplay = formatDisplay(quote, line, working);
                    applyCoach(out, saved != null ? saved : working);
                    return out;
                }
                String persistRecap = recapEngineChanges(working, saved);
                recap = joinRecaps(recap, persistRecap);
                loaded = saved;
                applyLiveConfigRules(String.valueOf(quote.Id), loaded);
                out.isSuccess = true;
                Set<String> pickKeys = confirmedAttributeKeys(input.attributePicksJson);
                if (hasBlockingIssues(loaded, pickKeys)) {
                    out.needsAction = true;
                    RLM_RampConfiguratorAction.attachFixGuidance(loaded, pickKeys);
                    out.configurationDisplay = formatDisplay(quote, line, loaded);
                    applyCoach(out, loaded);
                    if (String.isNotBlank(recap)) {
                        out.configurationDisplay += '\n\n' + recap;
                    }
                    if (String.isBlank(out.constraintCoachDisplay)
                        && String.isBlank(out.errorMessage)) {
                        out.errorMessage =
                            'Required or price-impacting attributes still need values in attributePicksJson. Do not copy this mix to other ramp years. Do not PDF or email.';
                    }
                    return out;
                }
                out.configurationDisplay = formatDisplay(quote, line, loaded);
                applyCoach(out, loaded);
                if (String.isNotBlank(recap)) {
                    out.configurationDisplay += '\n\n' + recap;
                }
                String copied = copyToRampSiblings(quote, line, toSelectionJson(saved));
                if (String.isNotBlank(copied)) {
                    out.configurationDisplay += '\n\n' + copied;
                }
                return out;
            }
            out.isSuccess = true;
            out.configurationDisplay = formatDisplay(quote, line, loaded);
            applyCoach(out, loaded);
            Boolean unconfigured = !hasChildren(quote.Id, line.Id);
            Boolean blocking = hasBlockingIssues(loaded);
            if (isConfigurable(loaded) && (unconfigured || blocking)) {
                out.needsAction = true;
                applyCoach(out, loaded);
                if (String.isBlank(loaded.constraintCoachDisplay)) {
                    out.configurationDisplay +=
                        '\n\nWait. Keep-or-drill picker — never dump values or SKUs on the overview. Step 1 of 2 — Attributes: bullet current values; Keep all current attributes, or pick which attributes to change (names only); drill only those; mark affects price. Step 2 of 2 — Add-on products: leaf groups only; Keep all catalog add-ons, or pick which groups to change (names only); drill only those. Drill cards: Keep current selection then other values; blanks have no keep chip; required blanks still get a card. Skip options hide/disable from configuration rules. Constraint messages are blocking; copy to other ramp years only after a clean engine save. Then one configureRevenueCloudBundle with quoteLineItemId '
                        + String.valueOf(line.Id)
                        + ', selectedProducts, and attributePicksJson. Do not PDF, email, or submit.';
                }
            }
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

    private static QuoteLineItem resolveBundleLine(Id quoteId, Request input, Response out) {
        if (input != null && String.isNotBlank(input.quoteLineItemId)) {
            Id lineId = toQuoteLineItemId(input.quoteLineItemId);
            if (lineId == null) {
                out.errorMessage = 'Invalid Quote Line Item Id: ' + input.quoteLineItemId;
                return null;
            }
            List<QuoteLineItem> byId = [
                SELECT Id, Product2Id, Product2.Name, Product2.StockKeepingUnit, Product2.Type,
                    Quantity, QuoteLineGroup.Name, QuoteLineGroup.IsRamped
                FROM QuoteLineItem
                WHERE Id = :lineId
                AND QuoteId = :quoteId
                AND ParentQuoteLineItemId = null
                WITH USER_MODE
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No parent line ' + lineId + ' is on this quote.';
                return null;
            }
            return byId[0];
        }
        String term = input == null ? null : blankToNull(input.productName);
        List<QuoteLineItem> lines;
        if (term == null) {
            lines = [
                SELECT Id, Product2Id, Product2.Name, Product2.StockKeepingUnit, Product2.Type,
                    Quantity, QuoteLineGroup.Name, QuoteLineGroup.IsRamped
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
                SELECT Id, Product2Id, Product2.Name, Product2.StockKeepingUnit, Product2.Type,
                    Quantity, QuoteLineGroup.Name, QuoteLineGroup.IsRamped
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
        if (config != null && String.isBlank(config.fixHeadline)) {
            RLM_RampConfiguratorAction.attachFixGuidance(config);
        }
        if (config != null && String.isNotBlank(config.constraintCoachDisplay)) {
            lines.add(config.constraintCoachDisplay);
            lines.add('');
        }
        String fix = formatFixThis(config);
        if (String.isNotBlank(fix)) {
            lines.add(fix);
            lines.add('');
        }
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
            Set<String> alreadyFixed = new Set<String>();
            if (config.fixSteps != null) {
                for (String step : config.fixSteps) {
                    if (String.isNotBlank(step)) {
                        alreadyFixed.add(step.toLowerCase());
                    }
                }
            }
            for (RLM_RampConfiguratorAction.ConfigMessage msg : config.messages) {
                if (msg == null || String.isBlank(msg.text)) {
                    continue;
                }
                if (alreadyFixed.contains(msg.text.toLowerCase())) {
                    continue;
                }
                String kind = String.isBlank(msg.messageType) ? 'info' : msg.messageType;
                if (kind.equalsIgnoreCase('constraint') || kind.equalsIgnoreCase('error')) {
                    continue;
                }
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
                    if (component.hidden == true) {
                        continue;
                    }
                    if (component.disabled == true && component.selected != true) {
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
                if (attr.priceImpacting == true) {
                    row += ' — affects price';
                }
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
            parts.add('selected by configuration rules');
        }
        return parts.isEmpty() ? null : String.join(parts, '; ');
    }

    @TestVisible
    static Boolean shouldFallbackToCatalog(RLM_RampConfiguratorAction.ConfigResult result) {
        if (result == null) {
            return true;
        }
        if (result.success == true) {
            return false;
        }
        String message = result.message;
        if (String.isBlank(message)) {
            return false;
        }
        return message.containsIgnoreCase('configuration rules')
            || message.containsIgnoreCase('ConfiguratorException');
    }

    @TestVisible
    static void overlayRulesCrash(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        RLM_RampConfiguratorAction.ConfigResult failed
    ) {
        if (catalog == null) {
            return;
        }
        if (catalog.messages == null) {
            catalog.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        }
        RLM_RampConfiguratorAction.ConfigMessage msg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        msg.messageType = 'constraint';
        msg.text = failed == null || String.isBlank(failed.message)
            ? 'Configurator could not finish rule evaluation.'
            : failed.message;
        catalog.messages.add(msg);
    }

    /**
     * Documented in-process Configurator path for Hosted MCP: standard
     * invocable runConfigRules (Help: Use an Apex Call to Run the Run Config
     * Rules Action). Same Invocable.Action pattern as createOrdersFromQuote.
     * Does not HTTP /connect/cpq/configurator (Script-thrown in MCP).
     */
    static void applyLiveConfigRules(
        String quoteId,
        RLM_RampConfiguratorAction.ConfigResult catalog
    ) {
        if (catalog == null || catalog.success != true || String.isBlank(quoteId)) {
            return;
        }
        if (Test.isRunningTest()) {
            return;
        }
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('runConfigRules');
            action.setInvocationParameter('transactionId', quoteId);
            List<Invocable.Action.Result> results = action.invoke();
            if (results == null || results.isEmpty() || !results[0].isSuccess()) {
                return;
            }
            Map<String, Object> outs = results[0].getOutputParameters();
            if (outs == null || !outs.containsKey('configRuleResult')) {
                return;
            }
            overlayConfigRules(catalog, JSON.serialize(outs.get('configRuleResult')));
        } catch (Exception e) {
            // Hide/disable overlay is optional when CRE configure already ran.
        }
    }

    @TestVisible
    static void overlayConfigRules(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        String configRuleResultJson
    ) {
        if (catalog == null || String.isBlank(configRuleResultJson)) {
            return;
        }
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(configRuleResultJson);
        } catch (Exception e) {
            return;
        }
        if (parsed == null) {
            return;
        }
        overlayMessageRules(catalog, asObjectList(parsed.get('messageRules')));
        overlayErrorStrings(catalog, parsed.get('errors'));
        overlayVisibility(
            catalog,
            asObjectList(parsed.get('visibilityRules')));
    }

    static void overlayMessageRules(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        List<Object> rows
    ) {
        if (rows == null) {
            return;
        }
        for (Object row : rows) {
            Map<String, Object> raw = asObjectMap(row);
            if (raw == null) {
                continue;
            }
            String severity = firstNonBlank(
                asText(raw.get('severity')),
                asText(raw.get('messageType')));
            List<String> texts = new List<String>();
            Object messagesObj = raw.get('messages');
            if (messagesObj instanceof List<Object>) {
                for (Object item : (List<Object>) messagesObj) {
                    if (item != null && String.isNotBlank(String.valueOf(item))) {
                        texts.add(String.valueOf(item));
                    }
                }
            }
            String single = asText(raw.get('message'));
            if (String.isNotBlank(single)) {
                texts.add(single);
            }
            String kind = messageKind(severity);
            for (String text : texts) {
                addConfigMessage(catalog, kind, text);
            }
        }
    }

    static void overlayErrorStrings(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        Object errorsObj
    ) {
        if (errorsObj instanceof List<Object>) {
            for (Object item : (List<Object>) errorsObj) {
                if (item == null) {
                    continue;
                }
                String text = String.valueOf(item);
                if (String.isNotBlank(text) && text != 'null') {
                    addConfigMessage(catalog, 'constraint', text);
                }
            }
        }
    }

    static void overlayVisibility(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        List<Object> rows
    ) {
        if (rows == null || rows.isEmpty()) {
            return;
        }
        Set<String> hiddenPicklistIds = new Set<String>();
        Set<String> disabledPrcIds = new Set<String>();
        Set<String> disabledProductIds = new Set<String>();
        for (Object row : rows) {
            Map<String, Object> raw = asObjectMap(row);
            if (raw == null) {
                continue;
            }
            String visType = asText(raw.get('type'));
            if (!isHideOrDisable(visType)) {
                continue;
            }
            String target = asText(raw.get('target'));
            String pvId = asText(raw.get('attributePicklistValueId'));
            if (String.isNotBlank(pvId)
                && (String.isBlank(target) || target.toLowerCase().contains('attribute'))) {
                hiddenPicklistIds.add(pvId);
            }
            String prcId = asText(raw.get('prcId'));
            if (String.isNotBlank(prcId)
                && (String.isBlank(target) || target.toLowerCase().contains('component')
                    || target.toLowerCase().contains('product'))) {
                disabledPrcIds.add(prcId);
            }
            addIds(disabledProductIds, raw.get('productId'));
            addIds(disabledProductIds, raw.get('productIds'));
        }
        hidePicklistOptions(catalog, hiddenPicklistIds);
        hideDisabledComponents(catalog, disabledPrcIds, disabledProductIds);
    }

    static void hidePicklistOptions(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        Set<String> hiddenPicklistIds
    ) {
        if (catalog.attributes == null || hiddenPicklistIds == null || hiddenPicklistIds.isEmpty()) {
            return;
        }
        for (RLM_RampConfiguratorAction.ConfigAttribute attr : catalog.attributes) {
            if (attr == null || attr.options == null || attr.options.isEmpty()) {
                continue;
            }
            List<RLM_RampConfiguratorAction.ConfigPicklistOption> kept =
                new List<RLM_RampConfiguratorAction.ConfigPicklistOption>();
            for (RLM_RampConfiguratorAction.ConfigPicklistOption option : attr.options) {
                if (option == null) {
                    continue;
                }
                Boolean hidden = String.isNotBlank(option.picklistValueId)
                    && hiddenPicklistIds.contains(option.picklistValueId);
                Boolean current = equalsIgnore(option.picklistValueId, attr.picklistValueId)
                    || equalsIgnore(option.value, attr.value)
                    || equalsIgnore(option.label, attr.value);
                if (hidden == true && current != true) {
                    continue;
                }
                kept.add(option);
            }
            attr.options = kept;
        }
    }

    static void hideDisabledComponents(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        Set<String> disabledPrcIds,
        Set<String> disabledProductIds
    ) {
        if (catalog.groups == null) {
            return;
        }
        Boolean noPrc = disabledPrcIds == null || disabledPrcIds.isEmpty();
        Boolean noProd = disabledProductIds == null || disabledProductIds.isEmpty();
        if (noPrc && noProd) {
            return;
        }
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : catalog.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            List<RLM_RampConfiguratorAction.ConfigComponent> kept =
                new List<RLM_RampConfiguratorAction.ConfigComponent>();
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component == null) {
                    continue;
                }
                Boolean disabled =
                    (String.isNotBlank(component.productRelatedComponentId)
                        && disabledPrcIds != null
                        && disabledPrcIds.contains(component.productRelatedComponentId))
                    || (String.isNotBlank(component.product2Id)
                        && disabledProductIds != null
                        && disabledProductIds.contains(component.product2Id));
                if (disabled != true) {
                    kept.add(component);
                    continue;
                }
                if (component.selected == true) {
                    kept.add(component);
                    String name = firstNonBlank(component.name, component.sku, 'This option');
                    addConfigMessage(
                        catalog,
                        'constraint',
                        name + ' is disabled by configuration rules.');
                }
            }
            optionGroup.components = kept;
        }
    }

    static void addConfigMessage(
        RLM_RampConfiguratorAction.ConfigResult catalog,
        String messageType,
        String text
    ) {
        if (catalog == null || String.isBlank(text)) {
            return;
        }
        if (catalog.messages == null) {
            catalog.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        }
        for (RLM_RampConfiguratorAction.ConfigMessage existing : catalog.messages) {
            if (existing != null && existing.text == text) {
                return;
            }
        }
        RLM_RampConfiguratorAction.ConfigMessage msg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        msg.messageType = String.isBlank(messageType) ? 'info' : messageType;
        msg.text = text;
        catalog.messages.add(msg);
    }

    static String messageKind(String severity) {
        if (String.isBlank(severity)) {
            return 'info';
        }
        String lower = severity.toLowerCase();
        if (lower.contains('error') || lower.contains('constraint')) {
            return 'constraint';
        }
        if (lower.contains('warn')) {
            return 'warning';
        }
        return 'info';
    }

    static Boolean isHideOrDisable(String visType) {
        if (String.isBlank(visType)) {
            return false;
        }
        String lower = visType.toLowerCase();
        return lower == 'hide' || lower == 'disable';
    }

    static void addIds(Set<String> bucket, Object raw) {
        if (bucket == null || raw == null) {
            return;
        }
        if (raw instanceof List<Object>) {
            for (Object item : (List<Object>) raw) {
                if (item != null && String.isNotBlank(String.valueOf(item))) {
                    bucket.add(String.valueOf(item));
                }
            }
            return;
        }
        String text = String.valueOf(raw);
        if (String.isNotBlank(text) && text != 'null') {
            bucket.add(text);
        }
    }

    static List<Object> asObjectList(Object raw) {
        return raw instanceof List<Object> ? (List<Object>) raw : new List<Object>();
    }

    static Map<String, Object> asObjectMap(Object raw) {
        return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : null;
    }

    static String asText(Object raw) {
        if (raw == null) {
            return null;
        }
        String text = String.valueOf(raw);
        return text == 'null' ? null : text;
    }

    @TestVisible
    static String recapEngineChanges(
        RLM_RampConfiguratorAction.ConfigResult requested,
        RLM_RampConfiguratorAction.ConfigResult saved
    ) {
        List<String> changes = new List<String>();
        Map<String, String> requestedAttrs = attributeValues(requested);
        Map<String, String> savedAttrs = attributeValues(saved);
        Set<String> attrKeys = new Set<String>();
        attrKeys.addAll(requestedAttrs.keySet());
        attrKeys.addAll(savedAttrs.keySet());
        List<String> attrNames = new List<String>(attrKeys);
        attrNames.sort();
        for (String key : attrNames) {
            String before = requestedAttrs.get(key);
            String afterVal = savedAttrs.get(key);
            if (before == afterVal || (String.isBlank(before) && String.isBlank(afterVal))) {
                continue;
            }
            changes.add(
                '- ' + key + ': '
                + (String.isBlank(before) ? '(not set)' : before)
                + ' → '
                + (String.isBlank(afterVal) ? '(not set)' : afterVal)
            );
        }
        Map<String, Decimal> requestedQty = selectedQuantities(requested);
        Map<String, Decimal> savedQty = selectedQuantities(saved);
        Set<String> componentKeys = new Set<String>();
        componentKeys.addAll(requestedQty.keySet());
        componentKeys.addAll(savedQty.keySet());
        List<String> componentNames = new List<String>(componentKeys);
        componentNames.sort();
        for (String key : componentNames) {
            Boolean had = requestedQty.containsKey(key);
            Boolean hasNow = savedQty.containsKey(key);
            if (had && !hasNow) {
                changes.add('- Removed ' + key);
                continue;
            }
            if (!had && hasNow) {
                Decimal qty = savedQty.get(key);
                changes.add(
                    '- Added ' + key
                    + (qty != null && qty != 1 ? ' qty ' + String.valueOf(qty) : '')
                );
                continue;
            }
            Decimal beforeQty = requestedQty.get(key);
            Decimal afterQty = savedQty.get(key);
            if (beforeQty != afterQty) {
                changes.add(
                    '- ' + key + ' qty ' + String.valueOf(beforeQty)
                    + ' → ' + String.valueOf(afterQty)
                );
            }
        }
        if (changes.isEmpty()) {
            return null;
        }
        return 'Configurator updated the mix:\n' + String.join(changes, '\n');
    }

    static String joinRecaps(String first, String second) {
        if (String.isBlank(first)) {
            return String.isBlank(second) ? null : second;
        }
        if (String.isBlank(second)) {
            return first;
        }
        String suffix = second;
        if (suffix.startsWith('Configurator updated the mix:\n')) {
            suffix = suffix.substring('Configurator updated the mix:\n'.length());
        }
        return first + '\n' + suffix;
    }

    static Map<String, String> attributeValues(RLM_RampConfiguratorAction.ConfigResult config) {
        Map<String, String> values = new Map<String, String>();
        if (config == null || config.attributes == null) {
            return values;
        }
        for (RLM_RampConfiguratorAction.ConfigAttribute attr : config.attributes) {
            if (attr == null) {
                continue;
            }
            String label = firstNonBlank(attr.label, attr.attributeName, attr.attributeKey);
            if (String.isBlank(label)) {
                continue;
            }
            values.put(label, attr.value);
        }
        return values;
    }

    static Map<String, Decimal> selectedQuantities(RLM_RampConfiguratorAction.ConfigResult config) {
        Map<String, Decimal> quantities = new Map<String, Decimal>();
        if (config == null || config.groups == null) {
            return quantities;
        }
        for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : config.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                if (component == null || component.selected != true) {
                    continue;
                }
                String name = firstNonBlank(component.name, component.sku, component.product2Id);
                if (String.isBlank(name)) {
                    continue;
                }
                quantities.put(name, component.quantity == null ? 1 : component.quantity);
            }
        }
        return quantities;
    }

    static String firstNonBlank(String a, String b) {
        return firstNonBlank(a, b, null);
    }

    static String firstNonBlank(String a, String b, String c) {
        if (String.isNotBlank(a)) {
            return a;
        }
        if (String.isNotBlank(b)) {
            return b;
        }
        return c;
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
        rows.add('Multiple bundle lines match. Pass quoteLineItemId for the year to configure.');
        Integer ordinal = 1;
        for (QuoteLineItem line : lines) {
            String name = line.Product2 == null ? 'Line' : line.Product2.Name;
            String sku = line.Product2 == null ? null : line.Product2.StockKeepingUnit;
            String row = ordinal + '. **' + name + '**';
            if (String.isNotBlank(sku)) {
                row += ' (' + sku + ')';
            }
            if (line.QuoteLineGroup != null && String.isNotBlank(line.QuoteLineGroup.Name)) {
                row += ' on ' + line.QuoteLineGroup.Name;
            }
            row += ' — quoteLineItemId ' + String.valueOf(line.Id);
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

    @TestVisible
    static Boolean isCreLoading(RLM_RampConfiguratorAction.ConfigResult result) {
        return result != null
            && result.success != true
            && result.message == RLM_RampConfiguratorAction.CRE_LOADING;
    }

    static void markCreLoading(Response out, String lineId) {
        if (out == null) {
            return;
        }
        out.isSuccess = false;
        out.needsAction = true;
        out.quoteLineItemId = lineId;
        RLM_RampConfiguratorAction.ConfigResult loading =
            new RLM_RampConfiguratorAction.ConfigResult();
        loading.success = false;
        loading.message = RLM_RampConfiguratorAction.CRE_LOADING;
        RLM_RampConfiguratorAction.attachFixGuidance(loading);
        String fix = formatFixThis(loading);
        out.errorMessage = String.isNotBlank(fix)
            ? fix
            : 'Lightning CRE is loading. Call this tool again immediately with quoteLineItemId '
                + lineId
                + '. Do not query QuoteLineItem children. Do not invent Dual, Gold, or Socket. Do not PDF or email.';
    }

    static void applyFixError(
        Response out,
        RLM_RampConfiguratorAction.ConfigResult result,
        String fallback
    ) {
        if (out == null) {
            return;
        }
        if (result != null && String.isBlank(result.fixHeadline)) {
            RLM_RampConfiguratorAction.attachFixGuidance(result);
        }
        applyCoach(out, result);
        String coach = result == null ? null : result.constraintCoachDisplay;
        String fix = formatFixThis(result);
        if (String.isNotBlank(coach)) {
            out.errorMessage = coach;
        } else {
            out.errorMessage = String.isNotBlank(fix) ? fix : fallback;
        }
    }

    static void applyCoach(
        Response out,
        RLM_RampConfiguratorAction.ConfigResult config
    ) {
        if (out == null) {
            return;
        }
        out.constraintCoachDisplay = config == null ? null : config.constraintCoachDisplay;
    }

    @TestVisible
    static String formatFixThis(RLM_RampConfiguratorAction.ConfigResult config) {
        if (config == null || String.isBlank(config.fixHeadline)) {
            return null;
        }
        List<String> lines = new List<String>{ '### Fix this', config.fixHeadline };
        if (config.fixSteps != null) {
            for (String step : config.fixSteps) {
                if (String.isNotBlank(step)) {
                    lines.add('- ' + step);
                }
            }
        }
        return String.join(lines, '\n');
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

    private static Id toQuoteLineItemId(String raw) {
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == QuoteLineItem.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible
    static Boolean hasChildren(Id quoteId, Id parentId) {
        if (quoteId == null || parentId == null) {
            return false;
        }
        return [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND ParentQuoteLineItemId = :parentId
            WITH USER_MODE
            LIMIT 1
        ].size() > 0;
    }

    @TestVisible
    static Boolean isConfigurable(RLM_RampConfiguratorAction.ConfigResult config) {
        if (config == null) {
            return false;
        }
        if (config.groups != null && !config.groups.isEmpty()) {
            return true;
        }
        return config.attributes != null && !config.attributes.isEmpty();
    }

    @TestVisible
    static Boolean hasBlockingIssues(RLM_RampConfiguratorAction.ConfigResult config) {
        return hasBlockingIssues(config, null);
    }

    @TestVisible
    static Boolean hasBlockingIssues(
        RLM_RampConfiguratorAction.ConfigResult config,
        Set<String> confirmedAttributeKeys
    ) {
        if (config == null) {
            return false;
        }
        if (String.isBlank(config.fixHeadline)) {
            RLM_RampConfiguratorAction.attachFixGuidance(config);
        }
        if (config.fixKind == 'change_picks' || config.fixKind == 'platform') {
            return true;
        }
        if (config.messages != null) {
            for (RLM_RampConfiguratorAction.ConfigMessage msg : config.messages) {
                if (msg == null || String.isBlank(msg.text)) {
                    continue;
                }
                String kind = String.isBlank(msg.messageType) ? '' : msg.messageType.toLowerCase();
                if (kind == 'error' || kind == 'constraint' || kind.contains('error')) {
                    return true;
                }
            }
        }
        if (config.groups != null) {
            for (RLM_RampConfiguratorAction.ConfigGroup optionGroup : config.groups) {
                if (optionGroup == null || optionGroup.components == null) {
                    continue;
                }
                for (RLM_RampConfiguratorAction.ConfigComponent component : optionGroup.components) {
                    if (component != null && component.required == true && component.selected != true) {
                        return true;
                    }
                }
            }
        }
        if (config.attributes != null) {
            for (RLM_RampConfiguratorAction.ConfigAttribute attr : config.attributes) {
                if (attr == null) {
                    continue;
                }
                Boolean mustHaveValue = attr.required == true || attr.priceImpacting == true;
                if (!mustHaveValue) {
                    continue;
                }
                if (String.isBlank(attr.value) && String.isBlank(attr.picklistValueId)) {
                    return true;
                }
                if (attr.priceImpacting == true
                    && confirmedAttributeKeys != null
                    && !attributeIsConfirmed(attr, confirmedAttributeKeys)) {
                    return true;
                }
            }
        }
        return false;
    }

    static Set<String> confirmedAttributeKeys(String raw) {
        Map<String, String> values = parseStringMap(raw);
        Set<String> keys = new Set<String>();
        if (values == null) {
            return keys;
        }
        for (String key : values.keySet()) {
            if (String.isNotBlank(key)) {
                keys.add(key.trim().toLowerCase());
            }
        }
        return keys;
    }

    static Boolean attributeIsConfirmed(
        RLM_RampConfiguratorAction.ConfigAttribute attr,
        Set<String> confirmedAttributeKeys
    ) {
        if (attr == null || confirmedAttributeKeys == null || confirmedAttributeKeys.isEmpty()) {
            return false;
        }
        List<String> names = new List<String>{ attr.label, attr.attributeName, attr.attributeKey };
        for (String name : names) {
            if (String.isNotBlank(name) && confirmedAttributeKeys.contains(name.trim().toLowerCase())) {
                return true;
            }
        }
        return false;
    }

    private static String copyToRampSiblings(
        Quote quote,
        QuoteLineItem source,
        String selectionJson
    ) {
        if (quote == null || source == null || source.Product2Id == null
            || String.isBlank(selectionJson)) {
            return null;
        }
        List<QuoteLineItem> candidates = [
            SELECT Id, QuoteLineGroup.Name, QuoteLineGroup.IsRamped, Product2Id
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            AND Product2Id = :source.Product2Id
            AND ParentQuoteLineItemId = null
            AND Id != :source.Id
            WITH USER_MODE
            LIMIT 20
        ];
        List<QuoteLineItem> siblings = new List<QuoteLineItem>();
        Set<Id> siblingIds = new Set<Id>();
        for (QuoteLineItem candidate : candidates) {
            if (candidate.QuoteLineGroup == null || candidate.QuoteLineGroup.IsRamped != true) {
                continue;
            }
            siblings.add(candidate);
            siblingIds.add(candidate.Id);
        }
        if (siblings.isEmpty()) {
            return null;
        }
        Set<Id> configured = new Set<Id>();
        for (QuoteLineItem child : [
            SELECT ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            AND ParentQuoteLineItemId IN :siblingIds
            WITH USER_MODE
            LIMIT 200
        ]) {
            configured.add(child.ParentQuoteLineItemId);
        }
        Set<Id> attributed = new Set<Id>();
        for (QuoteLineItemAttribute qlia : [
            SELECT QuoteLineItemId
            FROM QuoteLineItemAttribute
            WHERE QuoteLineItemId IN :siblingIds
            WITH USER_MODE
            LIMIT 200
        ]) {
            attributed.add(qlia.QuoteLineItemId);
        }
        List<String> copied = new List<String>();
        List<String> failed = new List<String>();
        for (QuoteLineItem sibling : siblings) {
            if (siblingAlreadyHasCopiedGraph(sibling.Id, configured, attributed)) {
                continue;
            }
            String yearName = sibling.QuoteLineGroup == null
                || String.isBlank(sibling.QuoteLineGroup.Name)
                ? 'another year' : sibling.QuoteLineGroup.Name;
            RLM_RampConfiguratorAction.ConfigResult saved = engine.save(
                String.valueOf(quote.Id),
                String.valueOf(sibling.Id),
                selectionJson
            );
            if (saved != null && saved.success == true) {
                copied.add(yearName);
            } else {
                String why = saved == null || String.isBlank(saved.message)
                    ? 'save failed' : saved.message;
                failed.add(yearName + ' (' + why + ')');
            }
        }
        if (copied.isEmpty() && failed.isEmpty()) {
            return null;
        }
        List<String> recap = new List<String>();
        if (!copied.isEmpty()) {
            recap.add('Same mix copied to ' + String.join(copied, ', ') + '.');
        }
        if (!failed.isEmpty()) {
            recap.add('Could not copy to ' + String.join(failed, '; ') + '.');
        }
        recap.add('If they asked for a different mix per year, describe that year’s quoteLineItemId instead.');
        return String.join(recap, ' ');
    }

    @TestVisible
    static Boolean siblingAlreadyHasCopiedGraph(
        Id siblingId,
        Set<Id> configured,
        Set<Id> attributed
    ) {
        return siblingId != null
            && configured != null
            && attributed != null
            && configured.contains(siblingId)
            && attributed.contains(siblingId);
    }
}
