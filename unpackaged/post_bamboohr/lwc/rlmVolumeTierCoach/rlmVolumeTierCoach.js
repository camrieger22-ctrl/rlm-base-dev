import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { RefreshEvent } from 'lightning/refresh';
import getCoachForQuote from '@salesforce/apex/RLM_BambooVolumeTiers.getCoachForQuote';

const STORAGE_PREFIX = 'rlmVolumeTierCoach.expanded.';

export default class RlmVolumeTierCoach extends LightningElement {
    selectedLineId;
    coach;
    error;
    wiredResult;
    isLoading = true;
    /** Collapsed by default to keep the Quote page compact. */
    isExpanded = false;
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.restoreExpandedState();
    }

    @wire(getCoachForQuote, { quoteId: '$recordId' })
    wiredCoach(result) {
        this.wiredResult = result;
        this.isLoading = false;
        const { data, error } = result;
        if (data) {
            this.coach = data;
            this.error = undefined;
            this.ensureSelection();
        } else if (error) {
            this.coach = undefined;
            this.error = this.reduceError(error);
        }
    }

    get hasLines() {
        return this.coach && this.coach.lines && this.coach.lines.length > 0;
    }

    get emptyMessage() {
        return (this.coach && this.coach.message) || 'No BambooHR volume lines on this quote.';
    }

    get coachClass() {
        return 'coach' + (this.isExpanded ? ' coach_expanded' : ' coach_collapsed');
    }

    get toggleLabel() {
        return this.isExpanded ? 'Collapse volume coach' : 'Expand volume coach';
    }

    get toggleIcon() {
        // Simple chevron via CSS class; label for a11y
        return this.isExpanded ? '▾' : '▸';
    }

    get expandCollapseText() {
        return this.isExpanded ? 'Hide' : 'Show';
    }

    get collapsedSummary() {
        if (this.isLoading) {
            return 'Loading…';
        }
        if (this.error) {
            return 'Unable to load tiers';
        }
        if (!this.hasLines) {
            return this.emptyMessage;
        }
        const line = this.selectedLine;
        if (!line) {
            return '';
        }
        const parts = [
            line.productName,
            this.heroDiscount + ' off',
            'band ' + this.heroBand,
            'qty ' + this.heroQuantity
        ];
        if (this.showNextCallout) {
            parts.push(this.nextHint);
        } else if (this.isTopTier) {
            parts.push('Top tier');
        }
        return parts.join(' · ');
    }

    get lineOptions() {
        if (!this.hasLines) {
            return [];
        }
        return this.coach.lines.map((line) => {
            const pct =
                line.discountPercent == null
                    ? '—'
                    : String(line.discountPercent) + '%';
            const selected = line.lineId === this.selectedLineId;
            return {
                lineId: line.lineId,
                label: line.productName,
                meta: (line.quantity || 0) + ' · ' + pct,
                buttonClass:
                    'line-chip' + (selected ? ' line-chip_selected' : '')
            };
        });
    }

    get selectedLine() {
        if (!this.hasLines) {
            return null;
        }
        return (
            this.coach.lines.find((l) => l.lineId === this.selectedLineId) ||
            this.coach.lines[0]
        );
    }

    get heroDiscount() {
        const line = this.selectedLine;
        if (!line || line.discountPercent == null) {
            return '0%';
        }
        return String(line.discountPercent) + '%';
    }

    get heroBand() {
        const line = this.selectedLine;
        return line && line.band ? line.band : '—';
    }

    get heroQuantity() {
        const line = this.selectedLine;
        return line && line.quantity != null ? String(line.quantity) : '—';
    }

    get nextHint() {
        const line = this.selectedLine;
        return line && line.nextTierHint ? line.nextTierHint : '';
    }

    get showNextCallout() {
        const hint = this.nextHint;
        return hint && hint !== 'Top volume tier';
    }

    get isTopTier() {
        return this.nextHint === 'Top volume tier';
    }

    get ladderRows() {
        if (!this.coach || !this.coach.ladder || !this.selectedLine) {
            return [];
        }
        const qty = Number(this.selectedLine.quantity || 0);
        const nextLower =
            this.selectedLine.unitsToNext != null
                ? qty + Number(this.selectedLine.unitsToNext)
                : null;
        return this.coach.ladder.map((tier) => {
            const upper = tier.upperBound;
            const inBand =
                qty >= tier.lowerBound &&
                (upper == null || qty <= upper);
            const below = qty < tier.lowerBound;
            const isImmediateNext =
                below && nextLower != null && tier.lowerBound === nextLower;
            let stateClass = 'ladder-row';
            if (inBand) {
                stateClass += ' ladder-row_current';
            } else if (below) {
                stateClass += ' ladder-row_ahead';
            } else {
                stateClass += ' ladder-row_passed';
            }
            const boundLabel =
                upper == null
                    ? tier.lowerBound + '+'
                    : tier.lowerBound + '–' + upper;
            let statusLabel = 'Unlocked';
            if (inBand) {
                statusLabel = 'Current';
            } else if (isImmediateNext) {
                statusLabel = 'Next up';
            } else if (below) {
                statusLabel = 'Locked';
            }
            return {
                key: String(tier.lowerBound),
                bandLabel: tier.bandLabel,
                boundLabel: boundLabel,
                discountLabel: String(tier.discountPercent) + '%',
                stateClass: stateClass,
                isCurrent: inBand,
                statusLabel: statusLabel
            };
        });
    }

    handleToggle() {
        this.isExpanded = !this.isExpanded;
        this.persistExpandedState();
    }

    handleSelectLine(event) {
        this.selectedLineId = event.currentTarget.dataset.lineId;
    }

    handleRefresh(event) {
        // Don't toggle when clicking Refresh inside the header actions.
        event.stopPropagation();
        if (this.wiredResult) {
            this.isLoading = true;
            refreshApex(this.wiredResult).finally(() => {
                this.isLoading = false;
            });
        }
        this.dispatchEvent(new RefreshEvent());
    }

    ensureSelection() {
        if (!this.hasLines) {
            this.selectedLineId = undefined;
            return;
        }
        const stillThere = this.coach.lines.some(
            (l) => l.lineId === this.selectedLineId
        );
        if (!stillThere) {
            this.selectedLineId = this.coach.lines[0].lineId;
        }
    }

    restoreExpandedState() {
        try {
            if (!this.recordId || typeof sessionStorage === 'undefined') {
                return;
            }
            const raw = sessionStorage.getItem(STORAGE_PREFIX + this.recordId);
            if (raw === '1') {
                this.isExpanded = true;
            } else if (raw === '0') {
                this.isExpanded = false;
            }
        } catch (e) {
            // sessionStorage may be unavailable; keep default collapsed
        }
    }

    persistExpandedState() {
        try {
            if (!this.recordId || typeof sessionStorage === 'undefined') {
                return;
            }
            sessionStorage.setItem(
                STORAGE_PREFIX + this.recordId,
                this.isExpanded ? '1' : '0'
            );
        } catch (e) {
            // ignore persistence failures
        }
    }

    reduceError(error) {
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body && typeof error.body.message === 'string') {
            return error.body.message;
        }
        return 'Unable to load volume tiers.';
    }
}
