import { LightningElement, api, wire } from 'lwc';
import { gql, graphql } from 'lightning/graphql';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import savePlan from '@salesforce/apex/RLM_RampTransactionAction.savePlan';
import browseCatalog from '@salesforce/apex/RLM_RampTransactionAction.browseCatalog';
import startConfiguration from '@salesforce/apex/RLM_RampTransactionAction.startConfiguration';
import loadConfiguration from '@salesforce/apex/RLM_RampConfiguratorAction.loadConfiguration';
import saveConfiguration from '@salesforce/apex/RLM_RampConfiguratorAction.saveConfiguration';
import QUOTE_NUMBER from '@salesforce/schema/Quote.QuoteNumber';
import QUOTE_NAME from '@salesforce/schema/Quote.Name';
import QUOTE_STATUS from '@salesforce/schema/Quote.Status';
import QUOTE_START from '@salesforce/schema/Quote.StartDate';
import QUOTE_PB from '@salesforce/schema/Quote.Pricebook2Id';
import QUOTE_ACCOUNT_NAME from '@salesforce/schema/Quote.Account.Name';

const APPROVAL_THRESHOLD = 35;
const MAX_PAID_SEGMENTS = 12;
const MONTHS = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

export default class RlmRampBuilder extends NavigationMixin(LightningElement) {
    _recordId;
    @api availableActions = [];
    @api planJson;
    @api saveRequested = false;
    @api cancelRequested = false;
    saving = false;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
    }

    scheduleName = '3 Year Ramp Schedule';
    segmentType = 'Annual';
    startDate = '';
    durationMonths = 36;
    customSegmentCount = 4;
    prorationPosition = 'End';
    trial = false;
    trialDays = 30;
    trialDiscount = 100;
    products = [];
    catalog = [];
    catalogOptions = [];
    catalogId = '';
    catalogName = '';
    catalogSearch = '';
    catalogLoading = false;
    catalogLoaded = false;
    showCatalog = false;
    showPlacement = false;
    browseSegmentKey = '';
    placementMode = 'later';
    placementSelected = {};
    pendingCatalogItem = null;
    adjustmentKindOptions = [
        { label: 'Discount', value: 'Discount' },
        { label: 'Markup', value: 'Markup' }
    ];
    placementModeOptions = [
        { label: 'This segment only', value: 'this' },
        { label: 'This and later segments', value: 'later' },
        { label: 'All segments', value: 'all' },
        { label: 'Choose segments', value: 'choose' }
    ];
    quoteLabel = '';
    errorMessage = '';
    hydrated = false;
    segmentOverrides = [];
    configuring = false;
    configureBusy = false;
    configureLineId = '';
    configureParentName = '';
    configureProductName = '';
    showAdvancedConfigurator = false;
    addonLoading = false;
    addonSaving = false;
    addonGroups = [];
    addonAttributes = [];
    engineMessages = [];
    addonContextId = '';
    addonNotice = '';

    get segmentTypeAnnual() {
        return this.segmentType === 'Annual';
    }
    get segmentTypeCustom() {
        return this.segmentType === 'Custom';
    }
    get prorationEnd() {
        return this.prorationPosition === 'End';
    }
    get prorationBeginning() {
        return this.prorationPosition === 'Beginning';
    }
    get trialYes() {
        return this.trial === true;
    }
    get trialNo() {
        return this.trial !== true;
    }
    get catalogButtonVariant() {
        return this.showCatalog ? 'brand' : 'neutral';
    }
    get step2BodyClass() {
        return this.showCatalog ? 'step2-body step2-body-catalog' : 'step2-body';
    }
    get effectiveBrowseKey() {
        if (this.browseSegmentKey && this.segments.some((segment) => segment.key === this.browseSegmentKey)) {
            return this.browseSegmentKey;
        }
        return this.segments[0] ? this.segments[0].key : '';
    }
    get browseSegmentOptions() {
        return this.segments.map((segment) => ({
            label: segment.name,
            value: segment.key
        }));
    }
    get browseScopeLabel() {
        const segment = this.segments.find((row) => row.key === this.effectiveBrowseKey);
        return segment ? segment.name : 'the first segment';
    }
    get placementProductName() {
        return this.pendingCatalogItem ? this.pendingCatalogItem.name : 'this product';
    }
    get showPlacementChoose() {
        return this.placementMode === 'choose';
    }
    get placementSegmentChoices() {
        return this.segments.map((segment) => ({
            key: segment.key,
            name: `${segment.name} (${segment.startShort} – ${segment.endDate})`,
            checked: this.placementSelected[segment.key] === true
        }));
    }
    get placementConfirmDisabled() {
        return this.placementKeys().length === 0;
    }
    get hasBrowseSegments() {
        return this.segments.length > 0;
    }
    get segments() {
        return buildSegments(this);
    }
    get gridRows() {
        const total = this.segments.length;
        return this.products.map((product) => {
            const cells = this.segments.map((segment) => {
                const cell = this.decorateCell(product, segment);
                return { ...cell, cellClass: cell.present ? 'cell' : 'cell cell-empty' };
            });
            const presentCount = cells.filter((cell) => cell.present).length;
            return {
                ...product,
                hasImage: Boolean(product.displayUrl),
                listPriceDisplay: money(product.listPrice) + '/yr list',
                sellingModelLine: [product.sku, product.sellingModel, money(product.listPrice) + '/yr list']
                    .filter(Boolean)
                    .join(' · '),
                coverage: `In ${presentCount} of ${total} segments`,
                configurable: product.configurable === true,
                cells
            };
        });
    }
    get segmentColumns() {
        return this.segments.map((segment) => {
            const total = this.products.reduce((sum, product) => {
                const cell = this.decorateCell(product, segment);
                return sum + (cell.present ? cell.netTotal : 0);
            }, 0);
            return { ...segment, total: money(total) };
        });
    }
    get contractValue() {
        const total = this.segmentColumns.reduce((sum, column) => {
            return sum + unmoney(column.total);
        }, 0);
        return money(total);
    }
    get approvalCount() {
        let count = 0;
        this.gridRows.forEach((row) => {
            row.cells.forEach((cell) => {
                if (cell.likelyApproval) count += 1;
            });
        });
        return count;
    }
    get approvalText() {
        const n = this.approvalCount;
        if (!n) return '';
        return `${n} line${n === 1 ? '' : 's'} likely to need approval (effective discount above ${APPROVAL_THRESHOLD}%). Approval rules run natively when the quote is submitted.`;
    }
    get quoteVariables() {
        return this.recordId ? { quoteId: this.recordId } : undefined;
    }
    get catalogHint() {
        const scope = this.hasBrowseSegments
            ? ` Adding to ${this.browseScopeLabel}. After Add, choose this segment, later segments, all segments, or specific years.`
            : '';
        if (this.catalogName) {
            return `Product Discovery · ${this.catalogName}.${scope}`;
        }
        return `Product Discovery. Qualification and list prices come from the quote.${scope}`;
    }
    get catalogEmpty() {
        return !this.catalogLoading && this.catalogLoaded && this.catalog.length === 0;
    }
    get hasCatalogPicker() {
        return this.catalogOptions.length > 1;
    }
    get catalogCards() {
        const segmentKeys = this.segments.map((segment) => segment.key);
        const byProduct = new Map(this.products.map((product) => [product.pricebookEntryId, product]));
        return this.catalog.map((item) => {
            const existing = byProduct.get(item.pricebookEntryId);
            const presentKeys = existing && existing.cells ? Object.keys(existing.cells) : [];
            const onAll = segmentKeys.length > 0
                && segmentKeys.every((key) => presentKeys.includes(key));
            return {
                ...item,
                alreadyAdded: presentKeys.length > 0,
                addDisabled: onAll || !this.hasBrowseSegments,
                addLabel: onAll ? 'Added to all' : (presentKeys.length ? 'Add to segments' : 'Add'),
                hasImage: Boolean(item.displayUrl),
                hasSellingModelPicker: (item.sellingModels || []).length > 1,
                configurable: item.configurable === true,
                cardClass: item.qualified === false ? 'catalog-card catalog-card-muted' : 'catalog-card'
            };
        });
    }
    get configureTitle() {
        return this.configureProductName
            ? `Configure ${this.configureProductName}`
            : 'Configure bundle';
    }
    get showAddonPanel() {
        return this.configuring && !this.showAdvancedConfigurator;
    }
    get catalogRuleMessages() {
        const productName = this.configureProductName || 'this product';
        const messages = [];
        (this.addonGroups || []).forEach((group) => {
            const selected = (group.components || []).filter((component) => component.selected);
            const count = selected.length;
            const min = group.minComponents;
            const max = group.maxComponents;
            const below = min != null && count < min;
            const above = max != null && count > max;
            if (!below && !above) return;
            const range = min != null && max != null
                ? `${min}-${max}`
                : (min != null ? `${min}+` : `up to ${max}`);
            messages.push({
                key: `range-${group.id}`,
                text: `The number of child products selected in the product component group ${group.name} for the product ${productName} isn’t in the specified range. Select child products in the range ${range} and try again.`,
                toneClass: 'addon-msg addon-msg-warning',
                groupName: group.name
            });
        });
        (this.addonAttributes || []).forEach((attr) => {
            if (attr.required && !attr.value) {
                messages.push({
                    key: `attr-${attr.attributeKey || attr.attributeName}`,
                    text: `${attr.label || attr.attributeName} is required.`,
                    toneClass: 'addon-msg addon-msg-error'
                });
            }
        });
        return messages;
    }
    get addonMessages() {
        const local = this.catalogRuleMessages;
        const inRangeNames = new Set();
        const outOfRangeNames = new Set(local.map((msg) => (msg.groupName || '').toLowerCase()).filter(Boolean));
        (this.addonGroups || []).forEach((group) => {
            const selected = (group.components || []).filter((component) => component.selected).length;
            const below = group.minComponents != null && selected < group.minComponents;
            const above = group.maxComponents != null && selected > group.maxComponents;
            if (!below && !above && group.name) {
                inRangeNames.add(group.name.toLowerCase());
            }
        });
        const merged = [...local];
        const seen = new Set(local.map((msg) => msg.text));
        (this.engineMessages || []).forEach((msg, index) => {
            const text = msg && msg.text ? msg.text : '';
            if (!text || seen.has(text)) return;
            const lower = text.toLowerCase();
            const isRange = lower.includes('range') || lower.includes('child products selected');
            if (isRange) {
                const stale = [...inRangeNames].some((name) => lower.includes(name));
                const covered = [...outOfRangeNames].some((name) => lower.includes(name));
                if (stale || covered) return;
            }
            seen.add(text);
            merged.push({
                key: `${msg.category || 'msg'}-${index}`,
                text,
                toneClass: msg.messageType === 'error'
                    ? 'addon-msg addon-msg-error'
                    : 'addon-msg addon-msg-warning'
            });
        });
        return merged;
    }
    get hasAddonMessages() {
        return this.addonMessages.length > 0;
    }
    get hasAddonAttributes() {
        return this.addonAttributes.length > 0;
    }
    get addonBusy() {
        return this.addonLoading || this.addonSaving;
    }
    get addonGroupsView() {
        return (this.addonGroups || []).map((group) => {
            const isSingle = group.selectionMode === 'single';
            return {
                ...group,
                isSingle,
                isMultiple: !isSingle,
                components: (group.components || []).map((component) => ({
                    ...component,
                    rowClass: 'addon-row' + (component.selected ? ' addon-row-selected' : ''),
                    checkboxDisabled: component.required === true,
                    qtyDisabled: !component.selected || component.quantityEditable === false,
                    priceLabel: formatAddonPrice(component.unitPrice, component.sellingModelName),
                    options: (component.sellingModels || []).map((model) => ({
                        label: `${model.name || 'Selling model'}${model.unitPrice == null ? '' : ` · ${money(model.unitPrice)}`}`,
                        value: model.pricebookEntryId
                    })),
                    hasSellingModelPicker: (component.sellingModels || []).length > 1 && component.selected
                }))
            };
        });
    }
    get addonAttributeView() {
        return (this.addonAttributes || []).map((attr) => ({
            ...attr,
            options: (attr.options || []).map((option) => ({
                label: option.label || option.value,
                value: option.value
            }))
        }));
    }
    get configuratorInputs() {
        return [
            { name: 'transactionId', type: 'String', value: this.recordId || '' },
            { name: 'transactionLineId', type: 'String', value: this.configureLineId || '' },
            { name: 'parentName', type: 'String', value: this.configureParentName || this.quoteLabel || '' },
            { name: 'origin', type: 'String', value: 'Quote' }
        ];
    }

    pricebookId;
    _placementFocused = false;

    connectedCallback() {
        if (!this.startDate) {
            this.startDate = toIso(new Date());
        }
    }

    renderedCallback() {
        if (this.showPlacement && !this._placementFocused) {
            const dialog = this.template.querySelector('[data-id="placement-dialog"]');
            if (dialog) {
                dialog.focus();
                this._placementFocused = true;
            }
        }
        if (!this.showPlacement) {
            this._placementFocused = false;
        }
    }

    @wire(CurrentPageReference)
    handlePageRef(ref) {
        const fromState = ref?.state?.c__recordId;
        if (fromState && !this._recordId) {
            this._recordId = fromState;
        }
    }

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [QUOTE_NUMBER, QUOTE_NAME, QUOTE_STATUS, QUOTE_START, QUOTE_PB, QUOTE_ACCOUNT_NAME]
    })
    wiredQuoteRecord({ data, error }) {
        if (error) {
            this.errorMessage = error.body ? error.body.message : 'Could not read the quote.';
            return;
        }
        if (!data) return;
        this.quoteLabel = [
            getFieldValue(data, QUOTE_NUMBER),
            getFieldValue(data, QUOTE_ACCOUNT_NAME),
            getFieldValue(data, QUOTE_STATUS)
        ].filter(Boolean).join(' · ');
        this.pricebookId = getFieldValue(data, QUOTE_PB);
        const start = getFieldValue(data, QUOTE_START);
        if (start) this.startDate = start;
    }

    queryQuote = gql`
        query RampBuilderQuote($quoteId: ID!) {
            uiapi {
                query {
                    Quote(where: { Id: { eq: $quoteId } }, first: 1) {
                        edges {
                            node {
                                Id
                                Name { value }
                                QuoteNumber { value }
                                Status { value }
                                StartDate { value }
                                Pricebook2Id { value }
                                Account { Name { value } }
                            }
                        }
                    }
                    QuoteLineGroup(where: { QuoteId: { eq: $quoteId } }, first: 50) {
                        edges {
                            node {
                                Id
                                Name { value }
                                Type { value }
                                IsRamped { value }
                                StartDate { value }
                                EndDate { value }
                                Discount { value }
                                UnitPriceUplift { value }
                                SortOrder { value }
                            }
                        }
                    }
                    QuoteLineItem(where: { QuoteId: { eq: $quoteId } }, first: 200) {
                        edges {
                            node {
                                Id
                                Quantity { value }
                                Discount { value }
                                NetUnitPrice { value }
                                ListPrice { value }
                                QuoteLineGroupId { value }
                                PricebookEntryId { value }
                                Product2Id { value }
                                ParentQuoteLineItemId { value }
                                Product2 {
                                    Name { value }
                                    ProductCode { value }
                                    DisplayUrl { value }
                                    Type { value }
                                }
                            }
                        }
                    }
                }
            }
        }
    `;

    @wire(graphql, { query: '$queryQuote', variables: '$quoteVariables' })
    wiredQuote({ data, errors }) {
        if (errors && errors.length) {
            return;
        }
        if (!data || this.hydrated) return;
        this.hydrateFromExisting(data);
        this.hydrated = true;
    }

    hydrateFromExisting(data) {
        const groups = (data?.uiapi?.query?.QuoteLineGroup?.edges || [])
            .map((edge) => edge.node)
            .filter((node) => node.Type?.value !== 'RampScheduleGroup')
            .sort((a, b) => (a.SortOrder?.value || 0) - (b.SortOrder?.value || 0));
        const lines = (data?.uiapi?.query?.QuoteLineItem?.edges || []).map((edge) => edge.node);
        if (!groups.length || !lines.length) return;

        const root = (data?.uiapi?.query?.QuoteLineGroup?.edges || [])
            .map((edge) => edge.node)
            .find((node) => node.Type?.value === 'RampScheduleGroup');
        if (root?.Name?.value) this.scheduleName = root.Name.value;

        const byProduct = new Map();
        lines.forEach((line) => {
            if (line.ParentQuoteLineItemId?.value) return;
            const key = line.PricebookEntryId?.value || line.Product2Id?.value;
            if (!key) return;
            if (!byProduct.has(key)) {
                const nodeType = line.Product2?.Type?.value;
                byProduct.set(key, {
                    pricebookEntryId: line.PricebookEntryId?.value,
                    product2Id: line.Product2Id?.value,
                    quoteLineItemId: line.Id,
                    name: line.Product2?.Name?.value || 'Product',
                    sku: line.Product2?.ProductCode?.value || '',
                    displayUrl: resolveImageUrl(line.Product2?.DisplayUrl?.value),
                    listPrice: Number(line.ListPrice?.value || line.NetUnitPrice?.value || 0),
                    sellingModel: '',
                    configurable: nodeType === 'Bundle',
                    persisted: nodeType === 'Bundle',
                    cells: {}
                });
            }
            const group = groups.find((g) => g.Id === line.QuoteLineGroupId?.value);
            if (!group) return;
            const segKey = 'existing-' + group.Id;
            byProduct.get(key).cells[segKey] = {
                quantity: Number(line.Quantity?.value || 1),
                adjustment: Number(line.Discount?.value || 0),
                adjustmentKind: 'Discount'
            };
        });
        this.products = [...byProduct.values()];
    }

    decorateCell(product, segment) {
        const raw = product.cells[segment.key];
        if (!raw) {
            return {
                key: product.pricebookEntryId + ':' + segment.key,
                segmentKey: segment.key,
                productId: product.pricebookEntryId,
                present: false,
                addLabel: '+ Add to ' + segment.name
            };
        }
        const qty = Number(raw.quantity || 0);
        const adj = Number(raw.adjustment || 0);
        const kind = raw.adjustmentKind || 'Discount';
        const factor = kind === 'Markup'
            ? (1 + adj / 100)
            : (1 - adj / 100);
        const netUnit = product.listPrice * factor;
        const effective = kind === 'Discount' ? adj : 0;
        return {
            key: product.pricebookEntryId + ':' + segment.key,
            segmentKey: segment.key,
            productId: product.pricebookEntryId,
            present: true,
            quantity: qty,
            adjustment: adj,
            adjustmentKind: kind,
            adjustmentLabel: kind === 'Markup' ? 'Markup %' : 'Discount %',
            listDisplay: money(product.listPrice * qty),
            netDisplay: money(netUnit) + ' net/unit/yr',
            netTotal: netUnit * qty,
            likelyApproval: effective > APPROVAL_THRESHOLD
        };
    }

    handleField(event) {
        const field = event.target.dataset.field;
        let value = event.detail ? event.detail.value : event.target.value;
        if (field === 'durationMonths' || field === 'customSegmentCount'
            || field === 'trialDays' || field === 'trialDiscount') {
            value = Number(value);
        }
        if (field === 'customSegmentCount') {
            if (!Number.isFinite(value) || value < 1) value = 1;
            if (value > MAX_PAID_SEGMENTS) value = MAX_PAID_SEGMENTS;
        }
        this[field] = value;
    }

    handleChoice(event) {
        const field = event.target.dataset.field;
        const value = event.target.dataset.value;
        if (field === 'trial') {
            this.trial = value === 'true';
            return;
        }
        this[field] = value;
    }

    handleSegmentEdit(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        const value = event.target.value;
        const next = this.segments.map((segment) => ({ ...segment }));
        const match = next.find((segment) => segment.key === key);
        if (!match) return;
        match[field] = field === 'name' ? value : Number(value);
        this.segmentOverrides = next;
    }

    handleOpenCatalog() {
        if (!this.browseSegmentKey) {
            this.browseSegmentKey = this.effectiveBrowseKey;
        }
        this.showCatalog = true;
        this.loadCatalog();
    }

    handleBrowseSegment(event) {
        const key = event.currentTarget.dataset.segment || event.target.dataset.segment;
        if (key) this.browseSegmentKey = key;
        this.handleOpenCatalog();
    }

    handleBrowseScopeChange(event) {
        this.browseSegmentKey = event.detail.value;
    }

    handleCloseCatalog() {
        this.showCatalog = false;
        this.handleCancelPlacement();
    }

    handleCatalogSearch(event) {
        this.catalogSearch = event.detail ? event.detail.value : event.target.value;
    }

    handleCatalogSearchCommit() {
        this.loadCatalog(true);
    }

    handleCatalogChange(event) {
        this.catalogId = event.detail.value;
        this.loadCatalog(true);
    }

    async loadCatalog(force) {
        if (!this.recordId || this.catalogLoading) return;
        if (this.catalogLoaded && !force) return;
        this.catalogLoading = true;
        this.errorMessage = '';
        try {
            const result = await browseCatalog({
                quoteId: this.recordId,
                searchTerm: this.catalogSearch,
                catalogId: this.catalogId
            });
            if (!result || result.success === false) {
                this.catalog = [];
                this.errorMessage = (result && result.message) || 'Could not browse the catalog.';
                this.catalogLoaded = true;
                return;
            }
            this.catalogId = result.catalogId || this.catalogId;
            this.catalogName = result.catalogName || '';
            this.catalogOptions = (result.catalogs || []).map((row) => ({
                label: row.name,
                value: row.id
            }));
            this.catalog = (result.products || []).map((row) => {
                const models = (row.sellingModels || []).map((model) => ({
                    pricebookEntryId: model.pricebookEntryId,
                    name: model.name || 'Selling model',
                    sellingModelType: model.sellingModelType || '',
                    listPrice: Number(model.listPrice || 0),
                    label: `${model.name || 'Selling model'} · ${money(Number(model.listPrice || 0))}`,
                    value: model.pricebookEntryId
                }));
                return {
                    product2Id: row.product2Id,
                    pricebookEntryId: row.pricebookEntryId,
                    name: row.name || 'Product',
                    sku: row.sku || '',
                    displayUrl: resolveImageUrl(row.displayUrl),
                    sellingModel: row.sellingModel || '',
                    sellingModels: models,
                    listPrice: Number(row.listPrice || 0),
                    listDisplay: money(Number(row.listPrice || 0)),
                    qualified: row.qualified !== false,
                    configurable: row.configurable === true || row.nodeType === 'bundleProduct',
                    nodeType: row.nodeType || ''
                };
            });
            this.catalogLoaded = true;
        } catch (error) {
            this.catalog = [];
            this.catalogLoaded = true;
            this.errorMessage = error.body ? error.body.message : error.message;
        } finally {
            this.catalogLoading = false;
        }
    }

    handleSellingModelChange(event) {
        const product2Id = event.target.dataset.product;
        const pricebookEntryId = event.detail.value;
        this.catalog = this.catalog.map((item) => {
            if (item.product2Id !== product2Id) return item;
            const model = (item.sellingModels || []).find((row) => {
                return row.pricebookEntryId === pricebookEntryId;
            });
            if (!model) return item;
            return {
                ...item,
                pricebookEntryId: model.pricebookEntryId,
                sellingModel: model.name,
                listPrice: model.listPrice,
                listDisplay: money(model.listPrice)
            };
        });
    }

    handleImageError(event) {
        const product2Id = event.target.dataset.product;
        this.catalog = this.catalog.map((item) => {
            if (item.product2Id !== product2Id) return item;
            return { ...item, displayUrl: '' };
        });
        this.products = this.products.map((item) => {
            if (item.product2Id !== product2Id) return item;
            return { ...item, displayUrl: '' };
        });
    }

    handleAddProduct(event) {
        const id = event.currentTarget.dataset.id || event.target.dataset.id;
        const item = this.catalog.find((row) => row.pricebookEntryId === id);
        if (!item) return;
        if (!this.hasBrowseSegments) {
            this.errorMessage = 'Set a start date and duration in the ramp schedule before adding products.';
            return;
        }
        this.pendingCatalogItem = item;
        this.placementMode = 'later';
        this.placementSelected = this.defaultPlacementSelected();
        this.showPlacement = true;
        this.errorMessage = '';
    }

    handlePlacementModeChange(event) {
        this.placementMode = event.detail.value;
        if (this.placementMode === 'choose' && !Object.values(this.placementSelected).some(Boolean)) {
            this.placementSelected = this.defaultPlacementSelected();
        }
    }

    handlePlacementSegmentToggle(event) {
        const key = event.target.dataset.key;
        this.placementSelected = {
            ...this.placementSelected,
            [key]: event.target.checked === true
        };
    }

    handleCancelPlacement() {
        this.showPlacement = false;
        this.pendingCatalogItem = null;
    }

    handleConfirmPlacement() {
        const item = this.pendingCatalogItem;
        const keys = this.placementKeys();
        if (!item || !keys.length) return;
        this.placeProduct(item, keys);
        this.handleCancelPlacement();
    }

    handlePlacementKeydown(event) {
        if (event.key === 'Escape') {
            this.handleCancelPlacement();
        }
    }

    handleConfigureProduct(event) {
        const id = event.currentTarget.dataset.id || event.target.dataset.id;
        const fromGrid = event.currentTarget.dataset.source === 'grid';
        const item = fromGrid
            ? this.products.find((row) => row.pricebookEntryId === id)
            : this.catalog.find((row) => row.pricebookEntryId === id);
        if (!item) return;
        this.openConfigurator(item);
    }

    async openConfigurator(item) {
        if (!this.recordId || this.configureBusy) return;
        this.configureBusy = true;
        this.errorMessage = '';
        try {
            const result = await startConfiguration({
                quoteId: this.recordId,
                pricebookEntryId: item.pricebookEntryId,
                quoteLineItemId: item.quoteLineItemId,
                planJson: JSON.stringify(this.toPlan())
            });
            if (!result || result.success === false) {
                this.errorMessage = (result && result.message)
                    || 'Could not open Product Configurator.';
                return;
            }
            const cells = item.cells && Object.keys(item.cells).length
                ? item.cells
                : this.cellsForKeys(this.placementKeysForMode('later'));
            if (!this.products.some((row) => row.pricebookEntryId === item.pricebookEntryId)) {
                this.products = [...this.products, {
                    pricebookEntryId: item.pricebookEntryId,
                    product2Id: item.product2Id,
                    quoteLineItemId: result.quoteLineItemId,
                    name: item.name,
                    sku: item.sku,
                    displayUrl: item.displayUrl,
                    sellingModel: item.sellingModel,
                    listPrice: item.listPrice,
                    configurable: true,
                    persisted: true,
                    cells
                }];
            } else {
                this.products = this.products.map((row) => {
                    if (row.pricebookEntryId !== item.pricebookEntryId) return row;
                    return {
                        ...row,
                        quoteLineItemId: result.quoteLineItemId,
                        configurable: true,
                        persisted: true
                    };
                });
            }
            this.configureLineId = result.quoteLineItemId;
            this.configureParentName = result.parentName || this.quoteLabel;
            this.configureProductName = item.name || '';
            this.showAdvancedConfigurator = false;
            this.configuring = true;
            await this.refreshAddonPanel();
        } catch (error) {
            this.errorMessage = error.body ? error.body.message : error.message;
        } finally {
            this.configureBusy = false;
        }
    }

    applyAddonResult(result) {
        this.addonGroups = result && result.groups ? result.groups : [];
        this.addonAttributes = result && result.attributes ? result.attributes : [];
        this.engineMessages = result && result.messages ? result.messages : [];
        if (result && result.transactionContextId) {
            this.addonContextId = result.transactionContextId;
        }
    }

    async refreshAddonPanel() {
        if (!this.recordId || !this.configureLineId) return;
        this.addonLoading = true;
        this.addonNotice = '';
        try {
            const result = await loadConfiguration({
                quoteId: this.recordId,
                quoteLineItemId: this.configureLineId
            });
            if (!result || result.success === false) {
                this.errorMessage = (result && result.message)
                    || 'Could not load add-ons for this bundle.';
                if (result && (result.groups || result.messages)) {
                    this.applyAddonResult(result);
                }
                return;
            }
            this.errorMessage = '';
            this.applyAddonResult(result);
        } catch (error) {
            this.errorMessage = error.body ? error.body.message : error.message;
        } finally {
            this.addonLoading = false;
        }
    }

    handleAddonToggle(event) {
        const product2Id = event.currentTarget.dataset.id;
        const groupId = event.currentTarget.dataset.group;
        const checked = event.target.checked;
        this.addonGroups = this.addonGroups.map((group) => {
            if (group.id !== groupId) return group;
            return {
                ...group,
                components: (group.components || []).map((component) => {
                    if (component.product2Id !== product2Id) return component;
                    if (component.required && !checked) return component;
                    return { ...component, selected: checked };
                })
            };
        });
    }

    handleAddonRadio(event) {
        const product2Id = event.currentTarget.dataset.id;
        const groupId = event.currentTarget.dataset.group;
        this.addonGroups = this.addonGroups.map((group) => {
            if (group.id !== groupId) return group;
            return {
                ...group,
                components: (group.components || []).map((component) => ({
                    ...component,
                    selected: component.product2Id === product2Id
                }))
            };
        });
    }

    handleAddonQty(event) {
        const product2Id = event.currentTarget.dataset.id;
        const groupId = event.currentTarget.dataset.group;
        const quantity = Number(event.target.value);
        this.addonGroups = this.addonGroups.map((group) => {
            if (group.id !== groupId) return group;
            return {
                ...group,
                components: (group.components || []).map((component) => {
                    if (component.product2Id !== product2Id) return component;
                    return { ...component, quantity: Number.isFinite(quantity) && quantity > 0 ? quantity : 1 };
                })
            };
        });
    }

    handleAddonSellingModel(event) {
        const product2Id = event.currentTarget.dataset.id;
        const groupId = event.currentTarget.dataset.group;
        const pricebookEntryId = event.detail.value;
        this.addonGroups = this.addonGroups.map((group) => {
            if (group.id !== groupId) return group;
            return {
                ...group,
                components: (group.components || []).map((component) => {
                    if (component.product2Id !== product2Id) return component;
                    const model = (component.sellingModels || []).find(
                        (row) => row.pricebookEntryId === pricebookEntryId
                    );
                    if (!model) return component;
                    return {
                        ...component,
                        pricebookEntryId: model.pricebookEntryId,
                        productSellingModelId: model.productSellingModelId,
                        sellingModelName: model.name,
                        unitPrice: model.unitPrice
                    };
                })
            };
        });
    }

    handleAddonAttribute(event) {
        const attributeName = event.currentTarget.dataset.name;
        const value = event.detail.value;
        this.addonAttributes = this.addonAttributes.map((attr) => {
            if (attr.attributeName !== attributeName) return attr;
            const option = (attr.options || []).find((row) => row.value === value);
            return {
                ...attr,
                value,
                picklistValueId: option ? option.picklistValueId : attr.picklistValueId
            };
        });
    }

    toAddonSelection() {
        const components = [];
        (this.addonGroups || []).forEach((group) => {
            (group.components || []).forEach((component) => {
                if (!component.selected) return;
                components.push({
                    product2Id: component.product2Id,
                    pricebookEntryId: component.pricebookEntryId,
                    productSellingModelId: component.productSellingModelId,
                    unitPrice: component.unitPrice,
                    quantity: component.quantity,
                    productRelatedComponentId: component.productRelatedComponentId,
                    productRelationshipTypeId: component.productRelationshipTypeId,
                    includedInBundle: component.includedInBundle === true,
                    quoteLineItemId: component.quoteLineItemId || null
                });
            });
        });
        return {
            components,
            transactionContextId: this.addonContextId || null,
            attributes: (this.addonAttributes || []).map((attr) => ({
                attributeKey: attr.attributeKey,
                attributeName: attr.attributeName,
                attributeRecordId: attr.attributeRecordId,
                value: attr.value,
                picklistValueId: attr.picklistValueId
            }))
        };
    }

    async handleSaveAddons() {
        if (!this.recordId || !this.configureLineId || this.addonSaving) return;
        this.addonSaving = true;
        this.addonNotice = '';
        this.errorMessage = '';
        try {
            const result = await saveConfiguration({
                quoteId: this.recordId,
                quoteLineItemId: this.configureLineId,
                selectionJson: JSON.stringify(this.toAddonSelection())
            });
            if (!result || result.success === false) {
                this.errorMessage = (result && result.message) || 'Could not save add-ons.';
                if (result && result.messages) {
                    this.engineMessages = result.messages;
                }
                return;
            }
            this.applyAddonResult(result);
            this.addonNotice = result.message || 'Add-ons saved.';
        } catch (error) {
            this.errorMessage = error.body ? error.body.message : error.message;
        } finally {
            this.addonSaving = false;
        }
    }

    handleOpenAdvanced() {
        this.showAdvancedConfigurator = true;
        this.addonNotice = '';
    }

    handleConfiguratorStatus(event) {
        const status = event.detail ? event.detail.status : '';
        if (status === 'STARTED' || status === 'PENDING') return;
        if (status === 'ERROR') {
            const errors = event.detail.errors || [];
            const first = errors[0];
            this.errorMessage = (first && (first.message || first.errorMessage))
                || 'Product Configurator could not start. Use Back to Ramp Builder.';
            return;
        }
        this.closeConfigurator();
    }

    handleCloseConfigurator() {
        this.closeConfigurator();
    }

    closeConfigurator() {
        this.configuring = false;
        this.showAdvancedConfigurator = false;
        this.configureLineId = '';
        this.configureProductName = '';
        this.addonGroups = [];
        this.addonAttributes = [];
        this.engineMessages = [];
        this.addonContextId = '';
        this.addonNotice = '';
        this.addonLoading = false;
        this.addonSaving = false;
    }

    handleRemoveProduct(event) {
        const id = event.target.dataset.id;
        this.products = this.products.filter((p) => p.pricebookEntryId !== id);
    }

    handleFillAll(event) {
        const id = event.target.dataset.id;
        this.products = this.products.map((product) => {
            if (product.pricebookEntryId !== id) return product;
            const cells = { ...product.cells };
            this.segments.forEach((segment) => {
                if (!cells[segment.key]) {
                    cells[segment.key] = seedCell(segment);
                }
            });
            return { ...product, cells };
        });
    }

    handleAddCell(event) {
        const segmentKey = event.target.dataset.segment;
        const segment = this.segments.find((row) => row.key === segmentKey);
        this.patchCell(event.target.dataset.product, segmentKey, seedCell(segment));
    }

    handleRemoveCell(event) {
        const productId = event.target.dataset.product;
        const segmentKey = event.target.dataset.segment;
        this.products = this.products.map((product) => {
            if (product.pricebookEntryId !== productId) return product;
            const cells = { ...product.cells };
            delete cells[segmentKey];
            return { ...product, cells };
        });
    }

    handleCellChange(event) {
        const field = event.target.dataset.field;
        let value = event.detail && event.detail.value !== undefined
            ? event.detail.value
            : event.target.value;
        if (field !== 'adjustmentKind') value = Number(value);
        this.patchCell(event.target.dataset.product, event.target.dataset.segment, {
            [field]: value
        });
    }

    handleCopyToLater(event) {
        const productId = event.target.dataset.product;
        const fromKey = event.target.dataset.segment;
        const start = this.segments.findIndex((segment) => segment.key === fromKey);
        this.products = this.products.map((product) => {
            if (product.pricebookEntryId !== productId) return product;
            const source = product.cells[fromKey];
            if (!source) return product;
            const cells = { ...product.cells };
            this.segments.slice(start + 1).forEach((segment) => {
                cells[segment.key] = { ...source };
            });
            return { ...product, cells };
        });
    }

    handleCopyFrom(event) {
        const toKey = event.target.dataset.segment;
        const index = this.segments.findIndex((segment) => segment.key === toKey);
        if (index < 1) return;
        const fromKey = this.segments[index - 1].key;
        this.products = this.products.map((product) => {
            const source = product.cells[fromKey];
            if (!source) return product;
            return { ...product, cells: { ...product.cells, [toKey]: { ...source } } };
        });
    }

    patchCell(productId, segmentKey, patch) {
        const segment = this.segments.find((row) => row.key === segmentKey);
        this.products = this.products.map((product) => {
            if (product.pricebookEntryId !== productId) return product;
            const current = product.cells[segmentKey] || seedCell(segment);
            return {
                ...product,
                cells: { ...product.cells, [segmentKey]: { ...current, ...patch } }
            };
        });
    }

    defaultPlacementSelected() {
        const keys = this.placementKeysForMode('later');
        const selected = {};
        this.segments.forEach((segment) => {
            selected[segment.key] = keys.includes(segment.key);
        });
        return selected;
    }

    placementKeys() {
        return this.placementKeysForMode(this.placementMode);
    }

    placementKeysForMode(mode) {
        const segments = this.segments;
        if (!segments.length) return [];
        if (mode === 'all') {
            return segments.map((segment) => segment.key);
        }
        if (mode === 'choose') {
            return segments
                .filter((segment) => this.placementSelected[segment.key] === true)
                .map((segment) => segment.key);
        }
        const startKey = this.effectiveBrowseKey || segments[0].key;
        const start = segments.findIndex((segment) => segment.key === startKey);
        const from = start < 0 ? 0 : start;
        if (mode === 'this') {
            return [segments[from].key];
        }
        return segments.slice(from).map((segment) => segment.key);
    }

    cellsForKeys(keys) {
        const cells = {};
        (keys || []).forEach((key) => {
            const segment = this.segments.find((row) => row.key === key);
            if (segment) cells[key] = seedCell(segment);
        });
        return cells;
    }

    placeProduct(item, keys) {
        const seeded = this.cellsForKeys(keys);
        const existing = this.products.find((product) => {
            return product.pricebookEntryId === item.pricebookEntryId;
        });
        if (existing) {
            this.products = this.products.map((product) => {
                if (product.pricebookEntryId !== item.pricebookEntryId) return product;
                const cells = { ...product.cells };
                keys.forEach((key) => {
                    if (!cells[key] && seeded[key]) cells[key] = seeded[key];
                });
                return { ...product, cells };
            });
            return;
        }
        this.products = [...this.products, {
            pricebookEntryId: item.pricebookEntryId,
            product2Id: item.product2Id,
            name: item.name,
            sku: item.sku,
            displayUrl: item.displayUrl,
            sellingModel: item.sellingModel,
            listPrice: item.listPrice,
            configurable: item.configurable === true,
            persisted: false,
            cells: seeded
        }];
    }

    handleCancel() {
        this.goToQuote();
    }

    async handleSave() {
        if (!this.recordId || this.saving) return;
        this.saving = true;
        this.errorMessage = '';
        try {
            const result = await savePlan({
                quoteId: this.recordId,
                planJson: JSON.stringify(this.toPlan())
            });
            if (result && result.success) {
                this.goToQuote();
                return;
            }
            this.errorMessage = (result && result.message) || 'Could not save the ramp.';
        } catch (error) {
            this.errorMessage = error.body ? error.body.message : error.message;
        }
        this.saving = false;
    }

    goToQuote() {
        if (!this.recordId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.recordId,
                objectApiName: 'Quote',
                actionName: 'view'
            }
        });
    }

    toPlan() {
        const segments = this.segments.map((segment) => ({
            key: segment.key,
            name: segment.name,
            type: segment.type,
            startDate: segment.startIso,
            endDate: segment.endIso,
            discount: Number(segment.discount || 0),
            uplift: Number(segment.uplift || 0)
        }));
        return {
            scheduleName: this.scheduleName,
            segmentType: this.segmentType,
            startDate: this.startDate,
            durationMonths: this.durationMonths,
            customSegmentCount: this.customSegmentCount,
            prorationPosition: this.prorationPosition,
            trial: this.trial,
            trialDays: this.trialDays,
            trialDiscount: this.trialDiscount,
            segments,
            products: this.products.map((product) => ({
                pricebookEntryId: product.pricebookEntryId,
                product2Id: product.product2Id,
                persisted: product.persisted === true,
                cells: product.cells
            }))
        };
    }
}

function seedCell(segment) {
    const discount = Number(segment && segment.discount || 0);
    const uplift = Number(segment && segment.uplift || 0);
    if (discount > 0) {
        return { quantity: 1, adjustment: discount, adjustmentKind: 'Discount' };
    }
    if (uplift > 0) {
        return { quantity: 1, adjustment: uplift, adjustmentKind: 'Markup' };
    }
    return { quantity: 1, adjustment: 0, adjustmentKind: 'Discount' };
}

function firstNode(data, name) {
    return data?.uiapi?.query?.[name]?.edges?.[0]?.node;
}

function buildSegments(state) {
    if (!state.startDate || !state.durationMonths) return [];
    const start = parseIso(state.startDate);
    if (Number.isNaN(start.getTime())) return [];
    const segments = [];
    let cursor = new Date(start);
    if (state.trial) {
        const trialEnd = addDays(cursor, Number(state.trialDays || 0) - 1);
        segments.push(makeSegment(state, {
            key: 'trial',
            name: 'Trial',
            type: 'Trial',
            start: cursor,
            end: trialEnd,
            discount: Number(state.trialDiscount || 0),
            length: `${Number(state.trialDays || 0)} Days`
        }));
        cursor = addDays(trialEnd, 1);
    }
    const paidMonths = Number(state.durationMonths);
    const lengths = state.segmentType === 'Custom'
        ? customSegmentLengths(paidMonths, state.customSegmentCount)
        : annualSegmentLengths(paidMonths, state.prorationPosition);
    lengths.forEach((months, index) => {
        const end = addMonths(cursor, months);
        end.setDate(end.getDate() - 1);
        const yearNumber = index + 1;
        const isProrated = state.segmentType !== 'Custom' && months !== 12;
        segments.push(makeSegment(state, {
            key: `s${index}`,
            name: state.segmentType === 'Custom'
                ? `Segment ${yearNumber}`
                : (isProrated ? `Year ${yearNumber} - Pro-rated` : `Year ${yearNumber}`),
            type: isProrated ? 'Prorated' : (state.segmentType === 'Annual' ? 'Yearly' : 'Custom'),
            start: new Date(cursor),
            end,
            discount: 0,
            length: `${months} Months`
        }));
        cursor = addDays(end, 1);
    });
    return segments.map((segment, index) => ({
        ...segment,
        number: index + 1,
        startShort: shortRange(segment.start),
        prevName: index ? segments[index - 1].name : ''
    }));
}

function makeSegment(state, spec) {
    const override = (state.segmentOverrides || []).find((row) => row.key === spec.key);
    return {
        key: spec.key,
        name: override?.name || spec.name,
        type: spec.type,
        start: spec.start,
        end: spec.end,
        startIso: toIso(spec.start),
        endIso: toIso(spec.end),
        startDate: formatLong(spec.start),
        endDate: formatLong(spec.end),
        discount: override?.discount ?? spec.discount,
        uplift: override?.uplift ?? 0,
        length: spec.length
    };
}

function annualSegmentLengths(paidMonths, prorationPosition) {
    const fullYears = Math.floor(paidMonths / 12);
    const remainder = paidMonths % 12;
    const yearly = [];
    for (let i = 0; i < fullYears; i += 1) {
        yearly.push(12);
    }
    if (remainder) {
        if (prorationPosition === 'Beginning') yearly.unshift(remainder);
        else yearly.push(remainder);
    }
    return yearly;
}

function customSegmentLengths(paidMonths, customSegmentCount) {
    const total = Math.max(1, Number(paidMonths) || 1);
    const count = Math.min(
        Math.max(1, Math.floor(Number(customSegmentCount) || 1)),
        total,
        MAX_PAID_SEGMENTS
    );
    const base = Math.floor(total / count);
    const extra = total % count;
    const lengths = [];
    for (let i = 0; i < count; i += 1) {
        lengths.push(base + (i >= count - extra ? 1 : 0));
    }
    return lengths;
}

function parseIso(value) {
    const [y, m, d] = value.split('-').map(Number);
    return new Date(y, m - 1, d);
}

function toIso(date) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
}

function addDays(date, days) {
    const next = new Date(date);
    next.setDate(next.getDate() + days);
    return next;
}

function addMonths(date, months) {
    const next = new Date(date);
    next.setMonth(next.getMonth() + months);
    return next;
}

function formatLong(date) {
    return `${MONTHS[date.getMonth()]} ${date.getDate()}, ${date.getFullYear()}`;
}

function shortRange(date) {
    return `${MONTHS[date.getMonth()]} ${String(date.getFullYear()).slice(2)}`;
}

function resolveImageUrl(url) {
    if (!url) return '';
    if (/^https?:\/\//i.test(url)) return url;
    if (url.startsWith('/')) {
        return (typeof window !== 'undefined' ? window.location.origin : '') + url;
    }
    return url;
}

function money(value) {
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        maximumFractionDigits: 0
    }).format(value || 0);
}

function formatAddonPrice(unitPrice, sellingModelName) {
    const parts = [];
    if (unitPrice != null) parts.push(money(unitPrice));
    if (sellingModelName) parts.push(sellingModelName);
    return parts.join(' · ');
}

function unmoney(value) {
    return Number(String(value).replace(/[^0-9.-]/g, '')) || 0;
}
