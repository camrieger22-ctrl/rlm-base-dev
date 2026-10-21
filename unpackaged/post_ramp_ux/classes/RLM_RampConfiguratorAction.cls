/**
 * Ramp-native bundle add-on panel. Loads option groups and attributes from
 * Configurator configure, and writes picks through the same API so constraint
 * and bundle-validation rules still run.
 */
public with sharing class RLM_RampConfiguratorAction {

    private static final String API_VERSION = 'v67.0';
    private static final String CONFIGURE_PATH =
        '/services/data/' + API_VERSION + '/connect/cpq/configurator/actions/configure';
    @TestVisible
    static final String LOOPBACK_NAMED_CREDENTIAL = 'RLM_SalesforceLoopback';
    public static final String CRE_LOADING = 'CRE_LOADING';
    @TestVisible
    static final String DUAL_GOLD_FIX =
        'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.';
    @TestVisible
    static final String SINGLE_WORKLOAD_FIX =
        'Socket is Single and Workload is not General. Set Workload to General, or switch Socket back to Dual.';
    @TestVisible
    static final String SINGLE_DUAL_QTY_FIX =
        'Socket is Single but the rack still has two CPUs or two liquid coolers. Set each to quantity 1, or switch Socket back to Dual.';
    @TestVisible
    static final String SINGLE_GPU_FIX =
        'Socket is Single but a Dual-only GPU is still on the rack. Remove the GPU, or switch Socket back to Dual.';
    @TestVisible
    static Boolean forceAsyncConfigure = false;
    /**
     * Hosted MCP describe/configure must never Http.send in the tool
     * transaction. Lightning Aura keeps session HTTP; MCP sets this flag.
     */
    public static Boolean queueConfigureCallout = false;
    public static final String CRE_LOAD_TASK_SUBJECT = 'RLM_CRE_LOAD';
    static final Integer CACHE_PENDING_SECONDS = 120;

    public class ConfigResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String quoteLineItemId;
        @AuraEnabled public String transactionContextId;
        @AuraEnabled public List<ConfigGroup> groups;
        @AuraEnabled public List<ConfigAttribute> attributes;
        @AuraEnabled public List<ConfigMessage> messages;
        @AuraEnabled public String fixKind;
        @AuraEnabled public String fixHeadline;
        @AuraEnabled public List<String> fixSteps;
    }

    public class ConfigGroup {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public Integer minComponents;
        @AuraEnabled public Integer maxComponents;
        @AuraEnabled public String selectionMode;
        @AuraEnabled public String rangeLabel;
        @AuraEnabled public List<ConfigComponent> components;
    }

    public class ConfigComponent {
        @AuraEnabled public String product2Id;
        @AuraEnabled public String name;
        @AuraEnabled public String sku;
        @AuraEnabled public String description;
        @AuraEnabled public String displayUrl;
        @AuraEnabled public Boolean required;
        @AuraEnabled public Boolean defaulted;
        @AuraEnabled public Boolean quantityEditable;
        @AuraEnabled public Boolean selected;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public String pricebookEntryId;
        @AuraEnabled public String productSellingModelId;
        @AuraEnabled public String sellingModelName;
        @AuraEnabled public String sellingModelType;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String productRelatedComponentId;
        @AuraEnabled public String productRelationshipTypeId;
        @AuraEnabled public Boolean includedInBundle;
        @AuraEnabled public Boolean hidden;
        @AuraEnabled public Boolean disabled;
        @AuraEnabled public String quoteLineItemId;
        @AuraEnabled public List<ConfigSellingModel> sellingModels;
    }

    public class ConfigSellingModel {
        @AuraEnabled public String pricebookEntryId;
        @AuraEnabled public String productSellingModelId;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Boolean isDefault;
    }

    public class ConfigAttribute {
        @AuraEnabled public String attributeKey;
        @AuraEnabled public String attributeName;
        @AuraEnabled public String attributeRecordId;
        @AuraEnabled public String label;
        @AuraEnabled public String dataType;
        @AuraEnabled public String value;
        @AuraEnabled public String picklistValueId;
        @AuraEnabled public Boolean required;
        @AuraEnabled public Boolean priceImpacting;
        @AuraEnabled public List<ConfigPicklistOption> options;
    }

    public class ConfigPicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String picklistValueId;
    }

    public class ConfigMessage {
        @AuraEnabled public String messageType;
        @AuraEnabled public String category;
        @AuraEnabled public String text;
    }

    public class Selection {
        public List<ConfigComponent> components;
        public List<ConfigAttribute> attributes;
        public String transactionContextId;
    }

    /**
     * Hosted MCP describe path: never Http.send, enqueueJob, getContent,
     * EventBus.publish, or Task DML that enqueues in this transaction.
     * Those throw uncatchable Script-thrown and roll back CRE_LOADING.
     * Read cache if Configure finished; otherwise upsert a Pending cache
     * row. A record-triggered Flow async path enqueues Configure after
     * this commits.
     */
    public static ConfigResult loadConfigurationForMcp(String quoteId, String quoteLineItemId) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return finish(out);
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return finish(out);
        }
        out.quoteLineItemId = String.valueOf(lineId);
        try {
            ConfigResult cached = readConfigureCacheByLine(lineId);
            if (cached != null) {
                if (cached.success == true) {
                    cached.groups = markSelectedFromChildren(
                        cached.groups, queryChildren(qId, lineId));
                    return finish(cached);
                }
                return cached;
            }
        } catch (Exception e) {
            // Cache read must not fail the tool; still ask Claude to retry.
        }
        try {
            requestConfigureViaCache(qId, lineId);
        } catch (Exception e) {
            // Cache DML is best-effort. Always return CRE_LOADING so Hosted
            // MCP gets a catchable tool result instead of UNKNOWN_EXCEPTION.
        }
        out.message = CRE_LOADING;
        return finish(out);
    }

    @AuraEnabled
    public static ConfigResult loadConfiguration(String quoteId, String quoteLineItemId) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return out;
        }
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        if (owned == null) {
            out.message = 'That line is not on this quote.';
            return out;
        }
        Map<String, QuoteLineItem> childrenByProduct = queryChildren(qId, lineId);
        Map<String, Object> body = baseConfigureBody(
            qId,
            lineId,
            childrenByProduct.isEmpty(),
            quoteAccountId(owned),
            null
        );
        try {
            if (!canSyncConfigureCallout()) {
                return cachedOrEnqueueConfigure(qId, lineId, body);
            }
            Map<String, Object> response = postConfigure(body);
            return parseConfiguration(
                response, qId, lineId, queryChildren(qId, lineId));
        } catch (Exception e) {
            out.message = e.getMessage();
            return finish(out);
        }
    }

    /**
     * Headless Lightning Configure attribute mutation: POST configure with
     * executeConfigurationRules=true and updatedNodes, 0 DML. Hosted MCP
     * persists the returned CRE graph through Place Sales Transaction.
     */
    public static ConfigResult applyConfigurationAttributes(
        String quoteId,
        String quoteLineItemId,
        Map<String, String> attributeValues
    ) {
        ConfigResult loaded = loadConfiguration(quoteId, quoteLineItemId);
        if (loaded == null || loaded.success != true) {
            return loaded;
        }
        if (attributeValues == null || attributeValues.isEmpty()) {
            return loaded;
        }
        String applyError = applyAttributeValueMap(loaded, attributeValues);
        if (applyError != null) {
            loaded.success = false;
            loaded.message = applyError;
            return finish(loaded);
        }
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        Map<String, QuoteLineItem> childrenByProduct = queryChildren(qId, lineId);
        Selection selection = selectionFromResult(loaded, null);
        Map<String, Object> body = baseConfigureBody(
            qId,
            lineId,
            false,
            quoteAccountId(owned),
            loaded.transactionContextId
        );
        List<Object> added = buildAddedAttributeNodes(qId, lineId, selection);
        if (!added.isEmpty()) {
            body.put('addedNodes', added);
        }
        body.put('updatedNodes', buildUpdatedNodes(qId, lineId, selection, childrenByProduct));
        try {
            if (!canSyncConfigureCallout()) {
                return cachedOrEnqueueConfigure(qId, lineId, body);
            }
            Map<String, Object> response = postConfigure(body);
            return parseConfiguration(response, qId, lineId, queryChildren(qId, lineId));
        } catch (Exception e) {
            loaded.success = false;
            loaded.message = e.getMessage();
            return finish(loaded);
        }
    }

    /**
     * Hosted MCP attribute apply: never Http.send, enqueueJob, or
     * EventBus.publish. Queue the Dual/attribute configure body on the
     * Pending cache row so the Flow async path POSTs it after commit.
     */
    public static ConfigResult applyConfigurationAttributesForMcp(
        String quoteId,
        String quoteLineItemId,
        Map<String, String> attributeValues
    ) {
        ConfigResult loaded = loadConfigurationForMcp(quoteId, quoteLineItemId);
        if (loaded == null || loaded.success != true) {
            return loaded;
        }
        if (attributeValues == null || attributeValues.isEmpty()) {
            return loaded;
        }
        if (attributesAlreadyApplied(loaded, attributeValues)) {
            return loaded;
        }
        String applyError = applyAttributeValueMap(loaded, attributeValues);
        if (applyError != null) {
            loaded.success = false;
            loaded.message = applyError;
            return finish(loaded);
        }
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        Map<String, QuoteLineItem> childrenByProduct = queryChildren(qId, lineId);
        Selection selection = selectionFromResult(loaded, null);
        Map<String, Object> body = baseConfigureBody(
            qId,
            lineId,
            false,
            quoteAccountId(owned),
            loaded.transactionContextId
        );
        List<Object> added = buildAddedAttributeNodes(qId, lineId, selection);
        if (!added.isEmpty()) {
            body.put('addedNodes', added);
        }
        body.put('updatedNodes', buildUpdatedNodes(qId, lineId, selection, childrenByProduct));
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        out.quoteLineItemId = String.valueOf(lineId);
        try {
            requestConfigureViaCache(qId, lineId, JSON.serialize(body));
        } catch (Exception e) {
            // Always return CRE_LOADING so Hosted MCP stays catchable.
        }
        out.message = CRE_LOADING;
        return finish(out);
    }

    public static ConfigResult persistMcpConfiguration(
        String quoteId,
        String quoteLineItemId,
        String selectionJson
    ) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return out;
        }
        Selection selection = parseSelection(selectionJson);
        if (selection == null) {
            out.message = 'Add-on selection is required.';
            return out;
        }
        try {
            String persistError = persistSelectionPreferringSystem(
                qId, lineId, selection, queryChildren(qId, lineId), true);
            ConfigResult cached = readConfigureCacheByLine(lineId);
            ConfigResult loaded = loadCatalogConfiguration(quoteId, quoteLineItemId);
            if (loaded != null && loaded.success == true) {
                applySelectionAttributeValues(loaded, selection);
                loaded.groups = markSelectedFromChildren(
                    loaded.groups, queryChildren(qId, lineId));
                mergeConfigureMessages(loaded, cached);
                if (persistError != null) {
                    loaded.success = false;
                    loaded.message = persistError;
                } else {
                    loaded.success = true;
                    loaded.message = 'Bundle picks saved.';
                }
                loaded = finish(loaded);
                writeConfigureCache(lineId, loaded);
                return loaded;
            }
            if (cached != null && cached.success == true) {
                cached.groups = markSelectedFromChildren(
                    cached.groups, queryChildren(qId, lineId));
                if (persistError != null) {
                    cached.success = false;
                    cached.message = persistError;
                }
                return finish(cached);
            }
            if (persistError != null) {
                out.message = persistError;
                return finish(out);
            }
            out.success = true;
            out.quoteLineItemId = String.valueOf(lineId);
            out.message = 'Bundle picks saved.';
            return finish(out);
        } catch (Exception e) {
            out.message = e.getMessage();
            return finish(out);
        }
    }

    @AuraEnabled
    public static ConfigResult saveConfiguration(
        String quoteId,
        String quoteLineItemId,
        String selectionJson
    ) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return out;
        }
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        if (owned == null) {
            out.message = 'That line is not on this quote.';
            return out;
        }
        Selection selection = parseSelection(selectionJson);
        if (selection == null) {
            out.message = 'Add-on selection is required.';
            return out;
        }
        Map<String, QuoteLineItem> childrenByProduct = queryChildren(qId, lineId);
        Map<String, Object> body = baseConfigureBody(
            qId,
            lineId,
            false,
            quoteAccountId(owned),
            selection.transactionContextId
        );
        List<Object> added = buildAddedNodes(qId, lineId, selection.components, childrenByProduct);
        added.addAll(buildAddedAttributeNodes(qId, lineId, selection));
        body.put('addedNodes', added);
        body.put('deletedNodes', buildDeletedNodes(qId, selection.components, childrenByProduct));
        body.put('updatedNodes', buildUpdatedNodes(qId, lineId, selection, childrenByProduct));
        try {
            Map<String, Object> response = postConfigure(body);
            ConfigResult parsed = parseConfiguration(response, qId, lineId, queryChildren(qId, lineId));
            if (parsed.success == true) {
                return afterSuccessfulConfigure(
                    parsed, qId, lineId, selection, childrenByProduct, quoteAccountId(owned));
            }
            if (!looksLikeInvalidAttribute(parsed.message) || selection.attributes == null
                || selection.attributes.isEmpty()) {
                return parsed;
            }
            body.put('addedNodes', buildAddedNodes(qId, lineId, selection.components, childrenByProduct));
            body.put('updatedNodes', buildQuantityUpdates(qId, selection.components, childrenByProduct));
            Map<String, Object> retry = postConfigure(body);
            ConfigResult retried = parseConfiguration(retry, qId, lineId, queryChildren(qId, lineId));
            if (retried.success == true) {
                retried = afterSuccessfulConfigure(
                    retried, qId, lineId, selection, childrenByProduct, quoteAccountId(owned));
            }
            retried.message = (retried.success == true ? 'Add-ons saved. ' : '')
                + 'Attributes were not saved: ' + parsed.message;
            return retried;
        } catch (Exception e) {
            if (selection.attributes != null && !selection.attributes.isEmpty()) {
                try {
                    body.put('addedNodes', buildAddedNodes(
                        qId, lineId, selection.components, childrenByProduct));
                    body.put('updatedNodes', buildQuantityUpdates(
                        qId, selection.components, childrenByProduct));
                    Map<String, Object> retry = postConfigure(body);
                    ConfigResult parsed = parseConfiguration(
                        retry, qId, lineId, queryChildren(qId, lineId));
                    if (parsed.success == true) {
                        parsed = afterSuccessfulConfigure(
                            parsed, qId, lineId, selection, childrenByProduct, quoteAccountId(owned));
                    }
                    parsed.message = (parsed.success == true ? 'Add-ons saved. ' : '')
                        + 'Attributes were not saved: ' + e.getMessage();
                    return parsed;
                } catch (Exception retryError) {
                    out.message = retryError.getMessage();
                    return out;
                }
            }
            out.message = e.getMessage();
            return out;
        }
    }

    /**
     * Catalog-backed load for Hosted MCP and other API invocables that cannot
     * call Configurator HTTP. Option groups come from ProductComponentGroup /
     * ProductRelatedComponent; current picks come from child quote lines.
     * Constraint Rules Engine is not invoked on load. Persist tries Place
     * Sales Transaction SYSTEM configuration first and falls back to SKIP
     * when that path throws ConfiguratorException, then runConfigRules
     * overlays hide/disable in the Hosted MCP engine.
     */
    public static ConfigResult loadCatalogConfiguration(String quoteId, String quoteLineItemId) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return out;
        }
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        if (owned == null) {
            out.message = 'That line is not on this quote.';
            return out;
        }
        if (owned.Product2Id == null) {
            out.message = 'That line has no product.';
            return out;
        }
        try {
            out.quoteLineItemId = String.valueOf(lineId);
            out.groups = buildCatalogGroups(
                owned.Product2Id,
                owned.Quote == null ? null : owned.Quote.Pricebook2Id,
                queryChildren(qId, lineId)
            );
            out.attributes = loadCatalogAttributes(owned.Product2Id, lineId);
            overlayPriceImpacting(out.attributes, owned.Product2Id);
            out.success = true;
            out.message = 'Loaded bundle options from the product catalog.';
            return out;
        } catch (Exception e) {
            out.success = false;
            out.message = e.getMessage();
            return out;
        }
    }

    public static ConfigResult saveCatalogConfiguration(
        String quoteId,
        String quoteLineItemId,
        String selectionJson
    ) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        Id qId = toId(quoteId);
        Id lineId = toId(quoteLineItemId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        if (lineId == null) {
            out.message = 'Quote line is required.';
            return out;
        }
        QuoteLineItem owned = queryOwnedLine(qId, lineId);
        if (owned == null) {
            out.message = 'That line is not on this quote.';
            return out;
        }
        Selection selection = parseSelection(selectionJson);
        if (selection == null) {
            out.message = 'Add-on selection is required.';
            return out;
        }
        Map<String, QuoteLineItem> childrenByProduct = queryChildren(qId, lineId);
        try {
            String persistError = persistSelectionPreferringSystem(
                qId, lineId, selection, childrenByProduct, true);
            ConfigResult loaded = loadCatalogConfiguration(quoteId, quoteLineItemId);
            applySelectionAttributeValues(loaded, selection);
            if (persistError != null) {
                loaded.success = false;
                loaded.message = persistError;
                return loaded;
            }
            loaded.success = true;
            loaded.message = 'Bundle picks saved.';
            invalidateConfigureCache(lineId);
            return loaded;
        } catch (Exception e) {
            out.message = e.getMessage();
            return out;
        }
    }

    @TestVisible
    static ConfigResult parseConfiguration(
        Map<String, Object> response,
        Id quoteId,
        Id lineId,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        ConfigResult out = new ConfigResult();
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        out.quoteLineItemId = lineId == null ? null : String.valueOf(lineId);
        if (response == null) {
            out.success = false;
            out.message = 'Configurator returned no response.';
            return finish(out);
        }
        out.transactionContextId = asString(response.get('transactionContextId'));
        out.messages = parseMessages(response.get('messages'));
        Map<String, Object> catalogProduct = firstCatalogProduct(response.get('catalogProducts'));
        Map<String, ConfigAttribute> contextAttributes = attributesFromContext(
            response.get('transactionContext'), lineId);
        Boolean hasChildren = childrenByProduct != null && !childrenByProduct.isEmpty();
        out.groups = parseGroups(catalogProduct, childrenByProduct, hasChildren);
        overlayCreSelections(out.groups, response.get('transactionContext'), lineId);
        out.attributes = parseAttributes(catalogProduct, contextAttributes);
        overlayPriceImpacting(
            out.attributes,
            catalogProduct == null ? null : toId(asString(catalogProduct.get('id'))));
        Boolean ok = response.get('success') == true;
        if (!ok) {
            out.success = false;
            out.message = firstError(response.get('errors'));
            if (String.isBlank(out.message) && !out.messages.isEmpty()) {
                out.message = out.messages[0].text;
            }
            if (String.isBlank(out.message)) {
                out.message = 'Configurator could not load this bundle.';
            }
            return finish(out);
        }
        out.success = true;
        return finish(out);
    }

    @TestVisible
    static List<ConfigGroup> parseGroups(
        Map<String, Object> catalogProduct,
        Map<String, QuoteLineItem> childrenByProduct,
        Boolean hasChildren
    ) {
        List<ConfigGroup> groups = new List<ConfigGroup>();
        if (catalogProduct == null) {
            return groups;
        }
        collectLeafGroups(
            catalogProduct.get('productComponentGroups'),
            groups,
            childrenByProduct,
            hasChildren
        );
        return groups;
    }

    static void collectLeafGroups(
        Object groupsObj,
        List<ConfigGroup> groups,
        Map<String, QuoteLineItem> childrenByProduct,
        Boolean hasChildren
    ) {
        if (!(groupsObj instanceof List<Object>)) {
            return;
        }
        for (Object item : (List<Object>) groupsObj) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> raw = (Map<String, Object>) item;
            ConfigGroup optionGroup = new ConfigGroup();
            optionGroup.id = asString(raw.get('id'));
            optionGroup.name = decodeName(asString(raw.get('name')));
            optionGroup.code = asString(raw.get('code'));
            optionGroup.minComponents = asInteger(raw.get('minBundleComponents'));
            optionGroup.maxComponents = asInteger(raw.get('maxBundleComponents'));
            optionGroup.selectionMode = optionGroup.maxComponents == 1 ? 'single' : 'multiple';
            optionGroup.rangeLabel = rangeLabel(optionGroup.minComponents, optionGroup.maxComponents);
            optionGroup.components = parseComponents(
                raw.get('components'),
                childrenByProduct,
                hasChildren,
                optionGroup.selectionMode
            );
            if (optionGroup.components != null && !optionGroup.components.isEmpty()) {
                groups.add(optionGroup);
            }
            collectLeafGroups(
                firstNonNull(raw.get('childGroups'), raw.get('productComponentGroups')),
                groups,
                childrenByProduct,
                hasChildren
            );
        }
    }

    static Object firstNonNull(Object a, Object b) {
        return a != null ? a : b;
    }

    @TestVisible
    static List<ConfigComponent> parseComponents(
        Object componentsObj,
        Map<String, QuoteLineItem> childrenByProduct,
        Boolean hasChildren,
        String selectionMode
    ) {
        List<ConfigComponent> components = new List<ConfigComponent>();
        if (!(componentsObj instanceof List<Object>)) {
            return components;
        }
        for (Object item : (List<Object>) componentsObj) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> raw = (Map<String, Object>) item;
            ConfigComponent component = new ConfigComponent();
            component.product2Id = asString(raw.get('id'));
            component.name = asString(raw.get('name'));
            component.sku = asString(raw.get('productCode'));
            component.description = asString(raw.get('description'));
            component.displayUrl = asString(raw.get('displayUrl'));
            component.required = raw.get('isComponentRequired') == true;
            component.defaulted = raw.get('isDefaultComponent') == true;
            component.hidden = raw.get('isHidden') == true;
            component.disabled = raw.get('isDisabled') == true;
            component.quantityEditable = raw.get('isQuantityEditable') != false;
            Map<String, Object> prc = asMap(raw.get('productRelatedComponent'));
            if (prc != null) {
                component.productRelatedComponentId = asString(prc.get('id'));
                component.productRelationshipTypeId = asString(prc.get('productRelationshipTypeId'));
                component.includedInBundle = prc.get('doesBundlePriceIncludeChild') == true;
                component.quantity = asDecimal(prc.get('quantity'));
                if (prc.get('isComponentRequired') == true) {
                    component.required = true;
                }
                if (prc.get('isDefaultComponent') == true) {
                    component.defaulted = true;
                }
                if (prc.get('isQuantityEditable') == false) {
                    component.quantityEditable = false;
                }
            }
            if (component.quantity == null || component.quantity <= 0) {
                component.quantity = 1;
            }
            component.sellingModels = parseComponentPrices(raw.get('prices'));
            applyPrice(component, null);
            QuoteLineItem existing = childrenByProduct == null
                ? null
                : childrenByProduct.get(component.product2Id);
            if (existing != null) {
                component.selected = true;
                component.quoteLineItemId = existing.Id;
                if (existing.Quantity != null) {
                    component.quantity = existing.Quantity;
                }
                applyPrice(component, existing);
            } else if (hasChildren == true) {
                component.selected = component.required == true;
            } else {
                component.selected = component.required == true || component.defaulted == true;
            }
            components.add(component);
        }
        return components;
    }

    @TestVisible
    static void overlayCreSelections(
        List<ConfigGroup> groups,
        Object transactionContext,
        Id parentLineId
    ) {
        if (groups == null || groups.isEmpty()) {
            return;
        }
        Map<String, Decimal> qtyByProduct = quantitiesFromContext(transactionContext, parentLineId);
        if (qtyByProduct.isEmpty()) {
            return;
        }
        for (ConfigGroup optionGroup : groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (ConfigComponent component : optionGroup.components) {
                if (component == null || String.isBlank(component.product2Id)) {
                    continue;
                }
                if (!qtyByProduct.containsKey(component.product2Id)) {
                    if (component.required != true) {
                        component.selected = false;
                    }
                    continue;
                }
                Decimal qty = qtyByProduct.get(component.product2Id);
                if (qty == null || qty <= 0) {
                    component.selected = false;
                    component.hidden = component.hidden == true;
                    continue;
                }
                component.selected = true;
                component.quantity = qty;
            }
        }
    }

    static Map<String, Decimal> quantitiesFromContext(Object contextObj, Id parentLineId) {
        Map<String, Decimal> qtyByProduct = new Map<String, Decimal>();
        Map<String, Object> context = asMap(contextObj);
        if (context == null) {
            return qtyByProduct;
        }
        Object txnsObj = context.get('SalesTransaction');
        if (!(txnsObj instanceof List<Object>)) {
            return qtyByProduct;
        }
        String lineKey = parentLineId == null ? null : String.valueOf(parentLineId);
        for (Object txnItem : (List<Object>) txnsObj) {
            Map<String, Object> txn = asMap(txnItem);
            if (txn == null) {
                continue;
            }
            Object itemsObj = txn.get('SalesTransactionItem');
            if (!(itemsObj instanceof List<Object>)) {
                continue;
            }
            for (Object itemObj : (List<Object>) itemsObj) {
                Map<String, Object> item = asMap(itemObj);
                if (item == null) {
                    continue;
                }
                String itemId = asString(item.get('id'));
                if (lineKey != null && itemId == lineKey) {
                    continue;
                }
                String productId = productIdFromItem(item);
                if (String.isBlank(productId) || productId == lineKey) {
                    continue;
                }
                Decimal qty = asDecimal(item.get('Quantity'));
                qtyByProduct.put(productId, qty == null ? 0 : qty);
            }
        }
        return qtyByProduct;
    }

    static String productIdFromItem(Map<String, Object> item) {
        if (item == null) {
            return null;
        }
        Object product = item.get('Product');
        if (product instanceof Map<String, Object>) {
            return asString(((Map<String, Object>) product).get('id'));
        }
        return asString(product);
    }

    @TestVisible
    static Boolean attributesAlreadyApplied(
        ConfigResult loaded,
        Map<String, String> values
    ) {
        if (loaded == null || values == null || values.isEmpty()) {
            return false;
        }
        for (String key : values.keySet()) {
            if (String.isBlank(key)) {
                continue;
            }
            ConfigAttribute attr = findLoadedAttribute(loaded, key);
            if (attr == null || !equalsIgnore(attr.value, values.get(key))) {
                return false;
            }
        }
        return true;
    }

    static String applyAttributeValueMap(ConfigResult loaded, Map<String, String> values) {
        if (loaded == null || values == null) {
            return null;
        }
        for (String key : values.keySet()) {
            if (String.isBlank(key)) {
                continue;
            }
            ConfigAttribute attr = findLoadedAttribute(loaded, key);
            if (attr == null) {
                return 'No attribute matching "' + key + '".';
            }
            String value = values.get(key);
            ConfigPicklistOption matched = matchPicklistOption(attr.options, value);
            if (attr.options != null && !attr.options.isEmpty() && matched == null) {
                String label = firstNonBlank(attr.label, attr.attributeName, key);
                return '"' + value + '" is not a valid value for ' + label + '.';
            }
            if (matched != null) {
                attr.value = firstNonBlank(matched.value, value);
                attr.picklistValueId = matched.picklistValueId;
            } else {
                attr.value = value;
            }
        }
        return null;
    }

    static ConfigAttribute findLoadedAttribute(ConfigResult loaded, String term) {
        if (loaded == null || loaded.attributes == null || String.isBlank(term)) {
            return null;
        }
        String needle = term.trim();
        for (ConfigAttribute attr : loaded.attributes) {
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

    static Boolean equalsIgnore(String left, String right) {
        if (left == null && right == null) {
            return true;
        }
        if (left == null || right == null) {
            return false;
        }
        return left.equalsIgnoreCase(right);
    }

    @TestVisible
    static List<ConfigAttribute> parseAttributes(
        Map<String, Object> catalogProduct,
        Map<String, ConfigAttribute> contextAttributes
    ) {
        List<ConfigAttribute> attributes = new List<ConfigAttribute>();
        if (catalogProduct == null) {
            return attributes;
        }
        Object catsObj = catalogProduct.get('attributeCategories');
        if (!(catsObj instanceof List<Object>)) {
            return attributes;
        }
        for (Object catItem : (List<Object>) catsObj) {
            Map<String, Object> cat = asMap(catItem);
            if (cat == null) {
                continue;
            }
            Object attrsObj = cat.get('attributes');
            if (!(attrsObj instanceof List<Object>)) {
                continue;
            }
            for (Object attrItem : (List<Object>) attrsObj) {
                Map<String, Object> raw = asMap(attrItem);
                if (raw == null || raw.get('isHidden') == true) {
                    continue;
                }
                ConfigAttribute attr = new ConfigAttribute();
                attr.attributeKey = asString(raw.get('id'));
                attr.attributeName = asString(raw.get('developerName'));
                attr.label = firstNonBlank(
                    asString(raw.get('attributeNameOverride')),
                    asString(raw.get('label')),
                    asString(raw.get('name')));
                attr.dataType = asString(raw.get('dataType'));
                attr.required = raw.get('isRequired') == true;
                attr.priceImpacting = asOptionalBoolean(
                    raw.get('isPriceImpacting'), raw.get('IsPriceImpacting'));
                attr.options = parsePicklist(raw.get('attributePicklist'));
                ConfigAttribute current = contextAttributeFor(contextAttributes, attr);
                if (current != null) {
                    attr.attributeRecordId = current.attributeRecordId;
                    if (String.isNotBlank(current.value)) {
                        attr.value = current.value;
                    }
                    if (String.isNotBlank(current.picklistValueId)) {
                        attr.picklistValueId = current.picklistValueId;
                    }
                }
                if (String.isBlank(attr.value)) {
                    attr.value = asString(raw.get('defaultValue'));
                }
                if (String.isBlank(attr.picklistValueId)) {
                    attr.picklistValueId = picklistIdForValue(attr.options, attr.value);
                }
                attributes.add(attr);
            }
        }
        return attributes;
    }

    @TestVisible
    static List<ConfigMessage> parseMessages(Object messagesObj) {
        List<ConfigMessage> messages = new List<ConfigMessage>();
        if (messagesObj instanceof List<Object>) {
            for (Object item : (List<Object>) messagesObj) {
                addParsedMessage(messages, asMap(item));
            }
            return messages;
        }
        if (!(messagesObj instanceof Map<String, Object>)) {
            return messages;
        }
        for (Object bucket : ((Map<String, Object>) messagesObj).values()) {
            if (!(bucket instanceof List<Object>)) {
                continue;
            }
            for (Object item : (List<Object>) bucket) {
                addParsedMessage(messages, asMap(item));
            }
        }
        return messages;
    }

    static void addParsedMessage(List<ConfigMessage> messages, Map<String, Object> raw) {
        if (messages == null || raw == null) {
            return;
        }
        ConfigMessage msg = new ConfigMessage();
        msg.messageType = firstNonBlank(
            asString(raw.get('messageType')),
            asString(raw.get('severity'))
        );
        msg.category = asString(raw.get('category'));
        msg.text = firstNonBlank(asString(raw.get('message')), asString(raw.get('text')));
        if (String.isNotBlank(msg.text)) {
            messages.add(msg);
        }
    }

    @TestVisible
    static List<Object> buildAddedNodes(
        Id quoteId,
        Id parentLineId,
        List<ConfigComponent> selected,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        List<Object> nodes = new List<Object>();
        if (selected == null) {
            return nodes;
        }
        Integer i = 0;
        for (ConfigComponent component : selected) {
            if (component == null || String.isBlank(component.product2Id)) {
                continue;
            }
            if (childrenByProduct != null && childrenByProduct.containsKey(component.product2Id)) {
                continue;
            }
            String qliRef = 'ref_qli_' + String.valueOf(i);
            String relRef = 'ref_rel_' + String.valueOf(i);
            i++;
            Map<String, Object> qli = new Map<String, Object>{
                'id' => qliRef,
                'SalesTransactionItemSource' => qliRef,
                'SalesTransactionItemParent' => String.valueOf(quoteId),
                'ParentSalesTransactionItem' => String.valueOf(parentLineId),
                'PricebookEntry' => component.pricebookEntryId,
                'ProductSellingModel' => component.productSellingModelId,
                'UnitPrice' => component.unitPrice == null ? 0 : component.unitPrice,
                'Quantity' => component.quantity == null ? 1 : component.quantity,
                'Product' => component.product2Id,
                'businessObjectType' => 'QuoteLineItem'
            };
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{ String.valueOf(quoteId), qliRef },
                'addedObject' => qli
            });
            Map<String, Object> rel = new Map<String, Object>{
                'id' => relRef,
                'MainItem' => String.valueOf(parentLineId),
                'AssociatedItem' => qliRef,
                'ProductRelatedComponent' => component.productRelatedComponentId,
                'AssociatedItemPricing' => component.includedInBundle == true
                    ? 'IncludedInBundlePrice'
                    : 'NotIncludedInBundlePrice',
                'AssociatedQuantScaleMethod' => 'Proportional',
                'businessObjectType' => 'QuoteLineItemRelationship'
            };
            if (String.isNotBlank(component.productRelationshipTypeId)) {
                rel.put('ProductRelationshipType', component.productRelationshipTypeId);
            }
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{ String.valueOf(quoteId), qliRef, relRef },
                'addedObject' => rel
            });
        }
        return nodes;
    }

    @TestVisible
    static List<Object> buildDeletedNodes(
        Id quoteId,
        List<ConfigComponent> selected,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        List<Object> nodes = new List<Object>();
        if (childrenByProduct == null || childrenByProduct.isEmpty()) {
            return nodes;
        }
        Set<String> keep = new Set<String>();
        if (selected != null) {
            for (ConfigComponent component : selected) {
                if (component != null && String.isNotBlank(component.product2Id)) {
                    keep.add(component.product2Id);
                }
            }
        }
        for (String productId : childrenByProduct.keySet()) {
            if (keep.contains(productId)) {
                continue;
            }
            QuoteLineItem child = childrenByProduct.get(productId);
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{ String.valueOf(quoteId), String.valueOf(child.Id) }
            });
        }
        return nodes;
    }

    @TestVisible
    static List<Object> buildUpdatedNodes(
        Id quoteId,
        Id parentLineId,
        Selection selection,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        List<Object> nodes = buildQuantityUpdates(
            quoteId,
            selection == null ? null : selection.components,
            childrenByProduct
        );
        if (selection == null || selection.attributes == null) {
            return nodes;
        }
        Boolean hasContext = String.isNotBlank(selection.transactionContextId);
        for (ConfigAttribute attr : selection.attributes) {
            if (!canSendAttribute(attr) || !isUsableAttributeNodeId(attr.attributeRecordId, hasContext)) {
                continue;
            }
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{
                    String.valueOf(quoteId),
                    String.valueOf(parentLineId),
                    attr.attributeRecordId
                },
                'updatedAttributes' => attributeFieldUpdates(attr)
            });
        }
        return nodes;
    }

    @TestVisible
    static List<Object> buildAddedAttributeNodes(Id quoteId, Id parentLineId, Selection selection) {
        List<Object> nodes = new List<Object>();
        if (selection == null || selection.attributes == null) {
            return nodes;
        }
        Boolean hasContext = String.isNotBlank(selection.transactionContextId);
        Integer i = 0;
        for (ConfigAttribute attr : selection.attributes) {
            if (!canSendAttribute(attr) || isUsableAttributeNodeId(attr.attributeRecordId, hasContext)) {
                continue;
            }
            if (String.isBlank(attr.attributeKey)) {
                continue;
            }
            String ref = 'ref_attr_' + String.valueOf(i);
            i++;
            Map<String, Object> added = new Map<String, Object>{
                'id' => ref,
                'businessObjectType' => 'QuoteLineItemAttribute',
                'AttributeKey' => attr.attributeKey,
                'AttributeValue' => attr.value,
                'SalesTransactionItemAttrParent' => String.valueOf(parentLineId)
            };
            if (String.isNotBlank(attr.attributeName)) {
                added.put('AttributeName', attr.attributeName);
            }
            if (String.isNotBlank(attr.picklistValueId)) {
                added.put('AttributePicklistValue', attr.picklistValueId);
            }
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{
                    String.valueOf(quoteId),
                    String.valueOf(parentLineId),
                    ref
                },
                'addedObject' => added
            });
        }
        return nodes;
    }

    @TestVisible
    static List<Object> buildQuantityUpdates(
        Id quoteId,
        List<ConfigComponent> selected,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        List<Object> nodes = new List<Object>();
        if (selected == null || childrenByProduct == null) {
            return nodes;
        }
        for (ConfigComponent component : selected) {
            if (component == null || String.isBlank(component.product2Id)) {
                continue;
            }
            QuoteLineItem existing = childrenByProduct.get(component.product2Id);
            if (existing == null) {
                continue;
            }
            Decimal nextQty = component.quantity == null ? 1 : component.quantity;
            if (existing.Quantity == nextQty) {
                continue;
            }
            nodes.add(new Map<String, Object>{
                'path' => new List<String>{ String.valueOf(quoteId), String.valueOf(existing.Id) },
                'updatedAttributes' => new Map<String, Object>{ 'Quantity' => nextQty }
            });
        }
        return nodes;
    }

    @TestVisible
    static Selection parseSelection(String selectionJson) {
        if (String.isBlank(selectionJson)) {
            return null;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(selectionJson);
        } catch (Exception e) {
            return null;
        }
        Map<String, Object> root = asMap(parsed);
        if (root == null) {
            return null;
        }
        Selection selection = new Selection();
        selection.components = new List<ConfigComponent>();
        selection.attributes = new List<ConfigAttribute>();
        Object compsObj = root.get('components');
        if (compsObj instanceof List<Object>) {
            for (Object item : (List<Object>) compsObj) {
                Map<String, Object> raw = asMap(item);
                if (raw == null) {
                    continue;
                }
                ConfigComponent component = new ConfigComponent();
                component.product2Id = asString(raw.get('product2Id'));
                component.pricebookEntryId = asString(raw.get('pricebookEntryId'));
                component.productSellingModelId = asString(raw.get('productSellingModelId'));
                component.sellingModelType = asString(raw.get('sellingModelType'));
                component.unitPrice = asDecimal(raw.get('unitPrice'));
                component.quantity = asDecimal(raw.get('quantity'));
                component.productRelatedComponentId = asString(raw.get('productRelatedComponentId'));
                component.productRelationshipTypeId = asString(raw.get('productRelationshipTypeId'));
                component.includedInBundle = raw.get('includedInBundle') == true;
                component.quoteLineItemId = asString(raw.get('quoteLineItemId'));
                if (String.isNotBlank(component.product2Id)) {
                    selection.components.add(component);
                }
            }
        }
        Object attrsObj = root.get('attributes');
        if (attrsObj instanceof List<Object>) {
            for (Object item : (List<Object>) attrsObj) {
                Map<String, Object> raw = asMap(item);
                if (raw == null) {
                    continue;
                }
                ConfigAttribute attr = new ConfigAttribute();
                attr.attributeKey = asString(raw.get('attributeKey'));
                attr.attributeName = asString(raw.get('attributeName'));
                attr.attributeRecordId = asString(raw.get('attributeRecordId'));
                attr.value = asString(raw.get('value'));
                attr.picklistValueId = asString(raw.get('picklistValueId'));
                if (String.isNotBlank(attr.attributeKey) || String.isNotBlank(attr.attributeName)) {
                    selection.attributes.add(attr);
                }
            }
        }
        selection.transactionContextId = asString(root.get('transactionContextId'));
        return selection;
    }

    static Map<String, Object> baseConfigureBody(
        Id quoteId,
        Id lineId,
        Boolean addDefaults,
        Id accountId,
        String transactionContextId
    ) {
        Map<String, Object> body = new Map<String, Object>{
            'transactionId' => String.valueOf(quoteId),
            'transactionLineId' => String.valueOf(lineId),
            'contextResponseType' => 'Full',
            'configuratorOptions' => new Map<String, Object>{
                'executePricing' => true,
                'returnProductCatalogData' => true,
                'executeConfigurationRules' => true,
                'addDefaultConfiguration' => addDefaults == true,
                'validateProductCatalog' => true,
                'qualifyAllProductsInTransaction' => true,
                'validateAmendRenewCancel' => true
            }
        };
        if (accountId != null) {
            body.put('qualificationContext', new Map<String, Object>{
                'accountId' => String.valueOf(accountId)
            });
        }
        if (String.isNotBlank(transactionContextId)) {
            body.put('transactionContextId', transactionContextId);
        }
        return body;
    }

    static ConfigResult afterSuccessfulConfigure(
        ConfigResult parsed,
        Id quoteId,
        Id lineId,
        Selection selection,
        Map<String, QuoteLineItem> childrenByProduct,
        Id accountId
    ) {
        if (Test.isRunningTest()) {
            parsed.message = 'Add-ons saved.';
            return parsed;
        }
        String persistError;
        try {
            persistError = persistSelection(
                quoteId,
                lineId,
                selectionFromResult(parsed, selection),
                childrenByProduct,
                false,
                false
            );
        } catch (Exception e) {
            persistError = e.getMessage();
        }
        parsed.groups = markSelectedFromChildren(parsed.groups, queryChildren(quoteId, lineId));
        parsed.message = persistError == null
            ? 'Add-ons saved.'
            : 'Add-ons saved. ' + persistError;
        return parsed;
    }

    @TestVisible
    static Selection selectionFromResult(ConfigResult parsed, Selection requested) {
        Selection selection = new Selection();
        selection.components = new List<ConfigComponent>();
        selection.attributes = new List<ConfigAttribute>();
        if (parsed != null) {
            selection.transactionContextId = parsed.transactionContextId;
            if (parsed.groups != null) {
                for (ConfigGroup optionGroup : parsed.groups) {
                    if (optionGroup == null || optionGroup.components == null) {
                        continue;
                    }
                    for (ConfigComponent component : optionGroup.components) {
                        if (component != null && component.selected == true
                            && String.isNotBlank(component.product2Id)) {
                            selection.components.add(component);
                        }
                    }
                }
            }
            if (parsed.attributes != null) {
                for (ConfigAttribute attr : parsed.attributes) {
                    if (attr == null) {
                        continue;
                    }
                    if (String.isBlank(attr.value) && String.isBlank(attr.picklistValueId)) {
                        continue;
                    }
                    selection.attributes.add(attr);
                }
            }
        }
        if (selection.components.isEmpty() && requested != null && requested.components != null) {
            selection.components = requested.components;
            if (requested.attributes != null && selection.attributes.isEmpty()) {
                selection.attributes = requested.attributes;
            }
            if (String.isBlank(selection.transactionContextId)) {
                selection.transactionContextId = requested.transactionContextId;
            }
        }
        return selection;
    }

    static List<ConfigGroup> markSelectedFromChildren(
        List<ConfigGroup> groups,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        if (groups == null) {
            return groups;
        }
        for (ConfigGroup optionGroup : groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (ConfigComponent component : optionGroup.components) {
                if (component == null || String.isBlank(component.product2Id)) {
                    continue;
                }
                QuoteLineItem child = childrenByProduct == null
                    ? null
                    : childrenByProduct.get(component.product2Id);
                component.selected = child != null;
                component.quoteLineItemId = child == null ? null : String.valueOf(child.Id);
                if (child != null && child.Quantity != null) {
                    component.quantity = child.Quantity;
                }
            }
        }
        return groups;
    }

    @TestVisible
    static Boolean isConfigurationRulesCrash(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        return message.containsIgnoreCase('ConfiguratorException')
            || message.containsIgnoreCase('configuration rules');
    }

    @TestVisible
    static String persistSelectionPreferringSystem(
        Id quoteId,
        Id parentLineId,
        Selection selection,
        Map<String, QuoteLineItem> childrenByProduct,
        Boolean skipPricing
    ) {
        String systemError = persistSelection(
            quoteId, parentLineId, selection, childrenByProduct, true, skipPricing);
        if (systemError == null || !isConfigurationRulesCrash(systemError)) {
            return systemError;
        }
        return persistSelection(
            quoteId, parentLineId, selection, childrenByProduct, false, skipPricing);
    }

    static String persistSelection(
        Id quoteId,
        Id parentLineId,
        Selection selection,
        Map<String, QuoteLineItem> childrenByProduct,
        Boolean runRules,
        Boolean skipPricing
    ) {
        if (Test.isRunningTest() || selection == null) {
            return null;
        }
        QuoteLineItem parent = [
            SELECT Id, QuoteLineGroupId, StartDate, EndDate, BillingFrequency, PeriodBoundary
            FROM QuoteLineItem
            WHERE Id = :parentLineId
            AND QuoteId = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode =
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId);
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quoteNode));

        Set<String> selectedIds = new Set<String>();
        Integer i = 0;
        Map<String, String> modelTypeByKey = sellingModelTypes(selection.components);
        if (selection.components != null) {
            for (ConfigComponent component : selection.components) {
                if (component == null || String.isBlank(component.product2Id)) {
                    continue;
                }
                selectedIds.add(component.product2Id);
                QuoteLineItem existing = childrenByProduct == null
                    ? null
                    : childrenByProduct.get(component.product2Id);
                if (existing != null) {
                    Decimal nextQty = component.quantity == null ? 1 : component.quantity;
                    if (existing.Quantity != nextQty) {
                        RevSalesTrxn.RecordResource patch = new RevSalesTrxn.RecordResource(
                            QuoteLineItem.getSObjectType(), 'PATCH', existing.Id);
                        patch.fieldValues = new Map<String, Object>{ 'Quantity' => nextQty };
                        records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                            'refQty' + String.valueOf(i), patch));
                        i++;
                    }
                    continue;
                }
                String childRef = 'refChild' + String.valueOf(i);
                RevSalesTrxn.RecordResource child = new RevSalesTrxn.RecordResource(
                    QuoteLineItem.getSObjectType(), 'POST');
                Map<String, Object> fields = new Map<String, Object>{
                    'QuoteId' => quoteId,
                    'Product2Id' => component.product2Id,
                    'PricebookEntryId' => component.pricebookEntryId,
                    'Quantity' => component.quantity == null ? 1 : component.quantity,
                    'UnitPrice' => component.unitPrice == null ? 0 : component.unitPrice
                };
                if (parent.QuoteLineGroupId != null) {
                    fields.put('QuoteLineGroupId', parent.QuoteLineGroupId);
                }
                applyParentTermFields(fields, parent, modelTypeOf(component, modelTypeByKey));
                child.fieldValues = fields;
                records.add(new RevSalesTrxn.RecordWithReferenceRequest(childRef, child));
                if (String.isNotBlank(component.productRelatedComponentId)) {
                    RevSalesTrxn.RecordResource rel = new RevSalesTrxn.RecordResource(
                        QuoteLineRelationship.getSObjectType(), 'POST');
                    Map<String, Object> relFields = new Map<String, Object>{
                        'MainQuoteLineId' => parentLineId,
                        'AssociatedQuoteLineId' => '@{' + childRef + '.id}',
                        'ProductRelatedComponentId' => component.productRelatedComponentId,
                        'AssociatedQuoteLinePricing' => component.includedInBundle == true
                            ? 'IncludedInBundlePrice'
                            : 'NotIncludedInBundlePrice'
                    };
                    if (String.isNotBlank(component.productRelationshipTypeId)) {
                        relFields.put('ProductRelationshipTypeId', component.productRelationshipTypeId);
                    }
                    rel.fieldValues = relFields;
                    records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                        'refRel' + String.valueOf(i), rel));
                }
                i++;
            }
        }
        if (childrenByProduct != null) {
            for (String productId : childrenByProduct.keySet()) {
                if (selectedIds.contains(productId)) {
                    continue;
                }
                QuoteLineItem child = childrenByProduct.get(productId);
                RevSalesTrxn.RecordResource del = new RevSalesTrxn.RecordResource(
                    QuoteLineItem.getSObjectType(), 'DELETE', child.Id);
                records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                    'refDel' + String.valueOf(i), del));
                i++;
            }
        }
        i = addAttributePersistNodes(records, parentLineId, selection, i);
        if (records.size() == 1) {
            return null;
        }
        RevSalesTrxn.ConfigurationOptionsInput options = new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = runRules == true;
        options.validateProductCatalog = runRules == true;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('RampConfiguratorSave', records);
        RevSalesTrxn.PricingPreferenceEnum pricingPref = skipPricing == true
            ? RevSalesTrxn.PricingPreferenceEnum.SKIP
            : RevSalesTrxn.PricingPreferenceEnum.FORCE;
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                pricingPref,
                runRules == true
                    ? RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM
                    : RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Could not persist add-ons to the quote.'
            : String.valueOf(resp.errorResponse);
    }

    @TestVisible
    static void applyParentTermFields(
        Map<String, Object> fields,
        QuoteLineItem parent,
        String sellingModelType
    ) {
        if (fields == null || parent == null) {
            return;
        }
        if (parent.StartDate != null) {
            fields.put('StartDate', String.valueOf(parent.StartDate));
        }
        Boolean oneTime = sellingModelType != null && sellingModelType.equalsIgnoreCase('OneTime');
        Boolean evergreen = sellingModelType != null && sellingModelType.equalsIgnoreCase('Evergreen');
        if (!oneTime && parent.BillingFrequency != null) {
            fields.put('BillingFrequency', parent.BillingFrequency);
        }
        if (!oneTime && parent.PeriodBoundary != null) {
            fields.put('PeriodBoundary', parent.PeriodBoundary);
        }
        if (!oneTime && !evergreen && parent.EndDate != null) {
            fields.put('EndDate', String.valueOf(parent.EndDate));
        }
    }

    static Map<String, String> sellingModelTypes(List<ConfigComponent> components) {
        Map<String, String> types = new Map<String, String>();
        if (components == null || components.isEmpty()) {
            return types;
        }
        Set<Id> psmIds = new Set<Id>();
        Set<Id> pbeIds = new Set<Id>();
        for (ConfigComponent component : components) {
            if (component == null) {
                continue;
            }
            if (String.isNotBlank(component.sellingModelType)) {
                if (String.isNotBlank(component.productSellingModelId)) {
                    types.put(component.productSellingModelId, component.sellingModelType);
                }
                if (String.isNotBlank(component.pricebookEntryId)) {
                    types.put(component.pricebookEntryId, component.sellingModelType);
                }
            }
            Id psmId = toId(component.productSellingModelId);
            if (psmId != null) {
                psmIds.add(psmId);
            }
            Id pbeId = toId(component.pricebookEntryId);
            if (pbeId != null) {
                pbeIds.add(pbeId);
            }
        }
        if (!psmIds.isEmpty()) {
            for (ProductSellingModel model : [
                SELECT Id, SellingModelType
                FROM ProductSellingModel
                WHERE Id IN :psmIds
                WITH USER_MODE
            ]) {
                types.put(String.valueOf(model.Id), model.SellingModelType);
            }
        }
        if (!pbeIds.isEmpty()) {
            for (PricebookEntry pbe : [
                SELECT Id, ProductSellingModelId, ProductSellingModel.SellingModelType
                FROM PricebookEntry
                WHERE Id IN :pbeIds
                WITH USER_MODE
            ]) {
                if (pbe.ProductSellingModel == null) {
                    continue;
                }
                types.put(String.valueOf(pbe.Id), pbe.ProductSellingModel.SellingModelType);
                if (pbe.ProductSellingModelId != null) {
                    types.put(String.valueOf(pbe.ProductSellingModelId),
                        pbe.ProductSellingModel.SellingModelType);
                }
            }
        }
        return types;
    }

    static String modelTypeOf(ConfigComponent component, Map<String, String> types) {
        if (component == null) {
            return null;
        }
        if (String.isNotBlank(component.sellingModelType)) {
            return component.sellingModelType;
        }
        if (types == null) {
            return null;
        }
        if (String.isNotBlank(component.productSellingModelId)
            && types.containsKey(component.productSellingModelId)) {
            return types.get(component.productSellingModelId);
        }
        if (String.isNotBlank(component.pricebookEntryId)
            && types.containsKey(component.pricebookEntryId)) {
            return types.get(component.pricebookEntryId);
        }
        return null;
    }

    static Map<String, Object> postConfigure(Map<String, Object> body) {
        String payload = JSON.serialize(body);
        // Lightning can use a Visualforce API session. Hosted MCP cannot —
        // session HTTP throws an uncatchable UnexpectedException there, so
        // invocables must use the Named Credential and never call getContent.
        if (canRenderVisualforceSession()) {
            return sendConfigure(
                URL.getOrgDomainUrl().toExternalForm() + CONFIGURE_PATH,
                payload,
                apiSessionId()
            );
        }
        // Named Credential injects OAuth. Do not stamp UserInfo.getSessionId()
        // — Queueable / Hosted MCP sessions are not API-capable and 401.
        return sendConfigure(
            'callout:' + LOOPBACK_NAMED_CREDENTIAL + CONFIGURE_PATH,
            payload,
            null
        );
    }

    static Map<String, Object> sendConfigure(
        String endpoint,
        String payload,
        String bearerToken
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        if (String.isNotBlank(bearerToken)) {
            req.setHeader('Authorization', 'Bearer ' + bearerToken);
        }
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(payload);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new CalloutException(
                'Configurator HTTP ' + res.getStatusCode() + ': ' + conciseError(res.getBody()));
        }
        Object parsed = JSON.deserializeUntyped(res.getBody());
        Map<String, Object> response = asMap(parsed);
        if (response == null) {
            throw new CalloutException('Configurator returned an empty body.');
        }
        return response;
    }

    @TestVisible
    static ConfigResult finish(ConfigResult result) {
        if (result == null) {
            return null;
        }
        attachFixGuidance(result);
        return result;
    }

    public static void attachFixGuidance(ConfigResult result) {
        if (result == null) {
            return;
        }
        result.fixKind = null;
        result.fixHeadline = null;
        result.fixSteps = null;
        if (result.message == CRE_LOADING) {
            result.fixKind = 'retry';
            result.fixHeadline =
                'Configuration is still running. Nothing on the rack needs to change.';
            result.fixSteps = new List<String>{
                'Call this tool again immediately with the same quote line.',
                'Do not query QuoteLineItem children. Do not invent Dual, Gold, or Socket.'
            };
            return;
        }
        List<String> steps = new List<String>();
        appendUnique(steps, invalidValueFixStep(result));
        if (isDualWithGeneral(result)) {
            appendUnique(
                steps,
                'Socket is Dual and Workload is still General. Dual sockets need Workload AI or High Performance Computing, or switch Socket back to Single.'
            );
        }
        if (isDualWithGold(result)) {
            appendUnique(steps, DUAL_GOLD_FIX);
        }
        if (isSingleWithDualHardware(result)) {
            appendUnique(steps, SINGLE_DUAL_QTY_FIX);
        }
        if (isSingleWithNonGeneral(result)) {
            appendUnique(steps, SINGLE_WORKLOAD_FIX);
        }
        if (isSingleWithDualGpu(result)) {
            appendUnique(steps, SINGLE_GPU_FIX);
        }
        if (result.messages != null) {
            for (ConfigMessage msg : result.messages) {
                if (msg == null || String.isBlank(msg.text) || !isBlockingMessage(msg)) {
                    continue;
                }
                if (isSolverLeftoverMessage(msg.text)) {
                    continue;
                }
                appendUnique(
                    steps,
                    rewriteKnownConstraint(stripConstraintPrefix(msg.text), result)
                );
            }
        }
        appendUnique(steps, laneDomainFixStep(result));
        appendRequiredFixSteps(result, steps);
        if (steps.isEmpty() && isChangePicksMessage(result.message)
            && !isSolverLeftoverMessage(result.message)) {
            appendUnique(steps, result.message);
        }
        if (!steps.isEmpty()) {
            result.fixKind = 'change_picks';
            result.fixHeadline = 'What to change';
            result.fixSteps = steps;
            return;
        }
        if (isPlatformConfigureMessage(result.message) || hasSolverLeftover(result)) {
            result.fixKind = 'platform';
            result.fixHeadline = 'This is not a rack-option problem.';
            result.fixSteps = platformFixSteps(result.message);
        }
    }

    @TestVisible
    static Boolean isPlatformConfigureMessage(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        return message.containsIgnoreCase('Configurator HTTP 401')
            || message.containsIgnoreCase('Configurator HTTP 403')
            || message.containsIgnoreCase('Session expired')
            || message.containsIgnoreCase('Invalid Session')
            || message.containsIgnoreCase('session id')
            || message.containsIgnoreCase('Unauthorized')
            || message.containsIgnoreCase('Script-thrown')
            || message.containsIgnoreCase('UnexpectedException')
            || message.containsIgnoreCase('ConfiguratorException')
            || (isSolverLeftoverMessage(message) && !isLaneDomainLeftover(message));
    }

    @TestVisible
    static Boolean isSolverLeftoverMessage(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        return message.containsIgnoreCase('not in domain')
            || message.containsIgnoreCase('Calculated value')
            || message.containsIgnoreCase('Server_0')
            || message.containsIgnoreCase('Server2_0');
    }

    static Boolean hasSolverLeftover(ConfigResult result) {
        if (result == null) {
            return false;
        }
        if (isSolverLeftoverMessage(result.message)) {
            return true;
        }
        if (result.messages == null) {
            return false;
        }
        for (ConfigMessage msg : result.messages) {
            if (msg != null && isSolverLeftoverMessage(msg.text)) {
                return true;
            }
        }
        return false;
    }

    @TestVisible
    static Boolean isLaneDomainLeftover(String message) {
        if (!isSolverLeftoverMessage(message)) {
            return false;
        }
        return message.containsIgnoreCase('x16Lanes')
            || message.containsIgnoreCase('x8Lanes')
            || message.containsIgnoreCase('x16 Lanes')
            || message.containsIgnoreCase('x8 Lanes');
    }

    static Boolean hasLaneDomainLeftover(ConfigResult result) {
        if (result == null) {
            return false;
        }
        if (isLaneDomainLeftover(result.message)) {
            return true;
        }
        if (result.messages == null) {
            return false;
        }
        for (ConfigMessage msg : result.messages) {
            if (msg != null && isLaneDomainLeftover(msg.text)) {
                return true;
            }
        }
        return false;
    }

    static String laneDomainFixStep(ConfigResult result) {
        if (!hasLaneDomainLeftover(result) && !isDualGpuLaneLeak(result)) {
            return null;
        }
        return 'Do not edit x16 Lanes — it is read-only. Dual with Performance Tier Standard, Performance, or Accelerated adds a GPU. Set Performance Tier to Entry, or set Socket back to Single and Workload back to General.';
    }

    static List<String> platformFixSteps(String message) {
        List<String> steps = new List<String>{
            'Retry the same quote line. Do not log out to fix this.',
            'Do not change Dual, Gold, or Socket to work around this error.'
        };
        if (String.isNotBlank(message) && message.containsIgnoreCase('ConfiguratorException')) {
            steps.add('If this quote is ramped, configure a single Q-Rack quote instead.');
        }
        return steps;
    }

    static Boolean isChangePicksMessage(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        return message.containsIgnoreCase('is not a valid value')
            || message.containsIgnoreCase('No attribute matching')
            || message.containsIgnoreCase('No option matching');
    }

    static String invalidValueFixStep(ConfigResult result) {
        if (result == null || String.isBlank(result.message)
            || !result.message.containsIgnoreCase('is not a valid value')) {
            return null;
        }
        String options = validOptionsForInvalidValue(result);
        if (String.isBlank(options)) {
            return result.message;
        }
        return result.message + ' Valid values: ' + options + '.';
    }

    static String validOptionsForInvalidValue(ConfigResult result) {
        if (result == null || result.attributes == null || String.isBlank(result.message)) {
            return null;
        }
        Integer marker = result.message.toLowerCase().indexOf(' for ');
        if (marker < 0) {
            return null;
        }
        String label = result.message.substring(marker + 5).trim();
        if (label.endsWith('.')) {
            label = label.left(label.length() - 1);
        }
        ConfigAttribute attr = findLoadedAttribute(result, label);
        if (attr == null || attr.options == null || attr.options.isEmpty()) {
            return null;
        }
        List<String> labels = new List<String>();
        for (ConfigPicklistOption option : attr.options) {
            if (option != null && String.isNotBlank(option.label)) {
                labels.add(option.label);
            } else if (option != null && String.isNotBlank(option.value)) {
                labels.add(option.value);
            }
        }
        return labels.isEmpty() ? null : String.join(labels, ', ');
    }

    static Boolean isDualWithGeneral(ConfigResult result) {
        String socket = attributeValue(
            result,
            new List<String>{ 'SocketConfiguration', 'Socket Configuration', 'Socket' }
        );
        String workload = attributeValue(result, new List<String>{ 'Workload' });
        return equalsIgnore(socket, 'Dual') && equalsIgnore(workload, 'General');
    }

    @TestVisible
    static Boolean isDualWithGold(ConfigResult result) {
        if (!equalsIgnore(
            attributeValue(
                result,
                new List<String>{ 'SocketConfiguration', 'Socket Configuration', 'Socket' }
            ),
            'Dual'
        )) {
            return false;
        }
        return hasSelectedGoldCpu(result);
    }

    static Boolean isSingleWithNonGeneral(ConfigResult result) {
        if (!equalsIgnore(socketValue(result), 'Single')) {
            return false;
        }
        String workload = workloadValue(result);
        return String.isNotBlank(workload) && !equalsIgnore(workload, 'General');
    }

    static Boolean isSingleWithDualHardware(ConfigResult result) {
        if (!equalsIgnore(socketValue(result), 'Single')) {
            return false;
        }
        return selectedQty(result, 'cpu') >= 2 || selectedQty(result, 'liquid') >= 2;
    }

    static Boolean isSingleWithDualGpu(ConfigResult result) {
        return equalsIgnore(socketValue(result), 'Single') && selectedQty(result, 'gpu') >= 1;
    }

    static String socketValue(ConfigResult result) {
        return attributeValue(
            result,
            new List<String>{ 'SocketConfiguration', 'Socket Configuration', 'Socket' }
        );
    }

    static String workloadValue(ConfigResult result) {
        return attributeValue(result, new List<String>{ 'Workload' });
    }

    static Decimal selectedQty(ConfigResult result, String kind) {
        Decimal total = 0;
        if (result == null || result.groups == null || String.isBlank(kind)) {
            return total;
        }
        for (ConfigGroup optionGroup : result.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (ConfigComponent component : optionGroup.components) {
                if (component == null || component.selected != true) {
                    continue;
                }
                Boolean match = (kind == 'cpu' && isCpu(component))
                    || (kind == 'liquid' && isLiquidCooler(component))
                    || (kind == 'gpu' && isGpu(component));
                if (!match) {
                    continue;
                }
                total += component.quantity == null ? 1 : component.quantity;
            }
        }
        return total;
    }

    static Boolean isCpu(ConfigComponent component) {
        if (component == null) {
            return false;
        }
        String name = component.name == null ? '' : component.name;
        String sku = component.sku == null ? '' : component.sku;
        if (name.containsIgnoreCase('Heat Sink') || sku.containsIgnoreCase('HEATSINK')) {
            return false;
        }
        return name.containsIgnoreCase('Xeon')
            || sku.containsIgnoreCase('INTEL-PLAT')
            || sku.containsIgnoreCase('INTEL-GOLD')
            || sku.containsIgnoreCase('XEON')
            || (sku.containsIgnoreCase('CPU') && !sku.containsIgnoreCase('COOL'));
    }

    static Boolean isLiquidCooler(ConfigComponent component) {
        if (component == null) {
            return false;
        }
        String name = component.name == null ? '' : component.name;
        String sku = component.sku == null ? '' : component.sku;
        return name.containsIgnoreCase('Liquid Cooler') || sku.containsIgnoreCase('LIQUIDCOOL');
    }

    static Boolean isGpu(ConfigComponent component) {
        if (component == null) {
            return false;
        }
        String name = component.name == null ? '' : component.name;
        String sku = component.sku == null ? '' : component.sku;
        return name.containsIgnoreCase('Nova')
            || name.containsIgnoreCase('Accel')
            || sku.containsIgnoreCase('Nova')
            || sku.containsIgnoreCase('Accel');
    }

    static Boolean hasSelectedGoldCpu(ConfigResult result) {
        if (result == null || result.groups == null) {
            return false;
        }
        for (ConfigGroup optionGroup : result.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (ConfigComponent component : optionGroup.components) {
                if (component != null && component.selected == true && isGoldCpu(component)) {
                    return true;
                }
            }
        }
        return false;
    }

    static Boolean isGoldCpu(ConfigComponent component) {
        if (component == null) {
            return false;
        }
        String name = component.name == null ? '' : component.name;
        String sku = component.sku == null ? '' : component.sku;
        if (name.containsIgnoreCase('Xeon Gold')) {
            return true;
        }
        return sku.containsIgnoreCase('INTEL-GOLD')
            || sku.containsIgnoreCase('XEON-GOLD')
            || (sku.containsIgnoreCase('GOLD')
                && (sku.containsIgnoreCase('CPU') || sku.containsIgnoreCase('INTEL')));
    }

    static Boolean isDualGpuLaneLeak(ConfigResult result) {
        if (!equalsIgnore(
            attributeValue(
                result,
                new List<String>{ 'SocketConfiguration', 'Socket Configuration', 'Socket' }
            ),
            'Dual'
        )) {
            return false;
        }
        String tier = attributeValue(
            result,
            new List<String>{ 'PerformanceTier', 'Performance Tier' }
        );
        if (String.isBlank(tier) || equalsIgnore(tier, 'Entry')) {
            return false;
        }
        String x16 = attributeValue(
            result,
            new List<String>{ 'x16Lanes', 'x16 Lanes' }
        );
        return x16 == '1' || x16 == '1.0';
    }

    static String rewriteKnownConstraint(String text) {
        return rewriteKnownConstraint(text, null);
    }

    static String rewriteKnownConstraint(String text, ConfigResult result) {
        if (String.isBlank(text) || !constraintAppliesToMix(result, text)) {
            return null;
        }
        if (isGoldConstraintText(text)) {
            return DUAL_GOLD_FIX;
        }
        if (isDualWorkloadConstraintText(text) && isSingleWithNonGeneral(result)) {
            return SINGLE_WORKLOAD_FIX;
        }
        return text;
    }

    static Boolean constraintAppliesToMix(ConfigResult result, String text) {
        if (String.isBlank(text)) {
            return false;
        }
        if (isGoldConstraintText(text)) {
            return goldConstraintApplies(result);
        }
        if (text.containsIgnoreCase('two liquid coolers')
            && equalsIgnore(socketValue(result), 'Single')) {
            return false;
        }
        return true;
    }

    static Boolean isGoldConstraintText(String text) {
        if (String.isBlank(text)) {
            return false;
        }
        return text.containsIgnoreCase('Gold CPU')
            || text.containsIgnoreCase('only available for Platinum');
    }

    static Boolean isDualWorkloadConstraintText(String text) {
        return String.isNotBlank(text) && text.containsIgnoreCase('Dual sockets need Workload');
    }

    static Boolean goldConstraintApplies(ConfigResult result) {
        if (equalsIgnore(socketValue(result), 'Single')) {
            return false;
        }
        if (equalsIgnore(socketValue(result), 'Dual')
            && selectedQty(result, 'cpu') > 0
            && !hasSelectedGoldCpu(result)) {
            return false;
        }
        return true;
    }

    static void mergeConfigureMessages(ConfigResult target, ConfigResult source) {
        if (target == null || source == null) {
            return;
        }
        if (source.messages != null) {
            if (target.messages == null) {
                target.messages = new List<ConfigMessage>();
            }
            Set<String> seen = new Set<String>();
            for (ConfigMessage existing : target.messages) {
                if (existing != null && String.isNotBlank(existing.text)) {
                    seen.add(existing.text.toLowerCase());
                }
            }
            for (ConfigMessage msg : source.messages) {
                if (msg == null || String.isBlank(msg.text)) {
                    continue;
                }
                if (!constraintAppliesToMix(target, msg.text)) {
                    continue;
                }
                if (seen.contains(msg.text.toLowerCase())) {
                    continue;
                }
                seen.add(msg.text.toLowerCase());
                target.messages.add(msg);
            }
        }
        if (String.isNotBlank(source.message)
            && source.message != CRE_LOADING
            && !source.message.containsIgnoreCase('Loaded bundle options')
            && (String.isBlank(target.message)
                || target.message.containsIgnoreCase('Loaded bundle options')
                || target.message.containsIgnoreCase('Bundle picks saved'))) {
            if (isSolverLeftoverMessage(source.message) || isChangePicksMessage(source.message)
                || isPlatformConfigureMessage(source.message)) {
                target.message = source.message;
            }
        }
    }

    static String attributeValue(ConfigResult result, List<String> names) {
        if (result == null || result.attributes == null || names == null) {
            return null;
        }
        for (String name : names) {
            ConfigAttribute attr = findLoadedAttribute(result, name);
            if (attr != null && String.isNotBlank(attr.value)) {
                return attr.value;
            }
        }
        return null;
    }

    static Boolean isBlockingMessage(ConfigMessage msg) {
        if (msg == null) {
            return false;
        }
        String kind = String.isBlank(msg.messageType) ? '' : msg.messageType.toLowerCase();
        return kind == 'error' || kind == 'constraint' || kind.contains('error');
    }

    static String stripConstraintPrefix(String text) {
        if (String.isBlank(text)) {
            return text;
        }
        String trimmed = text.trim();
        if (trimmed.toLowerCase().startsWith('constraint:')) {
            return trimmed.substring(11).trim();
        }
        return trimmed;
    }

    static void appendRequiredFixSteps(ConfigResult result, List<String> steps) {
        if (result == null || steps == null) {
            return;
        }
        if (result.attributes != null) {
            for (ConfigAttribute attr : result.attributes) {
                if (attr == null) {
                    continue;
                }
                Boolean mustHaveValue = attr.required == true || attr.priceImpacting == true;
                if (!mustHaveValue) {
                    continue;
                }
                if (String.isNotBlank(attr.value) || String.isNotBlank(attr.picklistValueId)) {
                    continue;
                }
                String label = firstNonBlank(attr.label, attr.attributeName, 'An attribute');
                appendUnique(steps, label + ' still needs a value.');
            }
        }
        if (result.groups == null) {
            return;
        }
        for (ConfigGroup optionGroup : result.groups) {
            if (optionGroup == null || optionGroup.components == null) {
                continue;
            }
            for (ConfigComponent component : optionGroup.components) {
                if (component != null && component.required == true && component.selected != true) {
                    String name = String.isBlank(component.name) ? 'A required option' : component.name;
                    appendUnique(steps, name + ' is required. Keep it selected.');
                }
            }
        }
    }

    static void appendUnique(List<String> steps, String step) {
        if (steps == null || String.isBlank(step)) {
            return;
        }
        for (String existing : steps) {
            if (equalsIgnore(existing, step)) {
                return;
            }
        }
        steps.add(step);
    }

    @TestVisible
    static Boolean isRetryableConfigureCallout(Exception e) {
        if (e == null) {
            return false;
        }
        String msg = e.getMessage();
        if (String.isBlank(msg)) {
            return e instanceof CalloutException;
        }
        return msg.containsIgnoreCase('Script-thrown')
            || msg.containsIgnoreCase('UnexpectedException')
            || msg.containsIgnoreCase('Unauthorized')
            || msg.containsIgnoreCase('Invalid Session')
            || msg.containsIgnoreCase('session id')
            || msg.containsIgnoreCase('Configurator HTTP 401')
            || msg.containsIgnoreCase('Configurator HTTP 403');
    }

    @TestVisible
    static Boolean isRetryableCacheError(RLM_CreCalloutCache__c row) {
        if (row == null || row.Status__c != 'Error') {
            return false;
        }
        String msg = row.Message__c;
        if (String.isBlank(msg)) {
            return false;
        }
        return msg.containsIgnoreCase('401')
            || msg.containsIgnoreCase('403')
            || msg.containsIgnoreCase('Session expired')
            || msg.containsIgnoreCase('Invalid Session')
            || msg.containsIgnoreCase('session id')
            || msg.containsIgnoreCase('Unauthorized');
    }

    /**
     * Lightning UI needs Visualforce $Api.Session_ID (UserInfo session is not
     * API-capable). Hosted MCP / invocables cannot render Visualforce — and
     * getContent() throws an uncatchable UnexpectedException there — so use
     * the current API session instead.
     */
    static String apiSessionId() {
        if (Test.isRunningTest()) {
            return 'test-session';
        }
        if (canRenderVisualforceSession()) {
            return Page.RLM_SessionId.getContent().toString().trim();
        }
        return UserInfo.getSessionId();
    }

    static Boolean canRenderVisualforceSession() {
        try {
            System.Request req = System.Request.getCurrent();
            if (req == null) {
                return false;
            }
            System.Quiddity q = req.getQuiddity();
            String name = String.valueOf(q);
            return name == 'AURA' || name == 'VF' || name == 'VF_AJAX';
        } catch (Exception e) {
            return false;
        }
    }

    @TestVisible
    static Boolean canSyncConfigureCallout() {
        if (queueConfigureCallout == true) {
            return false;
        }
        if (Test.isRunningTest()) {
            return forceAsyncConfigure != true;
        }
        if (canRenderVisualforceSession()) {
            return true;
        }
        // Hosted MCP is often REST or INVOCABLE_ACTION. Same-org Http.send
        // there throws an uncatchable Script-thrown exception, so only
        // Lightning and jobs that already allow callouts may POST configure
        // in this transaction.
        String name = quiddityName();
        return name == 'QUEUEABLE'
            || name == 'FUTURE'
            || name == 'BATCH_APEX'
            || name == 'BATCH_CHUNK_SERIAL'
            || name == 'BATCH_CHUNK_PARALLEL';
    }

    static String quiddityName() {
        try {
            System.Request req = System.Request.getCurrent();
            if (req == null) {
                return '';
            }
            return String.valueOf(req.getQuiddity());
        } catch (Exception e) {
            return '';
        }
    }

    static ConfigResult cachedOrEnqueueConfigure(Id quoteId, Id lineId, Map<String, Object> body) {
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.groups = new List<ConfigGroup>();
        out.attributes = new List<ConfigAttribute>();
        out.messages = new List<ConfigMessage>();
        out.quoteLineItemId = lineId == null ? null : String.valueOf(lineId);
        String payload = JSON.serialize(body);
        String key = configureCacheKey(lineId, payload);
        RLM_CreCalloutCache__c row;
        try {
            row = configureCacheRow(key);
        } catch (Exception e) {
            row = null;
        }
        if (row != null && row.Status__c == 'Success' && String.isNotBlank(row.Result_Json__c)) {
            ConfigResult cached = deserializeCachedResult(row.Result_Json__c);
            if (cached != null) {
                return cached;
            }
        }
        if (row != null && row.Status__c == 'Error' && !isRetryableCacheError(row)) {
            out.message = String.isBlank(row.Message__c)
                ? 'Configurator callout failed.'
                : row.Message__c;
            return finish(out);
        }
        if (row != null && row.Status__c == 'Pending' && !cachePendingExpired(row)) {
            out.message = CRE_LOADING;
            return finish(out);
        }
        if (Test.isRunningTest()) {
            enqueueConfigureJob(quoteId, lineId, key, payload, 'test-session');
            out.message = CRE_LOADING;
            return finish(out);
        }
        try {
            requestConfigureViaCache(quoteId, lineId, payload);
        } catch (Exception e) {
            out.message = CRE_LOADING;
            return finish(out);
        }
        out.message = CRE_LOADING;
        return finish(out);
    }

    public static void enqueueLoadFromTask(Id quoteId, String lineRaw) {
        Id lineId = toId(lineRaw);
        if (quoteId == null || lineId == null) {
            return;
        }
        enqueueConfigureJob(
            quoteId,
            lineId,
            String.valueOf(lineId),
            null,
            null
        );
    }

    static void requestConfigureViaCache(Id quoteId, Id lineId) {
        requestConfigureViaCache(quoteId, lineId, null);
    }

    static void requestConfigureViaCache(Id quoteId, Id lineId, String payload) {
        String key = String.valueOf(lineId);
        RLM_CreCalloutCache__c row = configureCacheRow(key);
        if (row != null && row.Status__c == 'Pending' && !cachePendingExpired(row)
            && String.isBlank(payload)) {
            return;
        }
        if (row == null) {
            row = new RLM_CreCalloutCache__c(
                Key__c = key,
                Line_Id__c = key,
                Quote_Id__c = quoteId == null ? null : String.valueOf(quoteId),
                Status__c = 'Pending'
            );
        } else {
            row.Status__c = 'Pending';
            row.Message__c = null;
            row.Result_Json__c = null;
            row.Quote_Id__c = quoteId == null ? null : String.valueOf(quoteId);
        }
        row.Request_Json__c = payload;
        Database.UpsertResult saved = Database.upsert(
            row, RLM_CreCalloutCache__c.Key__c, AccessLevel.SYSTEM_MODE);
        // Production Hosted MCP must not enqueueJob here. The record-triggered
        // Flow async path starts Configure after this transaction commits.
        if (Test.isRunningTest()) {
            Id cacheId = saved == null ? null : saved.getId();
            if (cacheId == null && row.Id != null) {
                cacheId = row.Id;
            }
            enqueueLoadFromCache(cacheId, quoteId, lineId);
        }
    }

    public static void enqueueLoadFromCache(Id cacheId, Id quoteId, Id lineId) {
        if (cacheId == null || lineId == null) {
            return;
        }
        System.enqueueJob(new RLM_RampConfigureCallout(
            cacheId,
            quoteId,
            lineId,
            null,
            null
        ));
    }

    static ConfigResult readConfigureCacheByLine(Id lineId) {
        if (lineId == null) {
            return null;
        }
        String lineKey = String.valueOf(lineId);
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Status__c, Result_Json__c, Message__c FROM RLM_CreCalloutCache__c '
                + 'WHERE Line_Id__c = :lineKey ORDER BY LastModifiedDate DESC LIMIT 1',
            new Map<String, Object>{ 'lineKey' => lineKey },
            AccessLevel.SYSTEM_MODE
        );
        if (rows.isEmpty()) {
            return null;
        }
        RLM_CreCalloutCache__c row = rows[0];
        if (row.Status__c == 'Success' && String.isNotBlank(row.Result_Json__c)) {
            return deserializeCachedResult(row.Result_Json__c);
        }
        ConfigResult out = new ConfigResult();
        out.success = false;
        out.quoteLineItemId = lineKey;
        if (row.Status__c == 'Error') {
            if (isRetryableCacheError(row)) {
                return null;
            }
            out.message = String.isBlank(row.Message__c)
                ? 'Configurator callout failed.'
                : row.Message__c;
            return finish(out);
        }
        out.message = CRE_LOADING;
        return finish(out);
    }

    static void writeConfigureCache(Id lineId, ConfigResult parsed) {
        if (lineId == null || parsed == null) {
            return;
        }
        String key = String.valueOf(lineId);
        RLM_CreCalloutCache__c row = new RLM_CreCalloutCache__c(
            Key__c = key,
            Line_Id__c = key,
            Status__c = parsed.success == true ? 'Success' : 'Error',
            Result_Json__c = JSON.serialize(parsed),
            Message__c = parsed.message
        );
        if (row.Message__c != null && row.Message__c.length() > 255) {
            row.Message__c = row.Message__c.left(255);
        }
        Database.upsert(row, RLM_CreCalloutCache__c.Key__c, AccessLevel.SYSTEM_MODE);
    }

    public static void enqueueFromEvent(RLM_CreConfigureRequest__e evt) {
        if (evt == null || String.isBlank(evt.Line_Id__c) || String.isBlank(evt.Request_Json__c)) {
            return;
        }
        Id quoteId = toId(evt.Quote_Id__c);
        Id lineId = toId(evt.Line_Id__c);
        if (lineId == null) {
            return;
        }
        String key = String.isBlank(evt.Cache_Key__c)
            ? configureCacheKey(lineId, evt.Request_Json__c)
            : evt.Cache_Key__c;
        enqueueConfigureJob(quoteId, lineId, key, evt.Request_Json__c, evt.Session_Id__c);
    }

    static void enqueueConfigureJob(
        Id quoteId,
        Id lineId,
        String key,
        String payload,
        String sessionId
    ) {
        RLM_CreCalloutCache__c row = configureCacheRow(key);
        if (row != null && row.Status__c == 'Success' && String.isNotBlank(row.Result_Json__c)) {
            return;
        }
        if (row == null) {
            row = new RLM_CreCalloutCache__c(
                Key__c = key,
                Line_Id__c = String.valueOf(lineId),
                Quote_Id__c = quoteId == null ? null : String.valueOf(quoteId),
                Status__c = 'Pending'
            );
        } else {
            row.Status__c = 'Pending';
            row.Message__c = null;
            row.Result_Json__c = null;
        }
        Database.upsert(row, RLM_CreCalloutCache__c.Key__c, AccessLevel.SYSTEM_MODE);
        System.enqueueJob(new RLM_RampConfigureCallout(
            row.Id,
            quoteId,
            lineId,
            payload,
            sessionId
        ));
    }

    static String configureCacheKey(Id lineId, String payload) {
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(payload == null ? '' : payload));
        return String.valueOf(lineId) + ':' + EncodingUtil.convertToHex(digest).left(32);
    }

    static RLM_CreCalloutCache__c configureCacheRow(String key) {
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Id, Key__c, Line_Id__c, Quote_Id__c, Status__c, Message__c, '
                + 'Result_Json__c, Request_Json__c, LastModifiedDate '
                + 'FROM RLM_CreCalloutCache__c WHERE Key__c = :key LIMIT 1',
            new Map<String, Object>{ 'key' => key },
            AccessLevel.SYSTEM_MODE
        );
        return rows.isEmpty() ? null : rows[0];
    }

    static String cachedRequestJson(Id cacheId) {
        if (cacheId == null) {
            return null;
        }
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Request_Json__c FROM RLM_CreCalloutCache__c WHERE Id = :cacheId LIMIT 1',
            new Map<String, Object>{ 'cacheId' => cacheId },
            AccessLevel.SYSTEM_MODE
        );
        if (rows.isEmpty() || String.isBlank(rows[0].Request_Json__c)) {
            return null;
        }
        return rows[0].Request_Json__c;
    }

    static Boolean cachePendingExpired(RLM_CreCalloutCache__c row) {
        if (row == null || row.LastModifiedDate == null) {
            return true;
        }
        return Datetime.now().getTime() - row.LastModifiedDate.getTime()
            > CACHE_PENDING_SECONDS * 1000;
    }

    static ConfigResult deserializeCachedResult(String jsonBody) {
        if (String.isBlank(jsonBody)) {
            return null;
        }
        try {
            ConfigResult cached = (ConfigResult) JSON.deserialize(jsonBody, ConfigResult.class);
            if (cached != null && cached.success == null) {
                cached.success = String.isBlank(cached.message);
            }
            return finish(cached);
        } catch (Exception e) {
            return null;
        }
    }

    static void invalidateConfigureCache(Id lineId) {
        if (lineId == null) {
            return;
        }
        String lineKey = String.valueOf(lineId);
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Id FROM RLM_CreCalloutCache__c WHERE Line_Id__c = :lineKey',
            new Map<String, Object>{ 'lineKey' => lineKey },
            AccessLevel.SYSTEM_MODE
        );
        if (!rows.isEmpty()) {
            Database.delete(rows, AccessLevel.SYSTEM_MODE);
        }
    }

    public static void runQueuedConfigure(
        Id cacheId,
        Id quoteId,
        Id lineId,
        String payload,
        String sessionId
    ) {
        if (cacheId == null) {
            return;
        }
        try {
            if (String.isBlank(payload)) {
                payload = cachedRequestJson(cacheId);
            }
            if (String.isBlank(payload)) {
                QuoteLineItem owned = queryOwnedLine(quoteId, lineId);
                if (owned == null) {
                    markQueuedConfigureError(cacheId, 'That line is not on this quote.');
                    return;
                }
                payload = JSON.serialize(baseConfigureBody(
                    quoteId,
                    lineId,
                    queryChildren(quoteId, lineId).isEmpty(),
                    quoteAccountId(owned),
                    null
                ));
            }
            Map<String, Object> response = sendConfigure(
                'callout:' + LOOPBACK_NAMED_CREDENTIAL + CONFIGURE_PATH,
                payload,
                null
            );
            ConfigResult parsed = parseConfiguration(
                response, quoteId, lineId, queryChildren(quoteId, lineId));
            if (parsed != null && parsed.success == true) {
                try {
                    persistSelectionPreferringSystem(
                        quoteId,
                        lineId,
                        selectionFromResult(parsed, null),
                        queryChildren(quoteId, lineId),
                        true
                    );
                } catch (Exception persistError) {
                    // Cache the CRE mix even if Place Sales Transaction fails.
                }
            }
            RLM_CreCalloutCache__c row = new RLM_CreCalloutCache__c(
                Id = cacheId,
                Status__c = parsed != null && parsed.success == true ? 'Success' : 'Error',
                Result_Json__c = parsed == null ? null : JSON.serialize(parsed),
                Message__c = parsed == null ? 'Configurator returned no response.' : parsed.message
            );
            if (row.Message__c != null && row.Message__c.length() > 255) {
                row.Message__c = row.Message__c.left(255);
            }
            Database.update(row, AccessLevel.SYSTEM_MODE);
            try {
                writeConfigureCache(lineId, parsed);
            } catch (Exception cacheError) {
                // Line-keyed cache is used by Hosted MCP retries.
            }
            if (row.Status__c == 'Success') {
                String lineKey = lineId == null ? null : String.valueOf(lineId);
                if (lineKey != null) {
                    List<RLM_CreCalloutCache__c> stale = Database.queryWithBinds(
                        'SELECT Id FROM RLM_CreCalloutCache__c '
                            + 'WHERE Line_Id__c = :lineKey AND Id != :cacheId',
                        new Map<String, Object>{
                            'lineKey' => lineKey,
                            'cacheId' => cacheId
                        },
                        AccessLevel.SYSTEM_MODE
                    );
                    if (!stale.isEmpty()) {
                        Database.delete(stale, AccessLevel.SYSTEM_MODE);
                    }
                }
            }
        } catch (Exception e) {
            markQueuedConfigureError(cacheId, e.getMessage());
        }
    }

    public static void markQueuedConfigureError(Id cacheId, String message) {
        if (cacheId == null) {
            return;
        }
        String trimmed = String.isBlank(message)
            ? 'Configurator callout failed.'
            : message.left(255);
        Database.update(
            new RLM_CreCalloutCache__c(
                Id = cacheId,
                Status__c = 'Error',
                Message__c = trimmed
            ),
            AccessLevel.SYSTEM_MODE
        );
    }

    static QuoteLineItem queryOwnedLine(Id quoteId, Id lineId) {
        List<QuoteLineItem> owned = [
            SELECT Id, Product2Id, Quote.AccountId, Quote.Pricebook2Id
            FROM QuoteLineItem
            WHERE Id = :lineId
            AND QuoteId = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        return owned.isEmpty() ? null : owned[0];
    }

    static Id quoteAccountId(QuoteLineItem line) {
        return line == null || line.Quote == null ? null : line.Quote.AccountId;
    }

    static Map<String, QuoteLineItem> queryChildren(Id quoteId, Id parentLineId) {
        Map<String, QuoteLineItem> byProduct = new Map<String, QuoteLineItem>();
        for (QuoteLineItem child : [
            SELECT Id, Product2Id, PricebookEntryId, Quantity, ProductSellingModelId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND ParentQuoteLineItemId = :parentLineId
            WITH USER_MODE
        ]) {
            if (child.Product2Id != null) {
                byProduct.put(String.valueOf(child.Product2Id), child);
            }
        }
        Set<Id> relatedIds = new Set<Id>();
        for (QuoteLineRelationship rel : [
            SELECT AssociatedQuoteLineId
            FROM QuoteLineRelationship
            WHERE MainQuoteLineId = :parentLineId
            WITH USER_MODE
        ]) {
            if (rel.AssociatedQuoteLineId != null) {
                relatedIds.add(rel.AssociatedQuoteLineId);
            }
        }
        if (relatedIds.isEmpty()) {
            return byProduct;
        }
        for (QuoteLineItem child : [
            SELECT Id, Product2Id, PricebookEntryId, Quantity, ProductSellingModelId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND Id IN :relatedIds
            WITH USER_MODE
        ]) {
            if (child.Product2Id != null && !byProduct.containsKey(String.valueOf(child.Product2Id))) {
                byProduct.put(String.valueOf(child.Product2Id), child);
            }
        }
        return byProduct;
    }

    @TestVisible
    static List<ConfigGroup> buildCatalogGroups(
        Id parentProductId,
        Id pricebookId,
        Map<String, QuoteLineItem> childrenByProduct
    ) {
        List<ConfigGroup> groups = new List<ConfigGroup>();
        if (parentProductId == null) {
            return groups;
        }
        Boolean hasChildren = childrenByProduct != null && !childrenByProduct.isEmpty();
        List<ProductComponentGroup> rawGroups = [
            SELECT Id, Name, Code, MinBundleComponents, MaxBundleComponents, Sequence
            FROM ProductComponentGroup
            WHERE ParentProductId = :parentProductId
            WITH USER_MODE
            ORDER BY Sequence NULLS LAST, Name
        ];
        List<ProductRelatedComponent> components = [
            SELECT Id, ChildProductId, ChildProduct.Name, ChildProduct.StockKeepingUnit,
                   ProductComponentGroupId, IsComponentRequired, IsDefaultComponent,
                   IsQuantityEditable, Quantity, DoesBundlePriceIncludeChild,
                   ProductRelationshipTypeId, ChildSellingModelId, Sequence
            FROM ProductRelatedComponent
            WHERE ParentProductId = :parentProductId
            AND ChildProductId != null
            WITH USER_MODE
            ORDER BY Sequence NULLS LAST
        ];
        Set<Id> childProductIds = new Set<Id>();
        Map<Id, List<ProductRelatedComponent>> byGroup = new Map<Id, List<ProductRelatedComponent>>();
        List<ProductRelatedComponent> ungrouped = new List<ProductRelatedComponent>();
        for (ProductRelatedComponent prc : components) {
            childProductIds.add(prc.ChildProductId);
            if (prc.ProductComponentGroupId == null) {
                ungrouped.add(prc);
            } else {
                if (!byGroup.containsKey(prc.ProductComponentGroupId)) {
                    byGroup.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
                }
                byGroup.get(prc.ProductComponentGroupId).add(prc);
            }
        }
        Map<String, PricebookEntry> pbeByProduct = new Map<String, PricebookEntry>();
        if (pricebookId != null && !childProductIds.isEmpty()) {
            for (PricebookEntry pbe : [
                SELECT Id, Product2Id, ProductSellingModelId, ProductSellingModel.Name,
                       ProductSellingModel.SellingModelType, UnitPrice
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebookId
                AND Product2Id IN :childProductIds
                AND IsActive = true
                WITH USER_MODE
            ]) {
                String key = String.valueOf(pbe.Product2Id);
                if (!pbeByProduct.containsKey(key)) {
                    pbeByProduct.put(key, pbe);
                }
            }
        }
        for (ProductComponentGroup raw : rawGroups) {
            ConfigGroup optionGroup = new ConfigGroup();
            optionGroup.id = raw.Id;
            optionGroup.name = raw.Name;
            optionGroup.code = raw.Code;
            optionGroup.minComponents = asInteger(raw.MinBundleComponents);
            optionGroup.maxComponents = asInteger(raw.MaxBundleComponents);
            optionGroup.selectionMode = optionGroup.maxComponents == 1 ? 'single' : 'multiple';
            optionGroup.rangeLabel = rangeLabel(optionGroup.minComponents, optionGroup.maxComponents);
            optionGroup.components = catalogComponents(
                byGroup.get(raw.Id), hasChildren, childrenByProduct, pbeByProduct, optionGroup.selectionMode);
            groups.add(optionGroup);
        }
        if (!ungrouped.isEmpty()) {
            ConfigGroup other = new ConfigGroup();
            other.name = 'Other';
            other.selectionMode = 'multiple';
            other.components = catalogComponents(
                ungrouped, hasChildren, childrenByProduct, pbeByProduct, other.selectionMode);
            groups.add(other);
        }
        return groups;
    }

    static List<ConfigComponent> catalogComponents(
        List<ProductRelatedComponent> rows,
        Boolean hasChildren,
        Map<String, QuoteLineItem> childrenByProduct,
        Map<String, PricebookEntry> pbeByProduct,
        String selectionMode
    ) {
        List<ConfigComponent> components = new List<ConfigComponent>();
        if (rows == null) {
            return components;
        }
        for (ProductRelatedComponent prc : rows) {
            ConfigComponent component = new ConfigComponent();
            component.product2Id = String.valueOf(prc.ChildProductId);
            component.name = prc.ChildProduct == null ? null : prc.ChildProduct.Name;
            component.sku = prc.ChildProduct == null ? null : prc.ChildProduct.StockKeepingUnit;
            component.required = prc.IsComponentRequired == true;
            component.defaulted = prc.IsDefaultComponent == true;
            component.quantityEditable = prc.IsQuantityEditable != false;
            component.quantity = prc.Quantity == null || prc.Quantity <= 0 ? 1 : prc.Quantity;
            component.productRelatedComponentId = prc.Id;
            component.productRelationshipTypeId = prc.ProductRelationshipTypeId;
            component.includedInBundle = prc.DoesBundlePriceIncludeChild == true;
            PricebookEntry pbe = pbeByProduct == null ? null : pbeByProduct.get(component.product2Id);
            if (pbe != null) {
                component.pricebookEntryId = pbe.Id;
                component.productSellingModelId = pbe.ProductSellingModelId;
                component.unitPrice = pbe.UnitPrice;
                if (pbe.ProductSellingModel != null) {
                    component.sellingModelName = pbe.ProductSellingModel.Name;
                    component.sellingModelType = pbe.ProductSellingModel.SellingModelType;
                }
            }
            QuoteLineItem existing = childrenByProduct == null
                ? null
                : childrenByProduct.get(component.product2Id);
            if (existing != null) {
                component.selected = true;
                component.quoteLineItemId = existing.Id;
                if (existing.Quantity != null) {
                    component.quantity = existing.Quantity;
                }
            } else if (hasChildren == true) {
                component.selected = component.required == true;
            } else {
                component.selected = component.required == true || component.defaulted == true;
            }
            components.add(component);
        }
        return components;
    }

    static List<ConfigSellingModel> parseComponentPrices(Object pricesObj) {
        List<ConfigSellingModel> models = new List<ConfigSellingModel>();
        if (!(pricesObj instanceof List<Object>)) {
            return models;
        }
        for (Object item : (List<Object>) pricesObj) {
            Map<String, Object> price = asMap(item);
            if (price == null || String.isBlank(asString(price.get('pricebookEntryId')))) {
                continue;
            }
            ConfigSellingModel model = new ConfigSellingModel();
            model.pricebookEntryId = asString(price.get('pricebookEntryId'));
            model.unitPrice = asDecimal(price.get('unitPrice'));
            model.isDefault = price.get('isDefault') == true;
            Map<String, Object> pricing = asMap(price.get('pricingModel'));
            if (pricing != null) {
                model.productSellingModelId = asString(pricing.get('id'));
                model.name = asString(pricing.get('name'));
            }
            models.add(model);
        }
        return models;
    }

    static void applyPrice(ConfigComponent component, QuoteLineItem existing) {
        if (component.sellingModels == null || component.sellingModels.isEmpty()) {
            return;
        }
        ConfigSellingModel selected;
        if (existing != null && existing.PricebookEntryId != null) {
            for (ConfigSellingModel model : component.sellingModels) {
                if (model.pricebookEntryId == String.valueOf(existing.PricebookEntryId)) {
                    selected = model;
                    break;
                }
            }
        }
        if (selected == null) {
            for (ConfigSellingModel model : component.sellingModels) {
                if (model.isDefault == true) {
                    selected = model;
                    break;
                }
            }
        }
        if (selected == null) {
            selected = component.sellingModels[0];
        }
        component.pricebookEntryId = selected.pricebookEntryId;
        component.productSellingModelId = selected.productSellingModelId;
        component.sellingModelName = selected.name;
        component.unitPrice = selected.unitPrice;
    }

    static Map<String, Object> firstCatalogProduct(Object catalogObj) {
        if (!(catalogObj instanceof List<Object>) || ((List<Object>) catalogObj).isEmpty()) {
            return null;
        }
        return asMap(((List<Object>) catalogObj)[0]);
    }

    static Map<String, ConfigAttribute> attributesFromContext(Object contextObj, Id lineId) {
        Map<String, ConfigAttribute> values = new Map<String, ConfigAttribute>();
        Map<String, Object> context = asMap(contextObj);
        if (context == null) {
            return values;
        }
        Object txnsObj = context.get('SalesTransaction');
        if (!(txnsObj instanceof List<Object>)) {
            return values;
        }
        String lineKey = lineId == null ? null : String.valueOf(lineId);
        for (Object txnItem : (List<Object>) txnsObj) {
            Map<String, Object> txn = asMap(txnItem);
            if (txn == null) {
                continue;
            }
            Object itemsObj = txn.get('SalesTransactionItem');
            if (!(itemsObj instanceof List<Object>)) {
                continue;
            }
            for (Object itemObj : (List<Object>) itemsObj) {
                Map<String, Object> item = asMap(itemObj);
                if (item == null) {
                    continue;
                }
                if (lineKey != null && asString(item.get('id')) != lineKey) {
                    continue;
                }
                Object attrsObj = item.get('SalesTransactionItemAttribute');
                if (!(attrsObj instanceof List<Object>)) {
                    continue;
                }
                for (Object attrObj : (List<Object>) attrsObj) {
                    Map<String, Object> raw = asMap(attrObj);
                    if (raw == null) {
                        continue;
                    }
                    ConfigAttribute attr = new ConfigAttribute();
                    attr.attributeRecordId = asString(raw.get('id'));
                    attr.attributeKey = asString(raw.get('AttributeKey'));
                    attr.attributeName = asString(raw.get('AttributeName'));
                    attr.value = asString(raw.get('AttributeValue'));
                    attr.picklistValueId = asString(raw.get('AttributePicklistValue'));
                    if (String.isNotBlank(attr.attributeKey)) {
                        values.put(attr.attributeKey, attr);
                    }
                    if (String.isNotBlank(attr.attributeName)) {
                        values.put(attr.attributeName, attr);
                    }
                }
            }
        }
        return values;
    }

    static ConfigAttribute contextAttributeFor(
        Map<String, ConfigAttribute> contextAttributes,
        ConfigAttribute catalogAttr
    ) {
        if (contextAttributes == null || catalogAttr == null) {
            return null;
        }
        if (String.isNotBlank(catalogAttr.attributeKey)
            && contextAttributes.containsKey(catalogAttr.attributeKey)) {
            return contextAttributes.get(catalogAttr.attributeKey);
        }
        if (String.isNotBlank(catalogAttr.attributeName)
            && contextAttributes.containsKey(catalogAttr.attributeName)) {
            return contextAttributes.get(catalogAttr.attributeName);
        }
        return null;
    }

    static Boolean canSendAttribute(ConfigAttribute attr) {
        return attr != null && String.isNotBlank(attr.value);
    }

    static Boolean isUsableAttributeNodeId(String value, Boolean hasContext) {
        if (String.isBlank(value)) {
            return false;
        }
        if (value.startsWithIgnoreCase('ref_')) {
            return hasContext == true;
        }
        return value.length() == 15 || value.length() == 18 || hasContext == true;
    }

    static Boolean looksLikeInvalidAttribute(String message) {
        return String.isNotBlank(message) && message.containsIgnoreCase('attribute key');
    }

    static Map<String, Object> attributeFieldUpdates(ConfigAttribute attr) {
        Map<String, Object> fields = new Map<String, Object>{
            'AttributeValue' => attr.value
        };
        if (String.isNotBlank(attr.picklistValueId)) {
            fields.put('AttributePicklistValue', attr.picklistValueId);
        }
        return fields;
    }

    static List<ConfigPicklistOption> parsePicklist(Object picklistObj) {
        List<ConfigPicklistOption> options = new List<ConfigPicklistOption>();
        Map<String, Object> picklist = asMap(picklistObj);
        if (picklist == null) {
            return options;
        }
        Object valuesObj = picklist.get('values');
        if (!(valuesObj instanceof List<Object>)) {
            return options;
        }
        for (Object item : (List<Object>) valuesObj) {
            Map<String, Object> raw = asMap(item);
            if (raw == null) {
                continue;
            }
            ConfigPicklistOption option = new ConfigPicklistOption();
            option.picklistValueId = asString(raw.get('id'));
            option.value = firstNonBlank(
                asString(raw.get('textValue')),
                asString(raw.get('displayValue')),
                asString(raw.get('name')));
            option.label = firstNonBlank(
                asString(raw.get('displayValue')),
                asString(raw.get('name')),
                option.value);
            if (String.isNotBlank(option.value)) {
                options.add(option);
            }
        }
        return options;
    }

    static ConfigPicklistOption matchPicklistOption(
        List<ConfigPicklistOption> options,
        String value
    ) {
        if (options == null || String.isBlank(value)) {
            return null;
        }
        for (ConfigPicklistOption option : options) {
            if (option == null) {
                continue;
            }
            if (equalsIgnore(option.value, value) || equalsIgnore(option.label, value)) {
                return option;
            }
        }
        return null;
    }

    static String picklistIdForValue(List<ConfigPicklistOption> options, String value) {
        ConfigPicklistOption matched = matchPicklistOption(options, value);
        return matched == null ? null : matched.picklistValueId;
    }

    @TestVisible
    static String rangeLabel(Integer minVal, Integer maxVal) {
        if (minVal != null && maxVal != null && minVal == maxVal) {
            return 'Pick ' + String.valueOf(minVal);
        }
        if (minVal != null && maxVal != null) {
            return 'Pick ' + String.valueOf(minVal) + '–' + String.valueOf(maxVal);
        }
        if (minVal != null) {
            return 'Pick at least ' + String.valueOf(minVal);
        }
        if (maxVal != null) {
            return 'Pick up to ' + String.valueOf(maxVal);
        }
        return 'Optional';
    }

    @TestVisible
    static String decodeName(String value) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"');
    }

    static String firstError(Object errorsObj) {
        if (errorsObj instanceof List<Object> && !((List<Object>) errorsObj).isEmpty()) {
            Map<String, Object> first = asMap(((List<Object>) errorsObj)[0]);
            if (first != null) {
                String msg = firstNonBlank(asString(first.get('message')), asString(first.get('errorCode')));
                if (String.isNotBlank(msg)) {
                    return msg;
                }
            }
        }
        return null;
    }

    static String conciseError(String body) {
        if (String.isBlank(body)) {
            return 'empty response';
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof List<Object> && !((List<Object>) parsed).isEmpty()) {
                Map<String, Object> first = asMap(((List<Object>) parsed)[0]);
                if (first != null) {
                    return firstNonBlank(asString(first.get('message')), body.left(300));
                }
            }
            Map<String, Object> mapBody = asMap(parsed);
            if (mapBody != null) {
                String msg = firstError(mapBody.get('errors'));
                if (String.isNotBlank(msg)) {
                    return msg;
                }
                msg = asString(mapBody.get('message'));
                if (String.isNotBlank(msg)) {
                    return msg;
                }
            }
        } catch (Exception e) {
            return body.left(300);
        }
        return body.left(300);
    }

    static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
    }

    @TestVisible
    static List<ConfigAttribute> loadCatalogAttributes(Id product2Id, Id lineId) {
        List<ConfigAttribute> attributes = new List<ConfigAttribute>();
        if (product2Id == null) {
            return attributes;
        }
        Id classificationId;
        for (Product2 product : [
            SELECT BasedOnId
            FROM Product2
            WHERE Id = :product2Id
            LIMIT 1
        ]) {
            classificationId = product.BasedOnId;
        }
        Map<Id, ConfigAttribute> byDefId = new Map<Id, ConfigAttribute>();
        List<Id> orderedDefIds = new List<Id>();
        if (classificationId != null) {
            for (ProductClassificationAttr pca : [
                SELECT AttributeDefinitionId, IsRequired, IsPriceImpacting, IsHidden,
                    IsReadOnly, AttributeNameOverride, DefaultValue, Name, Sequence
                FROM ProductClassificationAttr
                WHERE ProductClassificationId = :classificationId
                AND Status = 'Active'
                AND IsHidden = false
                AND IsReadOnly = false
                ORDER BY Sequence ASC NULLS LAST
            ]) {
                if (pca.AttributeDefinitionId == null) {
                    continue;
                }
                ConfigAttribute attr = new ConfigAttribute();
                attr.attributeKey = String.valueOf(pca.AttributeDefinitionId);
                attr.label = firstNonBlank(pca.AttributeNameOverride, pca.Name);
                attr.required = pca.IsRequired == true;
                attr.priceImpacting = pca.IsPriceImpacting == true;
                attr.value = pca.DefaultValue;
                byDefId.put(pca.AttributeDefinitionId, attr);
                orderedDefIds.add(pca.AttributeDefinitionId);
            }
        }
        for (ProductAttributeDefinition pad : [
            SELECT Id, Name, AttributeNameOverride, DefaultValue, IsRequired,
                IsPriceImpacting, AttributeDefinitionId, Sequence
            FROM ProductAttributeDefinition
            WHERE Product2Id = :product2Id
            AND IsHidden = false
            AND Status = 'Active'
            AND IsReadOnly = false
            ORDER BY Sequence ASC NULLS LAST
        ]) {
            if (pad.AttributeDefinitionId == null) {
                continue;
            }
            ConfigAttribute attr = byDefId.containsKey(pad.AttributeDefinitionId)
                ? byDefId.get(pad.AttributeDefinitionId)
                : new ConfigAttribute();
            attr.attributeKey = String.valueOf(pad.Id);
            attr.label = firstNonBlank(pad.AttributeNameOverride, pad.Name, attr.label);
            attr.required = pad.IsRequired == true;
            attr.priceImpacting = pad.IsPriceImpacting == true;
            if (String.isBlank(attr.value)) {
                attr.value = pad.DefaultValue;
            }
            if (!byDefId.containsKey(pad.AttributeDefinitionId)) {
                orderedDefIds.add(pad.AttributeDefinitionId);
            }
            byDefId.put(pad.AttributeDefinitionId, attr);
        }
        if (byDefId.isEmpty()) {
            return attributes;
        }
        Map<Id, AttributeDefinition> defs = new Map<Id, AttributeDefinition>([
            SELECT Id, Name, DeveloperName, DataType, PicklistId
            FROM AttributeDefinition
            WHERE Id IN :byDefId.keySet()
        ]);
        Set<Id> picklistIds = new Set<Id>();
        for (AttributeDefinition def : defs.values()) {
            ConfigAttribute attr = byDefId.get(def.Id);
            if (attr == null) {
                continue;
            }
            attr.attributeName = def.DeveloperName;
            if (String.isBlank(attr.label)) {
                attr.label = def.Name;
            }
            attr.dataType = def.DataType;
            if (def.PicklistId != null) {
                picklistIds.add(def.PicklistId);
            }
        }
        Map<Id, List<ConfigPicklistOption>> optionsByPicklist =
            new Map<Id, List<ConfigPicklistOption>>();
        if (!picklistIds.isEmpty()) {
            for (AttributePicklistValue pv : [
                SELECT Id, Name, Code, Value, DisplayValue, PicklistId, Status
                FROM AttributePicklistValue
                WHERE PicklistId IN :picklistIds
                ORDER BY Sequence ASC NULLS LAST
            ]) {
                if (pv.Status == 'Inactive') {
                    continue;
                }
                if (!optionsByPicklist.containsKey(pv.PicklistId)) {
                    optionsByPicklist.put(pv.PicklistId, new List<ConfigPicklistOption>());
                }
                ConfigPicklistOption option = new ConfigPicklistOption();
                option.picklistValueId = String.valueOf(pv.Id);
                option.value = firstNonBlank(pv.Value, pv.Code, pv.Name);
                option.label = firstNonBlank(pv.DisplayValue, pv.Name, option.value);
                if (String.isNotBlank(option.value)) {
                    optionsByPicklist.get(pv.PicklistId).add(option);
                }
            }
        }
        for (AttributeDefinition def : defs.values()) {
            ConfigAttribute attr = byDefId.get(def.Id);
            if (attr == null) {
                continue;
            }
            if (def.PicklistId != null && optionsByPicklist.containsKey(def.PicklistId)) {
                attr.options = optionsByPicklist.get(def.PicklistId);
            }
            if (String.isBlank(attr.picklistValueId)) {
                attr.picklistValueId = picklistIdForValue(attr.options, attr.value);
            }
        }
        if (lineId != null) {
            for (QuoteLineItemAttribute qlia : [
                SELECT Id, AttributeDefinitionId, AttributeName, AttributeValue,
                    AttributePicklistValueId, IsPriceImpacting
                FROM QuoteLineItemAttribute
                WHERE QuoteLineItemId = :lineId
            ]) {
                ConfigAttribute attr = qlia.AttributeDefinitionId == null
                    ? null
                    : byDefId.get(qlia.AttributeDefinitionId);
                if (attr == null) {
                    continue;
                }
                attr.attributeRecordId = String.valueOf(qlia.Id);
                if (String.isNotBlank(qlia.AttributeValue)) {
                    attr.value = qlia.AttributeValue;
                }
                if (qlia.AttributePicklistValueId != null) {
                    attr.picklistValueId = String.valueOf(qlia.AttributePicklistValueId);
                }
                if (attr.priceImpacting != true && qlia.IsPriceImpacting == true) {
                    attr.priceImpacting = true;
                }
            }
        }
        for (Id defId : orderedDefIds) {
            ConfigAttribute attr = byDefId.get(defId);
            if (attr != null) {
                attributes.add(attr);
            }
        }
        return attributes;
    }

    @TestVisible
    static void overlayPriceImpacting(List<ConfigAttribute> attributes, Id product2Id) {
        if (attributes == null || attributes.isEmpty() || product2Id == null) {
            return;
        }
        List<ConfigAttribute> missing = new List<ConfigAttribute>();
        for (ConfigAttribute attr : attributes) {
            if (attr != null && attr.priceImpacting == null) {
                missing.add(attr);
            }
        }
        if (missing.isEmpty()) {
            return;
        }
        Map<String, Boolean> byKey = new Map<String, Boolean>();
        for (ProductAttributeDefinition pad : [
            SELECT Id, Name, AttributeNameOverride, IsPriceImpacting,
                AttributeDefinition.DeveloperName
            FROM ProductAttributeDefinition
            WHERE Product2Id = :product2Id
        ]) {
            putPriceFlag(byKey, String.valueOf(pad.Id), pad.IsPriceImpacting);
            putPriceFlag(byKey, pad.Name, pad.IsPriceImpacting);
            putPriceFlag(byKey, pad.AttributeNameOverride, pad.IsPriceImpacting);
            putPriceFlag(
                byKey,
                pad.AttributeDefinition == null ? null : pad.AttributeDefinition.DeveloperName,
                pad.IsPriceImpacting);
        }
        Id classificationId;
        for (Product2 product : [
            SELECT BasedOnId
            FROM Product2
            WHERE Id = :product2Id
            LIMIT 1
        ]) {
            classificationId = product.BasedOnId;
        }
        if (classificationId != null) {
            for (ProductClassificationAttr pca : [
                SELECT AttributeDefinitionId, Name, AttributeNameOverride, IsPriceImpacting,
                    AttributeDefinition.DeveloperName
                FROM ProductClassificationAttr
                WHERE ProductClassificationId = :classificationId
            ]) {
                putPriceFlag(byKey, String.valueOf(pca.AttributeDefinitionId), pca.IsPriceImpacting);
                putPriceFlag(byKey, pca.Name, pca.IsPriceImpacting);
                putPriceFlag(byKey, pca.AttributeNameOverride, pca.IsPriceImpacting);
                putPriceFlag(
                    byKey,
                    pca.AttributeDefinition == null ? null : pca.AttributeDefinition.DeveloperName,
                    pca.IsPriceImpacting);
            }
        }
        for (ConfigAttribute attr : missing) {
            Boolean flagged = priceFlagFor(byKey, attr);
            if (flagged != null) {
                attr.priceImpacting = flagged;
            }
        }
    }

    static void putPriceFlag(Map<String, Boolean> byKey, String key, Boolean flagged) {
        if (byKey == null || String.isBlank(key) || flagged == null) {
            return;
        }
        byKey.put(key.toLowerCase(), flagged);
    }

    static Boolean priceFlagFor(Map<String, Boolean> byKey, ConfigAttribute attr) {
        if (byKey == null || attr == null) {
            return null;
        }
        List<String> keys = new List<String>{
            attr.attributeKey, attr.attributeName, attr.label
        };
        for (String key : keys) {
            if (String.isBlank(key)) {
                continue;
            }
            String lower = key.toLowerCase();
            if (byKey.containsKey(lower)) {
                return byKey.get(lower);
            }
        }
        return null;
    }

    static void applySelectionAttributeValues(ConfigResult loaded, Selection selection) {
        if (loaded == null || loaded.attributes == null || selection == null
            || selection.attributes == null) {
            return;
        }
        for (ConfigAttribute picked : selection.attributes) {
            if (picked == null) {
                continue;
            }
            for (ConfigAttribute attr : loaded.attributes) {
                if (attr == null) {
                    continue;
                }
                Boolean sameKey = String.isNotBlank(picked.attributeKey)
                    && picked.attributeKey == attr.attributeKey;
                Boolean sameName = String.isNotBlank(picked.attributeName)
                    && String.isNotBlank(attr.attributeName)
                    && picked.attributeName.equalsIgnoreCase(attr.attributeName);
                if (!sameKey && !sameName) {
                    continue;
                }
                if (String.isNotBlank(picked.value)) {
                    attr.value = picked.value;
                }
                if (String.isNotBlank(picked.picklistValueId)) {
                    attr.picklistValueId = picked.picklistValueId;
                }
            }
        }
    }

    @TestVisible
    static Integer addAttributePersistNodes(
        List<RevSalesTrxn.RecordWithReferenceRequest> records,
        Id parentLineId,
        Selection selection,
        Integer startIndex
    ) {
        Integer i = startIndex == null ? 0 : startIndex;
        if (records == null || parentLineId == null || selection == null
            || selection.attributes == null || selection.attributes.isEmpty()) {
            return i;
        }
        Set<String> names = new Set<String>();
        Set<Id> keyIds = new Set<Id>();
        for (ConfigAttribute attr : selection.attributes) {
            if (attr == null || !canSendAttribute(attr)) {
                continue;
            }
            if (String.isNotBlank(attr.attributeName)) {
                names.add(attr.attributeName);
            }
            Id keyId = toId(attr.attributeKey);
            if (keyId != null) {
                keyIds.add(keyId);
            }
        }
        Map<Id, QuoteLineItemAttribute> existingByDefId =
            new Map<Id, QuoteLineItemAttribute>();
        Map<String, QuoteLineItemAttribute> existingByName =
            new Map<String, QuoteLineItemAttribute>();
        for (QuoteLineItemAttribute qlia : [
            SELECT Id, AttributeDefinitionId, AttributeName
            FROM QuoteLineItemAttribute
            WHERE QuoteLineItemId = :parentLineId
        ]) {
            if (qlia.AttributeDefinitionId != null) {
                existingByDefId.put(qlia.AttributeDefinitionId, qlia);
            }
            if (String.isNotBlank(qlia.AttributeName)) {
                existingByName.put(qlia.AttributeName.toLowerCase(), qlia);
            }
        }
        Map<Id, Id> defIdByKey = new Map<Id, Id>();
        Map<String, Id> defIdByName = new Map<String, Id>();
        if (!keyIds.isEmpty()) {
            for (ProductAttributeDefinition pad : [
                SELECT Id, AttributeDefinitionId
                FROM ProductAttributeDefinition
                WHERE Id IN :keyIds
            ]) {
                if (pad.AttributeDefinitionId != null) {
                    defIdByKey.put(pad.Id, pad.AttributeDefinitionId);
                }
            }
        }
        if (!keyIds.isEmpty() || !names.isEmpty()) {
            for (AttributeDefinition def : [
                SELECT Id, DeveloperName
                FROM AttributeDefinition
                WHERE Id IN :keyIds
                OR DeveloperName IN :names
            ]) {
                defIdByKey.put(def.Id, def.Id);
                if (String.isNotBlank(def.DeveloperName)) {
                    defIdByName.put(def.DeveloperName.toLowerCase(), def.Id);
                }
            }
        }
        for (ConfigAttribute attr : selection.attributes) {
            if (attr == null || !canSendAttribute(attr)) {
                continue;
            }
            Id defId = defIdByKey.get(toId(attr.attributeKey));
            if (defId == null && String.isNotBlank(attr.attributeName)) {
                defId = defIdByName.get(attr.attributeName.toLowerCase());
            }
            QuoteLineItemAttribute existing = defId == null
                ? null
                : existingByDefId.get(defId);
            if (existing == null && String.isNotBlank(attr.attributeName)) {
                existing = existingByName.get(attr.attributeName.toLowerCase());
            }
            RevSalesTrxn.RecordResource node;
            if (existing != null && existing.Id != null) {
                node = new RevSalesTrxn.RecordResource(
                    QuoteLineItemAttribute.getSObjectType(), 'PATCH', existing.Id);
            } else if (defId != null) {
                node = new RevSalesTrxn.RecordResource(
                    QuoteLineItemAttribute.getSObjectType(), 'POST');
            } else {
                continue;
            }
            Map<String, Object> fields = new Map<String, Object>{
                'AttributeValue' => attr.value == null ? '' : attr.value
            };
            if (existing == null || existing.Id == null) {
                fields.put('QuoteLineItemId', parentLineId);
                fields.put('AttributeDefinitionId', defId);
                if (String.isNotBlank(attr.attributeName)) {
                    fields.put('AttributeName', attr.attributeName);
                }
            }
            if (String.isNotBlank(attr.picklistValueId)) {
                fields.put('AttributePicklistValueId', attr.picklistValueId);
            }
            node.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refAttr' + String.valueOf(i), node));
            i++;
        }
        return i;
    }

    static Boolean asOptionalBoolean(Object a, Object b) {
        Boolean fromA = asOptionalBoolean(a);
        return fromA != null ? fromA : asOptionalBoolean(b);
    }

    static Boolean asOptionalBoolean(Object value) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value);
        if (text.equalsIgnoreCase('true')) {
            return true;
        }
        if (text.equalsIgnoreCase('false')) {
            return false;
        }
        return null;
    }

    static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    static Integer asInteger(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Integer) {
            return (Integer) value;
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).intValue();
        }
        try {
            return Integer.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    static Decimal asDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : b;
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
    static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }
}
