(() => {
  const loginPanel = document.getElementById("loginPanel");
  const consoleRoot = document.getElementById("consoleRoot");
  const loginStatus = document.getElementById("loginStatus");
  const amendStatus = document.getElementById("amendStatus");
  const companyInput = document.getElementById("companyInput");
  const accountIdInput = document.getElementById("accountIdInput");
  const qtyInput = document.getElementById("qtyInput");
  const qtyRange = document.getElementById("qtyRange");

  let state = null;
  const selectedAddons = new Set();
  /** Last Pricing API estimate — enables Generate quote when fresh. */
  let pricedEstimate = null;
  /** Full Quote preview from Generate quote (has dueToday + quote ids). */
  let pricedPreview = null;
  /**
   * Sticky Draft Quote ids from the open self-serve change.
   * Generate quote always prefers these so Edit change → regenerate
   * retargets the same Revenue Cloud Quote(s) instead of creating extras.
   */
  let stickyAmendDrafts = null;
  let estimateTimer = null;
  let estimateSeq = 0;
  let estimateInFlight = false;
  let estimateNeedsRerun = false;
  let pricingBusy = false;
  const changeSuccess = document.getElementById("changeSuccess");
  const accountGrid = document.getElementById("accountGrid");
  const orderSummaryCard = document.getElementById("orderSummaryCard");
  const generateAmendQuoteBtn = document.getElementById("generateAmendQuoteBtn");
  const amendRailCard = document.getElementById("amendRailCard");

  const STICKY_KEY = "bhAmendSticky";

  const readStickyAmend = () => {
    try {
      const raw = sessionStorage.getItem(STICKY_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch (_) {
      return null;
    }
  };

  const writeStickyAmend = (payload) => {
    stickyAmendDrafts = payload;
    try {
      if (!payload) sessionStorage.removeItem(STICKY_KEY);
      else sessionStorage.setItem(STICKY_KEY, JSON.stringify(payload));
    } catch (_) {
      /* ignore quota */
    }
  };

  const clearStickyAmend = () => writeStickyAmend(null);

  const stickyFromPreview = (preview, accountId) => {
    if (!preview || !accountId) return null;
    const amendQuotes = (preview.amendQuotes || [])
      .filter((q) => q && q.quoteId)
      .map((q) => ({
        quoteId: q.quoteId,
        assetIds: Array.isArray(q.assetIds) ? q.assetIds : [],
      }));
    const moduleQuoteId = preview.moduleQuoteId || null;
    if (!amendQuotes.length && !moduleQuoteId) return null;
    return {
      accountId,
      amendQuotes,
      moduleQuoteId,
      newQty: preview.newQty ?? null,
      addonSkus: Array.isArray(preview.addonSkus)
        ? preview.addonSkus
        : [],
      startDate: preview.amendStartDate || preview.startDate || null,
      updatedAt: new Date().toISOString(),
    };
  };

  const activeStickyForAccount = () => {
    const sid = state?.account?.id;
    if (!sid) return null;
    const s = stickyAmendDrafts || readStickyAmend();
    if (!s || s.accountId !== sid) return null;
    if (!(s.amendQuotes || []).length && !s.moduleQuoteId) return null;
    return s;
  };
  const showChangeSuccess = (data) => {
    // Place order activated the Draft — clear sticky so the next change starts fresh.
    clearStickyAmend();
    pricedPreview = null;
    const conf = data.confirmation || {};
    const titleEl = document.getElementById("changeSuccessTitle");
    const ledeEl = document.getElementById("changeSuccessLede");
    const metricsEl = document.getElementById("changeSuccessMetrics");
    const linksEl = document.getElementById("changeSuccessLinks");
    const rawEl = document.getElementById("changeSuccessRaw");
    if (!changeSuccess || !metricsEl || !linksEl) return;

    if (titleEl) {
      titleEl.textContent =
        conf.title || `Changes complete for ${data.accountName || "your company"}`;
    }
    if (ledeEl) {
      ledeEl.textContent =
        conf.lede ||
        "Your change is activated in Salesforce Revenue Cloud — Account, Opportunity, Quote, Order, and Assets are live.";
    }

    const metricRows =
      Array.isArray(conf.metrics) && conf.metrics.length
        ? conf.metrics.map((m) => [m.label, m.value])
        : [
            ["Order", data.amendOrderNumber || data.amendOrderId || "—"],
            ["Status", "Activated"],
            ["Assets", String((data.assetIds || []).length || 0)],
          ];
    metricsEl.innerHTML = metricRows
      .map(
        ([label, value]) =>
          `<div class="q-metric"><span class="q-label">${label}</span><span class="q-value">${value}</span></div>`
      )
      .join("");

    const payEls = {
      card: document.getElementById("changePayNowCard"),
      title: document.getElementById("changePayNowTitle"),
      lede: document.getElementById("changePayNowLede"),
      status: document.getElementById("changePayNowStatus"),
      payBtn: document.getElementById("changePayNowBtn"),
      retryBtn: document.getElementById("changePayNowRetryBtn"),
      emailBtn: document.getElementById("changePayNowEmailBtn"),
      invoiceBtn: document.getElementById("changeOpenInvoiceBtn"),
      hint: document.getElementById("changePayNowHint"),
    };
    const payment = data.payment || {};
    if (window.BambooPayNow) {
      BambooPayNow.bindRetry(payEls, {
        currency: state?.account?.currency || "USD",
        onUpdated: (next) => {
          payEls._payment = next;
          data.payment = next;
        },
      });
      BambooPayNow.bindEmail(payEls, {
        accountId: state?.account?.id,
      });
      payEls._payment = payment;
      BambooPayNow.render(payEls, payment, {
        currency: state?.account?.currency || "USD",
        defaultTitle: "Pay your invoice",
        defaultLede:
          "Salesforce Billing posted an invoice for this change. Pay securely with Salesforce Payments.",
      });
    }

    const transactions = Array.isArray(conf.transactions) ? conf.transactions : [];
    const linkBlocks = [];
    if (transactions.length > 1) {
      transactions.forEach((txn) => {
        const links = txn.links || {};
        const items = [
          ["Account", links.account, txn.accountId],
          ["Contact", links.contact, txn.contactId],
          ["Opportunity", links.opportunity, txn.opportunityId],
          ["Quote", links.quote, txn.quoteId],
          ["Order", links.order, txn.orderId],
        ];
        (links.assets || []).forEach((url, i) => {
          items.push([`Asset ${i + 1}`, url, (txn.assetIds || [])[i]]);
        });
        linkBlocks.push(
          `<p class="success-links-label">${txn.label || "Transaction"}</p>` +
            `<ul class="success-link-list">${items
              .filter((row) => row[1])
              .map(
                ([label, url, id]) =>
                  `<li><a href="${url}" target="_blank" rel="noopener">${label}</a><code>${id || ""}</code></li>`
              )
              .join("")}</ul>`
        );
      });
    } else {
      const links = conf.links || data.links || {};
      const primary = transactions[0] || {};
      const items = [
        ["Account", links.account, data.accountId || primary.accountId],
        ["Contact", links.contact, primary.contactId],
        ["Opportunity", links.opportunity, primary.opportunityId],
        ["Quote", links.quote, primary.quoteId],
        ["Order", links.order, primary.orderId || data.amendOrderId],
      ];
      const assetUrls = links.assets || [];
      const assetIds = primary.assetIds || data.assetIds || [];
      assetUrls.forEach((url, i) => {
        items.push([`Asset ${i + 1}`, url, assetIds[i]]);
      });
      linkBlocks.push(
        `<p class="success-links-label">Open in Salesforce</p>` +
          `<ul class="success-link-list">${items
            .filter((row) => row[1])
            .map(
              ([label, url, id]) =>
                `<li><a href="${url}" target="_blank" rel="noopener">${label}</a><code>${id || ""}</code></li>`
            )
            .join("")}</ul>`
      );
    }
    linksEl.innerHTML = linkBlocks.join("");

    const openAcctBtn = document.getElementById("changeOpenSfAccountBtn");
    const acctUrl =
      (conf.links && conf.links.account) ||
      (data.links && data.links.account) ||
      "";
    if (openAcctBtn && acctUrl) {
      openAcctBtn.href = acctUrl;
      openAcctBtn.hidden = false;
    }
    if (rawEl) rawEl.textContent = JSON.stringify(data, null, 2);
    if (accountGrid) accountGrid.hidden = true;
    if (orderSummaryCard) orderSummaryCard.hidden = true;
    changeSuccess.hidden = false;
    amendStatus.textContent = "";
    changeSuccess.scrollIntoView({ behavior: "smooth", block: "start" });
    // Keep Invoices list in sync after a billable change.
    if (state?.account?.id) {
      refreshInvoices().catch(() => {});
    }
  };

  const hideChangeSuccess = () => {
    if (changeSuccess) changeSuccess.hidden = true;
    const payCard = document.getElementById("changePayNowCard");
    if (payCard) payCard.hidden = true;
    if (accountGrid) accountGrid.hidden = false;
    if (orderSummaryCard) orderSummaryCard.hidden = false;
  };

  const money = (n, cur = "USD") => {
    const abs = Math.abs(Number(n));
    const formatted = abs.toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    const sign = Number(n) < 0 ? "−" : "";
    if (cur === "USD") return `${sign}$${formatted}`;
    return `${sign}${cur} ${formatted}`;
  };

  /** Signed money for change impact (+$12.00 / −$12.00). */
  const signedMoney = (n, cur = "USD") => {
    const v = Number(n) || 0;
    const base = money(v, cur);
    return v > 0 ? `+${base}` : base;
  };

  const esc = (value) =>
    String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");

  /** Lightning record link — prove the demo wrote real Salesforce data. */
  const sfRecordLink = (url, label, objectLabel) => {
    const text = esc(label);
    if (!url) return `<strong>${text}</strong>`;
    const title = objectLabel
      ? `Open ${objectLabel} in Salesforce`
      : "Open in Salesforce";
    return `<strong><a class="sf-record-link" href="${esc(url)}" target="_blank" rel="noopener" title="${esc(title)}">${text}</a></strong>`;
  };

  /**
   * Seats in effect on a calendar day — same basis Connect amend uses
   * (AssetStatePeriod on amendmentStartDate), not today's CurrentQuantity.
   */
  const quantityAtStartDate = (isoDay) => {
    const day = String(isoDay || "").slice(0, 10);
    const todayQty = Number(state?.subscription?.currentQuantity) || 0;
    const periods = state?.subscription?.timeline?.periods || [];
    if (!day || !periods.length) return todayQty;
    const covering = periods.find((p) => {
      const start = String(p.startDate || "").slice(0, 10);
      const end = String(p.endDate || "9999-12-31").slice(0, 10);
      return start && start <= day && day <= end;
    });
    if (covering && covering.quantity != null) {
      return Number(covering.quantity) || 0;
    }
    const sorted = [...periods].sort((a, b) =>
      String(a.startDate || "").localeCompare(String(b.startDate || ""))
    );
    const last = sorted[sorted.length - 1];
    if (
      last &&
      last.quantity != null &&
      day > String(last.endDate || "").slice(0, 10)
    ) {
      return Number(last.quantity) || 0;
    }
    return todayQty;
  };

  const amendChangeCtx = () => {
    if (!state?.account?.id) return null;
    const todayQty = Number(state.subscription.currentQuantity) || 0;
    const startIso =
      document.getElementById("startDateInput")?.value || defaultStartDate();
    // RC delta = target − qty in effect on start date (upcoming ASP), not today.
    const baselineQty = quantityAtStartDate(startIso);
    const parsed = readQty();
    const newQty = parsed == null ? baselineQty : parsed;
    const termEnd = termEndDate();
    const daysLeft = daysBetween(
      parseDate(startIso) || parseDate(defaultStartDate()),
      termEnd
    );
    const qtyChanged = newQty !== baselineQty;
    const addons = [...selectedAddons];
    const hasChange = qtyChanged || addons.length > 0;
    return {
      currentQty: baselineQty,
      baselineQty,
      todayQty,
      newQty,
      startIso,
      termEnd,
      daysLeft,
      qtyChanged,
      addons,
      hasChange,
      qtyValid: parsed != null,
    };
  };

  /** Inclusive calendar-month fraction (matches Revenue Cloud amend proration). */
  const calendarMonthsBetween = (start, end) => {
    const s = start instanceof Date ? start : parseDate(start);
    const e = end instanceof Date ? end : parseDate(end);
    if (!s || !e || e < s) return 0;
    let months = 0;
    let y = s.getUTCFullYear();
    let m = s.getUTCMonth(); // 0-11
    for (;;) {
      const monthStart = new Date(Date.UTC(y, m, 1));
      const monthEnd = new Date(Date.UTC(y, m + 1, 0));
      const segStart = s > monthStart ? s : monthStart;
      const segEnd = e < monthEnd ? e : monthEnd;
      if (segStart <= segEnd) {
        const daysInSeg =
          Math.round((segEnd - segStart) / 86400000) + 1;
        const daysInMonth = monthEnd.getUTCDate();
        months += daysInSeg / daysInMonth;
      }
      const next = new Date(Date.UTC(y, m + 1, 1));
      if (next > e) break;
      y = next.getUTCFullYear();
      m = next.getUTCMonth();
    }
    return months;
  };

  const estimateQtyAddonsMatch = (ctx = amendChangeCtx()) => {
    if (!ctx || !pricedEstimate?.ok) return false;
    const estimateAddonSkus = new Set(
      (pricedEstimate.lines || [])
        .filter((l) => l.isNew)
        .map((l) => String(l.sku || ""))
    );
    const addonsMatch =
      ctx.addons.length === estimateAddonSkus.size &&
      ctx.addons.every((s) => estimateAddonSkus.has(s));
    return (
      pricedEstimate.accountId === state.account.id &&
      Number(pricedEstimate.newQty) === Number(ctx.newQty) &&
      addonsMatch
    );
  };

  const estimateIsFresh = (ctx = amendChangeCtx()) => {
    if (!estimateQtyAddonsMatch(ctx)) return false;
    const estimateStart = String(
      pricedEstimate.amendStartDate || pricedEstimate.startDate || ""
    ).slice(0, 10);
    const startMatch =
      !estimateStart || estimateStart === String(ctx.startIso || "").slice(0, 10);
    return startMatch;
  };

  /** When only the start date changed, recompute proration locally (no Pricing API). */
  const applyEstimateForStartDate = (ctx = amendChangeCtx()) => {
    if (!estimateQtyAddonsMatch(ctx)) return false;
    const daysLeft = Number(ctx.daysLeft);
    if (!Number.isFinite(daysLeft)) return false;
    const start = parseDate(ctx.startIso);
    const end = ctx.termEnd instanceof Date ? ctx.termEnd : parseDate(ctx.termEnd);
    const months =
      start && end ? calendarMonthsBetween(start, end) : Math.max(0, daysLeft) / (365.25 / 12);
    const lines = (pricedEstimate.lines || []).map((l) => {
      const charge =
        l.chargeMonthly != null && Number.isFinite(Number(l.chargeMonthly))
          ? Number(l.chargeMonthly)
          : Number(l.netPepm || 0) * Number(l.qtyDelta || 0);
      const prorated = Number.isFinite(charge)
        ? Math.round(charge * months * 100) / 100
        : l.prorated;
      return { ...l, chargeMonthly: charge, prorated };
    });
    const due = Math.round(
      lines.reduce((s, l) => s + (Number(l.prorated) || 0), 0) * 100
    ) / 100;
    pricedEstimate = {
      ...pricedEstimate,
      amendStartDate: ctx.startIso,
      daysRemaining: daysLeft,
      dueToday: due,
      dueTodayProvisional: true,
      lines,
    };
    renderOrderMath({
      currency: pricedEstimate.currency || state.account.currency || "USD",
      lines,
      dueToday: due,
      daysLeft,
      termEnd: ctx.termEnd,
      provisional: true,
      awaitingPrice: false,
      sourceNote:
        "Est. prorated updated for start date · Generate quote for exact charge",
    });
    return true;
  };

  const syncAmendActions = () => {
    const ctx = amendChangeCtx();
    const hasChange = !!(ctx && ctx.hasChange && ctx.qtyValid);
    const fresh = estimateIsFresh(ctx);
    const sticky = activeStickyForAccount();
    const estimating = hasChange && !fresh;
    const generating = hasChange && fresh && pricingBusy;
    const waiting = estimating || generating;
    if (generateAmendQuoteBtn) {
      generateAmendQuoteBtn.disabled = !hasChange || waiting;
      generateAmendQuoteBtn.classList.toggle("busy", waiting);
      if (!hasChange) {
        generateAmendQuoteBtn.textContent = sticky ? "Update quote" : "Generate quote";
      } else if (generating) {
        generateAmendQuoteBtn.textContent = sticky
          ? "Updating quote…"
          : "Generating quote…";
      } else if (estimating) {
        generateAmendQuoteBtn.textContent = "Pricing…";
      } else {
        generateAmendQuoteBtn.textContent = sticky ? "Update quote" : "Generate quote";
      }
    }
    amendRailCard?.classList.toggle("is-pricing", estimating);
  };

  const parseDate = (iso) => {
    if (!iso) return null;
    const d = new Date(`${String(iso).slice(0, 10)}T12:00:00Z`);
    return Number.isNaN(d.getTime()) ? null : d;
  };

  const formatDateLabel = (d) =>
    d
      ? d.toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
          year: "numeric",
          timeZone: "UTC",
        })
      : "—";

  const setInvoiceStatus = (msg, isError = false) => {
    const el = document.getElementById("invoiceStatus");
    if (!el) return;
    el.textContent = msg || "";
    el.classList.toggle("error", !!isError && !!msg);
  };

  const renderInvoices = (invoices, currency = "USD") => {
    const card = document.getElementById("invoicesCard");
    const list = document.getElementById("invoiceList");
    const hint = document.getElementById("invoicePayHint");
    if (!card || !list) return;
    const rows = Array.isArray(invoices) ? invoices : [];
    if (!rows.length) {
      card.hidden = true;
      list.innerHTML = "";
      if (hint) hint.hidden = true;
      return;
    }
    card.hidden = false;
    if (hint) hint.hidden = false;
    list.innerHTML = rows
      .map((inv) => {
        const when = (inv.createdDate || "").slice(0, 10);
        const bal = money(inv.balance, currency);
        const ready = !!inv.paymentUrl;
        const label = inv.invoiceNumber || inv.id;
        return `<li class="invoice-row" data-invoice-id="${esc(inv.id)}">
          <div>
            ${sfRecordLink(inv.invoiceUrl, label, "Invoice")}
            <span>${esc(when)} · balance ${esc(bal)}</span>
          </div>
          <div class="invoice-row-actions">
            <span class="activity-badge">${esc(inv.status || "Posted")}</span>
            <button type="button" class="demo-btn demo-btn-primary invoice-pay-btn"
              data-invoice-id="${esc(inv.id)}"
              data-payment-url="${ready ? esc(inv.paymentUrl) : ""}">
              Pay
            </button>
          </div>
        </li>`;
      })
      .join("");
    list.querySelectorAll(".invoice-pay-btn").forEach((btn) => {
      btn.addEventListener("click", () => payInvoice(btn));
    });
  };

  const refreshInvoices = async () => {
    if (!state?.account?.id) return;
    setInvoiceStatus("Refreshing invoices…");
    try {
      const params = new URLSearchParams({ accountId: state.account.id });
      const resp = await fetch(`/api/account-invoices?${params}`);
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Refresh failed");
      state.invoices = data.invoices || [];
      state.paymentReceived = !!data.paymentReceived;
      state.pendingBalanceApply = !!data.pendingBalanceApply;
      state.paymentHint = data.hint || null;
      renderInvoices(state.invoices, state.account.currency || "USD");
      if (data.pendingBalanceApply) {
        setInvoiceStatus(
          data.hint ||
            "Payment received — invoice balance may take a moment to update."
        );
        scheduleInvoicePoll();
      } else {
        setInvoiceStatus(
          state.invoices.length
            ? `${state.invoices.length} open invoice(s).`
            : data.paymentReceived
              ? "Payment received — no open balances."
              : "No open balances."
        );
        clearInvoicePoll();
      }
    } catch (err) {
      setInvoiceStatus(err.message || String(err), true);
    }
  };

  let invoicePollTimer = null;
  let invoicePollCount = 0;
  const clearInvoicePoll = () => {
    if (invoicePollTimer) {
      clearInterval(invoicePollTimer);
      invoicePollTimer = null;
    }
    invoicePollCount = 0;
  };
  const scheduleInvoicePoll = () => {
    if (invoicePollTimer) return;
    invoicePollCount = 0;
    invoicePollTimer = setInterval(() => {
      invoicePollCount += 1;
      if (invoicePollCount > 12) {
        clearInvoicePoll();
        return;
      }
      refreshInvoices().catch(() => {});
    }, 8000);
  };

  const payInvoice = async (btn) => {
    const invoiceId = btn?.dataset?.invoiceId;
    if (!invoiceId) return;
    const existingUrl = (btn.dataset.paymentUrl || "").trim();
    if (existingUrl) {
      window.open(existingUrl, "_blank", "noopener");
      setInvoiceStatus(
        "Opened Pay Now — use a private window if you’re logged into Salesforce."
      );
      return;
    }
    btn.disabled = true;
    setInvoiceStatus("Creating Pay Now link…");
    try {
      const resp = await fetch("/api/collect-payment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ invoiceId }),
      });
      const data = await resp.json();
      if (!resp.ok || !(data.paymentUrl || data.ready)) {
        throw new Error(
          data.blockedReason || data.error || "Could not create payment link"
        );
      }
      if (state?.invoices) {
        const row = state.invoices.find((i) => i.id === invoiceId);
        if (row) {
          row.paymentUrl = data.paymentUrl;
          row.paymentLinkId = data.paymentLinkId;
        }
        renderInvoices(state.invoices, state.account?.currency || "USD");
      }
      window.open(data.paymentUrl, "_blank", "noopener");
      setInvoiceStatus(
        "Opened Pay Now — use a private window if you’re logged into Salesforce."
      );
    } catch (err) {
      setInvoiceStatus(err.message || String(err), true);
    } finally {
      btn.disabled = false;
    }
  };

  const daysBetween = (start, end) => {
    if (!start || !end) return 0;
    const ms = end.getTime() - start.getTime();
    return Math.max(0, Math.round(ms / 86400000));
  };

  const defaultStartDate = () => {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() + 1);
    return d.toISOString().slice(0, 10);
  };

  /** Earliest amend start: tomorrow UTC, or latest upcoming ASP start if later. */
  const earliestAmendStartDate = () => {
    const tomorrow = defaultStartDate();
    const fromState = state?.subscription?.earliestAmendStartDate;
    if (fromState) {
      const day = String(fromState).slice(0, 10);
      return day > tomorrow ? day : tomorrow;
    }
    const periods = state?.subscription?.timeline?.periods || [];
    let floor = tomorrow;
    for (const p of periods) {
      const start = String(p.startDate || "").slice(0, 10);
      if (start && start > floor) floor = start;
    }
    return floor;
  };

  const applyStartDateBounds = ({ preferred, bumpedNote } = {}) => {
    const startInput = document.getElementById("startDateInput");
    if (!startInput) return null;
    const minDay = earliestAmendStartDate();
    startInput.min = minDay;
    if (state?.subscription?.termEndDate) {
      startInput.max = String(state.subscription.termEndDate).slice(0, 10);
    } else {
      startInput.removeAttribute("max");
    }
    let day = String(preferred || startInput.value || minDay).slice(0, 10);
    if (!day || day < minDay) day = minDay;
    if (startInput.max && day > startInput.max) day = startInput.max;
    const changed = startInput.value !== day;
    startInput.value = day;
    if (bumpedNote && changed) {
      const termHint = document.getElementById("termHint");
      if (termHint) {
        termHint.textContent = bumpedNote;
      }
    }
    return day;
  };

  const termEndDate = () => {
    const end = parseDate(state?.subscription?.termEndDate);
    if (end) return end;
    const start = parseDate(state?.subscription?.termStartDate);
    if (start) {
      const e = new Date(start);
      e.setUTCFullYear(e.getUTCFullYear() + 1);
      return e;
    }
    // Demo fallback: one year from tomorrow.
    const e = new Date();
    e.setUTCDate(e.getUTCDate() + 1);
    e.setUTCFullYear(e.getUTCFullYear() + 1);
    return e;
  };

  const savePin = (accountId, company) => {
    const payload = JSON.stringify({ accountId, company: company || "" });
    try {
      sessionStorage.setItem("bhAccountPin", payload);
    } catch (_) {
      /* ignore */
    }
    try {
      localStorage.setItem("bhAccountPin", payload);
    } catch (_) {
      /* ignore */
    }
  };

  const readPin = () => {
    for (const store of [sessionStorage, localStorage]) {
      try {
        const raw = store.getItem("bhAccountPin");
        if (!raw) continue;
        const parsed = JSON.parse(raw);
        if (parsed && parsed.accountId) return parsed;
      } catch (_) {
        /* ignore */
      }
    }
    return {};
  };

  const listForSku = (sku) => {
    const catalog = state?.catalog;
    if (!catalog) return null;
    const plan = (catalog.plans || []).find((p) => p.sku === sku);
    if (plan) return { listPepm: Number(plan.listPepm), kind: "plan", name: plan.name };
    const addon = (catalog.addons || []).find((a) => a.sku === sku);
    if (addon) return { listPepm: Number(addon.listPepm), kind: "addon", name: addon.name };
    if (sku && sku.includes("FLAT") && catalog.coreFlat) {
      return {
        listPepm: null,
        flatMonthly: Number(catalog.coreFlat.listPrice),
        kind: "flat",
        name: catalog.coreFlat.name,
      };
    }
    return null;
  };

  const volumeRate = (hc) => {
    if (hc < 25) return 0;
    for (const b of state?.volumeBands || []) {
      if (hc >= b.lo && (b.hi == null || hc <= b.hi)) return b.rate;
    }
    return 0;
  };

  const activeBand = (hc) => {
    if (hc < 25) return { lo: 1, hi: 24, rate: 0 };
    return (
      (state?.volumeBands || []).find(
        (b) => hc >= b.lo && (b.hi == null || hc <= b.hi)
      ) || { lo: 1, hi: 24, rate: 0 }
    );
  };

  const lineMonthly = (asset, qty) => {
    const info = listForSku(asset.sku);
    if (!info) return null;
    if (info.kind === "flat") return info.flatMonthly;
    const pepm = info.listPepm * (1 - volumeRate(qty));
    return Math.round(pepm * qty * 100) / 100;
  };

  const netPepm = (listPepm, qty) =>
    Math.round(Number(listPepm) * (1 - volumeRate(qty)) * 100) / 100;

  const subscriptionTotals = (headcount, { includeSelectedAddons = false } = {}) => {
    const assets = state?.subscription?.assets || [];
    const primaryId = state?.subscription?.primaryAssetId;
    const lines = [];
    let total = 0;
    for (const a of assets) {
      const info = listForSku(a.sku) || {};
      const isFlat =
        info.kind === "flat" || String(a.sku || "").toUpperCase().includes("FLAT");
      const q = isFlat ? 1 : headcount;
      const monthly = lineMonthly(a, q);
      if (monthly == null) continue;
      lines.push({
        id: a.id,
        name: a.name || a.productName || info.name || a.sku,
        sku: a.sku,
        qty: q,
        listPepm: info.listPepm,
        netPepm: isFlat ? null : netPepm(info.listPepm, q),
        flatMonthly: isFlat ? info.flatMonthly : null,
        isFlat,
        monthly,
        isPrimary: a.id === primaryId,
        isNew: false,
        isPepm: !isFlat,
      });
      total += monthly;
    }
    if (includeSelectedAddons) {
      for (const sku of selectedAddons) {
        const info = listForSku(sku);
        if (!info || info.listPepm == null) continue;
        const pepm = netPepm(info.listPepm, headcount);
        const monthly = Math.round(pepm * headcount * 100) / 100;
        lines.push({
          id: sku,
          name: info.name || sku,
          sku,
          qty: headcount,
          listPepm: info.listPepm,
          netPepm: pepm,
          flatMonthly: null,
          isFlat: false,
          monthly,
          isPrimary: false,
          isNew: true,
          isPepm: true,
        });
        total += monthly;
      }
    }
    return { lines, total: Math.round(total * 100) / 100 };
  };

  /** Recurring today from Salesforce Asset.CurrentMrr (server-provided). */
  const sfRecurringToday = () => {
    const assets = state?.subscription?.assets || [];
    const primaryId = state?.subscription?.primaryAssetId;
    const lines = [];
    let total = 0;
    let complete = true;
    for (const a of assets) {
      if (a.mrr == null || a.mrr === "") {
        complete = false;
        continue;
      }
      const monthly = Math.round(Number(a.mrr) * 100) / 100;
      const qty = Number(a.quantity);
      const info = listForSku(a.sku) || {};
      const flat =
        info.kind === "flat" || String(a.sku || "").toUpperCase().includes("FLAT");
      lines.push({
        id: a.id,
        name: a.name || a.productName || info.name || a.sku,
        sku: a.sku,
        qty: flat ? 1 : Number.isFinite(qty) ? qty : state?.subscription?.currentQuantity,
        listPepm: info.listPepm,
        netPepm:
          !flat && Number.isFinite(qty) && qty > 0
            ? Math.round((monthly / qty) * 1000000) / 1000000
            : null,
        flatMonthly: flat ? monthly : null,
        isFlat: flat,
        monthly,
        isPrimary: a.id === primaryId,
        isNew: false,
        isPepm: !flat,
        source: "salesforceCurrentMrr",
      });
      total += monthly;
    }
    const serverTotal = state?.subscription?.recurringMonthly;
    if (serverTotal != null && Number.isFinite(Number(serverTotal))) {
      total = Math.round(Number(serverTotal) * 100) / 100;
    } else {
      total = Math.round(total * 100) / 100;
    }
    if (!lines.length && state?.subscription?.recurringComplete === false) {
      // No MRR on assets yet — fall back to catalog estimate at current seats.
      return {
        ...subscriptionTotals(Number(state?.subscription?.currentQuantity) || 1),
        source: "catalogEstimate",
      };
    }
    return {
      lines,
      total,
      complete,
      source: state?.subscription?.recurringSource || "salesforceCurrentMrr",
    };
  };

  const formatShortDate = (iso) => {
    const d = parseDate(iso);
    return d ? formatDateLabel(d) : iso || "—";
  };

  const renderSubscriptionTimeline = (timeline, currency) => {
    const wrap = document.getElementById("subscriptionTimeline");
    const list = document.getElementById("timelineList");
    if (!wrap || !list) return;
    const periods = timeline?.periods || [];
    // Hide when empty or only a single current period with nothing upcoming.
    const hasUpcoming = periods.some((p) => !p.isCurrent);
    if (!periods.length || (periods.length === 1 && periods[0].isCurrent && !hasUpcoming)) {
      wrap.hidden = true;
      list.innerHTML = "";
      return;
    }
    wrap.hidden = false;
    const cur = currency || "USD";
    list.innerHTML = periods
      .map((p, idx) => {
        const label = p.isCurrent
          ? "Current"
          : `Starts ${formatShortDate(p.startDate)}`;
        const range = `${formatShortDate(p.startDate)} – ${formatShortDate(p.endDate)}`;
        const seats =
          p.quantity != null ? `${Number(p.quantity).toLocaleString()} seats` : "—";
        const mrr = money(p.recurringMonthly, cur);
        let deltaHtml = "";
        if (p.deltaQuantity != null || p.deltaRecurringMonthly != null) {
          const parts = [];
          if (p.deltaQuantity != null && p.deltaQuantity !== 0) {
            const sign = p.deltaQuantity > 0 ? "+" : "−";
            parts.push(`${sign}${Math.abs(p.deltaQuantity)} seats`);
          }
          if (p.deltaRecurringMonthly != null && p.deltaRecurringMonthly !== 0) {
            const sign = p.deltaRecurringMonthly > 0 ? "+" : "−";
            parts.push(
              `${sign}${money(Math.abs(p.deltaRecurringMonthly), cur)} / mo`
            );
          }
          if (parts.length) {
            const down = (p.deltaRecurringMonthly || 0) < 0;
            deltaHtml = `<div class="timeline-delta${down ? " is-down" : ""}">${parts.join(" · ")} vs prior period</div>`;
          }
        }
        const lines = (p.lines || [])
          .map(
            (l) => `<li>
              <div>
                <strong>${l.name || l.sku}</strong>
                <span>${l.sku || ""} · ${l.quantity != null ? l.quantity : "—"} emp</span>
              </div>
              <em>${money(l.mrr, cur)} / mo</em>
            </li>`
          )
          .join("");
        const cls = p.isCurrent ? "is-current" : "is-future";
        const pill = p.isCurrent ? `<span class="timeline-pill">Now</span>` : "";
        return `<li class="timeline-item ${cls}" data-period-idx="${idx}">
          <button type="button" class="timeline-summary" aria-expanded="false" data-timeline-toggle>
            <div>
              <div class="timeline-label">${label}${pill}</div>
              <span class="timeline-range">${range}</span>
            </div>
            <div class="timeline-metrics">
              <strong>${mrr} / mo</strong>
              <span>${seats}</span>
            </div>
            ${deltaHtml}
          </button>
          <ul class="timeline-lines" hidden>${lines}</ul>
        </li>`;
      })
      .join("");

    list.querySelectorAll("[data-timeline-toggle]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const item = btn.closest(".timeline-item");
        const detail = item?.querySelector(".timeline-lines");
        if (!detail) return;
        const open = detail.hidden;
        detail.hidden = !open;
        btn.setAttribute("aria-expanded", open ? "true" : "false");
      });
    });
  };

  const readQty = () => {
    const raw = (qtyInput?.value || "").trim();
    if (raw === "") return null;
    const n = Number(raw);
    if (!Number.isFinite(n)) return null;
    return Math.max(1, Math.min(100000, Math.round(n)));
  };

  const qtyOrCurrent = () => {
    const startIso =
      document.getElementById("startDateInput")?.value || defaultStartDate();
    // Parens required: ?? and || cannot mix without grouping (breaks whole file parse).
    return readQty() ?? (quantityAtStartDate(startIso) || 1);
  };

  const renderOrderMath = ({
    currency: cur,
    lines,
    dueToday,
    daysLeft,
    termEnd,
    provisional = false,
    awaitingPrice = false,
    sourceNote,
  }) => {
    const railPepm = document.getElementById("railPepm");
    const railPepmUnit = document.getElementById("railPepmUnit");
    const railBill = document.getElementById("railBill");
    const railLines = document.getElementById("railLines");
    const railTotal = document.getElementById("railTotal");
    const railTotalLabel = document.getElementById("railTotalLabel");
    const srcNote = document.getElementById("pricingSourceNote");
    const hasDue = dueToday != null && Number.isFinite(Number(dueToday));
    const due = hasDue ? Number(dueToday) : null;

    if (railBill) {
      if (hasDue && due < 0) {
        railBill.textContent = provisional ? "Est. credit" : "Credit";
      } else if (hasDue && !provisional) {
        railBill.textContent = "Prorated charge";
      } else {
        railBill.textContent = "Est. prorated";
      }
    }
    if (railPepm) {
      railPepm.textContent = hasDue ? signedMoney(due, cur) : "—";
    }
    if (railTotalLabel) {
      if (hasDue && due < 0) {
        railTotalLabel.textContent = provisional ? "Est. credit total" : "Credit total";
      } else if (hasDue && !provisional) {
        railTotalLabel.textContent = "Prorated total";
      } else {
        railTotalLabel.textContent = "Est. prorated total";
      }
    }
    if (railTotal) {
      railTotal.textContent = hasDue ? signedMoney(due, cur) : "—";
    }
    if (railPepmUnit) {
      const dayBit =
        daysLeft != null && Number.isFinite(Number(daysLeft))
          ? ` · ${Number(daysLeft)} day${Number(daysLeft) === 1 ? "" : "s"} left`
          : "";
      const endBit = termEnd
        ? ` · term ends ${formatDateLabel(termEnd instanceof Date ? termEnd : parseDate(termEnd))}`
        : "";
      if (!hasDue && awaitingPrice) {
        railPepmUnit.textContent = "Pricing with Salesforce Pricing API…";
      } else if (provisional) {
        railPepmUnit.textContent = `Pricing API estimate${dayBit} · Generate quote for exact charge`;
      } else if (hasDue) {
        railPepmUnit.textContent = `Salesforce Quote total${dayBit}${endBit}`;
      } else {
        railPepmUnit.textContent = "until Generate quote for exact charge";
      }
    }
    if (railLines && Array.isArray(lines)) {
      railLines.innerHTML = lines
        .map((l) => {
          const qtyDelta = Number(l.qtyDelta);
          let qtyBit = "";
          if (l.isFlat) {
            qtyBit = l.isNew ? "adding" : "flat";
          } else if (Number.isFinite(qtyDelta) && qtyDelta !== 0) {
            const sign = qtyDelta > 0 ? "+" : "−";
            qtyBit = `${sign}${Math.abs(qtyDelta)} seats`;
          } else if (l.isNew) {
            qtyBit = `+${l.qtyAfter || l.qty || 0} seats`;
          } else {
            qtyBit = `${l.qtyAfter ?? l.qty ?? "—"} seats`;
          }
          const pepmBit =
            l.isPepm && l.netPepm != null
              ? `${money(l.netPepm, cur)} PEPM`
              : "";
          const calc = [qtyBit, pepmBit].filter(Boolean).join(" · ");
          const amt =
            l.prorated != null && Number.isFinite(Number(l.prorated))
              ? signedMoney(Number(l.prorated), cur)
              : l.monthly != null
                ? money(l.monthly, cur)
                : "—";
          const tag = l.isNew ? " · new" : "";
          return `<li>
            <span class="name">${l.name}${tag}</span>
            <span class="calc">${calc}</span>
            <span class="amt">${amt}</span>
          </li>`;
        })
        .join("");
    }
    if (srcNote) {
      if (sourceNote) {
        srcNote.textContent = sourceNote;
      } else if (provisional || awaitingPrice || pricingBusy) {
        srcNote.textContent = "Pricing with Salesforce Pricing API…";
      } else {
        srcNote.textContent =
          "Change seats or modules — Pricing API estimates the prorated charge.";
      }
    }
  };

  const fetchPricingEstimate = async (
    { newQty, currentQty, startIso, daysLeft, termEnd },
    { manual = false } = {}
  ) => {
    if (!state?.account?.id) return;
    const qtyChanged = newQty !== currentQty;
    const addons = [...selectedAddons];
    if (!qtyChanged && !addons.length) return;

    if (estimateInFlight) {
      // Invalidate the in-flight response so it cannot overwrite the date/qty
      // the user just changed (stale amendStartDate was snapping the picker back).
      estimateNeedsRerun = true;
      estimateSeq += 1;
      return;
    }
    estimateInFlight = true;
    estimateNeedsRerun = false;

    const seq = ++estimateSeq;
    pricingBusy = true;
    syncAmendActions();
    const src = document.getElementById("pricingSourceNote");
    if (src) src.textContent = "Pricing with Salesforce Pricing API…";
    const cur = state.account.currency || "USD";

    try {
      const body = {
        accountId: state.account.id,
        addonSkus: addons,
        startDate: startIso,
      };
      if (qtyChanged) body.newQty = newQty;
      const resp = await fetch("/api/account-amend-estimate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (seq !== estimateSeq) return;
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Estimate failed");
      }
      pricedEstimate = data;
      pricedPreview = null;
      const startEl = document.getElementById("startDateInput");
      if (data.earliestAmendStartDate && state?.subscription) {
        state.subscription.earliestAmendStartDate = String(
          data.earliestAmendStartDate
        ).slice(0, 10);
      }
      if (data.amendStartDate && startEl) {
        const effective = String(data.amendStartDate).slice(0, 10);
        const bumpWarn = (data.warnings || []).find((w) =>
          String(w).toLowerCase().includes("change start moved")
        );
        // Only force the picker when the server bumped start (ASP floor).
        // Otherwise keep the user's date — always rewriting preferred caused
        // later dates (e.g. 9/14) to snap back to an older in-flight estimate.
        if (data.amendStartBumped) {
          applyStartDateBounds({
            preferred: effective,
            bumpedNote:
              bumpWarn ||
              `Change start moved to ${formatDateLabel(parseDate(effective))} so the amend lands on your latest quantity period.`,
          });
        } else {
          applyStartDateBounds();
        }
      }
      const lines = (data.lines || []).map((l) => ({
        name: l.name,
        sku: l.sku,
        qtyDelta: l.qtyDelta,
        qtyBefore: l.qtyBefore,
        qtyAfter: l.qtyAfter,
        qty: l.qtyAfter ?? l.qty,
        netPepm: l.netPepm,
        monthlyDiff: l.monthlyDiff,
        chargeMonthly: l.chargeMonthly,
        prorated: l.prorated,
        monthly: l.monthly,
        isFlat: !!l.isFlat,
        isPepm: !!l.isPepm,
        isNew: !!l.isNew,
        source: l.source,
      }));
      const apiDays =
        data.daysRemaining != null ? Number(data.daysRemaining) : daysLeft;
      const srcLabel =
        data.pricingSource === "localFallback"
          ? "Local schedule estimate — Generate quote for exact Salesforce prorated charge"
          : "Est. prorated from Salesforce Pricing API · Generate quote for exact charge · MRR/ARR on summary";
      renderOrderMath({
        currency: data.currency || cur,
        lines,
        dueToday: data.dueToday,
        daysLeft: apiDays,
        termEnd: data.termEndDate ? parseDate(data.termEndDate) : termEnd,
        provisional: !!data.dueTodayProvisional,
        awaitingPrice: false,
        sourceNote: srcLabel,
      });
      if (amendStatus && !amendStatus.classList.contains("error")) {
        amendStatus.textContent =
          "Estimate ready — Generate quote for the precise Salesforce prorated charge.";
      }
    } catch (err) {
      if (seq !== estimateSeq) return;
      pricedEstimate = null;
      if (src) {
        src.textContent = `Pricing API unavailable — showing local estimate. ${
          err.message || ""
        }`;
      }
      if (manual) {
        amendStatus.textContent =
          err.message || "Could not price this change.";
        amendStatus.classList.add("error");
      }
    } finally {
      estimateInFlight = false;
      if (seq === estimateSeq) {
        pricingBusy = false;
        syncAmendActions();
      }
      if (estimateNeedsRerun) {
        estimateNeedsRerun = false;
        const ctx = amendChangeCtx();
        if (ctx?.hasChange && ctx.qtyValid) {
          fetchPricingEstimate(
            {
              newQty: ctx.newQty,
              currentQty: ctx.baselineQty,
              startIso: ctx.startIso,
              daysLeft: ctx.daysLeft,
              termEnd: ctx.termEnd,
            },
            { manual: false }
          );
        }
      }
    }
  };

  const schedulePricingEstimate = () => {
    if (estimateTimer) clearTimeout(estimateTimer);
    // Match Get Pricing: disable Generate immediately while Pricing API runs.
    pricingBusy = true;
    syncAmendActions();
    const src = document.getElementById("pricingSourceNote");
    if (src) src.textContent = "Pricing with Salesforce Pricing API…";
    if (amendStatus && !amendStatus.classList.contains("error")) {
      amendStatus.textContent = "Pricing in progress — Generate quote unlocks when ready.";
    }
    estimateTimer = setTimeout(() => {
      const ctx = amendChangeCtx();
      if (!ctx?.hasChange || !ctx.qtyValid) {
        pricingBusy = false;
        syncAmendActions();
        return;
      }
      fetchPricingEstimate(
        {
          newQty: ctx.newQty,
          currentQty: ctx.baselineQty,
          startIso: ctx.startIso,
          daysLeft: ctx.daysLeft,
          termEnd: ctx.termEnd,
        },
        { manual: false }
      );
    }, 350);
  };

  const syncPreview = () => {
    if (!state) return;
    const cur = state.account.currency || "USD";
    const startInput = document.getElementById("startDateInput");
    const startIso = startInput?.value || defaultStartDate();
    const todayQty = Number(state.subscription.currentQuantity) || 0;
    const baselineQty = quantityAtStartDate(startIso);
    const parsed = readQty();
    const newQty = parsed == null ? baselineQty : parsed;
    const delta = newQty - baselineQty;
    const start = parseDate(startIso) || parseDate(defaultStartDate());
    const termEnd = termEndDate();
    const daysLeft = daysBetween(start, termEnd);

    const deltaLabel = document.getElementById("qtyDeltaLabel");
    if (deltaLabel) {
      if (parsed == null) deltaLabel.textContent = "Enter a count";
      else if (delta === 0) deltaLabel.textContent = "No change";
      else if (delta > 0) deltaLabel.textContent = `Adding ${delta} employees`;
      else deltaLabel.textContent = `Removing ${Math.abs(delta)} employees`;
    }

    const termHint = document.getElementById("termHint");
    if (termHint) {
      const minDay = earliestAmendStartDate();
      const minNote =
        minDay && startIso === minDay && minDay > defaultStartDate()
          ? ` · earliest amend start is ${formatDateLabel(parseDate(minDay))} (latest quantity period)`
          : "";
      const baselineNote =
        baselineQty !== todayQty
          ? ` · ${baselineQty} seats in effect on ${formatDateLabel(start)}`
          : "";
      termHint.textContent = termEnd
        ? `Current term ends ${formatDateLabel(termEnd)} · ${daysLeft} day${
            daysLeft === 1 ? "" : "s"
          } from your start date${baselineNote}${minNote}`
        : "Term end unavailable — proration uses a 365-day estimate." + minNote;
    }

    const before = sfRecurringToday();
    // "After" provisional estimate only — RC preview replaces this when ready.
    const after =
      delta === 0 && selectedAddons.size === 0
        ? before
        : (() => {
            const est = subscriptionTotals(newQty, { includeSelectedAddons: true });
            return est.lines.length ? est : before;
          })();
    const hasChange = delta !== 0 || selectedAddons.size > 0;

    document.getElementById("subRecurring").textContent = money(before.total, cur);

    const badge = document.getElementById("seatChangeBadge");
    const pepmCount = after.lines.filter((l) => l.isPepm).length;
    if (badge) {
      if (!hasChange) {
        badge.hidden = true;
      } else if (delta !== 0) {
        badge.hidden = false;
        const sign = delta > 0 ? "+" : "−";
        badge.textContent = `${sign}${Math.abs(delta)} seats across ${pepmCount} per-employee product${
          pepmCount === 1 ? "" : "s"
        } (${baselineQty} → ${newQty})`;
      } else {
        badge.hidden = false;
        badge.textContent = `Adding ${selectedAddons.size} module${
          selectedAddons.size === 1 ? "" : "s"
        } at ${newQty} seats`;
      }
    }

    // Local placeholder while Pricing API builds prorated line estimate.
    // Shape matches amend Quote: Δ seats × after PEPM × calendar months.
    const monthsLeft =
      start && termEnd ? calendarMonthsBetween(start, termEnd) : 0;
    const localChangeLines = [];
    if (hasChange && monthsLeft > 0) {
      const beforeBy = new Map((before.lines || []).map((l) => [l.sku, l]));
      const afterBy = new Map((after.lines || []).map((l) => [l.sku, l]));
      const skus = [
        ...new Set([
          ...(after.lines || []).map((l) => l.sku),
          ...(before.lines || []).map((l) => l.sku),
        ]),
      ].filter(Boolean);
      for (const sku of skus) {
        const b = beforeBy.get(sku);
        const a = afterBy.get(sku);
        const monthlyBefore = Number(b?.monthly) || 0;
        const monthlyAfter = Number(a?.monthly) || 0;
        const monthlyDiff = Math.round((monthlyAfter - monthlyBefore) * 100) / 100;
        const isNew = !!(a?.isNew) || (!b && !!a);
        const qtyDelta = isNew
          ? Number(a?.qty) || newQty
          : delta;
        if (!isNew && qtyDelta === 0 && Math.abs(monthlyDiff) < 0.005) continue;
        const netPepm = Number(a?.netPepm ?? b?.netPepm) || 0;
        const chargeMonthly = (a || b)?.isFlat
          ? isNew
            ? monthlyAfter
            : monthlyDiff
          : Math.round(netPepm * qtyDelta * 100) / 100;
        if (Math.abs(chargeMonthly) < 0.005 && !isNew) continue;
        localChangeLines.push({
          name: (a || b).name,
          sku,
          qtyDelta,
          qtyBefore: isNew ? 0 : baselineQty,
          qtyAfter: isNew ? qtyDelta : newQty,
          netPepm,
          monthlyDiff,
          chargeMonthly,
          prorated: Math.round(chargeMonthly * monthsLeft * 100) / 100,
          isFlat: !!(a || b).isFlat,
          isPepm: !!(a || b).isPepm,
          isNew,
        });
      }
    }
    const localDue = localChangeLines.length
      ? Math.round(
          localChangeLines.reduce((s, l) => s + (Number(l.prorated) || 0), 0) * 100
        ) / 100
      : null;

    renderOrderMath({
      currency: cur,
      lines: localChangeLines,
      dueToday: localDue,
      daysLeft,
      termEnd,
      provisional: localDue != null,
      awaitingPrice: hasChange,
    });

    if (orderSummaryCard) orderSummaryCard.hidden = false;

    if (estimateTimer) {
      clearTimeout(estimateTimer);
      estimateTimer = null;
    }
    pricedPreview = null;
    if (!hasChange) {
      pricedEstimate = null;
      pricingBusy = false;
      syncAmendActions();
      const src = document.getElementById("pricingSourceNote");
      if (src) {
        src.textContent =
          "Change seats or select a module — live pricing updates this change impact.";
      }
      if (amendStatus && !amendStatus.classList.contains("error")) {
        amendStatus.textContent = "";
      }
    } else {
      const ctx = amendChangeCtx();
      // Date-only tweaks: recompute proration from the last Pricing API nets.
      if (ctx && applyEstimateForStartDate(ctx)) {
        pricingBusy = false;
        syncAmendActions();
      } else {
        pricedEstimate = null;
        schedulePricingEstimate();
      }
    }

    const band = activeBand(newQty);
    const unlockTitle = document.getElementById("unlockTitle");
    const unlockBody = document.getElementById("unlockBody");
    if (unlockTitle && unlockBody) {
      if (band.rate > 0) {
        unlockTitle.textContent = `You unlocked ${Math.round(band.rate * 100)}% off`;
        unlockBody.textContent = `Volume band ${
          band.hi == null ? band.lo + "+" : band.lo + "–" + band.hi
        } employees applies to PEPM lines after this change.`;
      } else {
        unlockTitle.textContent = "List price band";
        unlockBody.textContent =
          "Grow to 25+ employees to unlock volume discounts on PEPM products.";
      }
    }

    const tbody = document.querySelector("#volumeTable tbody");
    if (tbody) {
      const bands = [{ lo: 1, hi: 24, rate: 0 }, ...(state.volumeBands || [])];
      tbody.innerHTML = bands
        .map((b) => {
          const on = newQty >= b.lo && (b.hi == null || newQty <= b.hi);
          const label = b.hi == null ? `${b.lo}+` : `${b.lo}–${b.hi}`;
          return `<tr class="${on ? "on" : ""}"><td>${label}</td><td>${Math.round(
            b.rate * 100
          )}%${on ? " · selected" : ""}</td></tr>`;
        })
        .join("");
    }
  };

  const setQty = (n, { syncInput = true } = {}) => {
    const hc = Math.max(1, Math.min(100000, Number(n) || 1));
    if (syncInput && qtyInput) qtyInput.value = String(hc);
    if (qtyRange) qtyRange.value = String(Math.min(600, hc));
    syncPreview();
  };

  const onQtyTyped = () => {
    const raw = (qtyInput?.value || "").trim();
    if (raw === "") {
      syncPreview();
      return;
    }
    // Allow partial typing (e.g. "5" while entering "50") without forcing steppers.
    if (!/^\d+$/.test(raw)) return;
    const n = Number(raw);
    if (!Number.isFinite(n)) return;
    if (qtyRange) qtyRange.value = String(Math.min(600, Math.max(1, n)));
    syncPreview();
  };

  const renderConsole = (data) => {
    state = data;
    loginPanel.hidden = true;
    consoleRoot.hidden = false;
    document.getElementById("accountSub").textContent =
      `${data.account.name} · ${data.account.currency}`;
    document.getElementById("identityNote").textContent = data.identityNote || "";
    const termEnd = data.subscription.termEndDate
      ? formatDateLabel(parseDate(data.subscription.termEndDate))
      : null;
    document.getElementById("subMeta").textContent =
      `${data.subscription.assets.length} product(s) · ${
        data.subscription.currentQuantity || "—"
      } employees on primary plan` + (termEnd ? ` · term ends ${termEnd}` : "");

    const startInput = document.getElementById("startDateInput");
    if (startInput) {
      applyStartDateBounds({ preferred: earliestAmendStartDate() });
    }

    const sf = document.getElementById("openSfAccount");
    if (sf && data.links?.account) {
      sf.href = data.links.account;
      sf.hidden = false;
    }

    const subLines = document.getElementById("subLines");
    const snap = sfRecurringToday();
    subLines.innerHTML = snap.lines
      .map(
        (l) => `<li>
          <div>
            <strong>${l.name}</strong>
            <span>${l.sku || ""} · ${l.qty} employees</span>
          </div>
          <em>${money(l.monthly, data.account.currency)}</em>
        </li>`
      )
      .join("") || "<li class='muted'>No assets on this Account yet.</li>";
    const subRecurring = document.getElementById("subRecurring");
    if (subRecurring) {
      subRecurring.textContent = snap.lines.length
        ? `${money(snap.total, data.account.currency)} / mo`
        : "—";
    }
    renderSubscriptionTimeline(
      data.subscription?.timeline,
      data.account?.currency || "USD"
    );

    const orders = document.getElementById("orderList");
    orders.innerHTML = (data.recentOrders || [])
      .map((o) => {
        const when = (o.createdDate || "").slice(0, 10);
        const label = `Order ${o.orderNumber || o.id}`;
        return `<li>
          <div>
            ${sfRecordLink(o.orderUrl, label, "Order")}
            <span>${esc(when)}</span>
          </div>
          <span class="activity-badge">${esc(o.status || "—")}</span>
        </li>`;
      })
      .join("") || "<li class='muted'>No orders yet.</li>";

    renderInvoices(data.invoices || [], data.account?.currency || "USD");
    state.paymentReceived = !!data.paymentReceived;
    state.pendingBalanceApply = !!data.pendingBalanceApply;
    state.paymentHint = data.paymentHint || null;
    if (state.pendingBalanceApply) {
      setInvoiceStatus(
        state.paymentHint ||
          "Payment received — invoice balance may take a moment to update."
      );
      scheduleInvoicePoll();
    }

    const ownedSkus = new Set(
      (data.subscription.assets || []).map((a) => a.sku).filter(Boolean)
    );
    // Drop selections that are already owned after a refresh.
    [...selectedAddons].forEach((sku) => {
      if (ownedSkus.has(sku)) selectedAddons.delete(sku);
    });
    const addons = data.catalog?.addons || [];
    const available = addons.filter((a) => a.available && !ownedSkus.has(a.sku));
    document.getElementById("moduleCount").textContent =
      `${available.length} available · ${ownedSkus.size} owned · ${selectedAddons.size} selected`;

    const mods = document.getElementById("moduleGrid");
    mods.innerHTML = addons
      .map((a) => {
        const owned = ownedSkus.has(a.sku);
        const selected = selectedAddons.has(a.sku);
        const disabled = owned || !a.available;
        return `<button type="button" class="module-card ${owned ? "owned" : ""} ${
          selected ? "selected" : ""
        } ${disabled ? "disabled" : ""}" data-sku="${a.sku}" ${
          disabled ? "disabled" : ""
        } aria-pressed="${selected ? "true" : "false"}">
          <span class="mod-check" aria-hidden="true"></span>
          <p class="mod-name">${a.name}</p>
          <p class="mod-price"><strong>${a.listPepm}</strong> <span>${
          a.currency
        } /emp/mo</span></p>
          <p class="mod-note">${
            owned
              ? "Already owned"
              : !a.available
                ? "Unavailable for this country"
                : selected
                  ? "Selected · will add on Place order"
                  : "Click to add"
          }</p>
        </button>`;
      })
      .join("");
    mods.querySelectorAll(".module-card:not([disabled])").forEach((card) => {
      card.addEventListener("click", () => {
        const sku = card.dataset.sku;
        if (selectedAddons.has(sku)) selectedAddons.delete(sku);
        else selectedAddons.add(sku);
        document.getElementById("moduleCount").textContent =
          `${available.length} available · ${ownedSkus.size} owned · ${selectedAddons.size} selected`;
        card.classList.toggle("selected", selectedAddons.has(sku));
        card.setAttribute("aria-pressed", selectedAddons.has(sku) ? "true" : "false");
        const note = card.querySelector(".mod-note");
        if (note) {
          note.textContent = selectedAddons.has(sku)
            ? "Selected · will add on Place order"
            : "Click to add";
        }
        syncPreview();
      });
    });

    const startQty = data.subscription.currentQuantity || 50;
    setQty(startQty);
    savePin(data.account.id, data.account.name);
    applyAccountFocus();
    restoreStickyAmendEditor(data);
  };

  const restoreStickyAmendEditor = (data) => {
    stickyAmendDrafts = readStickyAmend();
    const sticky = stickyAmendDrafts;
    const accountId = data?.account?.id;
    if (!sticky || !accountId || sticky.accountId !== accountId) {
      if (sticky && sticky.accountId !== accountId) clearStickyAmend();
      syncAmendActions();
      return;
    }
    const params = new URLSearchParams(location.search);
    const editing = params.get("edit") === "1";
    // Always keep sticky Quote ids for Update quote; restore seats/modules when
    // returning from amend summary Edit change.
    if (editing || sticky.newQty != null || (sticky.addonSkus || []).length) {
      if (sticky.startDate) {
        applyStartDateBounds({ preferred: String(sticky.startDate).slice(0, 10) });
      }
      if (sticky.newQty != null && Number(sticky.newQty) >= 1) {
        setQty(Number(sticky.newQty));
      }
      const ownedSkus = new Set(
        (data.subscription?.assets || [])
          .map((a) => a.sku)
          .filter(Boolean)
      );
      selectedAddons.clear();
      for (const sku of sticky.addonSkus || []) {
        if (sku && !ownedSkus.has(sku)) selectedAddons.add(sku);
      }
      // Re-paint module cards to match selection without a full console redraw.
      document.querySelectorAll("#moduleGrid .module-card").forEach((card) => {
        const sku = card.dataset.sku;
        if (card.disabled) return;
        const on = selectedAddons.has(sku);
        card.classList.toggle("selected", on);
        card.setAttribute("aria-pressed", on ? "true" : "false");
        const note = card.querySelector(".mod-note");
        if (note) {
          note.textContent = on
            ? "Selected · will add on Place order"
            : "Click to add";
        }
      });
      const available = (data.catalog?.addons || []).filter(
        (a) => a.available && !ownedSkus.has(a.sku)
      );
      const modCount = document.getElementById("moduleCount");
      if (modCount) {
        modCount.textContent = `${available.length} available · ${ownedSkus.size} owned · ${selectedAddons.size} selected`;
      }
      if (editing) {
        amendStatus.textContent =
          "Editing your open Draft Quote — change seats/modules, then Update quote.";
        amendStatus.classList.remove("error");
        // Drop ?edit=1 so refresh doesn't re-toast.
        params.delete("edit");
        const qs = params.toString();
        history.replaceState(
          {},
          "",
          `${location.pathname}${qs ? `?${qs}` : ""}`
        );
      }
      syncPreview();
    }
    syncAmendActions();
  };

  const applyAccountFocus = () => {
    const banner = document.getElementById("accountFocusBanner");
    const invoicesCard = document.getElementById("invoicesCard");
    const params = new URLSearchParams(location.search);
    const focus = (params.get("focus") || "").toLowerCase();
    const paid = params.get("paid") === "1" || params.get("paid") === "true";
    if (!focus && !paid) {
      if (banner) banner.hidden = true;
      return;
    }
    if (banner) {
      banner.hidden = false;
      banner.classList.remove("error");
      if (paid) {
        const aid = (
          (typeof state !== "undefined" && state.account && state.account.id) ||
          params.get("accountId") ||
          ""
        ).trim();
        const activateHref = aid
          ? "/activate?accountId=" + encodeURIComponent(aid)
          : "/activate";
        const lag =
          state && state.pendingBalanceApply
            ? " Invoice balance may take a moment to update."
            : "";
        banner.innerHTML =
          'Payment received — <a href="' +
          activateHref +
          '">finish activation</a>.' +
          lag;
        scheduleInvoicePoll();
      } else if (focus === "invoices") {
        banner.textContent = "Open invoices — pay remaining balances with Pay now.";
      } else {
        banner.textContent = "";
        banner.hidden = true;
      }
    }
    if ((focus === "invoices" || paid) && invoicesCard && !invoicesCard.hidden) {
      invoicesCard.classList.add("account-focus-target");
      invoicesCard.scrollIntoView({ behavior: "smooth", block: "start" });
      window.setTimeout(() => invoicesCard.classList.remove("account-focus-target"), 2500);
    }
    if (paid || focus === "invoices") {
      refreshInvoices().catch(() => {});
    }
  };

  const loadConsole = async ({ accountId, company, ecToken } = {}) => {
    loginStatus.textContent = "Loading subscription from Salesforce…";
    loginStatus.classList.remove("error");
    const params = new URLSearchParams();
    if (ecToken) params.set("ecToken", ecToken);
    else if (accountId) params.set("accountId", accountId);
    else if (company) params.set("company", company);
    else {
      loginStatus.textContent = "Enter a company name or Account Id.";
      loginStatus.classList.add("error");
      return;
    }
    try {
      const resp = await fetch(`/api/account-console?${params}`);
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Failed to load");
      savePin(data.account?.id, data.account?.name);
      renderConsole(data);
      loginStatus.textContent = ecToken
        ? "Opened via Experience Cloud sign-in."
        : "";
      // Drop one-time handoff token from the address bar after success.
      // Keep focus=invoices / paid=1 so refresh still lands on invoices.
      if (ecToken && window.history?.replaceState) {
        const clean = new URL(window.location.href);
        clean.searchParams.delete("ecToken");
        clean.searchParams.set("accountId", data.account.id);
        if (!clean.searchParams.get("focus")) {
          clean.searchParams.set("focus", "invoices");
        }
        window.history.replaceState({}, "", clean.pathname + clean.search);
      }
    } catch (err) {
      // ecToken handoff often fails when EC_HANDOFF_SECRET isn't set — fall back
      // to Account Id / company so the buyer still reaches Licenses.
      const fallbackId =
        accountId ||
        new URLSearchParams(location.search).get("accountId") ||
        readPin().accountId;
      const fallbackCompany =
        company ||
        new URLSearchParams(location.search).get("company") ||
        readPin().company;
      if (ecToken && (fallbackId || fallbackCompany)) {
        loginStatus.textContent =
          "Sign-in handoff unavailable — opening with saved Account pin…";
        loginStatus.classList.remove("error");
        return loadConsole(
          fallbackId
            ? { accountId: fallbackId }
            : { company: fallbackCompany }
        );
      }
      loginStatus.textContent = err.message || String(err);
      loginStatus.classList.add("error");
    }
  };

  const openFromPinFields = () => {
    const accountId = accountIdInput.value.trim();
    const company = companyInput.value.trim();
    loadConsole(accountId ? { accountId } : { company });
  };
  document.getElementById("loadAccountBtn")?.addEventListener("click", openFromPinFields);
  [companyInput, accountIdInput].forEach((el) => {
    el?.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        openFromPinFields();
      }
    });
  });

  document.getElementById("refreshInvoicesBtn")?.addEventListener("click", () => {
    refreshInvoices();
  });

  qtyInput?.addEventListener("input", onQtyTyped);
  qtyInput?.addEventListener("blur", () => {
    const q = readQty();
    if (q == null) {
      setQty(state?.subscription?.currentQuantity || 1);
      return;
    }
    setQty(q);
  });
  qtyRange?.addEventListener("input", () => setQty(qtyRange.value));
  document.getElementById("qtyMinus")?.addEventListener("click", () =>
    setQty(qtyOrCurrent() - 1)
  );
  document.getElementById("qtyPlus")?.addEventListener("click", () =>
    setQty(qtyOrCurrent() + 1)
  );
  document.querySelectorAll("[data-qty-delta]").forEach((btn) => {
    btn.addEventListener("click", () =>
      setQty(qtyOrCurrent() + Number(btn.dataset.qtyDelta))
    );
  });
  document.getElementById("startDateInput")?.addEventListener("change", () => {
    // Clamp to earliest valid start (latest ASP) before pricing.
    applyStartDateBounds();
    // Recalc delta against seats in effect on the new start (upcoming ASP).
    syncPreview();
    syncAmendActions();
  });

  generateAmendQuoteBtn?.addEventListener("click", async () => {
    const ctx = amendChangeCtx();
    if (!ctx?.hasChange || !ctx.qtyValid) {
      amendStatus.textContent =
        "Change employee count and/or select a module first.";
      amendStatus.classList.remove("error");
      return;
    }
    if (!estimateIsFresh(ctx) || !pricedEstimate?.ok) {
      amendStatus.textContent =
        "Wait for Pricing API estimate to finish, then generate quote.";
      amendStatus.classList.remove("error");
      return;
    }
    const sticky = activeStickyForAccount();
    amendStatus.textContent = sticky
      ? "Updating your Draft Quote in Revenue Cloud (same Quote, System reprice)…"
      : "Generating quote in Revenue Cloud (Opportunity + Quote, System reprice)…";
    amendStatus.classList.remove("error");
    pricingBusy = true;
    syncAmendActions();
    try {
      const body = {
        accountId: state.account.id,
        assetId: state.subscription.primaryAssetId || undefined,
        addonSkus: ctx.addons,
        startDate: ctx.startIso,
      };
      if (ctx.qtyChanged) body.newQty = ctx.newQty;
      // Prefer the open self-serve Draft Quote(s) — retarget instead of create.
      if (sticky?.amendQuotes?.length) body.amendQuotes = sticky.amendQuotes;
      if (sticky?.moduleQuoteId) body.moduleQuoteId = sticky.moduleQuoteId;
      const resp = await fetch("/api/account-amend-preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const preview = await resp.json();
      if (!resp.ok || !preview.ok) {
        throw new Error(preview.error || "Could not create amend quote");
      }
      pricedPreview = preview;
      writeStickyAmend(stickyFromPreview(preview, state.account.id));
      try {
        document.dispatchEvent(new CustomEvent("bh-agent-context-refresh"));
      } catch (_) {
        /* ignore */
      }
      // Paint exact Quote prorated before navigating to summary.
      const flashLines = [];
      for (const part of preview.dueParts || []) {
        for (const ql of part.lines || []) {
          flashLines.push({
            name: ql.name || ql.sku || part.kind,
            sku: ql.sku,
            qtyDelta: ql.quantity ?? ql.qtyDelta,
            qtyAfter: ql.quantity,
            netPepm: ql.netUnitPrice ?? ql.netPepm,
            prorated: ql.totalPrice ?? ql.netTotalPrice,
            isFlat: !!ql.isFlat,
            isPepm: !ql.isFlat,
            isNew: part.kind === "moduleSale",
          });
        }
      }
      renderOrderMath({
        currency: preview.currency || state.account.currency || "USD",
        lines: flashLines,
        dueToday: preview.dueToday,
        daysLeft: preview.daysRemaining ?? ctx.daysLeft,
        termEnd: ctx.termEnd,
        provisional: false,
        awaitingPrice: false,
        sourceNote: sticky
          ? "Updated sticky Draft Quote in Revenue Cloud — opening summary…"
          : "Quoted in Revenue Cloud (System reprice) — opening summary…",
      });
      const summary = {
        ...preview,
        assetId: state.subscription?.primaryAssetId || null,
        country: state.account?.billingCountry || state.account?.country || "US",
      };
      const cacheResp = await fetch("/api/account-amend-cache", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ summary }),
      });
      const data = await cacheResp.json();
      if (!cacheResp.ok || !data.ok) {
        throw new Error(data.error || "Could not cache summary");
      }
      window.location.href = data.amendQuoteUrl || `/amend-quote/${data.id}`;
    } catch (err) {
      amendStatus.textContent = err.message || String(err);
      amendStatus.classList.add("error");
    } finally {
      pricingBusy = false;
      syncAmendActions();
    }
  });

  document.getElementById("changeSuccessDismiss")?.addEventListener("click", () => {
    hideChangeSuccess();
  });

  const params = new URLSearchParams(location.search);
  const qEcToken = params.get("ecToken");
  const qAccount = params.get("accountId");
  const qCompany = params.get("company");
  const pin = readPin();
  // Prefer URL / saved pin over any placeholder — never force Northwind.
  if (pin.company && companyInput && !companyInput.value) {
    companyInput.value = pin.company;
  }
  if (pin.accountId && accountIdInput && !accountIdInput.value) {
    accountIdInput.value = pin.accountId;
  }
  if (qEcToken) {
    loadConsole({
      ecToken: qEcToken,
      accountId: qAccount || pin.accountId || undefined,
      company: qCompany || pin.company || undefined,
    });
  } else if (qAccount) {
    accountIdInput.value = qAccount;
    loadConsole({ accountId: qAccount });
  } else if (qCompany) {
    companyInput.value = qCompany;
    loadConsole({ company: qCompany });
  } else if (pin.accountId) {
    accountIdInput.value = pin.accountId;
    if (pin.company) companyInput.value = pin.company;
    loadConsole({ accountId: pin.accountId });
  }
})();
