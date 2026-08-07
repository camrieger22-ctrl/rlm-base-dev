import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import isGuest from '@salesforce/user/isGuest';
import bffUrlLabel from '@salesforce/label/c.RLM_Bamboo_Get_Pricing_Bff_Url';
import getBuyerContext from '@salesforce/apex/RLM_BambooEcIdentity.getBuyerContext';
import createHandoffToken from '@salesforce/apex/RLM_BambooEcIdentity.createHandoffToken';

export default class RlmBambooGetPricingShell extends NavigationMixin(LightningElement) {
    /** Optional design-time override of the Custom Label URL. */
    @api bffUrlOverride;
    /** When true, navigate to the BFF as soon as the page loads. */
    @api autoRedirect = false;
    /** When true, open the BFF in a new browser tab (design default true). */
    @api openInNewTab = false;

    _didAutoRedirect = false;
    buyerContext;
    buyerError;
    handoffBusy = false;
    handoffError;

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

    get isGuestUser() {
        return Boolean(isGuest);
    }

    get showManageLicenses() {
        return !this.isGuestUser && Boolean(this.buyerContext?.canManageLicenses);
    }

    get showSignInForLicenses() {
        return this.isGuestUser;
    }

    get identityMessage() {
        if (this.isGuestUser) {
            return 'Already a customer? Sign in to open Licenses & billing.';
        }
        if (this.buyerError) {
            return this.buyerError;
        }
        return this.buyerContext?.message || '';
    }

    get showIdentityMessage() {
        return Boolean(this.identityMessage);
    }

    connectedCallback() {
        if (!this.isGuestUser) {
            this.loadBuyerContext();
        }
        if (this.shouldAutoRedirect && this.hasUrl && !this._didAutoRedirect) {
            this._didAutoRedirect = true;
            // Defer so the first paint can show the shell branding briefly.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            window.setTimeout(() => this.goToPricing(), 400);
        }
    }

    async loadBuyerContext() {
        try {
            this.buyerContext = await getBuyerContext();
            this.buyerError = undefined;
        } catch (err) {
            this.buyerContext = undefined;
            this.buyerError = this.reduceError(err);
        }
    }

    handleGetPricing() {
        this.goToPricing();
    }

    handleSignIn() {
        this[NavigationMixin.Navigate]({
            type: 'comm__loginPage',
            attributes: { actionName: 'login' }
        });
    }

    async handleManageLicenses() {
        if (!this.hasUrl || this.handoffBusy) {
            return;
        }
        this.handoffBusy = true;
        this.handoffError = undefined;
        try {
            const handoff = await createHandoffToken();
            const url = handoff?.bffAccountUrl;
            if (!url) {
                throw new Error('Handoff did not return a BFF URL');
            }
            if (this.shouldOpenInNewTab) {
                window.open(url, '_blank', 'noopener,noreferrer');
            } else {
                this[NavigationMixin.Navigate]({
                    type: 'standard__webPage',
                    attributes: { url }
                });
            }
        } catch (err) {
            this.handoffError = this.reduceError(err);
        } finally {
            this.handoffBusy = false;
        }
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

    reduceError(err) {
        if (!err) {
            return 'Unexpected error';
        }
        if (Array.isArray(err.body)) {
            return err.body.map((e) => e.message).join(', ');
        }
        if (err.body?.message) {
            return err.body.message;
        }
        if (err.message) {
            return err.message;
        }
        return String(err);
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
