import { api, LightningElement } from 'lwc';

/**
 * Clickable discount buttons for Quinn after price history was already shown
 * in chat. Keep this form buttons-only — Agentforce user_input replaces chat
 * text, so history must be a prior turn (Get_Asset_Price_History).
 */
export default class RlmDiscountChoiceEditor extends LightningElement {
    @api readOnly = false;

    _value = {};
    selectedOption = '';
    customPercent = null;
    contextQuoteId = '';
    contextProductName = '';

    options = [
        { label: '10%', value: '10' },
        { label: '20%', value: '20' },
        { label: '30%', value: '30' },
        { label: '40%', value: '40' },
        { label: 'Other', value: 'other' }
    ];

    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val || {};
        if (val) {
            this.selectedOption = val.selectedOption || '';
            this.customPercent =
                val.customPercent != null ? val.customPercent : null;
            this.contextQuoteId = val.contextQuoteId || '';
            this.contextProductName = val.contextProductName || '';
        }
    }

    get showCustom() {
        return this.selectedOption === 'other';
    }

    get titleText() {
        return this.contextProductName
            ? 'Apply discount — ' + this.contextProductName
            : 'Apply discount';
    }

    handleOptionChange(event) {
        event.stopPropagation();
        this.selectedOption = event.detail.value;
        if (this.selectedOption !== 'other') {
            this.customPercent = null;
        }
        this.emitChange();
    }

    handleCustomChange(event) {
        event.stopPropagation();
        const raw = event.target.value;
        this.customPercent = raw === '' || raw == null ? null : Number(raw);
        this.emitChange();
    }

    emitChange() {
        this.dispatchEvent(
            new CustomEvent('valuechange', {
                detail: {
                    value: {
                        selectedOption: this.selectedOption,
                        customPercent: this.customPercent,
                        contextQuoteId: this.contextQuoteId,
                        contextProductName: this.contextProductName
                    }
                }
            })
        );
    }
}
