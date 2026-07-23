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
import addCatalogProductLine from '@salesforce/apex/RLM_AssetPriceHistoryController.addCatalogProductLine';
import removeWorkingLine from '@salesforce/apex/RLM_AssetPriceHistoryController.removeWorkingLine';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

export default class RlmAmendmentStudio extends NavigationMixin(LightningElement) {
    quoteId;
    quoteNumber;
    quoteName;
    history;
    workingLines = [];
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
    /** Installed ledger slide-over. */
    installedDrawerOpen = false;


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

    get headerSubtitle() {
        if (this.quoteNumber && this.quoteName) {
            return `Quote ${this.quoteNumber} · ${this.quoteName}`;
        }
        if (this.quoteNumber) {
            return `Quote ${this.quoteNumber}`;
        }
        return 'Amendment workspace';
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
                key: row.actionId || `hist-${idx}`,
                typeLabel: typeBits.join(' · ') || 'Transaction',
                dateRangeLabel: this._formatDateRange(row.periodStart, row.periodEnd),
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
        let hint = 'Model qty / discount / start in Working — Update to lock in.';
        let hintSecondary = '';
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
            if (r.prorationHint) {
                hint = r.prorationHint;
                hintSecondary = r.prorationHintSecondary || '';
            }
        }
        if (qty > 0) {
            return { qty, mrr, arr, prorated, hint, hintSecondary };
        }
        if (this.showAddProjection) {
            return {
                qty: this.projection.deltaQuantity || 0,
                mrr: this.projection.deltaMrr || 0,
                arr: this.projection.deltaArr || 0,
                prorated: 0,
                hint: 'From last Update — adjust Working to preview again.',
                hintSecondary: 'ARR/MRR stay annualized.'
            };
        }
        return { qty: 0, mrr: 0, arr: 0, prorated: 0, hint, hintSecondary };
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
    get thisAddHint() {
        return this._thisAddRollup.hint;
    }
    get thisAddHintSecondary() {
        return this._thisAddRollup.hintSecondary;
    }
    get hasThisAddHintSecondary() {
        return !!this._thisAddRollup.hintSecondary;
    }
    get thisAddQtyClass() {
        return this._deltaClass(this.thisAddQty);
    }
    get thisAddMrrClass() {
        return this._deltaClass(this.thisAddMrr);
    }
    get thisAddArrClass() {
        return this._deltaClass(this.thisAddArr);
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
        return (this.catalogResults || []).map((h) => ({
            ...h,
            key: h.pricebookEntryId
        }));
    }

    get catalogListHeading() {
        return this.catalogShowingCommon ? 'Common products' : 'Search results';
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
        return this.isLoading || this.saving;
    }

    get workingLineRows() {
        return (this.workingLines || []).map((line, idx) => {
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
            const termLabel =
                this._formatDateRange(startIso, endIso) || 'term';
            const waterfallSteps = [
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
                updateDisabled: this.saving || !dirty || draftIncomplete,
                hasInstalledQty,
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
                removeLabel:
                    line.isCatalogAdd === true
                        ? 'Remove this product line'
                        : 'Clear amendment (set qty to 0)',
                prorationHint: dirty
                    ? `Prorated ≈ billed for ${termLabel} (estimate until Update).`
                    : `Prorated = term bill for ${termLabel} (aligns with Grand Total).`,
                prorationHintSecondary: dirty
                    ? 'ARR/MRR are annualized run-rate — they will not match Grand Total.'
                    : 'ARR/MRR stay annualized.',
                waterfallId: `wf-${line.id || idx}`,
                waterfallSteps,
                waterfallNote: dirty
                    ? 'Preview until Update (platform waterfall after reprice).'
                    : 'Matches list discount until other pricing steps apply.'
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
                key: 'qty',
                label: 'Total qty',
                current: this.summary.totalQuantity,
                proposed: p.projected.totalQuantity,
                delta: p.deltaQuantity,
                deltaClass: this._deltaClass(p.deltaQuantity),
                format: 'qty'
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
                key: 'arr',
                label: 'ARR',
                current: this.summary.currentArr,
                proposed: p.projected.currentArr,
                delta: p.deltaArr,
                deltaClass: this._deltaClass(p.deltaArr),
                format: 'currency'
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
        const row = this.workingLineRows.find((r) => r.id === lineId);
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

    handleQtyApply(event) {
        const lineId = event.currentTarget.dataset.id;
        const row = this.workingLineRows.find((r) => r.id === lineId);
        if (!row || !this.quoteId) {
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
            quoteId: this.quoteId,
            lineItemId: lineId,
            newQuantity: qtyChanged ? qty : null,
            discountPercent: discChanged ? discount : null,
            startDate: startChanged ? startDate : null
        })
            .then((data) => {
                this._applyPayload(data);
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
                        message: 'Quote repriced — Net increase and Finalized contract refreshed.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
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
        // Blank / short → common products rail; 2+ chars → filter.
        if (term.trim().length < 2) {
            this._loadCommonCatalog();
            return;
        }
        this._catalogSearchTimer = setTimeout(() => {
            this._runRailCatalogSearch(term.trim());
        }, 250);
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
        searchCatalogProducts({ quoteId: this.quoteId, searchTerm: '' })
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
        searchCatalogProducts({ quoteId: this.quoteId, searchTerm: term })
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
        searchCatalogProducts({ quoteId: this.quoteId, searchTerm: term })
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

    handleRepriceAll() {
        if (!this.quoteId) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        repriceQuote({ quoteId: this.quoteId })
            .then((data) => {
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Repriced',
                        message: 'Quote force-repriced — KPIs and prorated amounts refreshed.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
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
        this.handleOpenLineEditor();
    }

    handleOpenLineEditor() {
        // Escape hatch only — scroll/focus is not available across page regions;
        // keep a path to the classic Quote surface for advanced TLE work.
        if (!this.quoteId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: this.quoteId,
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
        // Seed / refresh the catalog rail with common products when not mid-search.
        if (!this.catalogSearchTerm || this.catalogSearchTerm.trim().length < 2) {
            this._loadCommonCatalog();
        }
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
