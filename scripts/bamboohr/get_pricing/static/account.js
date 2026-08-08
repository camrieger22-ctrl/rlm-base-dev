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
  /** Last successful RC preview — Place order reuses these Quote ids. */
  let pricedPreview = null;
  let previewTimer = null;
  let previewSeq = 0;
  const changeSuccess = document.getElementById("changeSuccess");
  const accountGrid = document.getElementById("accountGrid");
  const orderSummaryCard = document.getElementById("orderSummaryCard");

  const showChangeSuccess = (data) => {
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
        return `<li class="invoice-row" data-invoice-id="${inv.id}">
          <div>
            <strong>${inv.invoiceNumber || inv.id}</strong>
            <span>${when} · balance ${bal}</span>
          </div>
          <div class="invoice-row-actions">
            <span class="activity-badge">${inv.status || "Posted"}</span>
            <button type="button" class="demo-btn demo-btn-primary invoice-pay-btn"
              data-invoice-id="${inv.id}"
              data-payment-url="${ready ? inv.paymentUrl : ""}">
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
      renderInvoices(state.invoices, state.account.currency || "USD");
      setInvoiceStatus(
        state.invoices.length
          ? `${state.invoices.length} open invoice(s).`
          : "No open balances."
      );
    } catch (err) {
      setInvoiceStatus(err.message || String(err), true);
    }
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

  const qtyOrCurrent = () =>
    readQty() ?? (Number(state?.subscription?.currentQuantity) || 1);

  const renderOrderMath = ({
    currency: cur,
    monthlyToday,
    monthlyAfter,
    lines,
    dueToday,
    daysLeft,
    termEnd,
    provisional,
    quoteNumbers,
  }) => {
    const monthlyDiff = Math.round((monthlyAfter - monthlyToday) * 100) / 100;
    const annualBefore = Math.round(monthlyToday * 12 * 100) / 100;
    const annualAfter = Math.round(monthlyAfter * 12 * 100) / 100;
    const annualDiff = Math.round((annualAfter - annualBefore) * 100) / 100;

    const paintDiff = (el, amount, unit) => {
      if (!el) return;
      const prefix = amount > 0 ? "+" : amount < 0 ? "" : "";
      el.textContent = `${prefix}${money(amount, cur)} / ${unit}`;
      el.classList.toggle("is-up", amount > 0);
      el.classList.toggle("is-down", amount < 0);
    };

    const prevCurrentMo = document.getElementById("prevCurrentMo");
    const prevAfterMo = document.getElementById("prevAfterMo");
    if (prevCurrentMo) prevCurrentMo.textContent = money(monthlyToday, cur);
    if (prevAfterMo) prevAfterMo.textContent = money(monthlyAfter, cur);
    paintDiff(document.getElementById("prevDiffMo"), monthlyDiff, "mo");
    document.getElementById("prevCurrent").textContent = money(annualBefore, cur);
    document.getElementById("prevAfter").textContent = money(annualAfter, cur);
    paintDiff(document.getElementById("prevDiff"), annualDiff, "yr");

    const checkout = document.getElementById("checkoutLines");
    if (checkout && Array.isArray(lines)) {
      checkout.innerHTML = lines
        .map((l) => {
          const detail = l.isFlat
            ? `${money(l.flatMonthly || l.monthly, cur)} / mo flat`
            : `${money(l.netPepm, cur)} /emp/mo × ${l.qty} seats`;
          const tag = l.isNew ? " · adding" : "";
          const src =
            l.source === "amendQuote" || l.source === "moduleQuote"
              ? " · RC"
              : provisional
                ? ""
                : "";
          return `<li>
            <div>
              <strong>${l.name}</strong>
              <span>${detail}${tag}${src}</span>
            </div>
            <em>${money(l.monthly, cur)}</em>
          </li>`;
        })
        .join("");
    }

    const prorationLabel = document.getElementById("prorationLabel");
    const prorationFormula = document.getElementById("prorationFormula");
    const dueLabel = document.getElementById("dueTodayLabel");
    const dueEl = document.getElementById("dueToday");
    const srcNote = document.getElementById("pricingSourceNote");

    if (dueToday != null && Number.isFinite(dueToday)) {
      if (prorationLabel) {
        prorationLabel.textContent =
          daysLeft > 0
            ? `Charged on your Revenue Cloud quote · ${daysLeft} day${
                daysLeft === 1 ? "" : "s"
              } left in term from start date`
            : "Charged on your Revenue Cloud quote";
      }
      if (prorationFormula) {
        const qn = (quoteNumbers || []).filter(Boolean).join(", ");
        prorationFormula.textContent = qn
          ? `Quote total ${money(dueToday, cur)} (${qn})`
          : `Quote total ${money(dueToday, cur)}`;
      }
      if (dueLabel) {
        dueLabel.innerHTML =
          dueToday < 0
            ? `Credit today <em>(Revenue Cloud)</em>`
            : `Charged today <em>(Revenue Cloud)</em>`;
      }
      if (dueEl) dueEl.textContent = money(dueToday, cur);
      if (srcNote) {
        srcNote.textContent = provisional
          ? "Refreshing Revenue Cloud pricing…"
          : "Priced in Revenue Cloud (System reprice + live volume tiers).";
      }
    } else {
      const estimate =
        daysLeft > 0
          ? Math.round(((annualDiff * daysLeft) / 365) * 100) / 100
          : 0;
      if (prorationLabel) {
        prorationLabel.textContent = provisional
          ? "Pricing in Revenue Cloud…"
          : daysLeft > 0
            ? `Prorated for the ${daysLeft} days left in your term`
            : "No remaining term days from this start date";
      }
      if (prorationFormula) {
        prorationFormula.textContent = provisional
          ? "Creating amendment quote…"
          : daysLeft > 0
            ? `${money(annualDiff, cur)} × ${daysLeft} ÷ 365 = ${money(estimate, cur)}`
            : "";
      }
      if (dueLabel) {
        dueLabel.innerHTML = provisional
          ? `Charged today <em>(pricing…)</em>`
          : `Charged today <em>(estimate)</em>`;
      }
      if (dueEl) dueEl.textContent = provisional ? "…" : money(estimate, cur);
      if (srcNote) {
        srcNote.textContent = provisional
          ? "Asking Revenue Cloud for quote totals…"
          : "Local estimate — change seats to price in Revenue Cloud.";
      }
    }

    const billingFoot = document.getElementById("billingFoot");
    if (billingFoot) {
      billingFoot.textContent = `Then ${money(monthlyAfter, cur)} / mo (${money(
        annualAfter,
        cur
      )} / yr) from ${formatDateLabel(termEnd)} · invoice to your billing contact`;
    }
  };

  const scheduleRcPreview = (ctx) => {
    if (previewTimer) clearTimeout(previewTimer);
    previewTimer = setTimeout(() => fetchRcPreview(ctx), 450);
  };

  const fetchRcPreview = async ({ newQty, currentQty, startIso, daysLeft, termEnd }) => {
    if (!state?.account?.id) return;
    const qtyChanged = newQty !== currentQty;
    const addons = [...selectedAddons];
    if (!qtyChanged && !addons.length) return;

    const seq = ++previewSeq;
    const src = document.getElementById("pricingSourceNote");
    if (src) src.textContent = "Pricing in Revenue Cloud…";
    const cur = state.account.currency || "USD";

    try {
      const body = {
        accountId: state.account.id,
        assetId: state.subscription.primaryAssetId || undefined,
        addonSkus: addons,
        startDate: startIso,
      };
      if (qtyChanged) body.newQty = newQty;
      const resp = await fetch("/api/account-amend-preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (seq !== previewSeq) return; // stale
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Preview failed");
      }
      pricedPreview = data;
      // Server may bump start onto the latest ASP so decreases validate.
      const startEl = document.getElementById("startDateInput");
      if (data.amendStartDate && startEl) {
        const bumped = String(data.amendStartDate).slice(0, 10);
        if (bumped && startEl.value !== bumped) {
          startEl.value = bumped;
        }
      }
      const lines = (data.lines || []).map((l) => ({
        name: l.name,
        sku: l.sku,
        qty: l.qty,
        netPepm: l.netPepm,
        flatMonthly: l.isFlat ? l.monthly : null,
        monthly: l.monthly,
        isFlat: !!l.isFlat,
        isPepm: !!l.isPepm,
        isNew: !!l.isNew,
        source: l.source,
      }));
      const quoteNumbers = [
        ...(data.amendQuotes || []).map((q) => q.quoteNumber || q.quoteId),
        data.moduleQuote?.quoteNumber || data.moduleQuoteId,
      ];
      renderOrderMath({
        currency: data.currency || cur,
        monthlyToday: data.monthly?.today ?? 0,
        monthlyAfter: data.monthly?.after ?? 0,
        lines,
        dueToday: data.dueToday,
        daysLeft,
        termEnd,
        provisional: false,
        quoteNumbers,
      });
      if (src && data.pricingSource === "revenueCloud") {
        const warn = (data.warnings || []).filter(Boolean).slice(0, 2).join(" ");
        src.textContent = warn
          ? `Today from Salesforce CurrentMrr · after priced in Revenue Cloud. ${warn}`
          : "Today from Salesforce CurrentMrr · after priced in Revenue Cloud.";
      }
      if (amendStatus && !amendStatus.classList.contains("error")) {
        amendStatus.textContent = "";
      }
    } catch (err) {
      if (seq !== previewSeq) return;
      pricedPreview = null;
      if (src) {
        src.textContent = `RC preview unavailable — showing estimate. ${
          err.message || ""
        }`;
      }
    }
  };

  const syncPreview = () => {
    if (!state) return;
    const cur = state.account.currency || "USD";
    const currentQty = Number(state.subscription.currentQuantity) || 0;
    const parsed = readQty();
    const newQty = parsed == null ? currentQty : parsed;
    const delta = newQty - currentQty;
    const startInput = document.getElementById("startDateInput");
    const startIso = startInput?.value || defaultStartDate();
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
      termHint.textContent = termEnd
        ? `Current term ends ${formatDateLabel(termEnd)} · ${daysLeft} day${
            daysLeft === 1 ? "" : "s"
          } from your start date`
        : "Term end unavailable — proration uses a 365-day estimate.";
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
        } (${currentQty} → ${newQty})`;
      } else {
        badge.hidden = false;
        badge.textContent = `Adding ${selectedAddons.size} module${
          selectedAddons.size === 1 ? "" : "s"
        } at ${newQty} seats`;
      }
    }

    // Local estimate while Revenue Cloud preview loads (or when no change).
    renderOrderMath({
      currency: cur,
      monthlyToday: before.total,
      monthlyAfter: after.total,
      lines: after.lines,
      dueToday: null,
      daysLeft,
      termEnd,
      provisional: hasChange,
    });

    if (orderSummaryCard) orderSummaryCard.hidden = false;

    if (hasChange) {
      scheduleRcPreview({
        newQty,
        currentQty,
        startIso,
        daysLeft,
        termEnd,
      });
    } else {
      pricedPreview = null;
      const src = document.getElementById("pricingSourceNote");
      if (src) {
        src.textContent =
          "Recurring today from Salesforce (Asset CurrentMrr). Change seats or select a module to price in Revenue Cloud.";
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
      const tomorrow = defaultStartDate();
      startInput.value = tomorrow;
      startInput.min = tomorrow;
      if (data.subscription.termEndDate) {
        startInput.max = String(data.subscription.termEndDate).slice(0, 10);
      } else {
        startInput.removeAttribute("max");
      }
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
        return `<li>
          <div>
            <strong>Order ${o.orderNumber || o.id}</strong>
            <span>${when}</span>
          </div>
          <span class="activity-badge">${o.status || "—"}</span>
        </li>`;
      })
      .join("") || "<li class='muted'>No orders yet.</li>";

    renderInvoices(data.invoices || [], data.account?.currency || "USD");

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
        banner.textContent =
          "Welcome back — if you just paid, refresh invoices. Balance may take a moment to update.";
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
      loginStatus.textContent = err.message || String(err);
      loginStatus.classList.add("error");
    }
  };

  document.getElementById("loadAccountBtn")?.addEventListener("click", () => {
    const accountId = accountIdInput.value.trim();
    const company = companyInput.value.trim();
    loadConsole(accountId ? { accountId } : { company });
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
    syncPreview();
  });

  document.getElementById("placeAmendBtn")?.addEventListener("click", async () => {
    if (!state?.account?.id) {
      amendStatus.textContent =
        "No account loaded — complete a Get Pricing purchase first.";
      amendStatus.classList.add("error");
      return;
    }
    const newQty = readQty();
    if (newQty == null) {
      amendStatus.textContent = "Enter a valid employee count.";
      amendStatus.classList.add("error");
      return;
    }
    const current = Number(state.subscription.currentQuantity) || 0;
    const qtyChanged = newQty !== current;
    const addons = [...selectedAddons];
    if (!qtyChanged && !addons.length) {
      amendStatus.textContent =
        "Change employee count and/or select a module before placing the order.";
      amendStatus.classList.remove("error");
      return;
    }
    if (qtyChanged && !state.subscription.primaryAssetId) {
      amendStatus.textContent = "No primary plan asset to amend quantity.";
      amendStatus.classList.add("error");
      return;
    }
    const startDate =
      document.getElementById("startDateInput")?.value || defaultStartDate();
    const parts = [];
    if (qtyChanged) parts.push(`qty ${current}→${newQty}`);
    if (addons.length) parts.push(`add ${addons.join(", ")}`);
    parts.push(`start ${startDate}`);
    amendStatus.textContent = `Placing in Revenue Cloud (${parts.join("; ")})…`;
    amendStatus.classList.remove("error");
    const btn = document.getElementById("placeAmendBtn");
    btn.disabled = true;
    try {
      // Prefer the priced preview Quotes so Place order matches the summary.
      let preview = pricedPreview;
      const previewAddonSkus = new Set(
        (preview?.lines || []).filter((l) => l.isNew).map((l) => String(l.sku || ""))
      );
      const addonsMatch =
        addons.length === previewAddonSkus.size &&
        addons.every((s) => previewAddonSkus.has(s));
      const previewFresh =
        preview &&
        preview.ok &&
        preview.accountId === state.account.id &&
        Number(preview.newQty) === Number(newQty) &&
        addonsMatch;
      if (!previewFresh) {
        amendStatus.textContent = "Refreshing Revenue Cloud price before placing…";
        await fetchRcPreview({
          newQty,
          currentQty: current,
          startIso: startDate,
          daysLeft: daysBetween(
            parseDate(startDate) || parseDate(defaultStartDate()),
            termEndDate()
          ),
          termEnd: termEndDate(),
        });
        preview = pricedPreview;
        if (!preview?.ok) {
          throw new Error("Could not price this change in Revenue Cloud.");
        }
      }

      const body = {
        accountId: state.account.id,
        assetId: state.subscription.primaryAssetId || undefined,
        addonSkus: addons,
        startDate,
        amendQuotes: (preview.amendQuotes || []).map((q) => ({
          quoteId: q.quoteId,
          assetIds: q.assetIds || [],
        })),
        moduleQuoteId: preview.moduleQuoteId || undefined,
      };
      if (qtyChanged) body.newQty = newQty;
      const resp = await fetch("/api/account-amend", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Change failed");
      pricedPreview = null;
      selectedAddons.clear();
      showChangeSuccess(data);
      // Refresh subscription data in the background so "Back to licenses" is current.
      try {
        await loadConsole({ accountId: state.account.id });
      } catch (_) {
        /* ignore — confirmation already shown */
      }
    } catch (err) {
      amendStatus.textContent = err.message || String(err);
      amendStatus.classList.add("error");
    } finally {
      btn.disabled = false;
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
  if (qEcToken) {
    loadConsole({ ecToken: qEcToken });
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
