/**
 * Ramp-native bundle add-on panel. Loads option groups and attributes from
 * Configurator configure, and writes picks through the same API so constraint
 * and bundle-validation rules still run.
 */
public with sharing class RLM_RampConfiguratorAction {

    private static final String API_VERSION = 'v67.0';
    private static final String CONFIGURE_PATH =
        '/services/data/' + API_VERSION + '/connect/cpq/configurator/actions/configure';

    public class ConfigResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String quoteLineItemId;
        @AuraEnabled public String transactionContextId;
        @AuraEnabled public List<ConfigGroup> groups;
        @AuraEnabled public List<ConfigAttribute> attributes;
        @AuraEnabled public List<ConfigMessage> messages;
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
            Map<String, Object> response = postConfigure(body);
            return parseConfiguration(response, qId, lineId, queryChildren(qId, lineId));
        } catch (Exception e) {
            out.message = e.getMessage();
            return out;
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
     * Constraint evaluation is skipped here: Hosted MCP cannot call Configurator
     * HTTP, and Place Sales Transaction SYSTEM configuration requires an active
     * configuration procedure version that this path cannot assume.
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
            String persistError = persistSelection(
                qId, lineId, selection, childrenByProduct, false, true);
            ConfigResult loaded = loadCatalogConfiguration(quoteId, quoteLineItemId);
            if (persistError != null) {
                loaded.success = false;
                loaded.message = persistError;
                return loaded;
            }
            loaded.success = true;
            loaded.message = 'Bundle picks saved.';
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
            return out;
        }
        out.transactionContextId = asString(response.get('transactionContextId'));
        out.messages = parseMessages(response.get('messages'));
        Map<String, Object> catalogProduct = firstCatalogProduct(response.get('catalogProducts'));
        Map<String, ConfigAttribute> contextAttributes = attributesFromContext(
            response.get('transactionContext'), lineId);
        Boolean hasChildren = childrenByProduct != null && !childrenByProduct.isEmpty();
        out.groups = parseGroups(catalogProduct, childrenByProduct, hasChildren);
        out.attributes = parseAttributes(catalogProduct, contextAttributes);
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
            return out;
        }
        out.success = true;
        return out;
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
        Object groupsObj = catalogProduct.get('productComponentGroups');
        if (!(groupsObj instanceof List<Object>)) {
            return groups;
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
                raw.get('components'), childrenByProduct, hasChildren, optionGroup.selectionMode);
            groups.add(optionGroup);
        }
        return groups;
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
        if (!(messagesObj instanceof Map<String, Object>)) {
            return messages;
        }
        for (Object bucket : ((Map<String, Object>) messagesObj).values()) {
            if (!(bucket instanceof List<Object>)) {
                continue;
            }
            for (Object item : (List<Object>) bucket) {
                Map<String, Object> raw = asMap(item);
                if (raw == null) {
                    continue;
                }
                ConfigMessage msg = new ConfigMessage();
                msg.messageType = asString(raw.get('messageType'));
                msg.category = asString(raw.get('category'));
                msg.text = asString(raw.get('message'));
                if (String.isNotBlank(msg.text)) {
                    messages.add(msg);
                }
            }
        }
        return messages;
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
            persistError = persistSelection(quoteId, lineId, selection, childrenByProduct, false, false);
        } catch (Exception e) {
            persistError = e.getMessage();
        }
        parsed.groups = markSelectedFromChildren(parsed.groups, queryChildren(quoteId, lineId));
        parsed.message = persistError == null
            ? 'Add-ons saved.'
            : 'Add-ons saved. ' + persistError;
        return parsed;
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
        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + CONFIGURE_PATH);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + apiSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));
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

    static String picklistIdForValue(List<ConfigPicklistOption> options, String value) {
        if (options == null || String.isBlank(value)) {
            return null;
        }
        for (ConfigPicklistOption option : options) {
            if (option.value == value || option.label == value) {
                return option.picklistValueId;
            }
        }
        return null;
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
