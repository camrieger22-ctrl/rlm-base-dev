import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import {
    RefreshEvent,
    registerRefreshHandler,
    unregisterRefreshHandler
} from 'lightning/refresh';
import getStudioPayload from '@salesforce/apex/RLM_AssetPriceHistoryController.getStudioPayload';
import updateWorkingLineQuantity from '@salesforce/apex/RLM_AssetPriceHistoryController.updateWorkingLineQuantity';
import repriceQuote from '@salesforce/apex/RLM_AssetPriceHistoryController.repriceQuote';
import searchCatalogProducts from '@salesforce/apex/RLM_AssetPriceHistoryController.searchCatalogProducts';
import getCatalogBrowseContext from '@salesforce/apex/RLM_AssetPriceHistoryController.getCatalogBrowseContext';
import getCatalogCategories from '@salesforce/apex/RLM_AssetPriceHistoryController.getCatalogCategories';
import addCatalogProductLine from '@salesforce/apex/RLM_AssetPriceHistoryController.addCatalogProductLine';
import removeWorkingLine from '@salesforce/apex/RLM_AssetPriceHistoryController.removeWorkingLine';
import getLinePricingWaterfall from '@salesforce/apex/RLM_AssetPriceHistoryController.getLinePricingWaterfall';
import getScenarioCompare from '@salesforce/apex/RLM_AssetPriceHistoryController.getScenarioCompare';
import createScenario from '@salesforce/apex/RLM_AssetPriceHistoryController.createScenario';
import setForecastScenario from '@salesforce/apex/RLM_AssetPriceHistoryController.setForecastScenario';
import renameScenario from '@salesforce/apex/RLM_AssetPriceHistoryController.renameScenario';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

export default class RlmAmendmentStudio extends NavigationMixin(LightningElement) {
    quoteId;
    quoteNumber;
    quoteName;
    accountName;
    grandTotal;
    quoteStatus;
    history;
    workingLines = [];
    calculationStatus;
    validationResult;
    loaded = false;
    error;
    saving = false;
    draftQtyByLineId = {};
    draftDiscountByLineId = {};
    draftStartByLineId = {};
    /** Local draft rows from + — search catalog before committing a QLI. */
    pendingAddRows = [];
    _pendingSeq = 0;
    _searchTimers = {};
    _requestSeq = 0;
    _refreshHandlerId;
    _pageRefQuoteId;
    _recordId;
    /** Left-rail catalog search state. */
    catalogSearchTerm = '';
    catalogResults = [];
    catalogSearching = false;
    catalogError;
    catalogAdding = false;
    /** True while results are the default common list (not a typed search). */
    catalogShowingCommon = true;
    _catalogSearchTimer;
    /** Discovery taxonomy (C+A): catalogs → categories → search/browse. */
    catalogNodes = [];
    categoryNodes = [];
    selectedCatalogId;
    selectedCategoryId;
    taxonomyLoading = false;
    /** Installed ledger slide-over. */
    installedDrawerOpen = false;
    /** lineId → { steps, source, loading, error, identifier } for OOTB waterfall. */
    platformWaterfallByLineId = {};
    _waterfallInflight = {};
    /** Sibling amend scenario compare (Opportunity-scoped). */
    opportunityId;
    scenarioCompare;
    scenarioLoading = false;
    scenarioBusyQuoteId;
    scenarioError;
    draftScenarioQtyByQuoteId = {};
    draftScenarioDiscByQuoteId = {};
    /** Draft option titles before renameScenario persists Quote.Name. */
    draftScenarioNameByQuoteId = {};
    /** Sibling quoteId → workingLines (hydrated via getStudioPayload; nested compare lists can arrive empty). */
    scenarioLinesByQuoteId = {};


    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this._resolveQuoteId();
    }

    @wire(CurrentPageReference)
    handlePageRef(pageRef) {
        const fromState = pageRef?.state?.c__quoteId || pageRef?.state?.c__recordId;
        this._pageRefQuoteId = fromState || undefined;
        this._resolveQuoteId();
    }

    connectedCallback() {
        this._refreshHandlerId = registerRefreshHandler(this, this.handleRefreshContext);
        this._resolveQuoteId();
    }

    disconnectedCallback() {
        if (this._refreshHandlerId != null) {
            unregisterRefreshHandler(this._refreshHandlerId);
            this._refreshHandlerId = undefined;
        }
    }

    @api
    get effectiveRecordId() {
        return this.quoteId;
    }

    get isLoading() {
        return !this.loaded;
    }

    get hasQuote() {
        return !!this.quoteId;
    }

    get isAmendment() {
        return this.history?.isAmendmentQuote === true;
    }

    get showNonAmendBanner() {
        return this.loaded && this.hasQuote && !this.isAmendment;
    }

    get showPricingAttentionBanner() {
        return this.loaded && this.hasQuote && !!this.validationResult;
    }

    get pricingAttentionMessage() {
        const vr = this.validationResult;
        const calc = this.calculationStatus;
        if (vr && calc) {
            return `Pricing needs attention — ValidationResult: ${vr} · CalculationStatus: ${calc}. Use Reprice All, then review Working lines.`;
        }
        if (vr) {
            return `Pricing needs attention — ValidationResult: ${vr}. Use Reprice All to refresh platform prices.`;
        }
        return '';
    }

    get showMultiPeriodBanner() {
        return (
            this.loaded &&
            this.hasQuote &&
            (this.workingLines || []).some((l) => l.hasQuoteLineDetails === true)
        );
    }

    get headerSubtitle() {
        if (this.quoteNumber && this.quoteName) {
            return `Quote ${this.quoteNumber} · ${this.quoteName}`;
        }
        if (this.quoteNumber) {
            return `Quote ${this.quoteNumber}`;
        }
        return 'Amendment workspace';
    }

    get chromeQuoteLabel() {
        return this.quoteNumber ? `Quote ${this.quoteNumber}` : 'Amendment Studio';
    }

    get chromeStatusLabel() {
        return this.quoteStatus || 'Draft';
    }

    get hasChromeGrandTotal() {
        return this.grandTotal != null && Number.isFinite(Number(this.grandTotal));
    }

    get hasChromeAccount() {
        return !!this.accountName;
    }

    get summary() {
        return this.history?.summary;
    }

    get projection() {
        return this.history?.projection;
    }

    get hasSummary() {
        return this.summary != null;
    }

    get hasHistoryRows() {
        return Array.isArray(this.history?.rows) && this.history.rows.length > 0;
    }

    get historyRows() {
        return (this.history?.rows || []).map((row, idx) => {
            const typeBits = [row.category, row.actionType].filter(Boolean);
            const lineQty =
                row.quantity != null ? row.quantity : row.quantityChange;
            return {
                ...row,
                key: `${row.actionId || 'hist'}-${idx}`,
                typeLabel: typeBits.join(' · ') || 'Installed period',
                startDateLabel: this._formatDateOnly(row.periodStart) || '—',
                endDateLabel: this._formatDateOnly(row.periodEnd) || '—',
                lineQty,
                hasDiscount:
                    row.discountPercent != null && Number(row.discountPercent) !== 0
            };
        });
    }

    get showAddProjection() {
        return this.projection && this.projection.mode === 'Add' && this.projection.projected;
    }

    get kpiCurrentArr() {
        return this.summary?.currentArr;
    }
    get kpiCurrentMrr() {
        return this.summary?.currentMrr;
    }
    get kpiCurrentQty() {
        return this.summary?.totalQuantity;
    }

    /** Sticky "This add" — live draft from Working lines (falls back to projection Δ). */
    get _thisAddRollup() {
        let qty = 0;
        let mrr = 0;
        let arr = 0;
        let prorated = 0;
        const rows = this.workingLineRows || [];
        for (const r of rows) {
            const q = Number(r.draftQuantity);
            if (!Number.isFinite(q) || q <= 0) {
                continue;
            }
            qty += q;
            mrr += Number(r.previewMrr) || 0;
            arr += Number(r.previewArr) || 0;
            prorated += Number(r.previewProrated) || 0;
        }
        if (qty > 0) {
            return { qty, mrr, arr, prorated };
        }
        if (this.showAddProjection) {
            return {
                qty: this.projection.deltaQuantity || 0,
                mrr: this.projection.deltaMrr || 0,
                arr: this.projection.deltaArr || 0,
                prorated: 0
            };
        }
        return { qty: 0, mrr: 0, arr: 0, prorated: 0 };
    }

    get thisAddQty() {
        return this._thisAddRollup.qty;
    }
    get thisAddMrr() {
        return this._thisAddRollup.mrr;
    }
    get thisAddArr() {
        return this._thisAddRollup.arr;
    }
    get thisAddProrated() {
        return this._thisAddRollup.prorated;
    }

    get installedAssetName() {
        return this.summary?.assetName || 'Installed products';
    }

    get historyMessage() {
        return this.history?.message || 'No installed transactions for this amendment.';
    }

    get installedDrawerExpanded() {
        return this.installedDrawerOpen ? 'true' : 'false';
    }

    get hasCatalogResults() {
        return Array.isArray(this.catalogResults) && this.catalogResults.length > 0;
    }

    get catalogResultViews() {
        return (this.catalogResults || []).map((h) => {
            const desc = h.description && h.description !== h.productName ? h.description : '';
            return {
                ...h,
                key: h.pricebookEntryId,
                metaLine: [h.productCode, h.sellingModelName].filter(Boolean).join(' · '),
                descriptionLine: desc
            };
        });
    }

    get catalogChipViews() {
        const allSelected = !this.selectedCatalogId;
        const chips = [
            {
                id: 'all',
                name: 'All',
                chipClass: 'catalog-chip' + (allSelected ? ' catalog-chip_selected' : ''),
                isSelected: allSelected
            }
        ];
        for (const c of this.catalogNodes || []) {
            const selected = this.selectedCatalogId === c.id;
            chips.push({
                id: c.id,
                name: this._shortCatalogName(c.name),
                chipClass: 'catalog-chip' + (selected ? ' catalog-chip_selected' : ''),
                isSelected: selected
            });
        }
        return chips;
    }

    get categoryChipViews() {
        if (!this.selectedCatalogId) {
            return [];
        }
        const chips = [
            {
                id: 'all-cat',
                name: 'All',
                chipClass:
                    'catalog-chip catalog-chip_category' +
                    (!this.selectedCategoryId ? ' catalog-chip_selected' : ''),
                isSelected: !this.selectedCategoryId
            }
        ];
        for (const c of this.categoryNodes || []) {
            const selected = this.selectedCategoryId === c.id;
            chips.push({
                id: c.id,
                name: c.name,
                chipClass:
                    'catalog-chip catalog-chip_category' +
                    (selected ? ' catalog-chip_selected' : ''),
                isSelected: selected
            });
        }
        return chips;
    }

    get hasCategoryChips() {
        return this.categoryChipViews.length > 1;
    }

    get catalogListHeading() {
        if (this.catalogShowingCommon) {
            return this.selectedCatalogId || this.selectedCategoryId
                ? 'Browse'
                : 'Common products';
        }
        return this.catalogFromDiscovery ? 'Product Discovery' : 'Search results';
    }

    get catalogFromDiscovery() {
        const rows = this.catalogResults || [];
        return rows.some((h) => h.source === 'Discovery');
    }

    get showCatalogEmptyHint() {
        return (
            !this.catalogSearching &&
            !this.catalogError &&
            !this.hasCatalogResults &&
            this.catalogShowingCommon
        );
    }

    get showCatalogNoHits() {
        return (
            !this.catalogSearching &&
            !this.catalogError &&
            !this.hasCatalogResults &&
            !this.catalogShowingCommon
        );
    }

    get hasPendingAddRows() {
        return this.pendingAddRows && this.pendingAddRows.length > 0;
    }

    get pendingAddRowViews() {
        return (this.pendingAddRows || []).map((row) => ({
            ...row,
            hasResults: Array.isArray(row.results) && row.results.length > 0
        }));
    }

    get hasWorkingLines() {
        return this.workingLines && this.workingLines.length > 0;
    }

    get workingLineCount() {
        return (this.workingLines || []).length;
    }

    get workingLineCountLabel() {
        const n = this.workingLineCount;
        return n === 1 ? '1 item' : `${n} items`;
    }

    get isBusy() {
        return this.isLoading || this.saving || this.scenarioLoading || !!this.scenarioBusyQuoteId;
    }

    get hasOpportunity() {
        return !!this.opportunityId;
    }

    get scenarioCurrentArr() {
        return this.scenarioCompare?.current?.currentArr ?? this.kpiCurrentArr;
    }

    get scenarioCurrentMrr() {
        return this.scenarioCompare?.current?.currentMrr ?? this.kpiCurrentMrr;
    }

    get scenarioCurrentQty() {
        return this.scenarioCompare?.current?.totalQuantity ?? this.kpiCurrentQty;
    }

    get hasScenarioOptions() {
        return this.scenarioOptionViews.length > 0;
    }

    get scenarioOptionViews() {
        const cols = this.scenarioCompare?.scenarios;
        if (cols && cols.length) {
            // Put the Quote you're on first so Open lands without scrolling.
            const ordered = [...cols].sort((a, b) => {
                if (a.quoteId === this.quoteId) {
                    return -1;
                }
                if (b.quoteId === this.quoteId) {
                    return 1;
                }
                return 0;
            });
            return ordered.map((col, idx) => this._mapScenarioOption(col, idx));
        }
        // No Opp / no siblings yet — still show this quote as Option 1.
        if (this.quoteId && (this.workingLines?.length || this.hasQuote)) {
            return [
                this._mapScenarioOption(
                    {
                        quoteId: this.quoteId,
                        quoteNumber: this.quoteNumber,
                        name: this.quoteName || 'Option 1',
                        isSynced: false,
                        grandTotal: null,
                        thisAddQty: this.thisAddQty,
                        thisAddArr: this.thisAddArr,
                        thisAddMrr: this.thisAddMrr,
                        thisAddProrated: this.thisAddProrated,
                        finalizedQty: this.projection?.projected?.totalQuantity,
                        finalizedArr: this.projection?.projected?.currentArr,
                        finalizedMrr: this.projection?.projected?.currentMrr,
                        deltaQty: this.projection?.deltaQuantity,
                        deltaArr: this.projection?.deltaArr,
                        deltaMrr: this.projection?.deltaMrr,
                        workingLines: this.workingLines
                    },
                    0
                )
            ];
        }
        return [];
    }

    get workingLineRows() {
        return this._buildWorkingLineRows(this.workingLines || []);
    }

    _mapScenarioOption(col, idx) {
        const qid = col.quoteId;
        const isCurrent = qid === this.quoteId;
        const busy = this.scenarioBusyQuoteId === qid;
        const lines =
            isCurrent && this.workingLines?.length
                ? this.workingLines
                : this.scenarioLinesByQuoteId[qid] ||
                  col.workingLines ||
                  [];
        const lineRows = this._buildWorkingLineRows(lines).map((row) => ({
            ...row,
            quoteId: qid,
            key: `${qid}-${row.key}`
        }));
        const anyDirty = lineRows.some((r) => r.isDirty);
        const showFinalized =
            col.finalizedArr != null ||
            col.finalizedMrr != null ||
            col.finalizedQty != null;
        const finalizedRows = showFinalized
            ? [
                  {
                      key: 'arr',
                      label: 'ARR',
                      proposed: col.finalizedArr,
                      delta: col.deltaArr,
                      deltaClass: this._deltaClass(col.deltaArr),
                      formatCurrency: true,
                      formatQty: false
                  },
                  {
                      key: 'mrr',
                      label: 'MRR',
                      proposed: col.finalizedMrr,
                      delta: col.deltaMrr,
                      deltaClass: this._deltaClass(col.deltaMrr),
                      formatCurrency: true,
                      formatQty: false
                  },
                  {
                      key: 'qty',
                      label: 'Qty',
                      proposed: col.finalizedQty,
                      delta: col.deltaQty,
                      deltaClass: this._deltaClass(col.deltaQty),
                      formatCurrency: false,
                      formatQty: true
                  }
              ]
            : [];
        const optionLabel =
            col.name ||
            (idx === 0 ? 'Option 1' : `Option ${idx + 1}`);
        const draftName = this.draftScenarioNameByQuoteId[qid];
        const nameValue =
            draftName !== undefined && draftName !== null ? draftName : optionLabel;
        const nameDirty =
            draftName !== undefined &&
            String(draftName).trim() !== String(optionLabel).trim();
        const metaBits = [];
        if (col.quoteNumber) {
            metaBits.push(`Quote ${col.quoteNumber}`);
        }
        if (col.grandTotal != null && Number.isFinite(Number(col.grandTotal))) {
            metaBits.push(
                `Grand total ${this._formatCurrency(Number(col.grandTotal))}`
            );
        }
        metaBits.push('Edit name to rename this Quote');
        return {
            quoteId: qid,
            quoteNumber: col.quoteNumber,
            name: optionLabel,
            nameValue,
            nameDirty,
            metaTitle: metaBits.join(' · '),
            isSynced: col.isSynced === true,
            isCurrent,
            grandTotal: col.grandTotal,
            currentArr: this.scenarioCurrentArr,
            currentMrr: this.scenarioCurrentMrr,
            currentQty: this.scenarioCurrentQty,
            thisAddQty: col.thisAddQty,
            thisAddArr: col.thisAddArr,
            thisAddMrr: col.thisAddMrr,
            thisAddProrated: col.thisAddProrated,
            showFinalized,
            finalizedRows,
            finalizedEmptyMessage: 'Update lines to see Current → proposed.',
            lineRows,
            hasLines: lineRows.length > 0,
            lineCount: lineRows.length,
            lineCountLabel:
                lineRows.length === 1 ? '1 item' : `${lineRows.length} items`,
            key: qid || `opt-${idx}`,
            cardClass:
                'scenario-option' +
                (col.isSynced ? ' scenario-option_forecast' : '') +
                (isCurrent ? ' scenario-option_current' : ''),
            headerBadge: col.isSynced
                ? 'Forecast'
                : isCurrent
                  ? 'Editing'
                  : 'Draft',
            openDisabled: this.isBusy || isCurrent,
            selectDisabled:
                this.isBusy || busy || !this.opportunityId || col.isSynced === true,
            updateDisabled: this.isBusy || busy || !anyDirty,
            nameDisabled: this.isBusy || busy,
            showPendingAdds: isCurrent
        };
    }

    _buildWorkingLineRows(lines) {
        return (lines || []).map((line, idx) => {
            const hasQtyDraft = this._hasDraft(this.draftQtyByLineId, line.id);
            const hasDiscDraft = this._hasDraft(this.draftDiscountByLineId, line.id);
            const hasStartDraft = this._hasDraft(this.draftStartByLineId, line.id);

            // Keep draft as string so clearing / mid-edit ("5" → "50" / "40") is not
            // overwritten by falling back to the saved number when value is empty.
            const draftQtyRaw = hasQtyDraft
                ? this.draftQtyByLineId[line.id]
                : line.quantity != null
                  ? String(line.quantity)
                  : '0';
            const draftDiscountRaw = hasDiscDraft
                ? this.draftDiscountByLineId[line.id]
                : line.discountPercent != null
                  ? String(line.discountPercent)
                  : '0';
            const draftStart = hasStartDraft
                ? this.draftStartByLineId[line.id]
                : this._toDateInput(line.startDate);

            const draftQtyNum =
                draftQtyRaw === '' || draftQtyRaw == null
                    ? NaN
                    : Number(draftQtyRaw);
            const draftDiscountNum =
                draftDiscountRaw === '' || draftDiscountRaw == null
                    ? NaN
                    : Number(draftDiscountRaw);

            const qtyDirty =
                hasQtyDraft &&
                (draftQtyRaw === '' ||
                    !Number.isFinite(draftQtyNum) ||
                    draftQtyNum !== Number(line.quantity));
            const discDirty =
                hasDiscDraft &&
                (draftDiscountRaw === '' ||
                    !Number.isFinite(draftDiscountNum) ||
                    draftDiscountNum !== Number(line.discountPercent || 0));
            const startDirty =
                (draftStart || '') !== (this._toDateInput(line.startDate) || '');
            const dirty = qtyDirty || discDirty || startDirty;
            const installed = Number(line.installedQuantity);
            const hasInstalledQty = Number.isFinite(installed);
            const addQty = Number.isFinite(draftQtyNum) ? draftQtyNum : 0;
            const proposedTotal =
                hasInstalledQty && Number.isFinite(draftQtyNum)
                    ? installed + draftQtyNum
                    : null;
            // Live preview: list×(1-disc%). Empty / invalid draft uses saved %.
            let unit = Number(line.netUnitPrice);
            const list = Number(line.listPrice);
            const discPct = Number.isFinite(draftDiscountNum)
                ? draftDiscountNum
                : Number(line.discountPercent || 0);
            if (
                Number.isFinite(list) &&
                list > 0 &&
                Number.isFinite(discPct)
            ) {
                unit = list * (1 - discPct / 100);
            }
            if (!Number.isFinite(unit)) {
                unit = 0;
            }
            const discAmount =
                Number.isFinite(list) && Number.isFinite(unit) ? list - unit : 0;
            const previewArr =
                Number.isFinite(addQty) && addQty > 0 && Number.isFinite(unit)
                    ? addQty * unit
                    : 0;
            const startIso = draftStart || this._toDateInput(line.startDate);
            const endIso = this._toDateInput(line.endDate);
            const frac = this._prorationFraction(startIso, endIso);
            // After reprice, TotalPrice is platform truth for term billing.
            // While drafting, estimate annualized × remaining-term fraction.
            let previewProrated = previewArr * frac;
            if (
                !dirty &&
                line.totalPrice != null &&
                Number.isFinite(Number(line.totalPrice))
            ) {
                previewProrated = Number(line.totalPrice);
            }
            const previewSteps = [
                {
                    key: 'list',
                    label: 'List price',
                    valueLabel: this._formatCurrency(list),
                    rowClass: 'waterfall-step'
                },
                {
                    key: 'disc',
                    label:
                        Number.isFinite(discPct) && discPct > 0
                            ? `Discount (${discPct}%)`
                            : 'Discount',
                    valueLabel:
                        discAmount > 0
                            ? `−${this._formatCurrency(discAmount)}`
                            : this._formatCurrency(0),
                    rowClass: 'waterfall-step waterfall-step_adj'
                },
                {
                    key: 'net',
                    label: 'Paying (net unit)',
                    valueLabel: this._formatCurrency(unit),
                    rowClass: 'waterfall-step waterfall-step_total'
                }
            ];
            const platformWf = this.platformWaterfallByLineId[line.id];
            let waterfallSteps = previewSteps;
            let waterfallNote = dirty
                ? 'Preview until Update (platform waterfall after reprice).'
                : 'Prorated = term bill — ARR/MRR stay annualized.';
            let waterfallTitle = 'Price waterfall (preview)';
            if (!dirty && platformWf?.loading) {
                waterfallTitle = 'Price waterfall';
                waterfallNote = 'Loading OOTB pricing procedure waterfall…';
            } else if (!dirty && platformWf?.error && !platformWf?.steps?.length) {
                waterfallTitle = 'Price waterfall (preview)';
                waterfallNote = `Platform waterfall unavailable — ${platformWf.error}`;
            } else if (!dirty && platformWf?.steps?.length) {
                waterfallTitle = 'Price waterfall';
                waterfallSteps = platformWf.steps.map((s, sIdx) => ({
                    key: s.key || `pwf-${sIdx}`,
                    label: s.label,
                    valueLabel: s.valueLabel,
                    rowClass:
                        'waterfall-step' +
                        (s.isAdjustment ? ' waterfall-step_adj' : '') +
                        (sIdx === platformWf.steps.length - 1
                            ? ' waterfall-step_total'
                            : '')
                }));
                waterfallNote = 'Salesforce Pricing procedure';
            } else if (!dirty && line.priceWaterfallIdentifier) {
                waterfallNote =
                    'Hover again or wait — loading OOTB pricing procedure waterfall.';
            }
            const draftIncomplete =
                (hasQtyDraft &&
                    (draftQtyRaw === '' || !Number.isFinite(draftQtyNum))) ||
                (hasDiscDraft &&
                    (draftDiscountRaw === '' ||
                        !Number.isFinite(draftDiscountNum)));
            return {
                ...line,
                key: line.id || `line-${idx}`,
                typeLabel: line.quoteActionType || 'Line',
                draftQuantity: draftQtyRaw,
                draftDiscount: draftDiscountRaw,
                draftStartDate: draftStart,
                endDateLabel: this._formatDateOnly(line.endDate) || '—',
                isDirty: dirty,
                dirtyFlag: dirty ? 'true' : 'false',
                updateDisabled: this.saving || !dirty || draftIncomplete,
                hasInstalledQty,
                installedQtyLabel: hasInstalledQty
                    ? `Installed ${this._formatInteger(installed)}${
                          proposedTotal != null
                              ? ` → ${this._formatInteger(proposedTotal)}`
                              : ''
                      }`
                    : '',
                proposedTotal,
                previewNetUnit: unit,
                previewArr,
                previewMrr: previewArr / 12,
                previewProrated,
                previewNetTotal:
                    Number.isFinite(addQty) && Number.isFinite(unit)
                        ? addQty * unit
                        : 0,
                rowClass: 'tle-row' + (dirty ? ' tle-row_dirty' : ''),
                isCatalogAdd: line.isCatalogAdd === true,
                hasQuoteLineDetails: line.hasQuoteLineDetails === true,
                removeLabel:
                    line.isCatalogAdd === true
                        ? 'Remove this product line'
                        : 'Clear amendment (set qty to 0)',
                waterfallId: `wf-${line.id || idx}`,
                waterfallTitle,
                waterfallSteps,
                waterfallNote,
                priceWaterfallIdentifier: line.priceWaterfallIdentifier
            };
        });
    }

    get impactDeltas() {
        if (!this.showAddProjection) {
            return [];
        }
        const p = this.projection;
        return [
            {
                key: 'arr',
                label: 'ARR',
                current: this.summary.currentArr,
                proposed: p.projected.currentArr,
                delta: p.deltaArr,
                deltaClass: this._deltaClass(p.deltaArr),
                format: 'currency'
            },
            {
                key: 'mrr',
                label: 'MRR',
                current: this.summary.currentMrr,
                proposed: p.projected.currentMrr,
                delta: p.deltaMrr,
                deltaClass: this._deltaClass(p.deltaMrr),
                format: 'currency'
            },
            {
                key: 'qty',
                label: 'Qty',
                current: this.summary.totalQuantity,
                proposed: p.projected.totalQuantity,
                delta: p.deltaQuantity,
                deltaClass: this._deltaClass(p.deltaQuantity),
                format: 'qty'
            }
        ].map((row) => ({
            ...row,
            formatCurrency: row.format === 'currency',
            formatQty: row.format === 'qty'
        }));
    }

    handleRefresh() {
        this.dispatchEvent(new RefreshEvent());
        this._load();
    }

    handleRefreshContext() {
        this._load();
        return Promise.resolve(true);
    }

    handleQtyInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value;
        // Persist '' while clearing so the field does not snap back to saved qty.
        this.draftQtyByLineId = {
            ...this.draftQtyByLineId,
            [lineId]: raw == null ? '' : String(raw)
        };
    }

    handleDiscountInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value;
        this.draftDiscountByLineId = {
            ...this.draftDiscountByLineId,
            [lineId]: raw == null ? '' : String(raw)
        };
    }

    handleStartDateInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value || null;
        this.draftStartByLineId = {
            ...this.draftStartByLineId,
            [lineId]: raw
        };
    }

    handleQtyStep(event) {
        const lineId = event.currentTarget.dataset.id;
        const delta = Number(event.currentTarget.dataset.delta);
        const row = this._findLineRow(lineId);
        if (!row) {
            return;
        }
        const current = Number(row.draftQuantity);
        const next = (Number.isFinite(current) ? current : 0) + delta;
        this.draftQtyByLineId = {
            ...this.draftQtyByLineId,
            [lineId]: String(next >= 0 ? next : 0)
        };
    }

    _findLineRow(lineId) {
        for (const opt of this.scenarioOptionViews) {
            const row = (opt.lineRows || []).find((r) => r.id === lineId);
            if (row) {
                return row;
            }
        }
        return this.workingLineRows.find((r) => r.id === lineId);
    }

    handleQtyApply(event) {
        const lineId = event.currentTarget.dataset.id;
        const quoteId = event.currentTarget.dataset.quoteId || this.quoteId;
        const row = this._findLineRow(lineId);
        if (!row || !quoteId) {
            return;
        }
        const qty = Number(row.draftQuantity);
        const discount = Number(row.draftDiscount);
        const startDate = row.draftStartDate || null;
        if (!Number.isFinite(qty) || qty < 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid quantity',
                    message: 'Enter an add quantity of zero or more.',
                    variant: 'error'
                })
            );
            return;
        }
        if (!Number.isFinite(discount) || discount < 0 || discount > 100) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid discount',
                    message: 'Enter a discount between 0 and 100%.',
                    variant: 'error'
                })
            );
            return;
        }
        const qtyChanged = Number(qty) !== Number(row.quantity);
        const discChanged = Number(discount) !== Number(row.discountPercent || 0);
        const startChanged =
            (startDate || '') !== (this._toDateInput(row.startDate) || '');
        this.saving = true;
        this.error = undefined;
        updateWorkingLineQuantity({
            quoteId,
            lineItemId: lineId,
            newQuantity: qtyChanged ? qty : null,
            discountPercent: discChanged ? discount : null,
            startDate: startChanged ? startDate : null
        })
            .then((data) => {
                const nextQty = { ...this.draftQtyByLineId };
                const nextDisc = { ...this.draftDiscountByLineId };
                const nextStart = { ...this.draftStartByLineId };
                delete nextQty[lineId];
                delete nextDisc[lineId];
                delete nextStart[lineId];
                this.draftQtyByLineId = nextQty;
                this.draftDiscountByLineId = nextDisc;
                this.draftStartByLineId = nextStart;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Line updated',
                        message: 'Quote repriced — This add and Finalized refreshed.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
                if (quoteId === this.quoteId) {
                    this._applyPayload(data);
                } else {
                    this._loadScenarioCompare();
                }
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Update failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    async handleRemoveLine(event) {
        const lineId = event.currentTarget.dataset.id;
        const isCatalogAdd = event.currentTarget.dataset.catalogAdd === 'true';
        if (!lineId || !this.quoteId) {
            return;
        }
        const confirmed = await LightningConfirm.open({
            message: isCatalogAdd
                ? 'Remove this product line from the amendment quote?'
                : 'Clear this amendment line (quantity → 0 / No Change)? The installed asset line stays on the quote.',
            label: isCatalogAdd ? 'Remove line' : 'Clear amendment',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        removeWorkingLine({ quoteId: this.quoteId, lineItemId: lineId })
            .then((data) => {
                const nextQty = { ...this.draftQtyByLineId };
                const nextDisc = { ...this.draftDiscountByLineId };
                const nextStart = { ...this.draftStartByLineId };
                delete nextQty[lineId];
                delete nextDisc[lineId];
                delete nextStart[lineId];
                this.draftQtyByLineId = nextQty;
                this.draftDiscountByLineId = nextDisc;
                this.draftStartByLineId = nextStart;
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: isCatalogAdd ? 'Line removed' : 'Amendment cleared',
                        message: 'Quote repriced.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Remove failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    /** Row + / Add Product — insert a blank line with inline catalog search (no modal). */
    handleAddLineBelow() {
        this._pendingSeq += 1;
        const key = `pending-${this._pendingSeq}`;
        this.pendingAddRows = [
            ...this.pendingAddRows,
            {
                key,
                searchTerm: '',
                results: [],
                searching: false,
                selecting: false,
                error: null
            }
        ];
    }

    handleOpenInstalledDrawer() {
        this.installedDrawerOpen = true;
        // Focus close control after the drawer paints.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const closeBtn = this.template.querySelector('.installed-drawer lightning-button-icon');
            if (closeBtn) {
                closeBtn.focus();
            }
        }, 0);
    }

    handleWaterfallEnter(event) {
        const root = event.currentTarget;
        const lineId = root.dataset.id;
        const isDirty = root.dataset.dirty === 'true';
        const identifier = root.dataset.pwf || '';
        if (lineId && !isDirty) {
            this._ensurePlatformWaterfall(lineId, identifier);
        }
        const pop = root.querySelector('.waterfall-popover');
        if (!pop) {
            return;
        }
        // Close any other open waterfall first.
        this.template.querySelectorAll('.waterfall-popover.is-open').forEach((el) => {
            if (el !== pop) {
                el.classList.remove('is-open', 'waterfall-popover_below', 'waterfall-popover_above');
            }
        });
        pop.classList.add('is-open');
        pop.classList.remove('waterfall-popover_below', 'waterfall-popover_above');
        // Measure after paint so we can flip above/below the viewport edge.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            this._positionWaterfallPopover(root, pop);
        });
    }

    _positionWaterfallPopover(root, pop) {
        if (!root || !pop || !pop.classList.contains('is-open')) {
            return;
        }
        const rect = root.getBoundingClientRect();
        const popRect = pop.getBoundingClientRect();
        const gap = 10;
        const width = popRect.width || 264;
        let left = rect.left;
        if (left + width > window.innerWidth - 8) {
            left = Math.max(8, window.innerWidth - width - 8);
        }
        let top = rect.bottom + gap;
        let placement = 'below';
        if (top + popRect.height > window.innerHeight - 8) {
            top = Math.max(8, rect.top - popRect.height - gap);
            placement = 'above';
        }
        pop.style.left = `${Math.round(left)}px`;
        pop.style.top = `${Math.round(top)}px`;
        pop.classList.add(
            placement === 'below' ? 'waterfall-popover_below' : 'waterfall-popover_above'
        );
    }

    _ensurePlatformWaterfall(lineId, identifier) {
        const cached = this.platformWaterfallByLineId[lineId];
        if (
            cached &&
            (cached.loading ||
                (cached.identifier === identifier &&
                    (cached.steps?.length || cached.error)))
        ) {
            return;
        }
        if (this._waterfallInflight[lineId]) {
            return;
        }
        this._waterfallInflight[lineId] = true;
        this.platformWaterfallByLineId = {
            ...this.platformWaterfallByLineId,
            [lineId]: {
                loading: true,
                identifier,
                steps: cached?.steps || [],
                error: undefined
            }
        };
        getLinePricingWaterfall({ lineItemId: lineId })
            .then((resp) => {
                this.platformWaterfallByLineId = {
                    ...this.platformWaterfallByLineId,
                    [lineId]: {
                        loading: false,
                        identifier,
                        steps: resp?.success ? resp.steps || [] : [],
                        error: resp?.success ? undefined : resp?.message || 'Unavailable',
                        source: resp?.source
                    }
                };
                // Reposition open popover after content grows.
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                requestAnimationFrame(() => {
                    const root = this.template.querySelector(
                        `.waterfall-trigger[data-id="${lineId}"]`
                    );
                    const pop = root?.querySelector('.waterfall-popover.is-open');
                    if (root && pop) {
                        this._positionWaterfallPopover(root, pop);
                    }
                });
            })
            .catch((e) => {
                this.platformWaterfallByLineId = {
                    ...this.platformWaterfallByLineId,
                    [lineId]: {
                        loading: false,
                        identifier,
                        steps: [],
                        error: this._reduceError(e)
                    }
                };
            })
            .finally(() => {
                delete this._waterfallInflight[lineId];
            });
    }

    handleWaterfallLeave(event) {
        // focusout bubbles — ignore when focus stays inside the trigger.
        if (event.type === 'focusout') {
            const next = event.relatedTarget;
            if (next && event.currentTarget.contains(next)) {
                return;
            }
        }
        const pop = event.currentTarget.querySelector('.waterfall-popover');
        if (!pop) {
            return;
        }
        pop.classList.remove('is-open', 'waterfall-popover_below', 'waterfall-popover_above');
        pop.style.left = '';
        pop.style.top = '';
    }

    handleCloseInstalledDrawer() {
        this.installedDrawerOpen = false;
    }

    handleInstalledDrawerKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleCloseInstalledDrawer();
        }
    }

    handleCatalogSearchInput(event) {
        const term = event.detail?.value != null ? String(event.detail.value) : '';
        this.catalogSearchTerm = term;
        this.catalogError = undefined;
        if (this._catalogSearchTimer) {
            clearTimeout(this._catalogSearchTimer);
            this._catalogSearchTimer = undefined;
        }
        // Blank / short → browse / common; 2+ chars → Discovery search.
        if (term.trim().length < 2) {
            this._loadCommonCatalog();
            return;
        }
        this._catalogSearchTimer = setTimeout(() => {
            this._runRailCatalogSearch(term.trim());
        }, 250);
    }

    handleCatalogChipClick(event) {
        const id = event.currentTarget.dataset.id;
        if (id === 'all') {
            this.selectedCatalogId = undefined;
            this.selectedCategoryId = undefined;
            this.categoryNodes = [];
            this._refreshCatalogRail();
            return;
        }
        if (this.selectedCatalogId === id) {
            return;
        }
        this.selectedCatalogId = id;
        this.selectedCategoryId = undefined;
        this._loadCategoriesForCatalog(id).then(() => this._refreshCatalogRail());
    }

    handleCategoryChipClick(event) {
        const id = event.currentTarget.dataset.id;
        const next = id === 'all-cat' ? undefined : id;
        if (this.selectedCategoryId === next) {
            return;
        }
        this.selectedCategoryId = next;
        this._refreshCatalogRail();
    }

    _refreshCatalogRail() {
        const term = (this.catalogSearchTerm || '').trim();
        if (term.length >= 2) {
            this._runRailCatalogSearch(term);
        } else {
            this._loadCommonCatalog();
        }
    }

    _loadCatalogTaxonomy() {
        if (!this.quoteId) {
            return Promise.resolve();
        }
        this.taxonomyLoading = true;
        return getCatalogBrowseContext({ quoteId: this.quoteId })
            .then((ctx) => {
                this.catalogNodes = ctx?.catalogs || [];
                // Default into Software (or platform default) so search is scoped.
                if (!this.selectedCatalogId && ctx?.defaultCatalogId) {
                    this.selectedCatalogId = ctx.defaultCatalogId;
                    this.categoryNodes = ctx?.categories || [];
                } else if (this.selectedCatalogId) {
                    this.categoryNodes = ctx?.categories || [];
                }
            })
            .catch(() => {
                // Taxonomy is progressive enhancement; search still works unscoped.
                this.catalogNodes = [];
                this.categoryNodes = [];
            })
            .finally(() => {
                this.taxonomyLoading = false;
            });
    }

    _loadCategoriesForCatalog(catalogId) {
        if (!this.quoteId || !catalogId) {
            this.categoryNodes = [];
            return Promise.resolve();
        }
        return getCatalogCategories({ quoteId: this.quoteId, catalogId })
            .then((nodes) => {
                this.categoryNodes = nodes || [];
            })
            .catch(() => {
                this.categoryNodes = [];
            });
    }

    _shortCatalogName(name) {
        if (!name) {
            return 'Catalog';
        }
        return name.replace(/^QuantumBit\s+/i, '');
    }

    _catalogScopeParams() {
        return {
            catalogId: this.selectedCatalogId || null,
            categoryId: this.selectedCategoryId || null
        };
    }

    _loadCommonCatalog() {
        if (!this.quoteId) {
            this.catalogResults = [];
            this.catalogShowingCommon = true;
            this.catalogSearching = false;
            return;
        }
        this.catalogSearching = true;
        this.catalogShowingCommon = true;
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: '',
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                if (this.catalogSearchTerm.trim().length >= 2) {
                    return;
                }
                this.catalogResults = hits || [];
                this.catalogShowingCommon = true;
                this.catalogSearching = false;
            })
            .catch((e) => {
                if (this.catalogSearchTerm.trim().length >= 2) {
                    return;
                }
                this.catalogResults = [];
                this.catalogSearching = false;
                this.catalogError = this._reduceError(e);
            });
    }

    _runRailCatalogSearch(term) {
        if (!this.quoteId) {
            return;
        }
        this.catalogSearching = true;
        this.catalogShowingCommon = false;
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: term,
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                // Ignore stale responses if the user kept typing.
                if (this.catalogSearchTerm.trim() !== term) {
                    return;
                }
                this.catalogResults = hits || [];
                this.catalogShowingCommon = false;
                this.catalogSearching = false;
            })
            .catch((e) => {
                if (this.catalogSearchTerm.trim() !== term) {
                    return;
                }
                this.catalogResults = [];
                this.catalogSearching = false;
                this.catalogError = this._reduceError(e);
            });
    }

    handleSelectRailCatalogProduct(event) {
        const pbeId = event.currentTarget.dataset.pbeId;
        if (!pbeId || !this.quoteId || this.catalogAdding) {
            return;
        }
        this.catalogAdding = true;
        this.catalogError = undefined;
        addCatalogProductLine({ quoteId: this.quoteId, pricebookEntryId: pbeId })
            .then((data) => {
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Product added',
                        message: 'New line created and repriced.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
            })
            .catch((e) => {
                const msg = this._reduceError(e);
                this.catalogError = msg;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not add product',
                        message: msg,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.catalogAdding = false;
            });
    }

    handlePendingSearchInput(event) {
        const key = event.currentTarget.dataset.key;
        const term = event.detail?.value != null ? String(event.detail.value) : '';
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key
                ? { ...row, searchTerm: term, error: null, results: term.trim().length < 2 ? [] : row.results }
                : row
        );
        if (this._searchTimers[key]) {
            clearTimeout(this._searchTimers[key]);
        }
        if (!this.quoteId || term.trim().length < 2) {
            return;
        }
        this._searchTimers[key] = setTimeout(() => {
            this._runCatalogSearch(key, term.trim());
        }, 250);
    }

    _runCatalogSearch(key, term) {
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key ? { ...row, searching: true } : row
        );
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: term,
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key
                        ? {
                              ...row,
                              searching: false,
                              results: (hits || []).map((h) => ({
                                  ...h,
                                  key: h.pricebookEntryId
                              }))
                          }
                        : row
                );
            })
            .catch((e) => {
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key
                        ? {
                              ...row,
                              searching: false,
                              results: [],
                              error: this._reduceError(e)
                          }
                        : row
                );
            });
    }

    handleSelectCatalogProduct(event) {
        const key = event.currentTarget.dataset.key;
        const pbeId = event.currentTarget.dataset.pbeId;
        if (!key || !pbeId || !this.quoteId) {
            return;
        }
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key ? { ...row, selecting: true, error: null } : row
        );
        addCatalogProductLine({ quoteId: this.quoteId, pricebookEntryId: pbeId })
            .then((data) => {
                this.pendingAddRows = this.pendingAddRows.filter((row) => row.key !== key);
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Product added',
                        message: 'New line created and repriced.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
            })
            .catch((e) => {
                const msg = this._reduceError(e);
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key ? { ...row, selecting: false, error: msg } : row
                );
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not add product',
                        message: msg,
                        variant: 'error'
                    })
                );
            });
    }

    handleCancelPendingRow(event) {
        const key = event.currentTarget.dataset.key;
        if (this._searchTimers[key]) {
            clearTimeout(this._searchTimers[key]);
            delete this._searchTimers[key];
        }
        this.pendingAddRows = this.pendingAddRows.filter((row) => row.key !== key);
    }

    handleBrowseCatalog() {
        // Prefer in-Studio blank line + search (Browse Catalog quick action hangs in this shell).
        this.handleAddLineBelow();
    }

    handleAddProductSoon() {
        this.handleAddLineBelow();
    }

    handleRepriceAll(event) {
        const quoteId =
            event?.currentTarget?.dataset?.quoteId || this.quoteId;
        if (!quoteId) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        repriceQuote({ quoteId })
            .then((data) => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Repriced',
                        message: 'Quote force-repriced — KPIs and prorated amounts refreshed.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
                if (quoteId === this.quoteId) {
                    this._applyPayload(data);
                } else {
                    this._loadScenarioCompare();
                }
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Reprice failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    /**
     * TLE parity actions that still live in the standard line editor.
     * Opens the OOTB Quote Line Items surface with a short guide toast.
     */
    handleTleTool(event) {
        const tool = event.currentTarget?.dataset?.tool;
        const quoteId =
            event.currentTarget?.dataset?.quoteId || this.quoteId;
        const labels = {
            headerAdjustment: 'Manage Header Adjustment',
            addAssets: 'Add Assets',
            importLines: 'Import Lines',
            bulkDelete: 'Bulk Delete',
            addGroup: 'Add Group'
        };
        const label = labels[tool] || 'That tool';
        this.dispatchEvent(
            new ShowToastEvent({
                title: label,
                message: `${label} runs in the standard Quote Line Items editor — opening it now.`,
                variant: 'info',
                mode: 'dismissible'
            })
        );
        this.handleOpenLineEditor(quoteId);
    }

    handleOpenLineEditor(quoteId) {
        // Escape hatch only — scroll/focus is not available across page regions;
        // keep a path to the classic Quote surface for advanced TLE work.
        const targetId = quoteId || this.quoteId;
        if (!targetId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: targetId,
                objectApiName: 'Quote',
                relationshipApiName: 'QuoteLineItems',
                actionName: 'view'
            }
        });
    }

    _resolveQuoteId() {
        const next = this.recordId || this._pageRefQuoteId;
        if (next !== this.quoteId) {
            this.quoteId = next;
            this.draftQtyByLineId = {};
            this.draftDiscountByLineId = {};
            this.draftStartByLineId = {};
            this._load();
        } else if (!this.loaded && next) {
            this._load();
        } else if (!next) {
            this.loaded = true;
            this.error = undefined;
            this.history = undefined;
            this.workingLines = [];
        }
    }

    _load() {
        if (!this.quoteId) {
            this.loaded = true;
            return;
        }
        const seq = ++this._requestSeq;
        this.loaded = false;
        getStudioPayload({ quoteId: this.quoteId })
            .then((data) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.error = undefined;
                this._applyPayload(data);
            })
            .catch((e) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.error = this._reduceError(e);
                this.history = undefined;
                this.workingLines = [];
            });
    }

    _applyPayload(data) {
        this.history = data.history;
        this.workingLines = data.workingLines || [];
        this.quoteNumber = data.quoteNumber;
        this.quoteName = data.quoteName;
        this.accountName = data.accountName;
        this.grandTotal = data.grandTotal;
        this.quoteStatus = data.status;
        this.opportunityId = data.opportunityId;
        this.calculationStatus = data.calculationStatus;
        this.validationResult = data.validationResult;
        if (data.opportunityAutoCreated && data.opportunityId) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Opportunity ready',
                    message:
                        'Created an Opportunity for this amendment so you can model scenarios and set a forecast.',
                    variant: 'success',
                    mode: 'dismissable'
                })
            );
        }
        // Invalidate waterfall cache when identifiers change after reprice.
        const nextCache = { ...this.platformWaterfallByLineId };
        for (const line of this.workingLines) {
            const cached = nextCache[line.id];
            if (cached && cached.identifier !== line.priceWaterfallIdentifier) {
                delete nextCache[line.id];
            }
        }
        this.platformWaterfallByLineId = nextCache;
        this._loadScenarioCompare();
        // Seed taxonomy once, then browse/search the rail.
        const seedRail = () => {
            if (!this.catalogSearchTerm || this.catalogSearchTerm.trim().length < 2) {
                this._loadCommonCatalog();
            }
        };
        if (!this.catalogNodes.length && !this.taxonomyLoading) {
            this._loadCatalogTaxonomy().then(seedRail);
        } else {
            seedRail();
        }
    }

    _loadScenarioCompare() {
        if (!this.opportunityId) {
            this.scenarioCompare = undefined;
            this.scenarioError = undefined;
            this.scenarioLoading = false;
            this.scenarioLinesByQuoteId = {};
            return;
        }
        this.scenarioLoading = true;
        this.scenarioError = undefined;
        getScenarioCompare({ opportunityId: this.opportunityId })
            .then((data) => {
                this.scenarioCompare = data;
                const nextQty = { ...this.draftScenarioQtyByQuoteId };
                const nextDisc = { ...this.draftScenarioDiscByQuoteId };
                for (const col of data?.scenarios || []) {
                    if (
                        nextQty[col.quoteId] !== undefined &&
                        Number(nextQty[col.quoteId]) === Number(col.thisAddQty)
                    ) {
                        delete nextQty[col.quoteId];
                    }
                    if (
                        nextDisc[col.quoteId] !== undefined &&
                        Number(nextDisc[col.quoteId]) ===
                            Number(col.thisAddDiscountPercent || 0)
                    ) {
                        delete nextDisc[col.quoteId];
                    }
                }
                this.draftScenarioQtyByQuoteId = nextQty;
                this.draftScenarioDiscByQuoteId = nextDisc;
                return this._hydrateScenarioLines(data?.scenarios || []);
            })
            .then(() => {
                this.scenarioLoading = false;
            })
            .catch((e) => {
                this.scenarioLoading = false;
                this.scenarioError = this._reduceError(e);
            });
    }

    /**
     * Load working lines for sibling options. Nested workingLines on
     * getScenarioCompare often arrive empty in LWC even when This add KPIs
     * were computed server-side from those same lines.
     */
    _hydrateScenarioLines(scenarios) {
        const lineMap = { ...this.scenarioLinesByQuoteId };
        const fetches = [];
        for (const col of scenarios || []) {
            const qid = col.quoteId;
            if (!qid || qid === this.quoteId) {
                continue;
            }
            const embedded = col.workingLines;
            if (Array.isArray(embedded) && embedded.length) {
                lineMap[qid] = embedded;
                continue;
            }
            fetches.push(
                getStudioPayload({ quoteId: qid })
                    .then((payload) => {
                        lineMap[qid] = payload?.workingLines || [];
                    })
                    .catch(() => {
                        lineMap[qid] = lineMap[qid] || [];
                    })
            );
        }
        const apply = () => {
            this.scenarioLinesByQuoteId = lineMap;
        };
        if (!fetches.length) {
            apply();
            return Promise.resolve();
        }
        return Promise.all(fetches).then(apply);
    }

    handleScenarioQtyInput(event) {
        const quoteId = event.target.dataset.quoteId;
        if (!quoteId) {
            return;
        }
        this.draftScenarioQtyByQuoteId = {
            ...this.draftScenarioQtyByQuoteId,
            [quoteId]: event.target.value
        };
    }

    handleScenarioDiscInput(event) {
        const quoteId = event.target.dataset.quoteId;
        if (!quoteId) {
            return;
        }
        this.draftScenarioDiscByQuoteId = {
            ...this.draftScenarioDiscByQuoteId,
            [quoteId]: event.target.value
        };
    }

    handleScenarioUpdate(event) {
        const quoteId = event.currentTarget.dataset.quoteId;
        const lineId = event.currentTarget.dataset.lineId;
        if (!quoteId || !lineId) {
            return;
        }
        const col = (this.scenarioCompare?.scenarios || []).find(
            (c) => c.quoteId === quoteId
        );
        const qtyRaw = this.draftScenarioQtyByQuoteId[quoteId];
        const discRaw = this.draftScenarioDiscByQuoteId[quoteId];
        const qty =
            qtyRaw !== undefined && qtyRaw !== ''
                ? Number(qtyRaw)
                : Number(col?.thisAddQty);
        const disc =
            discRaw !== undefined && discRaw !== ''
                ? Number(discRaw)
                : Number(col?.thisAddDiscountPercent || 0);
        if (!Number.isFinite(qty) || qty < 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid quantity',
                    message: 'Enter a non-negative quantity for this scenario.',
                    variant: 'error'
                })
            );
            return;
        }
        this.scenarioBusyQuoteId = quoteId;
        updateWorkingLineQuantity({
            quoteId,
            lineItemId: lineId,
            newQuantity: qty,
            discountPercent: Number.isFinite(disc) ? disc : null,
            startDate: null
        })
            .then(() => {
                this.scenarioBusyQuoteId = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Scenario updated',
                        message: 'Qty / discount applied and repriced.',
                        variant: 'success'
                    })
                );
                if (quoteId === this.quoteId) {
                    this._load();
                } else {
                    this._loadScenarioCompare();
                }
            })
            .catch((e) => {
                this.scenarioBusyQuoteId = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not update scenario',
                        message: this._reduceError(e),
                        variant: 'error'
                    })
                );
            });
    }

    handleScenarioNameInput(event) {
        const quoteId = event.target.dataset.quoteId;
        if (!quoteId) {
            return;
        }
        const raw =
            event.detail && event.detail.value !== undefined
                ? event.detail.value
                : event.target.value;
        this.draftScenarioNameByQuoteId = {
            ...this.draftScenarioNameByQuoteId,
            [quoteId]: raw == null ? '' : String(raw)
        };
    }

    handleScenarioNameKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            event.target.blur();
        } else if (event.key === 'Escape') {
            const quoteId = event.target.dataset.quoteId;
            if (!quoteId) {
                return;
            }
            const next = { ...this.draftScenarioNameByQuoteId };
            delete next[quoteId];
            this.draftScenarioNameByQuoteId = next;
            event.target.blur();
        }
    }

    handleScenarioNameCommit(event) {
        const quoteId = event.target.dataset.quoteId;
        if (!quoteId || this.isBusy) {
            return;
        }
        const opt = this.scenarioOptionViews.find((o) => o.quoteId === quoteId);
        if (!opt) {
            return;
        }
        const nextName = String(opt.nameValue || '').trim();
        if (!nextName) {
            const revert = { ...this.draftScenarioNameByQuoteId };
            delete revert[quoteId];
            this.draftScenarioNameByQuoteId = revert;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Name required',
                    message: 'Option name cannot be blank.',
                    variant: 'warning'
                })
            );
            return;
        }
        if (nextName === String(opt.name || '').trim()) {
            const clear = { ...this.draftScenarioNameByQuoteId };
            delete clear[quoteId];
            this.draftScenarioNameByQuoteId = clear;
            return;
        }
        this.scenarioBusyQuoteId = quoteId;
        renameScenario({ quoteId, name: nextName })
            .then((result) => {
                this.scenarioBusyQuoteId = undefined;
                if (!result?.success) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Could not rename option',
                            message: result?.message || 'Unknown error',
                            variant: 'error'
                        })
                    );
                    return;
                }
                const clear = { ...this.draftScenarioNameByQuoteId };
                delete clear[quoteId];
                this.draftScenarioNameByQuoteId = clear;
                if (quoteId === this.quoteId) {
                    this.quoteName = nextName;
                }
                // Patch local compare cache so the new name shows without a full reload.
                if (this.scenarioCompare?.scenarios) {
                    this.scenarioCompare = {
                        ...this.scenarioCompare,
                        scenarios: this.scenarioCompare.scenarios.map((col) =>
                            col.quoteId === quoteId ? { ...col, name: nextName } : col
                        )
                    };
                }
            })
            .catch((e) => {
                this.scenarioBusyQuoteId = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not rename option',
                        message: this._reduceError(e),
                        variant: 'error'
                    })
                );
            });
    }

    handleScenarioOptionUpdate(event) {
        const quoteId = event.currentTarget.dataset.quoteId;
        if (!quoteId) {
            return;
        }
        const opt = this.scenarioOptionViews.find((o) => o.quoteId === quoteId);
        const dirty = (opt?.lineRows || []).filter(
            (r) => r.isDirty && !r.updateDisabled
        );
        if (!dirty.length) {
            return;
        }
        this.scenarioBusyQuoteId = quoteId;
        const runNext = (index) => {
            if (index >= dirty.length) {
                this.scenarioBusyQuoteId = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Option updated',
                        message: 'Lines saved and repriced.',
                        variant: 'success'
                    })
                );
                if (quoteId === this.quoteId) {
                    this._load();
                } else {
                    this._loadScenarioCompare();
                }
                return;
            }
            const row = dirty[index];
            const qty = Number(row.draftQuantity);
            const discount = Number(row.draftDiscount);
            const startDate = row.draftStartDate || null;
            const qtyChanged = Number(qty) !== Number(row.quantity);
            const discChanged =
                Number(discount) !== Number(row.discountPercent || 0);
            const startChanged =
                (startDate || '') !== (this._toDateInput(row.startDate) || '');
            updateWorkingLineQuantity({
                quoteId,
                lineItemId: row.id,
                newQuantity: qtyChanged ? qty : null,
                discountPercent: discChanged ? discount : null,
                startDate: startChanged ? startDate : null
            })
                .then(() => {
                    const nextQty = { ...this.draftQtyByLineId };
                    const nextDisc = { ...this.draftDiscountByLineId };
                    const nextStart = { ...this.draftStartByLineId };
                    delete nextQty[row.id];
                    delete nextDisc[row.id];
                    delete nextStart[row.id];
                    this.draftQtyByLineId = nextQty;
                    this.draftDiscountByLineId = nextDisc;
                    this.draftStartByLineId = nextStart;
                    runNext(index + 1);
                })
                .catch((e) => {
                    this.scenarioBusyQuoteId = undefined;
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Could not update option',
                            message: this._reduceError(e),
                            variant: 'error'
                        })
                    );
                });
        };
        runNext(0);
    }

    handleScenarioOpen(event) {
        const quoteId = event.currentTarget.dataset.quoteId;
        if (!quoteId || quoteId === this.quoteId) {
            return;
        }
        // Open the sibling option's Quote record (Studio is embedded there).
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: quoteId,
                objectApiName: 'Quote',
                actionName: 'view'
            }
        });
    }

    handleScenarioSelectForecast(event) {
        const quoteId = event.currentTarget.dataset.quoteId;
        if (!quoteId || !this.opportunityId) {
            return;
        }
        this.scenarioBusyQuoteId = quoteId;
        setForecastScenario({
            opportunityId: this.opportunityId,
            quoteId
        })
            .then((result) => {
                this.scenarioBusyQuoteId = undefined;
                if (!result?.success) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Could not set forecast',
                            message: result?.message || 'Unknown error',
                            variant: 'error'
                        })
                    );
                    return;
                }
                if (result.message) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Forecast set — reprice needed',
                            message: result.message,
                            variant: 'warning',
                            mode: 'sticky'
                        })
                    );
                } else {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Forecast updated',
                            message:
                                'Synced to the Opportunity and repriced — ready for Create Order.',
                            variant: 'success'
                        })
                    );
                }
                this._loadScenarioCompare();
                if (quoteId === this.quoteId) {
                    this._load();
                }
            })
            .catch((e) => {
                this.scenarioBusyQuoteId = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not set forecast',
                        message: this._reduceError(e),
                        variant: 'error'
                    })
                );
            });
    }

    handleDuplicateScenario(event) {
        const sourceQuoteId =
            event?.currentTarget?.dataset?.quoteId || this.quoteId;
        if (!sourceQuoteId) {
            return;
        }
        const n = Math.max(this.scenarioOptionViews.length, 1) + 1;
        const label = `Option ${n}`;
        this.scenarioLoading = true;
        createScenario({
            sourceQuoteId,
            label,
            opportunityId: this.opportunityId || null
        })
            .then((result) => {
                this.scenarioLoading = false;
                if (!result?.success) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Could not duplicate scenario',
                            message: result?.message || 'Unknown error',
                            variant: 'error'
                        })
                    );
                    return;
                }
                if (result.opportunityId) {
                    this.opportunityId = result.opportunityId;
                }
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Scenario created',
                        message: `${label} added below — edit lines, then Set forecast when ready.`,
                        variant: 'success'
                    })
                );
                this._load();
            })
            .catch((e) => {
                this.scenarioLoading = false;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not duplicate scenario',
                        message: this._reduceError(e),
                        variant: 'error'
                    })
                );
            });
    }

    _deltaClass(value) {
        const n = Number(value);
        if (!Number.isFinite(n) || n === 0) {
            return 'delta delta_neutral';
        }
        return n > 0 ? 'delta delta_up' : 'delta delta_down';
    }

    _prorationFraction(startIso, endIso) {
        const s = startIso ? new Date(`${startIso}T00:00:00`) : null;
        const e = endIso ? new Date(`${endIso}T00:00:00`) : null;
        if (!s || !e || Number.isNaN(s.getTime()) || Number.isNaN(e.getTime())) {
            return 1;
        }
        if (e < s) {
            return 0;
        }
        const days = Math.round((e - s) / 86400000) + 1;
        return Math.min(1, Math.max(0, days / 365));
    }

    _hasDraft(map, lineId) {
        return Object.prototype.hasOwnProperty.call(map || {}, lineId);
    }

    _formatCurrency(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) {
            return '—';
        }
        try {
            return new Intl.NumberFormat(undefined, {
                style: 'currency',
                currency: 'USD'
            }).format(n);
        } catch (e) {
            return `$${n.toFixed(2)}`;
        }
    }

    _formatInteger(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) {
            return '—';
        }
        try {
            return new Intl.NumberFormat(undefined, {
                maximumFractionDigits: 0
            }).format(n);
        } catch (e) {
            return String(Math.round(n));
        }
    }

    _toDateInput(value) {
        if (!value) {
            return '';
        }
        if (typeof value === 'string') {
            return value.length >= 10 ? value.slice(0, 10) : value;
        }
        try {
            const d = new Date(value);
            if (Number.isNaN(d.getTime())) {
                return '';
            }
            return d.toISOString().slice(0, 10);
        } catch (e) {
            return '';
        }
    }

    _formatDateOnly(value) {
        const iso = this._toDateInput(value);
        if (!iso) {
            return '';
        }
        try {
            const d = new Date(iso + 'T00:00:00');
            return d.toLocaleDateString(undefined, {
                year: 'numeric',
                month: 'short',
                day: 'numeric'
            });
        } catch (e) {
            return iso;
        }
    }

    _formatDateRange(start, end) {
        const a = this._formatDateOnly(start);
        const b = this._formatDateOnly(end);
        if (a && b) {
            return `${a} → ${b}`;
        }
        return a || b || '';
    }

    _reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (typeof error?.body?.message === 'string') {
            return error.body.message;
        }
        return error?.message || 'Unable to load Amendment Studio.';
    }
}
