import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import openFromOpportunity from '@salesforce/apex/RLM_BambooRevenueSuite.openFromOpportunity';

export default class RlmBambooOppSuiteCta extends NavigationMixin(LightningElement) {
    @api recordId;

    busy = false;
    error;
    lastQuoteId;

    get disabled() {
        return this.busy || !this.recordId;
    }

    get buttonLabel() {
        return this.busy ? 'Opening…' : '+ Create Quote';
    }

    async handleCreate() {
        if (!this.recordId || this.busy) {
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            const session = await openFromOpportunity({ opportunityId: this.recordId });
            this.lastQuoteId = session.quoteId;
            this[NavigationMixin.Navigate]({
                type: 'standard__navItemPage',
                attributes: {
                    apiName: 'RLM_Bamboo_Revenue_Suite'
                },
                state: {
                    c__opportunityId: session.opportunityId,
                    c__quoteId: session.quoteId
                }
            });
        } catch (e) {
            this.error = this.reduceError(e);
        } finally {
            this.busy = false;
        }
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
}
