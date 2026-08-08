(() => {
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

  const signedMoney = (n, cur) => {
    const v = Number(n) || 0;
    if (Math.abs(v) < 0.005) return money(0, cur);
    return `${v > 0 ? "+" : "−"}${money(Math.abs(v), cur)}`;
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

  let summary = null;

  const render = (data) => {
    summary = data;
    const cur = data.currency || "USD";
    const monthly = data.monthly || {};
    const annual = data.annual || {};
    const accountId = data.accountId || "";

    const qtyBefore = Number(data.baselineQty ?? data.currentQty ?? 0);
    const qtyAfter = Number(data.newQty ?? qtyBefore);
    const qtyDelta = qtyAfter - qtyBefore;
    const mrrBefore = Number(monthly.today ?? 0);
    const mrrAfter = Number(monthly.after ?? 0);
    const mrrDiff = Number(monthly.difference ?? mrrAfter - mrrBefore);
    const arrBefore = Number(annual.today ?? mrrBefore * 12);
    const arrAfter = Number(annual.after ?? mrrAfter * 12);
    const arrDiff = Number(annual.difference ?? arrAfter - arrBefore);
    const due = data.dueToday;
    const hasDue = due != null && Number.isFinite(Number(due));
    const newMods = (data.lines || []).filter((l) => l.isNew);
    const startLabel = formatStart(data.amendStartDate);

    document.getElementById("amendCard").hidden = false;
    document.getElementById("amendLede").textContent = [
      data.accountName || "Account",
      data.country || "",
      cur,
    ]
      .filter(Boolean)
      .join(" · ");

    // --- 1. What you're paying ---
    const payHero = document.getElementById("payHero");
    const dueEl = document.getElementById("dueAmount");
    const payPlain = document.getElementById("payPlain");
    const dueNote = document.getElementById("dueNote");
    const payKicker = document.getElementById("payKicker");

    const changeBits = [];
    if (qtyDelta !== 0) {
      changeBits.push(
        `${qtyDelta > 0 ? "Adding" : "Removing"} ${Math.abs(qtyDelta)} employees`
      );
    }
    if (newMods.length) {
      changeBits.push(
        `Adding ${newMods.map((l) => l.name || l.sku).join(" + ")}`
      );
    }
    if (!changeBits.length) changeBits.push("License change");

    if (hasDue) {
      payKicker.textContent =
        Number(due) < 0
          ? "Credit for this change"
          : "What you’re paying for this change";
      dueEl.textContent = money(due, cur);
      dueEl.classList.toggle("is-credit", Number(due) < 0);
      payPlain.textContent = [
        changeBits.join(" · "),
        startLabel ? `Starts ${startLabel}` : "",
      ]
        .filter(Boolean)
        .join(" · ");
      dueNote.textContent =
        Number(due) < 0
          ? "Prorated credit from your Revenue Cloud quote for this change."
          : "Prorated charge from your Revenue Cloud quote for this change only — not your full annual bill.";
    } else {
      payKicker.textContent = "This change";
      dueEl.textContent = changeBits[0];
      dueEl.classList.remove("is-credit");
      payPlain.textContent = [
        changeBits.slice(1).join(" · "),
        startLabel ? `Starts ${startLabel}` : "",
      ]
        .filter(Boolean)
        .join(" · ");
      dueNote.textContent =
        "Quote charge will appear after Revenue Cloud pricing finishes.";
    }

    // --- 2. Today → After comparison ---
    const rows = [
      {
        label: "Employees",
        before: String(qtyBefore),
        change:
          qtyDelta === 0
            ? "—"
            : `${qtyDelta > 0 ? "+" : "−"}${Math.abs(qtyDelta)}`,
        after: String(qtyAfter),
        changeClass: qtyDelta > 0 ? "is-up" : qtyDelta < 0 ? "is-down" : "",
      },
      {
        label: "Monthly (MRR)",
        before: money(mrrBefore, cur),
        change: signedMoney(mrrDiff, cur),
        after: money(mrrAfter, cur),
        changeClass: mrrDiff > 0 ? "is-up" : mrrDiff < 0 ? "is-down" : "",
      },
      {
        label: "Annual (ARR)",
        before: money(arrBefore, cur),
        change: signedMoney(arrDiff, cur),
        after: money(arrAfter, cur),
        changeClass: arrDiff > 0 ? "is-up" : arrDiff < 0 ? "is-down" : "",
      },
    ];
    document.getElementById("compareTable").innerHTML = `
      <div class="amend-compare-head">
        <span></span>
        <span>Today</span>
        <span>This change</span>
        <span>After</span>
      </div>
      ${rows
        .map(
          (r) => `<div class="amend-compare-row">
          <span class="amend-compare-label">${esc(r.label)}</span>
          <span class="amend-compare-before">${esc(r.before)}</span>
          <span class="amend-compare-change ${r.changeClass}">${esc(r.change)}</span>
          <span class="amend-compare-after">${esc(r.after)}</span>
        </div>`
        )
        .join("")}`;

    // --- 3. Product cards (what the charge is for) ---
    const todayBySku = {};
    (data.linesToday || []).forEach((l) => {
      if (l.sku) todayBySku[String(l.sku).toUpperCase()] = l;
    });

    const products = (data.lines || []).map((l) => {
      const sku = String(l.sku || "").toUpperCase();
      const before = todayBySku[sku];
      const qtyB = before ? Number(before.qty || 0) : 0;
      const qtyA = Number(l.qty || 0);
      const moB = before ? Number(before.monthly || 0) : 0;
      const moA = Number(l.monthly || 0);
      const pepmB = before && before.netPepm != null ? Number(before.netPepm) : null;
      const pepmA = l.netPepm != null ? Number(l.netPepm) : null;
      const seatAdd = l.isNew ? qtyA : qtyA - qtyB;
      const moDiff = moA - moB;
      const pepmChanged =
        pepmB != null && pepmA != null && Math.abs(pepmA - pepmB) > 0.009;
      return { l, sku, qtyB, qtyA, seatAdd, moDiff, moA, pepmA, pepmChanged, pepmB };
    });

    // Prefer products that actually change; still show all if everything moves.
    const changed = products.filter(
      (p) => p.l.isNew || p.seatAdd !== 0 || Math.abs(p.moDiff) > 0.009
    );
    const list = changed.length ? changed : products;

    document.getElementById("productsLede").textContent = hasDue
      ? `These products drive the ${money(due, cur)} charge above.`
      : "Seat and monthly impact by product.";

    document.getElementById("productList").innerHTML = list
      .map((p) => {
        const seatLine = p.l.isNew
          ? `${p.qtyA} seats · new module`
          : p.seatAdd === 0
            ? `${p.qtyA} seats · no qty change`
            : `${p.qtyB} → ${p.qtyA} seats (${p.seatAdd > 0 ? "+" : "−"}${Math.abs(
                p.seatAdd
              )})`;
        const pepmLine =
          p.pepmA == null
            ? ""
            : p.pepmChanged
              ? `PEPM ${money(p.pepmB, cur)} → ${money(p.pepmA, cur)}`
              : `PEPM ${money(p.pepmA, cur)}`;
        return `<article class="amend-product-card${p.l.isNew ? " is-new" : ""}">
          <div class="amend-product-main">
            <h4>${esc(p.l.name || p.sku)}${
              p.l.isNew ? ' <span class="line-badge">New</span>' : ""
            }</h4>
            <p class="amend-product-seats">${esc(seatLine)}</p>
            ${pepmLine ? `<p class="muted amend-product-pepm">${esc(pepmLine)}</p>` : ""}
          </div>
          <div class="amend-product-impact">
            <p class="amend-product-delta ${
              p.moDiff > 0 ? "is-up" : p.moDiff < 0 ? "is-down" : ""
            }">${esc(signedMoney(p.moDiff, cur))}</p>
            <p class="muted">/ mo after</p>
            <p class="amend-product-after">${esc(money(p.moA, cur))} / mo</p>
          </div>
        </article>`;
      })
      .join("") || `<p class="muted">No product changes on this quote.</p>`;

    const qids = [
      ...(data.amendQuotes || []).map((q) => q.quoteNumber || q.quoteId),
      data.moduleQuote?.quoteNumber || data.moduleQuoteId,
    ].filter(Boolean);
    document.getElementById("quoteIds").textContent = qids.join(", ") || "—";
    document.getElementById("oppMeta").textContent = data.opportunityId
      ? `Opportunity ${data.opportunityId}`
      : "";
    const warns = (data.warnings || []).filter(Boolean).slice(0, 3);
    document.getElementById("warnings").innerHTML = warns.length
      ? `<ul>${warns.map((w) => `<li>${esc(w)}</li>`).join("")}</ul>`
      : "";

    const back = `/account?accountId=${encodeURIComponent(accountId)}`;
    document.getElementById("backToAccount").href = back;
    document.getElementById("editChangeLink").href = back;
    document.getElementById("backLicenses").href = back;

    void payHero;
  };

  const placeOrder = async () => {
    if (!summary?.accountId) return;
    const btn = document.getElementById("placeAmendBtn");
    const status = document.getElementById("placeStatus");
    btn.disabled = true;
    status.textContent = "Placing in Revenue Cloud (Order + Activate)…";
    status.classList.remove("error");
    try {
      const body = {
        accountId: summary.accountId,
        assetId: summary.assetId || undefined,
        addonSkus: (summary.lines || [])
          .filter((l) => l.isNew && l.sku)
          .map((l) => l.sku),
        startDate: summary.amendStartDate || undefined,
        amendQuotes: (summary.amendQuotes || []).map((q) => ({
          quoteId: q.quoteId,
          assetIds: q.assetIds || [],
          opportunityId: q.opportunityId || summary.opportunityId,
        })),
        moduleQuoteId: summary.moduleQuoteId || undefined,
      };
      const baseline = Number(summary.baselineQty ?? summary.currentQty);
      if (summary.newQty != null && Number(summary.newQty) !== baseline) {
        body.newQty = summary.newQty;
      }
      const resp = await fetch("/api/account-amend", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Change failed");

      document.getElementById("amendCard").querySelector(".quote-actions").hidden =
        true;
      document.getElementById("payHero").hidden = true;
      document.querySelector(".amend-impact").hidden = true;
      document.querySelector(".amend-products").hidden = true;
      status.textContent = "";
      const success = document.getElementById("orderSuccess");
      success.hidden = false;
      const conf = data.confirmation || {};
      document.getElementById("successTitle").textContent =
        conf.title ||
        `Changes complete for ${summary.accountName || "your company"}`;
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
    } catch (err) {
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
      render(data.summary || data);
    } catch (err) {
      document.getElementById("loadError").hidden = false;
      document.getElementById("loadError").textContent = err.message || String(err);
    }
  };

  boot();
})();
