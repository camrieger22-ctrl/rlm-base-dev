(() => {
  const PATH_B_SKUS = new Set(["BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"]);
  const PLAN_SKUS = new Set([
    "BAMBOO-CORE",
    "BAMBOO-PRO",
    "BAMBOO-ELITE",
    "BAMBOO-CORE-TRIAL",
    "BAMBOO-PRO-TRIAL",
    "BAMBOO-ELITE-TRIAL",
  ]);

  const money = (n, cur = "USD") => {
    if (n == null || !Number.isFinite(Number(n))) return "—";
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: cur,
        maximumFractionDigits: 2,
      }).format(Number(n));
    } catch (_) {
      return `$${Number(n).toFixed(2)}`;
    }
  };

  const esc = (s) =>
    String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  const pathId = () => {
    const m = location.pathname.match(/\/amend-quote\/([^/]+)/);
    return m ? decodeURIComponent(m[1]) : "";
  };

  const formatStart = (iso) => {
    if (!iso) return "";
    try {
      const d = new Date(`${String(iso).slice(0, 10)}T12:00:00Z`);
      return d.toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
        timeZone: "UTC",
      });
    } catch (_) {
      return String(iso).slice(0, 10);
    }
  };

  const formatWindow = (start, end) => {
    const a = formatStart(start);
    const b = formatStart(end);
    if (a && b) return `${a} – ${b}`;
    return a || b || "";
  };

  const formatPricedAt = (iso) => {
    if (!iso) return "";
    try {
      const d = new Date(iso);
      if (Number.isNaN(d.getTime())) return String(iso);
      return d.toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
        hour: "numeric",
        minute: "2-digit",
      });
    } catch (_) {
      return String(iso);
    }
  };

  /** Full cached preview (Place order needs quote ids / assetIds). */
  let summary = null;
  /** Phase A view model (preferred for display). */
  let view = null;

  const resolveView = (data) => {
    const v = data?.amendSummaryView;
    if (v && v.ok) return v;
    return null;
  };

  const changeBitsFromView = (v) => {
    const bits = [];
    const delta = Number(v.seats?.delta || 0);
    if (delta !== 0) {
      bits.push(
        `${delta > 0 ? "Adding" : "Removing"} ${Math.abs(delta)} employees`
      );
    }
    const newMods = (v.products || []).filter((p) => p.isNew);
    if (newMods.length) {
      bits.push(`Adding ${newMods.map((p) => p.name || p.sku).join(" + ")}`);
    }
    if (!bits.length) bits.push("License change");
    return bits;
  };

  const metricBubble = (label, value, { accent = false, hint = null } = {}) => {
    const hintHtml = hint ? `<span class="q-hint">${esc(hint)}</span>` : "";
    return `<div class="q-metric">
      <span class="q-label">${esc(label)}</span>
      <span class="q-value${accent ? " accent" : ""}">${esc(value)}</span>
      ${hintHtml}
    </div>`;
  };

  const logicArrow = () =>
    `<span class="logic-arrow" aria-hidden="true">→</span>`;

  const productLogicPanel = (p, cur, volPct) => {
    const after = p.after || {};
    const sku = String(p.sku || "").toUpperCase();
    const kind = PLAN_SKUS.has(sku) ? "Plan" : "Add-on";
    const listP = after.listPepm;
    const afterBundle = after.afterBundlePepm;
    const bundlePct = Number(after.bundleSavePercent || 0);
    const vol =
      after.volumePercent != null ? Number(after.volumePercent) : Number(volPct || 0);
    const net = after.netPepm ?? after.pepm;
    const badge =
      bundlePct > 0
        ? `<span class="line-badge">Bundle &amp; Save</span>`
        : "";
    const volLabel =
      vol > 0 ? `−${Number.isInteger(vol) ? vol : vol}%` : "0%";

    const bubbles = [metricBubble("List PEPM", money(listP, cur))];
    if (bundlePct > 0) {
      bubbles.push(logicArrow());
      bubbles.push(
        metricBubble("After Bundle", money(afterBundle, cur), {
          hint: `−${Math.round(bundlePct)}% Bundle & Save`,
        })
      );
    }
    bubbles.push(logicArrow());
    if (vol > 0) {
      bubbles.push(
        metricBubble("Volume", volLabel, {
          hint: "Applied after Bundle when present",
        })
      );
    } else {
      bubbles.push(metricBubble("Volume", "0%", { hint: "Under volume band" }));
    }
    bubbles.push(logicArrow());
    bubbles.push(metricBubble("Net PEPM", money(net, cur), { accent: true }));

    return `<article class="price-logic${bundlePct > 0 ? " is-bundle" : ""}">
      <header class="price-logic-head">
        <p class="price-logic-kicker">${kind}</p>
        <h3 class="price-logic-title">${esc(p.name || sku)}${badge}</h3>
      </header>
      <div class="logic-bubbles">${bubbles.join("")}</div>
    </article>`;
  };

  const renderPricingLogic = (v, cur) => {
    const host = document.getElementById("pricingLogic");
    const products = (v.products || []).filter((p) => p.isPepm && !p.isFlat);
    const volPct = Number(v.volumePercentAfter || 0);
    if (!products.length) {
      host.hidden = true;
      host.innerHTML = "";
      return;
    }
    const bySku = Object.fromEntries(
      products.map((p) => [String(p.sku || "").toUpperCase(), p])
    );
    const panels = [];
    const plan =
      products.find((p) => PLAN_SKUS.has(String(p.sku || "").toUpperCase())) ||
      products.find((p) => String(p.sku || "").toUpperCase().includes("ELITE")) ||
      products[0];
    if (plan) panels.push(productLogicPanel(plan, cur, volPct));
    for (const sku of PATH_B_SKUS) {
      if (bySku[sku] && bySku[sku] !== plan) {
        panels.push(productLogicPanel(bySku[sku], cur, volPct));
      }
    }
    for (const p of products) {
      const sku = String(p.sku || "").toUpperCase();
      if (p === plan || PATH_B_SKUS.has(sku)) continue;
      panels.push(productLogicPanel(p, cur, volPct));
    }
    host.hidden = false;
    host.innerHTML = `<p class="price-logic-lede">How each product gets to net PEPM</p>${panels.join(
      ""
    )}`;
  };

  const renderDiscountStack = (v) => {
    const host = document.getElementById("discountStack");
    const pathB = !!v.pathBBundleSave;
    const vol = Number(v.volumePercentAfter || 0);
    const hc = v.seats?.after ?? v.seats?.baselineOnStart ?? "—";
    const step2Cls = pathB ? "is-on" : "is-off";
    const step2Badge = pathB
      ? `<span class="step-badge on">Applied on Payroll + Benefits</span>`
      : `<span class="step-badge off">Not on this quote</span>`;
    const step3Badge =
      vol > 0
        ? `<span class="step-badge on">−${vol}% at ${esc(hc)} employees</span>`
        : `<span class="step-badge off">No volume band (under 25)</span>`;
    const bundleCallout = pathB
      ? `<p class="callout callout-save"><strong>Bundle &amp; Save: 15% off Payroll + Benefits.</strong> Because you have both add-ons with your plan, step ② cuts those list rates by 15% before volume discount is applied.</p>`
      : "";
    host.hidden = false;
    host.innerHTML = `
      <h3>How discounts apply</h3>
      <p class="discount-stack-lede">Every line moves from list to net in this order:</p>
      <ol class="discount-steps">
        <li class="is-on">
          <span class="step-num">1</span>
          <div><strong>List PEPM</strong> — catalog rate before discounts.</div>
        </li>
        <li class="${step2Cls}">
          <span class="step-num">2</span>
          <div><strong>Bundle &amp; Save 15%</strong> — Payroll + Benefits only, when both are on the quote. ${step2Badge}</div>
        </li>
        <li class="is-on">
          <span class="step-num">3</span>
          <div><strong>Volume discount</strong> — headcount band on the post-bundle amount. ${step3Badge}</div>
        </li>
        <li class="is-result">
          <span class="step-num">=</span>
          <div><strong>Net PEPM</strong> — what you pay per employee × qty.</div>
        </li>
      </ol>
      <p class="discount-stack-note">Plans, Time, and Global skip step ② (no Bundle &amp; Save) and go List → Volume → Net.</p>
      ${bundleCallout}`;
  };

  const renderChargeLines = (v, due, cur, labels) => {
    const chargeLines = v.dueForChange?.lines || [];
    const chargeBlock = document.getElementById("chargeLinesBlock");
    const chargeTable = document.getElementById("chargeLinesTable");
    const chargeFoot = document.getElementById("chargeLinesFoot");
    const chargeLede = document.getElementById("chargeLinesLede");
    if (chargeLede && labels.chargeLinesLede) {
      chargeLede.textContent = labels.chargeLinesLede;
    }
    if (!chargeLines.length) {
      chargeBlock.hidden = true;
      chargeTable.innerHTML = "";
      chargeFoot.textContent = "";
      return;
    }
    chargeBlock.hidden = false;
    const rows = chargeLines
      .map((li) => {
        const listP = li.listPepm;
        const bundlePct = Number(li.bundleSavePercent || 0);
        const afterBundle = li.afterBundlePepm;
        const volPct = Number(li.volumePercent || 0);
        const net = li.netPepm;
        const qty = li.quantity;
        const bundleCell =
          bundlePct > 0
            ? `<td class="num"><span class="step-inner"><span class="now">${esc(
                money(afterBundle, cur)
              )}</span><span class="chip">−${Math.round(
                bundlePct
              )}%</span></span></td>`
            : `<td class="num muted-cell">—</td>`;
        const volumeCell =
          volPct > 0
            ? `<td class="num"><span class="step-inner"><span class="now">${esc(
                money(net, cur)
              )}</span><span class="chip">−${Math.round(
                volPct
              )}%</span></span></td>`
            : `<td class="num">${esc(money(net, cur))}</td>`;
        const serviceWindow = formatWindow(li.startDate, li.endDate);
        return `<tr class="${bundlePct > 0 ? "has-bundle" : ""}">
          <td class="prod">
            ${esc(li.name || li.sku)}
            ${
              serviceWindow
                ? `<div class="muted amend-line-dates">${esc(serviceWindow)}</div>`
                : ""
            }
          </td>
          <td class="num">${esc(qty)}</td>
          <td class="num">${esc(money(listP, cur))}</td>
          ${bundleCell}
          ${volumeCell}
          <td class="num amt">${esc(money(li.lineTotal, cur))}</td>
        </tr>`;
      })
      .join("");
    chargeTable.innerHTML = `<div class="lines-wrap"><table class="lines lines-waterfall">
      <thead><tr>
        <th>Product</th><th>Qty</th><th>List</th><th>Bundle</th><th>Volume</th><th>Charge</th>
      </tr></thead>
      <tbody>${rows}</tbody>
      <tfoot><tr>
        <th colspan="5">Prorated charge total</th>
        <td class="num amt"><strong>${esc(
          money(v.dueForChange?.linesTotal ?? due, cur)
        )}</strong></td>
      </tr></tfoot>
    </table></div>`;
    chargeFoot.textContent =
      "Qty is the seats (or modules) on this amend Quote — not your full after-headcount. Dates are that line's service window. Line charges sum to the prorated total above.";
  };

  const hidePreSuccessSections = () => {
    const ids = [
      "quoteParts",
      "customerCard",
      "drivers",
      "pricingLogic",
      "discountStack",
      "chargeLinesBlock",
      "quoteMeta",
      "amendFootnote",
    ];
    ids.forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.hidden = true;
    });
    document.querySelector(".amend-card-head")?.setAttribute("hidden", "");
  };

  const renderFromView = (data, v) => {
    summary = data;
    view = v;
    const cur = v.currency || data.currency || "USD";
    const labels = v.labels || {};
    const startLabel = formatStart(v.amendStartDate || data.amendStartDate);
    const bits = changeBitsFromView(v);
    const due = v.dueForChange?.amount ?? v.hero?.amount;
    const hasDue = due != null && Number.isFinite(Number(due));
    const isCredit = !!(v.hero?.isCredit || Number(due) < 0);
    const seats = v.seats || {};
    const volPct = Number(v.volumePercentAfter || 0);

    document.getElementById("amendCard").hidden = false;
    document.getElementById("amendFootnote").hidden = false;
    document.getElementById("amendLede").textContent = [
      v.accountName || data.accountName || "Account",
      v.country || data.country || "",
      cur,
    ]
      .filter(Boolean)
      .join(" · ");

    // 1. Selected change + prorated charge
    document.getElementById("changeTitle").textContent = bits[0];
    document.getElementById("changeSub").textContent = [
      bits.slice(1).join(" · "),
      startLabel ? `Starts ${startLabel}` : "",
    ]
      .filter(Boolean)
      .join(" · ");

    const payKicker = document.getElementById("payKicker");
    const dueEl = document.getElementById("dueAmount");
    payKicker.textContent =
      v.hero?.label ||
      (isCredit
        ? labels.proratedCredit || "Quoted credit (remaining term)"
        : labels.proratedCharge || "Quoted now (remaining term)");
    if (hasDue) {
      dueEl.textContent = money(due, cur);
      dueEl.classList.toggle("is-credit", isCredit);
    } else {
      dueEl.textContent = "—";
      dueEl.classList.remove("is-credit");
    }
    document.getElementById("payPlain").textContent = hasDue
      ? v.cashDueHint
        ? `${v.cashDueHint} Remaining-term Quote total — Pay Now collects the first bill`
        : "Remaining-term Quote total — Pay Now collects the first bill"
      : "Quote charge pending";

    const partsEl = document.getElementById("quoteParts");
    const parts = v.dueForChange?.parts || v.quotes || [];
    const showParts = !!(v.dueForChange?.showParts || v.hero?.showPerQuoteParts);
    if (showParts && parts.length > 1) {
      partsEl.hidden = false;
      partsEl.innerHTML = `<p class="amend-parts-kicker">Includes</p><ul>${parts
        .map(
          (p) => `<li>
            <span>${esc(p.kindLabel || p.kind || "Quote")}${
            p.quoteNumber ? ` · ${esc(p.quoteNumber)}` : ""
          }</span>
            <strong>${esc(money(p.totalPrice, cur))}</strong>
          </li>`
        )
        .join("")}</ul>`;
    } else {
      partsEl.hidden = true;
      partsEl.innerHTML = "";
    }

    // Customer and pricing context
    document.getElementById("customerKicker").innerHTML =
      `Customer in Salesforce <span class="line-badge">Existing customer</span>`;
    document.getElementById("customerName").textContent =
      v.accountName || data.accountName || "—";
    const contact = data.contactName || data.contactEmail;
    const contactEl = document.getElementById("customerContact");
    if (contact) {
      contactEl.hidden = false;
      contactEl.textContent = [
        data.contactName || "Buyer",
        data.contactEmail || "",
      ]
        .filter(Boolean)
        .join(" · ");
    } else {
      contactEl.hidden = true;
      contactEl.textContent = "";
    }
    document.getElementById("customerMeta").innerHTML = v.accountId
      ? `Account <code>${esc(v.accountId)}</code>`
      : "";

    document.getElementById("drivers").innerHTML =
      metricBubble("Headcount", String(seats.after ?? seats.baselineOnStart ?? "—")) +
      metricBubble(
        "Volume band",
        volPct > 0 ? `${Math.round(volPct)}%` : "0%",
        {
          accent: volPct > 0,
          hint: "Applies to every PEPM line after Bundle",
        }
      );

    renderPricingLogic(v, cur);
    renderDiscountStack(v);
    renderChargeLines(v, due, cur, labels);

    const qids = (v.quotes || parts || [])
      .map((q) => q.quoteNumber || q.quoteId)
      .filter(Boolean);
    document.getElementById("quoteIds").textContent = qids.join(", ") || "—";
    document.getElementById("oppMeta").textContent = v.opportunityId
      ? `Opportunity ${v.opportunityId}`
      : "";
    document.getElementById("pricedAtMeta").textContent = v.pricedAt
      ? `Priced ${formatPricedAt(v.pricedAt)} · Place order uses this snapshot`
      : "";
    const warns = (v.warnings || data.warnings || []).filter(Boolean).slice(0, 4);
    document.getElementById("warnings").innerHTML = warns.length
      ? `<ul>${warns.map((w) => `<li>${esc(w)}</li>`).join("")}</ul>`
      : "";

    const accountId = v.accountId || data.accountId || "";
    const back = `/account?accountId=${encodeURIComponent(accountId)}`;
    const editHref = `${back}&edit=1`;
    document.getElementById("backToAccount").href = back;
    document.getElementById("editChangeLink").href = editHref;
    document.getElementById("backLicenses").href = back;

    // Persist sticky Draft Quote ids so Licenses Update quote retargets the same records.
    try {
      const amendQuotes = (data.amendQuotes || v.amendQuotes || [])
        .filter((q) => q && q.quoteId)
        .map((q) => ({
          quoteId: q.quoteId,
          assetIds: Array.isArray(q.assetIds) ? q.assetIds : [],
        }));
      const moduleQuoteId =
        data.moduleQuoteId || v.moduleQuoteId || null;
      const upgradeQuoteId =
        data.upgradeQuoteId || v.upgradeQuoteId || null;
      const upgradeSku = data.upgradeSku || v.upgradeSku || null;
      if (accountId && (amendQuotes.length || moduleQuoteId || upgradeQuoteId || upgradeSku)) {
        sessionStorage.setItem(
          "bhAmendSticky",
          JSON.stringify({
            accountId,
            amendQuotes,
            moduleQuoteId,
            upgradeQuoteId,
            upgradeSku,
            newQty: v.seats?.after ?? data.newQty ?? null,
            addonSkus: (v.products || data.lines || [])
              .filter((p) => p.isNew)
              .map((p) => p.sku)
              .filter(
                (sku) =>
                  sku &&
                  !["BAMBOO-CORE", "BAMBOO-PRO", "BAMBOO-ELITE"].includes(
                    String(sku).toUpperCase()
                  )
              ),
            startDate: v.amendStartDate || data.amendStartDate || null,
            updatedAt: new Date().toISOString(),
          })
        );
      }
    } catch (_) {
      /* ignore */
    }
  };

  const quoteIdsFromPlaceBody = (body) =>
    [
      body.upgradeQuoteId,
      body.moduleQuoteId,
      ...((body.amendQuotes || []).map((q) => q.quoteId) || []),
    ].filter(Boolean);

  const recoverPlacedOrder = async (accountId, quoteIds) => {
    const ids = (quoteIds || []).filter(Boolean);
    if (!ids.length) return null;
    const params = new URLSearchParams({
      accountId: accountId || "",
      quoteIds: ids.join(","),
    });
    const resp = await fetch(`/api/account-amend-place-status?${params}`);
    const data = await resp.json();
    if (resp.ok && data.ok && data.found && data.orderId) return data;
    return null;
  };

  const kickCollectPayment = (orderId) => {
    if (!orderId) return;
    fetch("/api/collect-payment", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ orderId, pollTimeout: 90 }),
    }).catch(() => {});
  };

  const showPlaceSuccess = (data) => {
    try {
      sessionStorage.removeItem("bhAmendSticky");
    } catch (_) {
      /* ignore */
    }
    const actions = document.getElementById("quoteActions");
    if (actions) actions.hidden = true;
    hidePreSuccessSections();
    const status = document.getElementById("placeStatus");
    if (status) {
      status.textContent = "";
      status.classList.remove("error");
    }
    const success = document.getElementById("orderSuccess");
    success.hidden = false;
    const conf = data.confirmation || {};
    document.getElementById("successTitle").textContent =
      conf.title ||
      `Changes complete for ${
        view?.accountName || summary.accountName || "your company"
      }`;
    document.getElementById("successLede").textContent =
      conf.lede ||
      "Your change is activated in Salesforce Revenue Cloud — Opportunity, Quote, Order, and Assets are live.";
    const metrics = Array.isArray(conf.metrics) ? conf.metrics : [];
    document.getElementById("successMetrics").innerHTML = metrics
      .map(
        (m) =>
          `<div class="q-metric"><span class="q-label">${esc(
            m.label
          )}</span><span class="q-value">${esc(m.value)}</span></div>`
      )
      .join("");
    const links = conf.links || data.links || {};
    const linkRows = [
      ["Account", links.account],
      ["Opportunity", links.opportunity],
      ["Quote", links.quote],
      ["Order", links.order],
    ].filter(([, href]) => href);
    document.getElementById("successLinks").innerHTML = linkRows
      .map(
        ([label, href]) =>
          `<a class="button-link secondary" href="${esc(
            href
          )}" target="_blank" rel="noopener">Open ${esc(label)}</a>`
      )
      .join("");
    success.scrollIntoView({ behavior: "smooth", block: "start" });
    const orderId =
      (data.payment && data.payment.orderId) ||
      data.orderId ||
      data.amendOrderId ||
      null;
    kickCollectPayment(orderId);
  };

  const placeOrder = async () => {
    if (!summary?.accountId) return;
    const btn = document.getElementById("placeAmendBtn");
    const status = document.getElementById("placeStatus");
    btn.disabled = true;
    status.textContent = "Placing in Revenue Cloud (Order + Activate)…";
    status.classList.remove("error");
    const planSkus = new Set(["BAMBOO-CORE", "BAMBOO-PRO", "BAMBOO-ELITE"]);
    const newSkus = (view?.products || summary.lines || [])
      .filter((l) => l.isNew && (l.sku || l.after))
      .map((l) => l.sku)
      .filter((sku) => sku && !planSkus.has(String(sku).toUpperCase()));
    const body = {
      accountId: summary.accountId,
      assetId: summary.assetId || undefined,
      addonSkus: newSkus,
      startDate:
        view?.amendStartDate || summary.amendStartDate || undefined,
      amendQuotes: (summary.amendQuotes || view?.amendQuotes || []).map(
        (q) => ({
          quoteId: q.quoteId,
          assetIds: q.assetIds || [],
          opportunityId:
            q.opportunityId ||
            summary.opportunityId ||
            view?.opportunityId,
        })
      ),
      moduleQuoteId:
        summary.moduleQuoteId || view?.moduleQuoteId || undefined,
      upgradeQuoteId:
        summary.upgradeQuoteId || view?.upgradeQuoteId || undefined,
      upgradeSku: summary.upgradeSku || view?.upgradeSku || undefined,
    };
    const baseline = Number(
      summary.baselineQty ?? view?.seats?.baselineOnStart ?? summary.currentQty
    );
    const newQty = summary.newQty ?? view?.seats?.after;
    if (newQty != null && Number(newQty) !== baseline) {
      body.newQty = Number(newQty);
    }
    try {
      const resp = await fetch("/api/account-amend", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Change failed");
      showPlaceSuccess(data);
    } catch (err) {
      status.textContent =
        "Checking whether Salesforce already placed the order…";
      status.classList.remove("error");
      let recovered = null;
      try {
        recovered = await recoverPlacedOrder(
          body.accountId,
          quoteIdsFromPlaceBody(body)
        );
        if (!recovered) {
          await new Promise((r) => setTimeout(r, 4000));
          recovered = await recoverPlacedOrder(
            body.accountId,
            quoteIdsFromPlaceBody(body)
          );
        }
      } catch (_) {
        recovered = null;
      }
      if (recovered) {
        showPlaceSuccess(recovered);
        return;
      }
      status.textContent = err.message || String(err);
      status.classList.add("error");
      btn.disabled = false;
    }
  };

  document.getElementById("placeAmendBtn")?.addEventListener("click", placeOrder);

  const boot = async () => {
    const id = pathId();
    if (!id) {
      document.getElementById("loadError").hidden = false;
      document.getElementById("loadError").textContent =
        "Missing amend summary id — generate a quote from Licenses & billing.";
      return;
    }
    try {
      const resp = await fetch(
        `/api/account-amend-summary/${encodeURIComponent(id)}`
      );
      const data = await resp.json();
      if (!resp.ok || !data.ok) {
        throw new Error(
          data.error || "Amend summary not found (session may have restarted)."
        );
      }
      const payload = data.summary || data;
      const v = resolveView(payload);
      if (!v) {
        throw new Error(
          "This summary is missing amendSummaryView. Generate quote again from Licenses & billing."
        );
      }
      renderFromView(payload, v);
    } catch (err) {
      document.getElementById("amendCard").hidden = true;
      document.getElementById("amendLede").textContent =
        "Summary unavailable — generate quote again from Licenses.";
      const errEl = document.getElementById("loadError");
      errEl.hidden = false;
      errEl.textContent = err.message || String(err);
    }
  };

  boot();
})();
