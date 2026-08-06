import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import bffUrlLabel from '@salesforce/label/c.RLM_Bamboo_Get_Pricing_Bff_Url';

export default class RlmBambooGetPricingShell extends NavigationMixin(LightningElement) {
    /** Optional design-time override of the Custom Label URL. */
    @api bffUrlOverride;
    /** When true, navigate to the BFF as soon as the page loads. */
    @api autoRedirect = false;
    /** When true, open the BFF in a new browser tab (design default true). */
    @api openInNewTab = false;

    _didAutoRedirect = false;

    get resolvedUrl() {
        const override = (this.bffUrlOverride || '').trim();
        const fromLabel = (bffUrlLabel || '').trim();
        const raw = override || fromLabel;
        return this.normalizeUrl(raw);
    }

    get hasUrl() {
        return Boolean(this.resolvedUrl);
    }

    get displayUrl() {
        return this.resolvedUrl || 'Not configured';
    }

    get shouldAutoRedirect() {
        return this.toBool(this.autoRedirect);
    }

    get shouldOpenInNewTab() {
        return this.toBool(this.openInNewTab, true);
    }

    connectedCallback() {
        if (this.shouldAutoRedirect && this.hasUrl && !this._didAutoRedirect) {
            this._didAutoRedirect = true;
            // Defer so the first paint can show the shell branding briefly.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            window.setTimeout(() => this.goToPricing(), 400);
        }
    }

    handleGetPricing() {
        this.goToPricing();
    }

    goToPricing() {
        const url = this.resolvedUrl;
        if (!url) {
            return;
        }
        if (this.shouldOpenInNewTab) {
            window.open(url, '_blank', 'noopener,noreferrer');
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url }
        });
    }

    toBool(value, defaultValue = false) {
        if (value === undefined || value === null || value === '') {
            return defaultValue;
        }
        if (typeof value === 'boolean') {
            return value;
        }
        return String(value).toLowerCase() === 'true';
    }

    normalizeUrl(value) {
        if (!value) {
            return '';
        }
        const trimmed = value.trim().replace(/\/+$/, '');
        if (!/^https?:\/\//i.test(trimmed)) {
            return `https://${trimmed}`;
        }
        return trimmed;
    }
}
