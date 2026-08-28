import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { open as openAgentforce, execute as executeAgentforce } from 'lightning/accApi';
import wordmarkUrl from '@salesforce/resourceUrl/RLM_BambooHR_Wordmark';
import openFromOpportunity from '@salesforce/apex/RLM_BambooRevenueSuite.openFromOpportunity';
import getSession from '@salesforce/apex/RLM_BambooRevenueSuite.getSession';
import getCatalog from '@salesforce/apex/RLM_BambooRevenueSuite.getCatalog';
import getOptionDetail from '@salesforce/apex/RLM_BambooRevenueSuite.getOptionDetail';
import addProductLine from '@salesforce/apex/RLM_BambooRevenueSuite.addProductLine';
import addProductLinesBySku from '@salesforce/apex/RLM_BambooRevenueSuite.addProductLinesBySku';
import addWorkforcePackage from '@salesforce/apex/RLM_BambooRevenueSuite.addWorkforcePackage';
import updateLineQuantity from '@salesforce/apex/RLM_BambooRevenueSuite.updateLineQuantity';
import updateLineDiscount from '@salesforce/apex/RLM_BambooRevenueSuite.updateLineDiscount';
import repriceOption from '@salesforce/apex/RLM_BambooRevenueSuite.repriceOption';
import estimateCatalogAdd from '@salesforce/apex/RLM_BambooRevenueSuite.estimateCatalogAdd';
import listOptions from '@salesforce/apex/RLM_BambooRevenueSuite.listOptions';
import addOption from '@salesforce/apex/RLM_BambooRevenueSuite.addOption';
import deleteOption from '@salesforce/apex/RLM_BambooRevenueSuite.deleteOption';
import removeLine from '@salesforce/apex/RLM_BambooRevenueSuite.removeLine';
import removeLines from '@salesforce/apex/RLM_BambooRevenueSuite.removeLines';
import applyTermToOption from '@salesforce/apex/RLM_BambooRevenueSuite.applyTermToOption';
import applyTermToAllOptions from '@salesforce/apex/RLM_BambooRevenueSuite.applyTermToAllOptions';
import applyBillingToAllOptions from '@salesforce/apex/RLM_BambooRevenueSuite.applyBillingToAllOptions';
import previewProposal from '@salesforce/apex/RLM_BambooRevenueSuite.previewProposal';
import getProposalStatus from '@salesforce/apex/RLM_BambooRevenueSuite.getProposalStatus';
import getQuotingAssistantBotId from '@salesforce/apex/RLM_BambooRevenueSuite.getQuotingAssistantBotId';
import syncOptionToOpportunity from '@salesforce/apex/RLM_BambooRevenueSuite.syncOptionToOpportunity';
import unsyncOpportunity from '@salesforce/apex/RLM_BambooRevenueSuite.unsyncOpportunity';
import submitOptionForApproval from '@salesforce/apex/RLM_BambooRevenueSuite.submitOptionForApproval';
import listOpportunityContacts from '@salesforce/apex/RLM_BambooRevenueSuite.listOpportunityContacts';
import sendOptionToCustomer from '@salesforce/apex/RLM_BambooRevenueSuite.sendOptionToCustomer';

const TERM_CHOICES = [
    { value: 1, label: 'M2M' },
    { value: 12, label: '1 year' },
    { value: 24, label: '2 years' },
    { value: 36, label: '3 years' }
];

const BILLING_CHOICES = [
    { value: 'Monthly', label: 'Monthly' },
    { value: 'Quarterly', label: 'Quarterly' },
    { value: 'Annual', label: 'Annual' }
];

const WORKFORCE_PKG_SKU = 'BAMBOO-PKG-WORKFORCE';
const WORKFORCE_PLAN_CHOICES = [
    { value: 'BAMBOO-CORE', label: 'Core' },
    { value: 'BAMBOO-PRO', label: 'Pro' },
    { value: 'BAMBOO-ELITE', label: 'Elite' }
];

const QTY_PRESETS = [10, 25, 50, 100, 250];
const QTY_DEBOUNCE_MS = 400;

function todayIso() {
    return new Date().toISOString().slice(0, 10);
}

function approvalChipClassFor(status) {
    const base = 'chip approval-chip';
    const s = String(status || 'Draft').toLowerCase();
    if (s === 'approved') {
        return `${base} approval-approved`;
    }
    if (s === 'pending') {
        return `${base} approval-pending`;
    }
    if (s === 'rejected') {
        return `${base} approval-rejected`;
    }
    return `${base} approval-draft`;
}

/** Inclusive term end: start + N months − 1 day (Neocol-style). Returns YYYY-MM-DD or null. */
function computeEndIso(startIso, termMonths) {
    if (!startIso || Number(termMonths) === 1) {
        return null;
    }
    const [y, m, d] = startIso.split('-').map(Number);
    if (!y || !m || !d) {
        return null;
    }
    const end = new Date(Date.UTC(y, m - 1, d));
    end.setUTCMonth(end.getUTCMonth() + Number(termMonths));
    end.setUTCDate(end.getUTCDate() - 1);
    return end.toISOString().slice(0, 10);
}

/** Display YYYY-MM-DD as M/D/YYYY (US). */
function formatDateMdY(iso) {
    if (!iso || iso === '—') {
        return '—';
    }
    const [y, m, d] = iso.split('-').map(Number);
    if (!y || !m || !d) {
        return iso;
    }
    return `${m}/${d}/${y}`;
}

/** Compare panel: term length from OptionDetailDTO (per-option, not ribbon). */
function formatCompareTermLabel(detail) {
    const months = Number(detail?.termMonths);
    if (!Number.isFinite(months) || months === 1 || detail?.evergreen) {
        return 'M2M';
    }
    return `${months} months`;
}

/** Optional date span under term length in compare. */
function formatCompareTermDates(detail) {
    const start = detail?.startDate;
    const months = Number(detail?.termMonths);
    if (!start) {
        return '';
    }
    if (!Number.isFinite(months) || months === 1 || detail?.evergreen) {
        return `${formatDateMdY(start)} → open-ended`;
    }
    const endIso = detail?.endDate || computeEndIso(start, months);
    if (!endIso) {
        return formatDateMdY(start);
    }
    return `${formatDateMdY(start)} → ${formatDateMdY(endIso)}`;
}

function formatCompareBillingLabel(detail) {
    return detail?.billingFrequency || 'Monthly';
}

/** Inclusive day count between two YYYY-MM-DD dates. */
function dayCountInclusive(startIso, endIso) {
    if (!startIso || !endIso) {
        return null;
    }
    const [ys, ms, ds] = startIso.split('-').map(Number);
    const [ye, me, de] = endIso.split('-').map(Number);
    if (!ys || !ms || !ds || !ye || !me || !de) {
        return null;
    }
    const start = Date.UTC(ys, ms - 1, ds);
    const end = Date.UTC(ye, me - 1, de);
    return Math.round((end - start) / 86400000) + 1;
}

function enrichLine(line, selected, termStartDate, termMonths, formatMoney, extra = {}) {
    const start = line.startDate || termStartDate || todayIso();
    const end = line.endDate || computeEndIso(start, termMonths);
    const dayCount =
        line.dayCount != null ? line.dayCount : end ? dayCountInclusive(start, end) : null;
    const isSelected = extra.selected != null ? extra.selected : selected.has(line.lineId);
    const listTotal =
        line.listTotal != null
            ? line.listTotal
            : (line.listUnitPrice || 0) * (line.quantity || 0);
    return {
        ...line,
        ...extra,
        selected: isSelected,
        cardClass:
            extra.rowClass ||
            (isSelected ? 'line-card line-card-selected' : 'line-card'),
        discountPercent: line.discountPercent == null ? 0 : Number(line.discountPercent),
        unitLabel: formatMoney(line.unitPrice),
        listLabel: extra.listLabel || `${formatMoney(listTotal)}/mo`,
        netLabel: extra.netLabel || formatMoney(line.netTotal),
        dateRangeLabel: end
            ? `${formatDateMdY(start)} — ${formatDateMdY(end)}`
            : `${formatDateMdY(start)} — —`,
        dayCountLabel: dayCount != null ? `${dayCount} days` : '',
        isBundleHead: extra.rowKind === 'bundle-head',
        isBundleChild: extra.rowKind === 'bundle-child'
    };
}

function buildLineDisplayRows(lines, selectedIds, termStartDate, termMonths, formatMoney) {
    const selected = new Set(selectedIds || []);
    const childrenByParent = new Map();
    for (const line of lines || []) {
        if (line.parentLineId) {
            if (!childrenByParent.has(line.parentLineId)) {
                childrenByParent.set(line.parentLineId, []);
            }
            childrenByParent.get(line.parentLineId).push(line);
        }
    }
    const rows = [];
    for (const line of lines || []) {
        if (line.parentLineId) {
            continue;
        }
        const children = childrenByParent.get(line.lineId) || [];
        if (children.length > 0) {
            const childRows = children.map((child) =>
                enrichLine(child, selected, termStartDate, termMonths, formatMoney, {
                    rowKind: 'bundle-child',
                    rowClass: 'line-card line-card-bundle-child'
                })
            );
            const listTotal = childRows.reduce(
                (sum, child) => sum + Number(child.listTotal || 0),
                0
            );
            const netTotal = childRows.reduce(
                (sum, child) => sum + Number(child.netTotal || 0),
                0
            );
            const bundleLineIds = [line.lineId, ...children.map((c) => c.lineId)];
            rows.push(
                enrichLine(line, selected, termStartDate, termMonths, formatMoney, {
                    rowKind: 'bundle-head',
                    rowClass: 'line-card line-card-bundle-head',
                    hideLineControls: true,
                    hideQtyInput: true,
                    hideUnitPrice: true,
                    unitLabel: '',
                    listLabel: `${formatMoney(listTotal)}/mo`,
                    netLabel: formatMoney(netTotal),
                    bundleLineIds: bundleLineIds.join(','),
                    selected: bundleLineIds.every((id) => selected.has(id)),
                    childCountLabel: `${children.length} components`
                })
            );
            rows.push(...childRows);
        } else {
            rows.push(
                enrichLine(line, selected, termStartDate, termMonths, formatMoney, {
                    rowKind: 'standalone'
                })
            );
        }
    }
    return rows;
}

function buildCompareLineRows(lines, formatMoney) {
    const childrenByParent = new Map();
    for (const line of lines || []) {
        if (line.parentLineId) {
            if (!childrenByParent.has(line.parentLineId)) {
                childrenByParent.set(line.parentLineId, []);
            }
            childrenByParent.get(line.parentLineId).push(line);
        }
    }
    const rows = [];
    for (const line of lines || []) {
        if (line.parentLineId) {
            continue;
        }
        const children = childrenByParent.get(line.lineId) || [];
        if (children.length > 0) {
            const netTotal = children.reduce(
                (sum, child) => sum + Number(child.netTotal || 0),
                0
            );
            rows.push({
                lineId: line.lineId,
                name: line.name,
                sku: line.sku,
                qtyLabel: String(line.quantity ?? ''),
                unitLabel: 'Bundle',
                netLabel: formatMoney(netTotal),
                rowClass: 'compare-line compare-line-bundle-head'
            });
            for (const child of children) {
                rows.push({
                    lineId: child.lineId,
                    name: child.name,
                    sku: child.sku,
                    qtyLabel: String(child.quantity ?? ''),
                    unitLabel: formatMoney(child.unitPrice),
                    netLabel: formatMoney(child.netTotal),
                    rowClass: 'compare-line compare-line-bundle-child'
                });
            }
        } else {
            rows.push({
                lineId: line.lineId,
                name: line.name,
                sku: line.sku,
                qtyLabel: String(line.quantity ?? ''),
                unitLabel: formatMoney(line.unitPrice),
                netLabel: formatMoney(line.netTotal),
                rowClass: 'compare-line'
            });
        }
    }
    return rows;
}

export default class RlmBambooRevenueSuite extends NavigationMixin(LightningElement) {
    wordmarkUrl = wordmarkUrl;

    opportunityId;
    quoteId;
    session;
    error;
    loading = true;
    agentOpen = false;
    agentChatBusy = false;
    agentStatus;
    estimateBusy = false;
    estimateResult;
    estimateError;
    agentError;
    quotingAssistantBotId;
    termMonths = 12;
    termStartDate = todayIso();
    billingFrequency = 'Monthly';

    catalog = [];
    catalogError;
    searchText = '';
    selectedSku;
    /**
     * Catalog add queue: [{ sku, quantity }, ...]. Per-product qty before Place.
     * `quantity` is the default for newly queued items / single-product stepper.
     */
    catalogQueue = [];
    quantity = 10;
    packagePlanSku = 'BAMBOO-PRO';
    adding = false;
    addError;
    optionDetail;
    optionError;
    pricingBusy = false;
    pricingStatus = 'idle'; // idle | pending | priced | error
    previewBusy = false;
    previewError;
    syncBusy = false;
    syncError;
    approvalBusy = false;
    approvalError;
    approvalStatusMsg;
    sendOpen = false;
    sendBusy = false;
    sendError;
    sendStatusMsg;
    sendContacts = [];
    sendContactId;
    sendToAddress = '';
    sendAttachPdf = true;
    options = [];
    optionsError;
    addingOption = false;
    compareMode = false;
    compareDetails = [];
    compareLoading = false;
    compareError;
    termBusy = false;
    /** Per-quote term / start / billing when the option has no lines yet. */
    termByQuoteId = {};
    startByQuoteId = {};
    billingByQuoteId = {};
    /** Per-quote term scope: 'shared' (default) | 'custom'. */
    termScopeByQuoteId = {};
    /** Per-quote billing scope: 'shared' (default) | 'custom'. */
    billingScopeByQuoteId = {};
    /** Selected line Ids for multi-delete (active option only). */
    selectedLineIds = [];

    _qtyTimers = {};
    _qtyInFlight = false;
    _qtyQueued = null;
    _discTimers = {};
    _discInFlight = false;
    _discQueued = null;

    termChoices = TERM_CHOICES;
    billingChoices = BILLING_CHOICES;
    qtyPresets = QTY_PRESETS;

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (!pageRef) {
            return;
        }
        const state = pageRef.state || {};
        const nextOpp = state.c__opportunityId || state.opportunityId;
        const nextQuote = state.c__quoteId || state.quoteId;
        if (nextOpp !== this.opportunityId || nextQuote !== this.quoteId) {
            this.opportunityId = nextOpp;
            this.quoteId = nextQuote;
            this.bootstrap();
        }
    }

    get title() {
        return this.session?.opportunityName || 'BambooHR Revenue Suite';
    }

    get accountLabel() {
        return this.session?.accountName || '';
    }

    /** Account-first hero; falls back to opportunity name when account is missing. */
    get headerPrimary() {
        return this.accountLabel || this.title || 'BambooHR Revenue Suite';
    }

    /** Opportunity context under the account — omit when it only repeats the account. */
    get headerSecondary() {
        const opp = (this.session?.opportunityName || '').trim();
        const acct = (this.accountLabel || '').trim();
        if (!opp) {
            return '';
        }
        if (!acct) {
            return '';
        }
        if (opp.toLowerCase() === acct.toLowerCase()) {
            return '';
        }
        return opp;
    }

    get optionLabel() {
        return this.optionDetail?.optionLabel || this.session?.optionLabel || 'Option A';
    }

    get saveLabel() {
        if (this.previewBusy) {
            return 'Generating…';
        }
        return this.session?.quoteId ? 'All saved' : 'Unsaved';
    }

    get previewDisabled() {
        return (
            this.previewBusy ||
            !this.session?.quoteId ||
            !this.hasLines ||
            this.pricingBusy
        );
    }

    get previewButtonLabel() {
        return this.previewBusy ? 'Generating…' : 'Preview';
    }

    get activeOptionSynced() {
        const qid = this.session?.quoteId;
        if (!qid) {
            return false;
        }
        if (this.session?.syncedQuoteId === qid) {
            return true;
        }
        const card = (this.options || []).find((o) => o.quoteId === qid);
        return Boolean(card?.syncedToOpportunity);
    }

    get showStopSync() {
        return this.activeOptionSynced;
    }

    get syncDisabled() {
        const priced =
            this.optionDetail?.priced || this.pricingStatus === 'priced';
        return (
            this.syncBusy ||
            this.pricingBusy ||
            !this.session?.quoteId ||
            (!this.activeOptionSynced && !priced)
        );
    }

    get syncButtonTitle() {
        if (this.activeOptionSynced) {
            return 'Stop syncing this option to the Opportunity';
        }
        if (!(this.optionDetail?.priced || this.pricingStatus === 'priced')) {
            return 'Price the option before syncing to the Opportunity';
        }
        return 'Use this option as the Opportunity synced quote (forecasting Amount)';
    }

    get activeApprovalStatus() {
        return (
            this.optionDetail?.approvalStatus ||
            this.activeOptionCard?.approvalStatus ||
            'Draft'
        );
    }

    get approvalChipLabel() {
        return String(this.activeApprovalStatus || 'Draft').toUpperCase();
    }

    get approvalChipClass() {
        const base = 'chip approval-chip';
        const s = String(this.activeApprovalStatus || 'Draft').toLowerCase();
        if (s === 'approved') {
            return `${base} approval-approved`;
        }
        if (s === 'pending') {
            return `${base} approval-pending`;
        }
        if (s === 'rejected') {
            return `${base} approval-rejected`;
        }
        return `${base} approval-draft`;
    }

    get submitApprovalDisabled() {
        const priced =
            this.optionDetail?.priced || this.pricingStatus === 'priced';
        const status = String(this.activeApprovalStatus || 'Draft').toLowerCase();
        return (
            this.approvalBusy ||
            this.pricingBusy ||
            !this.session?.quoteId ||
            !priced ||
            status === 'pending' ||
            status === 'approved'
        );
    }

    get submitApprovalLabel() {
        if (this.approvalBusy) {
            return 'Submitting…';
        }
        const status = String(this.activeApprovalStatus || 'Draft').toLowerCase();
        if (status === 'approved') {
            return 'Approved';
        }
        if (status === 'pending') {
            return 'Pending approval';
        }
        return 'Submit for approval';
    }

    get sendDisabled() {
        const priced =
            this.optionDetail?.priced || this.pricingStatus === 'priced';
        const status = String(this.activeApprovalStatus || 'Draft').toLowerCase();
        return (
            this.sendBusy ||
            this.previewBusy ||
            this.pricingBusy ||
            !this.session?.quoteId ||
            !priced ||
            status === 'pending'
        );
    }

    get sendButtonLabel() {
        if (this.sendBusy) {
            return 'Sending…';
        }
        return this.sendOpen ? 'Close send' : 'Send to customer';
    }

    get sendContactOptions() {
        return (this.sendContacts || []).map((c) => ({
            ...c,
            label: `${c.name} <${c.email}>`,
            selected: c.contactId === this.sendContactId
        }));
    }

    get pricingChipLabel() {
        if (this.pricingBusy || this.pricingStatus === 'pending') {
            return 'Pricing…';
        }
        if (this.pricingStatus === 'error') {
            return 'Pricing error';
        }
        if (this.optionDetail?.priced || this.pricingStatus === 'priced') {
            return 'Priced';
        }
        if (this.hasLines) {
            return 'List';
        }
        return '—';
    }

    get pricingChipClass() {
        const base = 'chip pricing-chip';
        if (this.pricingBusy || this.pricingStatus === 'pending') {
            return `${base} pricing-pending`;
        }
        if (this.pricingStatus === 'error') {
            return `${base} pricing-error`;
        }
        if (this.optionDetail?.priced || this.pricingStatus === 'priced') {
            return `${base} pricing-ok`;
        }
        return base;
    }

    get currencyCode() {
        return this.session?.currencyIsoCode || 'USD';
    }

    get termStartDisplay() {
        return this.termStartDate || todayIso();
    }

    get termEndDisplay() {
        const iso = computeEndIso(this.termStartDate || todayIso(), this.termMonths);
        return formatDateMdY(iso);
    }

    get isEvergreen() {
        return Number(this.termMonths) === 1;
    }

    get termControlsDisabled() {
        return this.termBusy || this.pricingBusy || !this.session?.quoteId;
    }

    get showWorkspace() {
        return !this.loading && !this.error && this.session;
    }

    get bodyClass() {
        const parts = ['body'];
        if (this.hasSelection) {
            parts.push('body-with-config');
        } else {
            parts.push('body-catalog-options');
        }
        if (this.agentOpen) {
            parts.push('agent-open');
        }
        return parts.join(' ');
    }

    get termPills() {
        return this.termChoices.map((t) => ({
            ...t,
            className:
                Number(this.termMonths) === Number(t.value) ? 'pill pill-active' : 'pill',
            disabled: this.termControlsDisabled
        }));
    }

    get billingPills() {
        return this.billingChoices.map((b) => ({
            ...b,
            className: this.billingFrequency === b.value ? 'pill pill-active' : 'pill',
            disabled: this.termControlsDisabled
        }));
    }

    get quantityLessEqualOne() {
        return Number(this.quantity) <= 1;
    }

    get optionTermRangeLabel() {
        const start = this.effectiveTermStart;
        const months = this.effectiveTermMonths;
        const endIso =
            this.isActiveTermCustom
                ? computeEndIso(start, months)
                : this.optionDetail?.endDate || computeEndIso(start, months);
        const startLabel = formatDateMdY(start);
        if (!endIso || Number(months) === 1) {
            return `${startLabel} → — (M2M)`;
        }
        return `${startLabel} → ${formatDateMdY(endIso)}`;
    }

    get isActiveTermCustom() {
        const qid = this.session?.quoteId;
        return Boolean(qid && this.termScopeByQuoteId[qid] === 'custom');
    }

    get isActiveTermShared() {
        return !this.isActiveTermCustom;
    }

    get effectiveTermMonths() {
        const qid = this.session?.quoteId;
        if (qid && this.isActiveTermCustom && this.termByQuoteId[qid] != null) {
            return this.termByQuoteId[qid];
        }
        return this.termMonths;
    }

    get effectiveTermStart() {
        const qid = this.session?.quoteId;
        if (qid && this.isActiveTermCustom && this.startByQuoteId[qid]) {
            return this.startByQuoteId[qid];
        }
        return this.termStartDate || todayIso();
    }

    get optionTermScopeLabel() {
        return this.isActiveTermCustom ? 'Custom' : 'Shared';
    }

    get optionTermScopeClass() {
        return this.isActiveTermCustom
            ? 'chip term-scope-chip term-scope-custom'
            : 'chip term-scope-chip term-scope-shared';
    }

    get optionLocalTermPills() {
        const months = Number(this.effectiveTermMonths);
        return this.termChoices.map((t) => ({
            ...t,
            className: Number(t.value) === months ? 'pill pill-active' : 'pill',
            disabled: this.termControlsDisabled
        }));
    }

    get optionLocalTermEndDisplay() {
        return formatDateMdY(computeEndIso(this.effectiveTermStart, this.effectiveTermMonths));
    }

    get customOptionCount() {
        return Object.values(this.termScopeByQuoteId || {}).filter((s) => s === 'custom')
            .length;
    }

    get ribbonHintLabel() {
        const termN = this.customOptionCount;
        const billN = this.customBillingOptionCount;
        const termPart =
            termN === 0
                ? 'Shared term'
                : termN === 1
                  ? 'Shared term · 1 custom'
                  : `Shared term · ${termN} custom`;
        const billPart =
            billN === 0
                ? 'Shared billing'
                : billN === 1
                  ? '1 custom billing'
                  : `${billN} custom billing`;
        return `${termPart} · ${billPart}`;
    }

    get isActiveBillingCustom() {
        const qid = this.session?.quoteId;
        return Boolean(qid && this.billingScopeByQuoteId[qid] === 'custom');
    }

    get isActiveBillingShared() {
        return !this.isActiveBillingCustom;
    }

    get effectiveBillingFrequency() {
        const qid = this.session?.quoteId;
        if (qid && this.isActiveBillingCustom && this.billingByQuoteId[qid]) {
            return this.billingByQuoteId[qid];
        }
        return this.billingFrequency || 'Monthly';
    }

    get optionBillingScopeLabel() {
        return this.isActiveBillingCustom ? 'Custom' : 'Shared';
    }

    get optionBillingScopeClass() {
        return this.isActiveBillingCustom
            ? 'chip term-scope-chip term-scope-custom'
            : 'chip term-scope-chip term-scope-shared';
    }

    get optionLocalBillingPills() {
        const current = this.effectiveBillingFrequency;
        return this.billingChoices.map((b) => ({
            ...b,
            className: b.value === current ? 'pill pill-active' : 'pill',
            disabled: this.termControlsDisabled
        }));
    }

    get customBillingOptionCount() {
        return Object.values(this.billingScopeByQuoteId || {}).filter((s) => s === 'custom')
            .length;
    }

    get frequentProducts() {
        const queued = new Set((this.catalogQueue || []).map((e) => e.sku));
        return (this.catalog || [])
            .filter((p) => p.frequent)
            .map((p) => ({
                ...p,
                className: queued.has(p.sku)
                    ? 'freq-tile freq-tile-queued'
                    : 'freq-tile'
            }));
    }

    get filteredProducts() {
        const q = (this.searchText || '').trim().toLowerCase();
        let rows = this.catalog || [];
        if (q) {
            rows = rows.filter(
                (p) =>
                    (p.name || '').toLowerCase().includes(q) ||
                    (p.sku || '').toLowerCase().includes(q) ||
                    (p.badge || '').toLowerCase().includes(q)
            );
        }
        const checked = new Set((this.catalogQueue || []).map((e) => e.sku));
        return rows.map((p) => {
            const isQueued = checked.has(p.sku);
            const isFocused = p.sku === this.selectedSku;
            let className = 'prod';
            if (isQueued) {
                className += ' prod-queued';
            }
            if (isFocused) {
                className += ' selected';
            }
            return {
                ...p,
                className,
                rowClass: isQueued ? 'prod-row prod-row-queued' : 'prod-row',
                checked: isQueued,
                priceLabel: this.formatMoney(p.listPrice)
            };
        });
    }

    get catalogQueuedProducts() {
        const bySku = new Map((this.catalog || []).map((p) => [p.sku, p]));
        return (this.catalogQueue || [])
            .map((entry) => {
                const sku = entry.sku;
                const qty = Number(entry.quantity) > 0 ? Number(entry.quantity) : 1;
                const p = bySku.get(sku);
                const listUnit = p ? Number(p.listPrice || 0) : 0;
                return {
                    sku,
                    name: p?.name || sku,
                    badge: p?.badge || '',
                    quantity: qty,
                    priceLabel: this.formatMoney(listUnit),
                    lineListLabel: `${this.formatMoney(listUnit * qty)}/mo`,
                    qtyLessEqualOne: qty <= 1
                };
            })
            .filter((p) => p.sku);
    }

    get hasCatalogQueue() {
        return this.catalogSelectionCount > 0;
    }

    get selectedProduct() {
        return (this.catalog || []).find((p) => p.sku === this.selectedSku);
    }

    get hasSelection() {
        return Boolean(this.selectedProduct) || this.hasCatalogQueue;
    }

    get catalogSelectionCount() {
        return (this.catalogQueue || []).length;
    }

    get hasCatalogMultiSelect() {
        return this.catalogSelectionCount > 1;
    }

    /** Shared qty stepper only for single queued product / Workforce package. */
    get showSharedQuantity() {
        return !this.hasCatalogMultiSelect;
    }

    get configureHeading() {
        if (this.hasCatalogMultiSelect) {
            return `${this.catalogSelectionCount} products queued`;
        }
        if (this.hasCatalogQueue && this.catalogQueuedProducts.length === 1) {
            return this.catalogQueuedProducts[0].name;
        }
        return this.selectedProduct?.name || 'Configure';
    }

    get configureHint() {
        if (this.hasCatalogMultiSelect) {
            return 'Set a quantity on each product, then add to the option';
        }
        if (this.hasCatalogQueue) {
            return 'Ready to add — adjust quantity below';
        }
        if (this.isWorkforcePackageSelected) {
            return `${WORKFORCE_PKG_SKU} · Path A Bundle & Save`;
        }
        if (this.selectedProduct) {
            return `${this.selectedProduct.sku} · ${this.selectedProduct.badge}`;
        }
        return '';
    }

    get isWorkforcePackageSelected() {
        return (
            !this.hasCatalogMultiSelect &&
            (this.selectedSku === WORKFORCE_PKG_SKU ||
                this.selectedProduct?.sku === WORKFORCE_PKG_SKU ||
                (this.catalogQueue || []).some((e) => e.sku === WORKFORCE_PKG_SKU))
        );
    }

    get workforcePlanPills() {
        return WORKFORCE_PLAN_CHOICES.map((p) => ({
            ...p,
            className:
                this.packagePlanSku === p.value ? 'pill pill-active' : 'pill',
            // Place expand uses IsDefaultComponent=Pro; Core/Elite need configurator.
            disabled: this.addDisabled || p.value !== 'BAMBOO-PRO',
            title:
                p.value === 'BAMBOO-PRO'
                    ? 'Path A default plan'
                    : 'Core/Elite under Workforce needs configurator selection — use catalog a-la-carte for Path B'
        }));
    }

    get configPriceLabel() {
        const queued = this.catalogQueuedProducts || [];
        if (queued.length > 1) {
            const bySku = new Map((this.catalog || []).map((p) => [p.sku, p]));
            let listTotal = 0;
            for (const entry of this.catalogQueue || []) {
                const unit = Number(bySku.get(entry.sku)?.listPrice || 0);
                const qty = Number(entry.quantity) > 0 ? Number(entry.quantity) : 1;
                listTotal += unit * qty;
            }
            return `${queued.length} products · ~${this.formatMoney(listTotal)}/mo list (priced on add)`;
        }
        const qty =
            queued.length === 1
                ? Number(queued[0].quantity || this.quantity || 0)
                : Number(this.quantity || 0);
        const p = this.selectedProduct || (queued[0] ? (this.catalog || []).find((c) => c.sku === queued[0].sku) : null);
        if (!p) {
            return '';
        }
        const unit = Number(p.listPrice || 0);
        return `${this.formatMoney(unit)} /user/mo · line ${this.formatMoney(unit * qty)}/mo (list)`;
    }

    get lineDisplayRows() {
        return buildLineDisplayRows(
            this.optionDetail?.lines || [],
            this.selectedLineIds,
            this.termStartDate,
            this.termMonths,
            (n) => this.formatMoney(n)
        );
    }

    get hasLines() {
        return (this.optionDetail?.lines || []).length > 0;
    }

    get selectedLineCount() {
        return (this.selectedLineIds || []).length;
    }

    get hasSelectedLines() {
        return this.selectedLineCount > 0;
    }

    get allLinesSelected() {
        const lines = this.optionDetail?.lines || [];
        return lines.length > 0 && this.selectedLineCount === lines.length;
    }

    get deleteSelectedDisabled() {
        return this.pricingBusy || !this.hasSelectedLines || !this.session?.quoteId;
    }

    get deleteSelectedLabel() {
        const n = this.selectedLineCount;
        if (n === 0) {
            return 'Delete selected';
        }
        return n === 1 ? 'Delete 1 line' : `Delete ${n} lines`;
    }

    get mrrLabel() {
        return this.formatMoney(this.optionDetail?.mrr || 0);
    }

    get arrLabel() {
        return this.formatMoney(this.optionDetail?.arr || 0);
    }

    get grandTotalLabel() {
        return this.formatMoney(this.optionDetail?.grandTotal || 0);
    }

    get subscriptionTermLabel() {
        const months = Number(this.effectiveTermMonths);
        const billing = this.effectiveBillingFrequency;
        if (months === 1) {
            return `M2M · ${billing}`;
        }
        return `${months} months · ${billing}`;
    }

    get subscriptionTotalLabel() {
        if (Number(this.effectiveTermMonths) === 1) {
            return `${this.mrrLabel}/mo`;
        }
        return this.arrLabel;
    }

    get addOptionDisabled() {
        return (
            this.addingOption ||
            this.pricingBusy ||
            !this.opportunityIdOrSession ||
            (this.options || []).length >= 6
        );
    }

    get opportunityIdOrSession() {
        return this.opportunityId || this.session?.opportunityId;
    }

    get showCompare() {
        return this.compareMode && (this.options || []).length > 1;
    }

    get showEditWorkspace() {
        return this.showWorkspace && !this.showCompare;
    }

    get showBootPanel() {
        return !this.showCompare && !this.showWorkspace && (this.loading || this.error);
    }

    get compareColumns() {
        const selectedId = this.session?.quoteId;
        const statusByQuote = {};
        (this.options || []).forEach((o) => {
            statusByQuote[o.quoteId] = o.status;
        });
        return (this.compareDetails || []).map((detail) => {
            const lines = buildCompareLineRows(detail.lines || [], (n) =>
                this.formatMoney(n)
            );
            const isSelected = detail.quoteId === selectedId;
            const opt = (this.options || []).find((o) => o.quoteId === detail.quoteId);
            const syncedToOpportunity = Boolean(opt?.syncedToOpportunity);
            const termDatesLabel = formatCompareTermDates(detail);
            return {
                quoteId: detail.quoteId,
                optionLabel: detail.optionLabel || 'Option',
                termLabel: formatCompareTermLabel(detail),
                termDatesLabel,
                hasTermDates: Boolean(termDatesLabel),
                billingLabel: formatCompareBillingLabel(detail),
                mrrLabel: this.formatMoney(detail.mrr),
                arrLabel: this.formatMoney(detail.arr),
                grandTotalLabel: this.formatMoney(
                    detail.grandTotal ?? opt?.grandTotal ?? 0
                ),
                statusLabel: (statusByQuote[detail.quoteId] || 'Draft').toUpperCase(),
                approvalLabel: String(
                    detail.approvalStatus || opt?.approvalStatus || 'Draft'
                ).toUpperCase(),
                approvalClass: approvalChipClassFor(
                    detail.approvalStatus || opt?.approvalStatus
                ),
                pricedLabel: detail.priced ? 'Priced' : 'List',
                pricedClass: detail.priced
                    ? 'chip pricing-chip pricing-ok'
                    : 'chip pricing-chip',
                syncedToOpportunity,
                lineCount: (detail.lines || []).filter((l) => !l.parentLineId).length,
                lines,
                hasLines: lines.length > 0,
                panelClass: isSelected
                    ? 'compare-panel compare-panel-selected'
                    : 'compare-panel',
                isSelected
            };
        });
    }

    get compareBoardClass() {
        const n = (this.compareColumns || []).length || 2;
        return `compare-board compare-cols-${Math.min(n, 4)}`;
    }

    get optionCards() {
        return (this.options || []).map((o) => ({
            ...o,
            mrrLabel: this.formatMoney(o.mrr),
            arrLabel: this.formatMoney(o.arr),
            grandTotalLabel: this.formatMoney(o.grandTotal),
            statusLabel: (o.status || 'Draft').toUpperCase(),
            approvalLabel: String(o.approvalStatus || 'Draft').toUpperCase(),
            approvalClass: approvalChipClassFor(o.approvalStatus),
            syncedToOpportunity: Boolean(o.syncedToOpportunity),
            isActive: o.quoteId === this.session?.quoteId,
            cardClass:
                o.quoteId === this.session?.quoteId
                    ? 'option-card option-card-active'
                    : 'option-card option-card-idle'
        }));
    }

    get activeOptionCard() {
        return this.optionCards.find((o) => o.isActive) || this.optionCards[0];
    }

    get addDisabled() {
        const hasTargets = this.hasCatalogQueue || Boolean(this.selectedSku);
        return this.adding || this.pricingBusy || !hasTargets || !this.session?.quoteId;
    }

    get estimateDisabled() {
        return (
            this.estimateBusy ||
            this.adding ||
            this.pricingBusy ||
            this.isWorkforcePackageSelected ||
            !(this.hasCatalogQueue || this.selectedSku)
        );
    }

    get estimateSummaryLabel() {
        if (!this.estimateResult?.ok) {
            return '';
        }
        const src =
            this.estimateResult.pricingSource === 'pricingApi'
                ? 'RC estimate'
                : 'List estimate';
        return `${src}: ${this.formatMoney(this.estimateResult.mrr)}/mo`;
    }

    get hasEstimateLines() {
        return (this.estimateResult?.lines || []).length > 0;
    }

    get estimateLineRows() {
        return (this.estimateResult?.lines || []).map((line) => ({
            ...line,
            netUnitLabel: this.formatMoney(line.netUnitPrice),
            netTotalLabel: this.formatMoney(line.netTotal)
        }));
    }

    get addButtonLabel() {
        if (this.isWorkforcePackageSelected) {
            return `Add package to ${this.optionLabel}`;
        }
        const n = this.catalogSelectionCount;
        if (n > 1) {
            return `Add ${n} to ${this.optionLabel}`;
        }
        return `Add to ${this.optionLabel}`;
    }

    get repriceDisabled() {
        return this.pricingBusy || !this.hasLines || !this.session?.quoteId;
    }

    get deleteOptionDisabled() {
        return (
            this.pricingBusy ||
            this.addingOption ||
            !this.session?.quoteId ||
            (this.options || []).length < 2
        );
    }

    get deleteOptionTitle() {
        if ((this.options || []).length < 2) {
            return 'Keep at least one option';
        }
        return `Delete ${this.optionLabel}`;
    }

    get compareToggleLabel() {
        return this.compareMode ? '← Back to edit' : 'Compare';
    }

    get compareDisabled() {
        return (this.options || []).length < 2;
    }

    disconnectedCallback() {
        Object.values(this._qtyTimers).forEach((t) => clearTimeout(t));
        this._qtyTimers = {};
        Object.values(this._discTimers).forEach((t) => clearTimeout(t));
        this._discTimers = {};
    }

    async bootstrap() {
        this.loading = true;
        this.error = undefined;
        try {
            if (this.quoteId) {
                this.session = await getSession({ quoteId: this.quoteId });
                this.opportunityId =
                    this.opportunityId || this.session?.opportunityId;
            } else if (this.opportunityId) {
                this.session = await openFromOpportunity({
                    opportunityId: this.opportunityId
                });
                this.quoteId = this.session?.quoteId;
            } else {
                this.session = undefined;
                this.error =
                    'Open this suite from an Opportunity (Create Quote) or use ?c__opportunityId=.';
            }
            if (this.session?.termMonths) {
                this.termMonths = this.session.termMonths;
            }
            if (this.session?.billingFrequency) {
                this.billingFrequency = this.session.billingFrequency;
            }
            if (this.session?.quoteId) {
                this.opportunityId =
                    this.opportunityId || this.session.opportunityId;
                await Promise.all([
                    this.loadCatalog(),
                    this.loadOption(),
                    this.loadOptions()
                ]);
            }
        } catch (e) {
            this.session = undefined;
            this.error = this.reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    async loadCatalog() {
        this.catalogError = undefined;
        try {
            this.catalog = await getCatalog({ currencyIsoCode: this.currencyCode });
        } catch (e) {
            this.catalog = [];
            this.catalogError = this.reduceError(e);
        }
    }

    async loadOption() {
        if (!this.session?.quoteId) {
            return;
        }
        this.selectedLineIds = [];
        this.optionDetail = await getOptionDetail({ quoteId: this.session.quoteId });
        this.syncRibbonFromOption(this.optionDetail);
        this.pricingStatus = this.optionDetail?.priced ? 'priced' : 'idle';
    }

    syncRibbonFromOption(detail) {
        const qid = this.session?.quoteId;
        if (!detail || !qid) {
            return;
        }
        const isCustom = this.termScopeByQuoteId[qid] === 'custom';
        const isBillingCustom = this.billingScopeByQuoteId[qid] === 'custom';
        if (detail.lines?.length) {
            if (detail.termMonths) {
                this.termByQuoteId = { ...this.termByQuoteId, [qid]: detail.termMonths };
                if (!isCustom) {
                    this.termMonths = detail.termMonths;
                }
            }
            if (detail.startDate) {
                this.startByQuoteId = { ...this.startByQuoteId, [qid]: detail.startDate };
                if (!isCustom) {
                    this.termStartDate = detail.startDate;
                }
            }
            if (detail.billingFrequency) {
                this.billingByQuoteId = {
                    ...this.billingByQuoteId,
                    [qid]: detail.billingFrequency
                };
                if (!isBillingCustom) {
                    this.billingFrequency = detail.billingFrequency;
                }
            }
        } else if (isCustom) {
            // Keep custom maps; do not overwrite shared ribbon.
            if (this.termByQuoteId[qid] == null && detail.termMonths) {
                this.termByQuoteId = { ...this.termByQuoteId, [qid]: detail.termMonths };
            }
            if (!this.startByQuoteId[qid] && detail.startDate) {
                this.startByQuoteId = { ...this.startByQuoteId, [qid]: detail.startDate };
            }
            if (detail.billingFrequency) {
                this.billingByQuoteId = {
                    ...this.billingByQuoteId,
                    [qid]: detail.billingFrequency
                };
            }
        } else {
            if (this.termByQuoteId[qid] != null) {
                this.termMonths = this.termByQuoteId[qid];
            } else if (detail.termMonths) {
                this.termMonths = detail.termMonths;
                this.termByQuoteId = { ...this.termByQuoteId, [qid]: detail.termMonths };
            }
            if (this.startByQuoteId[qid]) {
                this.termStartDate = this.startByQuoteId[qid];
            } else if (detail.startDate) {
                this.termStartDate = detail.startDate;
                this.startByQuoteId = { ...this.startByQuoteId, [qid]: detail.startDate };
            }
            if (isBillingCustom) {
                if (this.billingByQuoteId[qid]) {
                    // keep custom billing; do not overwrite shared ribbon
                } else if (detail.billingFrequency) {
                    this.billingByQuoteId = {
                        ...this.billingByQuoteId,
                        [qid]: detail.billingFrequency
                    };
                }
            } else if (this.billingByQuoteId[qid]) {
                this.billingFrequency = this.billingByQuoteId[qid];
            } else if (detail.billingFrequency) {
                this.billingFrequency = detail.billingFrequency;
                this.billingByQuoteId = {
                    ...this.billingByQuoteId,
                    [qid]: detail.billingFrequency
                };
            }
        }
        if (this.termScopeByQuoteId[qid] == null) {
            this.termScopeByQuoteId = { ...this.termScopeByQuoteId, [qid]: 'shared' };
        }
        if (this.billingScopeByQuoteId[qid] == null) {
            this.billingScopeByQuoteId = { ...this.billingScopeByQuoteId, [qid]: 'shared' };
        }
    }

    scopeForQuote(qid) {
        return this.termScopeByQuoteId[qid] === 'custom' ? 'custom' : 'shared';
    }

    billingScopeForQuote(qid) {
        return this.billingScopeByQuoteId[qid] === 'custom' ? 'custom' : 'shared';
    }

    sharedQuoteIds() {
        const quoteIds = (this.options || []).map((o) => o.quoteId).filter(Boolean);
        if (this.session?.quoteId && !quoteIds.includes(this.session.quoteId)) {
            quoteIds.push(this.session.quoteId);
        }
        return quoteIds.filter((qid) => this.scopeForQuote(qid) === 'shared');
    }

    sharedBillingQuoteIds() {
        const quoteIds = (this.options || []).map((o) => o.quoteId).filter(Boolean);
        if (this.session?.quoteId && !quoteIds.includes(this.session.quoteId)) {
            quoteIds.push(this.session.quoteId);
        }
        return quoteIds.filter((qid) => this.billingScopeForQuote(qid) === 'shared');
    }

    allOptionQuoteIds() {
        const quoteIds = (this.options || []).map((o) => o.quoteId).filter(Boolean);
        if (this.session?.quoteId && !quoteIds.includes(this.session.quoteId)) {
            quoteIds.push(this.session.quoteId);
        }
        return quoteIds;
    }

    rememberBillingForQuote() {
        const qid = this.session?.quoteId;
        if (!qid) {
            return;
        }
        this.billingByQuoteId = {
            ...this.billingByQuoteId,
            [qid]: this.effectiveBillingFrequency || 'Monthly'
        };
    }

    rememberBillingOnSharedOptions() {
        const billing = this.billingFrequency || 'Monthly';
        const next = { ...this.billingByQuoteId };
        this.sharedBillingQuoteIds().forEach((qid) => {
            next[qid] = billing;
        });
        this.billingByQuoteId = next;
    }

    rememberSharedTermOnSharedOptions() {
        const start = this.termStartDate || todayIso();
        const months = this.termMonths;
        const nextTerm = { ...this.termByQuoteId };
        const nextStart = { ...this.startByQuoteId };
        this.sharedQuoteIds().forEach((qid) => {
            nextTerm[qid] = months;
            nextStart[qid] = start;
        });
        this.termByQuoteId = nextTerm;
        this.startByQuoteId = nextStart;
    }

    /** Per-option billing (and custom-term) change — only restamps the active option. */
    async persistTermToActiveOption() {
        if (!this.session?.quoteId) {
            return;
        }
        this.rememberBillingForQuote();
        const qid = this.session.quoteId;
        const months = this.effectiveTermMonths;
        const start = this.effectiveTermStart;
        this.termByQuoteId = { ...this.termByQuoteId, [qid]: months };
        this.startByQuoteId = { ...this.startByQuoteId, [qid]: start };
        const hasLines = (this.optionDetail?.lines || []).length > 0;
        if (!hasLines) {
            return;
        }
        this.termBusy = true;
        this.pricingBusy = true;
        this.optionError = undefined;
        this.pricingStatus = 'pending';
        try {
            this.optionDetail = await applyTermToOption({
                quoteId: qid,
                termMonths: months,
                startDateIso: start,
                billingFrequency: this.effectiveBillingFrequency || 'Monthly'
            });
            this.syncRibbonFromOption(this.optionDetail);
            this.pricingStatus = 'priced';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this.termBusy = false;
            this.pricingBusy = false;
        }
    }

    /** Ribbon term start / length — restamps Shared-scope options only. */
    async persistTermToSharedOptions() {
        const oppId = this.opportunityIdOrSession;
        if (!oppId || !this.session?.quoteId) {
            return;
        }
        const sharedIds = this.sharedQuoteIds();
        this.rememberSharedTermOnSharedOptions();
        if (sharedIds.length === 0) {
            return;
        }
        this.termBusy = true;
        this.pricingBusy = true;
        this.optionError = undefined;
        this.optionsError = undefined;
        this.pricingStatus = 'pending';
        try {
            this.optionDetail = await applyTermToAllOptions({
                opportunityId: oppId,
                selectedQuoteId: this.session.quoteId,
                termMonths: this.termMonths,
                startDateIso: this.termStartDate || todayIso(),
                quoteIds: sharedIds
            });
            this.syncRibbonFromOption(this.optionDetail);
            this.pricingStatus = this.optionDetail?.priced ? 'priced' : 'idle';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this.termBusy = false;
            this.pricingBusy = false;
        }
    }

    handleClearSelection() {
        this.selectedSku = undefined;
        this.catalogQueue = [];
        this.addError = undefined;
    }

    handleRemoveFromQueue(event) {
        const sku = event.currentTarget.dataset.sku;
        if (!sku) {
            return;
        }
        this.catalogQueue = (this.catalogQueue || []).filter((e) => e.sku !== sku);
        if (this.selectedSku === sku) {
            const remaining = this.catalogQueue;
            this.selectedSku = remaining.length
                ? remaining[remaining.length - 1].sku
                : undefined;
            if (remaining.length === 1) {
                this.quantity = Number(remaining[0].quantity) || 10;
            }
        }
        this.addError = undefined;
    }

    handleQueueQtyInput(event) {
        const sku = event.currentTarget.dataset.sku;
        const n = Number(event.target.value);
        const qty = Number.isFinite(n) && n > 0 ? n : 1;
        this.setQueueQuantity(sku, qty);
    }

    handleQueueQtyStep(event) {
        const sku = event.currentTarget.dataset.sku;
        const delta = Number(event.currentTarget.dataset.delta || 0);
        const entry = (this.catalogQueue || []).find((e) => e.sku === sku);
        if (!entry) {
            return;
        }
        const next = Number(entry.quantity || 1) + delta;
        this.setQueueQuantity(sku, Number.isFinite(next) && next > 0 ? next : 1);
    }

    handleQueueQtyPreset(event) {
        const sku = event.currentTarget.dataset.sku;
        const qty = Number(event.currentTarget.dataset.qty);
        if (!sku || !Number.isFinite(qty) || qty <= 0) {
            return;
        }
        this.setQueueQuantity(sku, qty);
    }

    handleApplyQtyToAll(event) {
        const qty = Number(event.currentTarget.dataset.qty);
        if (!Number.isFinite(qty) || qty <= 0) {
            return;
        }
        this.quantity = qty;
        this.catalogQueue = (this.catalogQueue || []).map((e) => ({
            ...e,
            quantity: qty
        }));
    }

    setQueueQuantity(sku, qty) {
        if (!sku) {
            return;
        }
        const safe = Number.isFinite(qty) && qty > 0 ? qty : 1;
        this.catalogQueue = (this.catalogQueue || []).map((e) =>
            e.sku === sku ? { ...e, quantity: safe } : e
        );
        if (!this.hasCatalogMultiSelect) {
            this.quantity = safe;
        }
        this.addError = undefined;
    }

    enqueueCatalogSku(sku, quantity) {
        if (!sku) {
            return;
        }
        const qty =
            Number.isFinite(Number(quantity)) && Number(quantity) > 0
                ? Number(quantity)
                : Number(this.quantity) > 0
                  ? Number(this.quantity)
                  : 10;
        const existing = (this.catalogQueue || []).find((e) => e.sku === sku);
        if (existing) {
            return;
        }
        this.catalogQueue = [...(this.catalogQueue || []), { sku, quantity: qty }];
        this.clearEstimate();
    }

    handleOverrideTerm() {
        const qid = this.session?.quoteId;
        if (!qid || this.termControlsDisabled) {
            return;
        }
        const months = this.termMonths;
        const start = this.termStartDate || todayIso();
        this.termScopeByQuoteId = { ...this.termScopeByQuoteId, [qid]: 'custom' };
        this.termByQuoteId = { ...this.termByQuoteId, [qid]: months };
        this.startByQuoteId = { ...this.startByQuoteId, [qid]: start };
    }

    async handleUseSharedTerm() {
        const qid = this.session?.quoteId;
        if (!qid || this.termControlsDisabled) {
            return;
        }
        this.termScopeByQuoteId = { ...this.termScopeByQuoteId, [qid]: 'shared' };
        this.termByQuoteId = { ...this.termByQuoteId, [qid]: this.termMonths };
        this.startByQuoteId = {
            ...this.startByQuoteId,
            [qid]: this.termStartDate || todayIso()
        };
        await this.persistTermToActiveOption();
    }

    handleOverrideBilling() {
        const qid = this.session?.quoteId;
        if (!qid || this.termControlsDisabled) {
            return;
        }
        this.billingScopeByQuoteId = { ...this.billingScopeByQuoteId, [qid]: 'custom' };
        this.billingByQuoteId = {
            ...this.billingByQuoteId,
            [qid]: this.billingFrequency || 'Monthly'
        };
    }

    async handleUseSharedBilling() {
        const qid = this.session?.quoteId;
        if (!qid || this.termControlsDisabled) {
            return;
        }
        this.billingScopeByQuoteId = { ...this.billingScopeByQuoteId, [qid]: 'shared' };
        this.billingByQuoteId = {
            ...this.billingByQuoteId,
            [qid]: this.billingFrequency || 'Monthly'
        };
        await this.persistTermToActiveOption();
    }

    handleFocusTermRibbon() {
        const el = this.template.querySelector('#term-start');
        if (el) {
            el.focus();
            el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
    }

    async loadOptions() {
        const oppId = this.opportunityIdOrSession;
        if (!oppId) {
            this.options = [];
            return;
        }
        this.optionsError = undefined;
        try {
            this.options = await listOptions({
                opportunityId: oppId,
                selectedQuoteId: this.session?.quoteId
            });
            const nextScope = { ...this.termScopeByQuoteId };
            const nextBillingScope = { ...this.billingScopeByQuoteId };
            (this.options || []).forEach((o) => {
                if (o.quoteId && nextScope[o.quoteId] == null) {
                    nextScope[o.quoteId] = 'shared';
                }
                if (o.quoteId && nextBillingScope[o.quoteId] == null) {
                    nextBillingScope[o.quoteId] = 'shared';
                }
            });
            this.termScopeByQuoteId = nextScope;
            this.billingScopeByQuoteId = nextBillingScope;
        } catch (e) {
            this.options = [];
            this.optionsError = this.reduceError(e);
        }
    }

    async refreshOptionsQuietly() {
        try {
            await this.loadOptions();
        } catch (e) {
            // keep prior options list
        }
    }

    async handleTerm(event) {
        const next = Number(event.currentTarget.dataset.value);
        if (!Number.isFinite(next) || next === Number(this.termMonths)) {
            return;
        }
        this.termMonths = next;
        await this.persistTermToSharedOptions();
    }

    async handleTermStartChange(event) {
        const next = event.target.value;
        if (!next || next === this.termStartDate) {
            return;
        }
        this.termStartDate = next;
        await this.persistTermToSharedOptions();
    }

    async handleOptionLocalTerm(event) {
        const qid = this.session?.quoteId;
        if (!qid || !this.isActiveTermCustom) {
            return;
        }
        const next = Number(event.currentTarget.dataset.value);
        if (!Number.isFinite(next) || next === Number(this.effectiveTermMonths)) {
            return;
        }
        this.termByQuoteId = { ...this.termByQuoteId, [qid]: next };
        await this.persistTermToActiveOption();
    }

    async handleOptionLocalTermStartChange(event) {
        const qid = this.session?.quoteId;
        if (!qid || !this.isActiveTermCustom) {
            return;
        }
        const next = event.target.value;
        if (!next || next === this.effectiveTermStart) {
            return;
        }
        this.startByQuoteId = { ...this.startByQuoteId, [qid]: next };
        await this.persistTermToActiveOption();
    }

    async handleOptionLocalBilling(event) {
        const qid = this.session?.quoteId;
        if (!qid || !this.isActiveBillingCustom) {
            return;
        }
        const next = event.currentTarget.dataset.value;
        if (!next || next === this.effectiveBillingFrequency) {
            return;
        }
        this.billingByQuoteId = { ...this.billingByQuoteId, [qid]: next };
        await this.persistTermToActiveOption();
    }

    async handleBilling(event) {
        const next = event.currentTarget.dataset.value;
        if (!next || next === this.billingFrequency) {
            return;
        }
        this.billingFrequency = next;
        await this.persistBillingToSharedOptions();
    }

    /** Ribbon billing — restamps Shared-scope options only; preserves each term. */
    async persistBillingToSharedOptions() {
        const oppId = this.opportunityIdOrSession;
        if (!oppId || !this.session?.quoteId) {
            return;
        }
        const sharedIds = this.sharedBillingQuoteIds();
        this.rememberBillingOnSharedOptions();
        // Empty options have no QLI term; seed maps so Apex can preserve length/start.
        const nextTerm = { ...this.termByQuoteId };
        const nextStart = { ...this.startByQuoteId };
        sharedIds.forEach((qid) => {
            if (nextTerm[qid] == null) {
                nextTerm[qid] =
                    this.scopeForQuote(qid) === 'custom' && this.termByQuoteId[qid] != null
                        ? this.termByQuoteId[qid]
                        : this.termMonths;
            }
            if (!nextStart[qid]) {
                nextStart[qid] =
                    this.scopeForQuote(qid) === 'custom' && this.startByQuoteId[qid]
                        ? this.startByQuoteId[qid]
                        : this.termStartDate || todayIso();
            }
        });
        this.termByQuoteId = nextTerm;
        this.startByQuoteId = nextStart;
        if (sharedIds.length === 0) {
            return;
        }
        this.termBusy = true;
        this.pricingBusy = true;
        this.optionError = undefined;
        this.optionsError = undefined;
        this.pricingStatus = 'pending';
        try {
            this.optionDetail = await applyBillingToAllOptions({
                opportunityId: oppId,
                selectedQuoteId: this.session.quoteId,
                billingFrequency: this.billingFrequency || 'Monthly',
                termMonthsByQuoteId: this.termByQuoteId || {},
                startDateByQuoteId: this.startByQuoteId || {},
                quoteIds: sharedIds
            });
            this.syncRibbonFromOption(this.optionDetail);
            this.pricingStatus = this.optionDetail?.priced ? 'priced' : 'idle';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this.termBusy = false;
            this.pricingBusy = false;
        }
    }

    handleToggleAgent() {
        this.agentOpen = !this.agentOpen;
        if (this.agentOpen) {
            this.agentError = undefined;
            this.ensureQuotingAssistantBotId();
        }
    }

    async ensureQuotingAssistantBotId() {
        if (this.quotingAssistantBotId) {
            return this.quotingAssistantBotId;
        }
        try {
            this.quotingAssistantBotId = await getQuotingAssistantBotId();
        } catch (e) {
            this.agentError = this.reduceError(e);
        }
        return this.quotingAssistantBotId;
    }

    get agentOpenLabel() {
        return this.agentChatBusy ? 'Opening…' : 'Open Agentforce';
    }

    get agentRefreshDisabled() {
        return this.agentChatBusy || this.loading || !this.session?.opportunityId;
    }

    buildSuiteOpportunitySeed(oppId) {
        return (
            `I am in the BambooHR Revenue Suite working on opportunity ${oppId}. ` +
            `Remember this Opportunity Id as activeOpportunityId for BambooHR Good/Better/Best ` +
            `and other suite quoting. Confirm the opportunity in one short line; do not build tiers yet. ` +
            `When I later ask to change term length or billing frequency on all suite options without ` +
            `changing seat count, use BambooHR Suite Apply Commercial Terms — not Build Tier or line field updates.`
        );
    }

    async handleOpenAgentforce() {
        this.agentError = undefined;
        const botId = await this.ensureQuotingAssistantBotId();
        if (!botId) {
            this.agentError =
                'Quoting Assistant is not published in this org. Publish/activate RLM_Quoting_Assistant.';
            return;
        }
        const oppId = this.session?.opportunityId || this.opportunityId;
        this.agentChatBusy = true;
        try {
            await openAgentforce(botId);
            if (oppId) {
                await executeAgentforce(this.buildSuiteOpportunitySeed(oppId), botId);
                this.agentStatus =
                    'Agentforce opened with this suite’s Opportunity — continue in the panel, then Refresh options.';
            } else {
                this.agentStatus =
                    'Agentforce opened — no Opportunity loaded in the suite; name the Opp in chat if needed.';
            }
        } catch (e) {
            this.agentError = this.reduceError(e);
            this.agentStatus = undefined;
        } finally {
            this.agentChatBusy = false;
        }
    }

    async handleAgentRefreshOptions() {
        if (!this.session?.opportunityId) {
            return;
        }
        this.agentError = undefined;
        this.agentStatus = 'Refreshing options…';
        try {
            await this.loadOptions();
            if (this.session?.quoteId) {
                await this.loadOption();
            }
            if ((this.options || []).length > 1) {
                this.compareMode = true;
                await this.loadCompareDetails();
            }
            this.agentStatus =
                'Options refreshed. Hard-refresh any open Quote tab if the line editor still looks stale.';
        } catch (e) {
            this.agentError = this.reduceError(e);
            this.agentStatus = undefined;
        }
    }

    handleSearch(event) {
        this.searchText = event.target.value;
    }

    handleSelectProduct(event) {
        const sku = event.currentTarget.dataset.sku;
        this.selectedSku = sku;
        this.addError = undefined;
        if (sku === WORKFORCE_PKG_SKU) {
            this.packagePlanSku = 'BAMBOO-PRO';
            const qty = Number(this.quantity) > 0 ? Number(this.quantity) : 10;
            this.catalogQueue = [{ sku, quantity: qty }];
            return;
        }
        this.enqueueCatalogSku(sku);
        const entry = (this.catalogQueue || []).find((e) => e.sku === sku);
        if (entry && !this.hasCatalogMultiSelect) {
            this.quantity = Number(entry.quantity) || 10;
        }
    }

    handlePackagePlan(event) {
        const next = event.currentTarget.dataset.value;
        if (!next) {
            return;
        }
        this.packagePlanSku = next;
    }

    handleToggleCatalogSku(event) {
        event.stopPropagation();
        const sku = event.currentTarget.dataset.sku;
        if (!sku) {
            return;
        }
        const checked = event.currentTarget.checked;
        if (checked) {
            this.enqueueCatalogSku(sku);
            this.selectedSku = sku;
            if (sku === WORKFORCE_PKG_SKU) {
                this.packagePlanSku = 'BAMBOO-PRO';
                // Workforce is exclusive in the queue for Path A configure UX.
                const qty = Number(this.quantity) > 0 ? Number(this.quantity) : 10;
                this.catalogQueue = [{ sku, quantity: qty }];
            } else {
                // Drop Workforce if mixing a-la-carte products.
                this.catalogQueue = (this.catalogQueue || []).filter(
                    (e) => e.sku !== WORKFORCE_PKG_SKU
                );
            }
        } else {
            this.catalogQueue = (this.catalogQueue || []).filter((e) => e.sku !== sku);
            if (this.selectedSku === sku) {
                const remaining = this.catalogQueue;
                this.selectedSku = remaining.length
                    ? remaining[remaining.length - 1].sku
                    : undefined;
                if (remaining.length === 1) {
                    this.quantity = Number(remaining[0].quantity) || 10;
                }
            }
        }
        this.addError = undefined;
    }

    handleQtyInput(event) {
        const n = Number(event.target.value);
        const qty = Number.isFinite(n) && n > 0 ? n : 1;
        this.quantity = qty;
        if ((this.catalogQueue || []).length === 1) {
            const sku = this.catalogQueue[0].sku;
            this.setQueueQuantity(sku, qty);
        }
    }

    handleQtyPreset(event) {
        const qty = Number(event.currentTarget.dataset.qty);
        if (!Number.isFinite(qty) || qty <= 0) {
            return;
        }
        this.quantity = qty;
        if ((this.catalogQueue || []).length === 1) {
            this.setQueueQuantity(this.catalogQueue[0].sku, qty);
        }
    }

    handleQtyStep(event) {
        const delta = Number(event.currentTarget.dataset.delta || 0);
        const next = Number(this.quantity || 1) + delta;
        const qty = Number.isFinite(next) && next > 0 ? next : 1;
        this.quantity = qty;
        if ((this.catalogQueue || []).length === 1) {
            this.setQueueQuantity(this.catalogQueue[0].sku, qty);
        }
    }

    handleLineQtyInput(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const n = Number(event.target.value);
        const qty = Number.isFinite(n) && n > 0 ? n : 1;
        if (!lineId || !this.optionDetail?.lines) {
            return;
        }
        this.optionDetail = {
            ...this.optionDetail,
            lines: this.optionDetail.lines.map((line) =>
                line.lineId === lineId ? { ...line, quantity: qty } : line
            )
        };
        this.scheduleQtyUpdate(lineId, qty);
    }

    handleLineDiscountInput(event) {
        const lineId = event.currentTarget.dataset.lineId;
        let n = Number(event.target.value);
        if (!Number.isFinite(n) || n < 0) {
            n = 0;
        }
        if (n > 100) {
            n = 100;
        }
        if (!lineId || !this.optionDetail?.lines) {
            return;
        }
        this.optionDetail = {
            ...this.optionDetail,
            lines: this.optionDetail.lines.map((line) =>
                line.lineId === lineId ? { ...line, discountPercent: n } : line
            )
        };
        this.scheduleDiscUpdate(lineId, n);
    }

    scheduleQtyUpdate(lineId, qty) {
        if (this._qtyTimers[lineId]) {
            clearTimeout(this._qtyTimers[lineId]);
        }
        this.pricingStatus = 'pending';
        this._qtyTimers[lineId] = setTimeout(() => {
            delete this._qtyTimers[lineId];
            this.enqueueQtyUpdate(lineId, qty);
        }, QTY_DEBOUNCE_MS);
    }

    scheduleDiscUpdate(lineId, pct) {
        if (this._discTimers[lineId]) {
            clearTimeout(this._discTimers[lineId]);
        }
        this.pricingStatus = 'pending';
        this._discTimers[lineId] = setTimeout(() => {
            delete this._discTimers[lineId];
            this.enqueueDiscUpdate(lineId, pct);
        }, QTY_DEBOUNCE_MS);
    }

    enqueueQtyUpdate(lineId, qty) {
        if (this._qtyInFlight) {
            this._qtyQueued = { lineId, qty };
            return;
        }
        this.runQtyUpdate(lineId, qty);
    }

    enqueueDiscUpdate(lineId, pct) {
        if (this._discInFlight) {
            this._discQueued = { lineId, pct };
            return;
        }
        this.runDiscUpdate(lineId, pct);
    }

    async runQtyUpdate(lineId, qty) {
        if (!this.session?.quoteId) {
            return;
        }
        this._qtyInFlight = true;
        this.pricingBusy = true;
        this.optionError = undefined;
        try {
            this.optionDetail = await updateLineQuantity({
                quoteId: this.session.quoteId,
                lineId,
                quantity: qty
            });
            this.pricingStatus = this.optionDetail?.priced ? 'priced' : 'priced';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this._qtyInFlight = false;
            this.pricingBusy = false;
            if (this._qtyQueued) {
                const next = this._qtyQueued;
                this._qtyQueued = null;
                this.runQtyUpdate(next.lineId, next.qty);
            }
        }
    }

    async runDiscUpdate(lineId, pct) {
        if (!this.session?.quoteId) {
            return;
        }
        this._discInFlight = true;
        this.pricingBusy = true;
        this.optionError = undefined;
        try {
            this.optionDetail = await updateLineDiscount({
                quoteId: this.session.quoteId,
                lineId,
                discountPercent: pct
            });
            this.pricingStatus = 'priced';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this._discInFlight = false;
            this.pricingBusy = false;
            if (this._discQueued) {
                const next = this._discQueued;
                this._discQueued = null;
                this.runDiscUpdate(next.lineId, next.pct);
            }
        }
    }

    clearEstimate() {
        this.estimateResult = undefined;
        this.estimateError = undefined;
    }

    buildEstimateLines() {
        let queue = (this.catalogQueue || []).filter((e) => e?.sku);
        if (!queue.length && this.selectedSku) {
            queue = [
                {
                    sku: this.selectedSku,
                    quantity: Number(this.quantity) > 0 ? Number(this.quantity) : 10
                }
            ];
        }
        return queue.map((entry) => ({
            sku: entry.sku,
            quantity: Number(entry.quantity) > 0 ? Number(entry.quantity) : 1
        }));
    }

    async handleEstimateCatalog() {
        if (this.estimateDisabled) {
            return;
        }
        const lines = this.buildEstimateLines();
        if (!lines.length) {
            return;
        }
        this.estimateBusy = true;
        this.estimateError = undefined;
        try {
            this.estimateResult = await estimateCatalogAdd({
                currencyIsoCode: this.session?.currencyIsoCode || 'USD',
                termMonths: this.effectiveTermMonths,
                startDateIso: this.effectiveTermStart,
                lines
            });
            if (!this.estimateResult?.ok) {
                this.estimateError =
                    this.estimateResult?.errorMessage || 'Estimate unavailable.';
            }
        } catch (e) {
            this.estimateError = this.reduceError(e);
            this.estimateResult = undefined;
        } finally {
            this.estimateBusy = false;
        }
    }

    async handleAddToOption() {
        if (this.addDisabled) {
            return;
        }
        let queue = (this.catalogQueue || []).filter((e) => e?.sku);
        if (!queue.length && this.selectedSku) {
            queue = [
                {
                    sku: this.selectedSku,
                    quantity: Number(this.quantity) > 0 ? Number(this.quantity) : 10
                }
            ];
        }
        if (!queue.length) {
            return;
        }
        this.adding = true;
        this.pricingBusy = true;
        this.addError = undefined;
        this.pricingStatus = 'pending';
        try {
            const termMonths = this.effectiveTermMonths;
            const startDateIso = this.effectiveTermStart;
            const billingFrequency = this.effectiveBillingFrequency || 'Monthly';
            let result;
            if (this.isWorkforcePackageSelected) {
                const qty =
                    Number(queue[0]?.quantity) > 0
                        ? Number(queue[0].quantity)
                        : Number(this.quantity) > 0
                          ? Number(this.quantity)
                          : 10;
                result = await addWorkforcePackage({
                    quoteId: this.session.quoteId,
                    planSku: this.packagePlanSku || 'BAMBOO-PRO',
                    quantity: qty,
                    termMonths,
                    startDateIso,
                    billingFrequency
                });
            } else if (queue.length === 1) {
                result = await addProductLine({
                    quoteId: this.session.quoteId,
                    sku: queue[0].sku,
                    quantity:
                        Number(queue[0].quantity) > 0 ? Number(queue[0].quantity) : 1,
                    termMonths,
                    startDateIso,
                    billingFrequency
                });
            } else {
                result = await addProductLinesBySku({
                    quoteId: this.session.quoteId,
                    skus: queue.map((e) => e.sku),
                    quantities: queue.map((e) =>
                        Number(e.quantity) > 0 ? Number(e.quantity) : 1
                    ),
                    termMonths,
                    startDateIso,
                    billingFrequency
                });
            }
            this.optionDetail = result.option;
            this.syncRibbonFromOption(result.option);
            this.pricingStatus = result.option?.priced ? 'priced' : 'priced';
            this.catalogQueue = [];
            this.selectedSku = undefined;
            this.clearEstimate();
            this.refreshOptionsQuietly();
        } catch (e) {
            this.addError = this.reduceError(e);
            this.pricingStatus = 'error';
        } finally {
            this.adding = false;
            this.pricingBusy = false;
        }
    }

    async handleRemoveLine(event) {
        const lineId = event.currentTarget.dataset.lineId;
        if (!lineId || !this.session?.quoteId || this.pricingBusy) {
            return;
        }
        await this.deleteLines([lineId]);
    }

    handleToggleLineSelect(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const bundleLineIds = event.currentTarget.dataset.bundleLineIds;
        if (!lineId && !bundleLineIds) {
            return;
        }
        const checked = event.currentTarget.checked;
        const set = new Set(this.selectedLineIds || []);
        const ids = bundleLineIds
            ? bundleLineIds.split(',').filter(Boolean)
            : [lineId];
        for (const id of ids) {
            if (checked) {
                set.add(id);
            } else {
                set.delete(id);
            }
        }
        this.selectedLineIds = [...set];
    }

    handleToggleSelectAllLines(event) {
        if (event.currentTarget.checked) {
            this.selectedLineIds = (this.optionDetail?.lines || [])
                .map((l) => l.lineId)
                .filter(Boolean);
        } else {
            this.selectedLineIds = [];
        }
    }

    async handleDeleteSelectedLines() {
        if (this.deleteSelectedDisabled) {
            return;
        }
        const ids = [...(this.selectedLineIds || [])];
        const n = ids.length;
        // eslint-disable-next-line no-alert
        const ok = window.confirm(
            n === 1
                ? 'Delete the selected line? This cannot be undone.'
                : `Delete ${n} selected lines? This cannot be undone.`
        );
        if (!ok) {
            return;
        }
        await this.deleteLines(ids);
    }

    async deleteLines(lineIds) {
        if (!lineIds?.length || !this.session?.quoteId || this.pricingBusy) {
            return;
        }
        this.pricingBusy = true;
        this.optionError = undefined;
        this.pricingStatus = 'pending';
        try {
            this.optionDetail =
                lineIds.length === 1
                    ? await removeLine({
                          quoteId: this.session.quoteId,
                          lineId: lineIds[0]
                      })
                    : await removeLines({
                          quoteId: this.session.quoteId,
                          lineIds
                      });
            this.selectedLineIds = [];
            this.pricingStatus = this.optionDetail?.priced ? 'priced' : 'idle';
            if (this.optionDetail?.termMonths && this.optionDetail?.lines?.length) {
                this.termMonths = this.optionDetail.termMonths;
            }
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this.pricingBusy = false;
        }
    }

    async handleDeleteOption() {
        if (this.deleteOptionDisabled) {
            return;
        }
        const label = this.optionLabel || 'this option';
        // eslint-disable-next-line no-alert
        const ok = window.confirm(
            `Delete ${label}? This removes the draft quote and its lines. This cannot be undone.`
        );
        if (!ok) {
            return;
        }
        const deletedId = this.session?.quoteId;
        this.addingOption = true;
        this.pricingBusy = true;
        this.optionsError = undefined;
        this.optionError = undefined;
        try {
            const result = await deleteOption({ quoteId: deletedId });
            if (deletedId) {
                const nextTerm = { ...this.termByQuoteId };
                const nextStart = { ...this.startByQuoteId };
                const nextBilling = { ...this.billingByQuoteId };
                const nextScope = { ...this.termScopeByQuoteId };
                const nextBillingScope = { ...this.billingScopeByQuoteId };
                delete nextTerm[deletedId];
                delete nextStart[deletedId];
                delete nextBilling[deletedId];
                delete nextScope[deletedId];
                delete nextBillingScope[deletedId];
                this.termByQuoteId = nextTerm;
                this.startByQuoteId = nextStart;
                this.billingByQuoteId = nextBilling;
                this.termScopeByQuoteId = nextScope;
                this.billingScopeByQuoteId = nextBillingScope;
            }
            this.options = result.options || [];
            this.session = result.session;
            this.quoteId = result.session?.quoteId;
            this.compareMode = false;
            this.compareDetails = [];
            await this.loadOption();
            this.refreshOptionsQuietly();
        } catch (e) {
            this.optionsError = this.reduceError(e);
        } finally {
            this.addingOption = false;
            this.pricingBusy = false;
        }
    }

    async handleReprice() {
        if (this.repriceDisabled) {
            return;
        }
        this.pricingBusy = true;
        this.optionError = undefined;
        this.pricingStatus = 'pending';
        try {
            this.optionDetail = await repriceOption({ quoteId: this.session.quoteId });
            this.pricingStatus = 'priced';
            this.refreshOptionsQuietly();
        } catch (e) {
            this.pricingStatus = 'error';
            this.optionError = this.reduceError(e);
        } finally {
            this.pricingBusy = false;
        }
    }

    async handleAddOption() {
        if (this.addOptionDisabled) {
            return;
        }
        this.addingOption = true;
        this.optionsError = undefined;
        try {
            const result = await addOption({
                opportunityId: this.opportunityIdOrSession
            });
            this.options = result.options || [];
            this.session = result.session;
            this.quoteId = result.session?.quoteId;
            const newId = result.session?.quoteId;
            if (newId) {
                this.termScopeByQuoteId = { ...this.termScopeByQuoteId, [newId]: 'shared' };
                this.billingScopeByQuoteId = {
                    ...this.billingScopeByQuoteId,
                    [newId]: 'shared'
                };
                this.termByQuoteId = { ...this.termByQuoteId, [newId]: this.termMonths };
                this.startByQuoteId = {
                    ...this.startByQuoteId,
                    [newId]: this.termStartDate || todayIso()
                };
                this.billingByQuoteId = {
                    ...this.billingByQuoteId,
                    [newId]: this.billingFrequency || 'Monthly'
                };
            }
            this.optionDetail = {
                quoteId: result.session?.quoteId,
                optionLabel: result.created?.optionLabel,
                mrr: 0,
                arr: 0,
                lines: [],
                priced: false,
                termMonths: this.termMonths,
                evergreen: Number(this.termMonths) === 1,
                startDate: this.termStartDate || todayIso(),
                endDate:
                    Number(this.termMonths) === 1
                        ? null
                        : computeEndIso(this.termStartDate || todayIso(), this.termMonths)
            };
            this.pricingStatus = 'idle';
            this.compareMode = false;
            this.compareDetails = [];
            await this.loadOption();
        } catch (e) {
            this.optionsError = this.reduceError(e);
        } finally {
            this.addingOption = false;
        }
    }

    async handleToggleCompare() {
        if (this.compareDisabled && !this.compareMode) {
            return;
        }
        const next = !this.compareMode;
        this.compareMode = next;
        if (next) {
            await this.loadCompareDetails();
        } else {
            this.compareDetails = [];
            this.compareError = undefined;
        }
    }

    async handlePreview() {
        const quoteId = this.session?.quoteId;
        if (!quoteId || this.previewBusy) {
            return;
        }
        this.previewBusy = true;
        this.previewError = undefined;
        try {
            let status = await previewProposal({ quoteId });
            const maxAttempts = 45;
            for (let i = 0; i < maxAttempts; i += 1) {
                const st = (status?.status || '').toLowerCase();
                if (st === 'completed' || st === 'success') {
                    break;
                }
                if (st === 'failed' || st === 'error') {
                    throw new Error(status.message || 'Document generation failed.');
                }
                await new Promise((resolve) => setTimeout(resolve, 2000));
                status = await getProposalStatus({ processId: status.processId });
            }
            const done = (status?.status || '').toLowerCase();
            if (done !== 'completed' && done !== 'success') {
                throw new Error(
                    status?.message || 'Proposal generation timed out. Try again.'
                );
            }
            if (status.contentDocumentId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__namedPage',
                    attributes: { pageName: 'filePreview' },
                    state: { selectedRecordId: status.contentDocumentId }
                });
            } else if (status.downloadUrl) {
                window.open(status.downloadUrl, '_blank');
            } else {
                throw new Error(status.message || 'No proposal file was produced.');
            }
        } catch (e) {
            this.previewError = this.reduceError(e);
        } finally {
            this.previewBusy = false;
        }
    }

    applySyncResult(result) {
        if (result?.options) {
            this.options = result.options;
        }
        if (this.session) {
            this.session = {
                ...this.session,
                syncedQuoteId: result?.syncedQuoteId || null
            };
        }
    }

    async handleSyncToOpportunity() {
        const quoteId = this.session?.quoteId;
        if (!quoteId || this.syncDisabled) {
            return;
        }
        const otherSynced = (this.options || []).find(
            (o) => o.syncedToOpportunity && o.quoteId !== quoteId
        );
        if (otherSynced) {
            const ok = window.confirm(
                `Replace ${otherSynced.optionLabel} with ${this.optionLabel} on the Opportunity?`
            );
            if (!ok) {
                return;
            }
        }
        this.syncBusy = true;
        this.syncError = undefined;
        try {
            const result = await syncOptionToOpportunity({ quoteId });
            this.applySyncResult(result);
            if (this.compareMode) {
                await this.loadCompareDetails();
            }
        } catch (e) {
            this.syncError = this.reduceError(e);
        } finally {
            this.syncBusy = false;
        }
    }

    async handleUnsyncOpportunity() {
        const opportunityId = this.opportunityIdOrSession;
        if (!opportunityId || this.syncBusy) {
            return;
        }
        this.syncBusy = true;
        this.syncError = undefined;
        try {
            const result = await unsyncOpportunity({ opportunityId });
            this.applySyncResult(result);
            if (this.compareMode) {
                await this.loadCompareDetails();
            }
        } catch (e) {
            this.syncError = this.reduceError(e);
        } finally {
            this.syncBusy = false;
        }
    }

    async handleSubmitForApproval() {
        const quoteId = this.session?.quoteId;
        if (!quoteId || this.submitApprovalDisabled) {
            return;
        }
        this.approvalBusy = true;
        this.approvalError = undefined;
        this.approvalStatusMsg = undefined;
        try {
            const result = await submitOptionForApproval({
                quoteId,
                comments: 'Submitted from BambooHR Revenue Suite'
            });
            if (result?.options) {
                this.options = result.options;
            }
            if (result?.option) {
                this.optionDetail = result.option;
            }
            this.approvalStatusMsg = result?.summary || 'Submitted for approval.';
            if (this.compareMode) {
                await this.loadCompareDetails();
            }
        } catch (e) {
            this.approvalError = this.reduceError(e);
        } finally {
            this.approvalBusy = false;
        }
    }

    async handleToggleSend() {
        if (this.sendOpen) {
            this.sendOpen = false;
            this.sendError = undefined;
            return;
        }
        if (this.sendDisabled) {
            return;
        }
        this.sendOpen = true;
        this.sendError = undefined;
        this.sendStatusMsg = undefined;
        const opportunityId = this.opportunityIdOrSession;
        if (!opportunityId) {
            return;
        }
        try {
            this.sendContacts =
                (await listOpportunityContacts({ opportunityId })) || [];
            if (!this.sendContactId && this.sendContacts.length) {
                this.sendContactId = this.sendContacts[0].contactId;
            }
        } catch (e) {
            this.sendError = this.reduceError(e);
        }
    }

    handleSendContactChange(event) {
        this.sendContactId = event.target.value || undefined;
    }

    handleSendToAddressChange(event) {
        this.sendToAddress = event.target.value || '';
    }

    handleSendAttachPdfChange(event) {
        this.sendAttachPdf = Boolean(event.target.checked);
    }

    async handleSendToCustomer() {
        const quoteId = this.session?.quoteId;
        if (!quoteId || this.sendBusy) {
            return;
        }
        this.sendBusy = true;
        this.sendError = undefined;
        this.sendStatusMsg = undefined;
        try {
            if (this.sendAttachPdf) {
                let status = await previewProposal({ quoteId });
                const maxAttempts = 45;
                for (let i = 0; i < maxAttempts; i += 1) {
                    const st = (status?.status || '').toLowerCase();
                    if (st === 'completed' || st === 'success') {
                        break;
                    }
                    if (st === 'failed' || st === 'error') {
                        throw new Error(
                            status.message || 'Document generation failed.'
                        );
                    }
                    await new Promise((resolve) => setTimeout(resolve, 2000));
                    status = await getProposalStatus({
                        processId: status.processId
                    });
                }
            }
            const result = await sendOptionToCustomer({
                quoteId,
                contactId: this.sendContactId || null,
                toAddress: this.sendToAddress || null,
                attachPdf: this.sendAttachPdf,
                generatePdfIfMissing: false
            });
            this.sendStatusMsg = result?.message || 'Email sent.';
            this.sendOpen = false;
        } catch (e) {
            this.sendError = this.reduceError(e);
        } finally {
            this.sendBusy = false;
        }
    }

    async loadCompareDetails() {
        const quoteIds = (this.options || []).map((o) => o.quoteId).filter(Boolean);
        if (quoteIds.length === 0) {
            this.compareDetails = [];
            return;
        }
        this.compareLoading = true;
        this.compareError = undefined;
        try {
            const details = await Promise.all(
                quoteIds.map((quoteId) => getOptionDetail({ quoteId }))
            );
            this.compareDetails = details;
        } catch (e) {
            this.compareDetails = [];
            this.compareError = this.reduceError(e);
        } finally {
            this.compareLoading = false;
        }
    }

    async handleSelectOption(event) {
        const nextQuoteId = event.currentTarget.dataset.quoteId;
        if (!nextQuoteId || nextQuoteId === this.session?.quoteId) {
            if (this.compareMode && nextQuoteId === this.session?.quoteId) {
                this.compareMode = false;
                this.compareDetails = [];
            }
            return;
        }
        this.pricingBusy = true;
        this.optionError = undefined;
        try {
            this.session = await getSession({ quoteId: nextQuoteId });
            this.quoteId = nextQuoteId;
            if (this.session?.termMonths) {
                this.termMonths = this.session.termMonths;
            }
            await Promise.all([this.loadOption(), this.loadOptions()]);
            this.compareMode = false;
            this.compareDetails = [];
        } catch (e) {
            this.optionError = this.reduceError(e);
        } finally {
            this.pricingBusy = false;
        }
    }

    handleBackToOpp() {
        const recordId = this.opportunityId || this.session?.opportunityId;
        if (!recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'Opportunity',
                actionName: 'view'
            }
        });
    }

    formatMoney(value) {
        const n = Number(value || 0);
        try {
            return new Intl.NumberFormat('en-US', {
                style: 'currency',
                currency: this.currencyCode,
                maximumFractionDigits: 0
            }).format(n);
        } catch (e) {
            return `$${n}`;
        }
    }

    reduceError(err) {
        if (!err) {
            return 'Unexpected error';
        }
        let raw;
        if (Array.isArray(err.body)) {
            raw = err.body.map((e) => e.message).join(', ');
        } else if (err.body?.message) {
            raw = err.body.message;
        } else if (err.message) {
            raw = err.message;
        } else {
            raw = String(err);
        }
        const upper = (raw || '').toUpperCase();
        if (upper.includes('UNABLE_TO_LOCK_ROW') || upper.includes('ROW LOCK')) {
            return (
                'Opportunity is busy (row lock). Wait a moment and retry, or open this ' +
                'option Quote and click Reprice All, then Refresh options in the suite.'
            );
        }
        return raw;
    }
}
