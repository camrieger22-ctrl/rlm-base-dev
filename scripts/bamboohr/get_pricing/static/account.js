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

  const money = (n, cur = "USD") =>
    `${cur} ${Number(n).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })}`;

  const savePin = (accountId, company) => {
    try {
      sessionStorage.setItem(
        "bhAccountPin",
        JSON.stringify({ accountId, company: company || "" })
      );
    } catch (_) {
      /* ignore */
    }
  };

  const readPin = () => {
    try {
      return JSON.parse(sessionStorage.getItem("bhAccountPin") || "{}") || {};
    } catch (_) {
      return {};
    }
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

  const subscriptionTotals = (qty, { includeSelectedAddons = false } = {}) => {
    const assets = state?.subscription?.assets || [];
    const primaryId = state?.subscription?.primaryAssetId;
    const lines = [];
    let total = 0;
    for (const a of assets) {
      // Qty amend applies to primary plan; other assets keep their current qty for estimate.
      const q =
        a.id === primaryId ? qty : Number(a.quantity) || qty;
      const monthly = lineMonthly(a, q);
      if (monthly == null) continue;
      const info = listForSku(a.sku) || {};
      lines.push({
        id: a.id,
        name: a.name || a.productName || info.name || a.sku,
        sku: a.sku,
        qty: q,
        listPepm: info.listPepm,
        monthly,
        isPrimary: a.id === primaryId,
        isNew: false,
      });
      total += monthly;
    }
    if (includeSelectedAddons) {
      for (const sku of selectedAddons) {
        const info = listForSku(sku);
        if (!info || info.listPepm == null) continue;
        const pepm = info.listPepm * (1 - volumeRate(qty));
        const monthly = Math.round(pepm * qty * 100) / 100;
        lines.push({
          id: sku,
          name: info.name || sku,
          sku,
          qty,
          listPepm: info.listPepm,
          monthly,
          isPrimary: false,
          isNew: true,
        });
        total += monthly;
      }
    }
    return { lines, total: Math.round(total * 100) / 100 };
  };

  const syncPreview = () => {
    if (!state) return;
    const cur = state.account.currency || "USD";
    const currentQty = Number(state.subscription.currentQuantity) || 0;
    const newQty = Math.max(1, Number(qtyInput.value) || 1);
    const delta = newQty - currentQty;

    const deltaLabel = document.getElementById("qtyDeltaLabel");
    if (deltaLabel) {
      if (delta === 0) deltaLabel.textContent = "No change";
      else if (delta > 0) deltaLabel.textContent = `Adding ${delta} employees`;
      else deltaLabel.textContent = `Removing ${Math.abs(delta)} employees`;
    }

    const before = subscriptionTotals(currentQty, { includeSelectedAddons: false });
    const after = subscriptionTotals(newQty, { includeSelectedAddons: true });
    const diff = Math.round((after.total - before.total) * 100) / 100;

    document.getElementById("subRecurring").textContent = money(before.total, cur);
    document.getElementById("prevCurrent").textContent = money(before.total, cur);
    document.getElementById("prevAfter").textContent = money(after.total, cur);
    const diffEl = document.getElementById("prevDiff");
    diffEl.textContent = (diff >= 0 ? "+" : "") + money(diff, cur);
    diffEl.classList.toggle("is-up", diff > 0);
    diffEl.classList.toggle("is-down", diff < 0);
    document.getElementById("dueToday").textContent =
      money(Math.max(0, diff), cur);

    const checkout = document.getElementById("checkoutLines");
    if (checkout) {
      checkout.innerHTML = after.lines
        .map((l) => {
          const pepm =
            l.listPepm != null
              ? `${money(l.listPepm * (1 - volumeRate(l.qty)), cur)} PEPM`
              : "flat";
          const tag = l.isNew
            ? " · adding"
            : l.isPrimary && delta
              ? " · amending"
              : "";
          return `<li>
            <div>
              <strong>${l.name}</strong>
              <span>${l.qty} emp · ${pepm}${tag}</span>
            </div>
            <em>${money(l.monthly, cur)}</em>
          </li>`;
        })
        .join("");
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

  const setQty = (n) => {
    const hc = Math.max(1, Math.min(100000, Number(n) || 1));
    qtyInput.value = String(hc);
    if (qtyRange) qtyRange.value = String(Math.min(600, hc));
    syncPreview();
  };

  const renderConsole = (data) => {
    state = data;
    loginPanel.hidden = true;
    consoleRoot.hidden = false;
    document.getElementById("accountSub").textContent =
      `${data.account.name} · ${data.account.currency}`;
    document.getElementById("identityNote").textContent = data.identityNote || "";
    document.getElementById("subMeta").textContent =
      `${data.subscription.assets.length} product(s) · ${
        data.subscription.currentQuantity || "—"
      } employees on primary plan`;

    const sf = document.getElementById("openSfAccount");
    if (sf && data.links?.account) {
      sf.href = data.links.account;
      sf.hidden = false;
    }

    const subLines = document.getElementById("subLines");
    const curQty = Number(data.subscription.currentQuantity) || 0;
    const snap = subscriptionTotals(curQty);
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
      if (ecToken && window.history?.replaceState) {
        const clean = new URL(window.location.href);
        clean.searchParams.delete("ecToken");
        clean.searchParams.set("accountId", data.account.id);
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

  qtyInput?.addEventListener("input", () => setQty(qtyInput.value));
  qtyRange?.addEventListener("input", () => setQty(qtyRange.value));
  document.getElementById("qtyMinus")?.addEventListener("click", () =>
    setQty(Number(qtyInput.value) - 1)
  );
  document.getElementById("qtyPlus")?.addEventListener("click", () =>
    setQty(Number(qtyInput.value) + 1)
  );
  document.querySelectorAll("[data-qty-delta]").forEach((btn) => {
    btn.addEventListener("click", () =>
      setQty(Number(qtyInput.value) + Number(btn.dataset.qtyDelta))
    );
  });

  document.getElementById("placeAmendBtn")?.addEventListener("click", async () => {
    if (!state?.account?.id) {
      amendStatus.textContent =
        "No account loaded — complete a Get Pricing purchase first.";
      amendStatus.classList.add("error");
      return;
    }
    const newQty = Math.max(1, Number(qtyInput.value) || 1);
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
    const parts = [];
    if (qtyChanged) parts.push(`qty ${current}→${newQty}`);
    if (addons.length) parts.push(`add ${addons.join(", ")}`);
    amendStatus.textContent = `Placing in Revenue Cloud (${parts.join("; ")})…`;
    amendStatus.classList.remove("error");
    const btn = document.getElementById("placeAmendBtn");
    btn.disabled = true;
    try {
      const body = {
        accountId: state.account.id,
        assetId: state.subscription.primaryAssetId || undefined,
        addonSkus: addons,
      };
      if (qtyChanged) body.newQty = newQty;
      const resp = await fetch("/api/account-amend", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "Change failed");
      const bits = [];
      if (data.qtyAmend?.amendOrderNumber || data.qtyAmend?.amendOrderId) {
        bits.push(
          `qty Order ${data.qtyAmend.amendOrderNumber || data.qtyAmend.amendOrderId}`
        );
      }
      if (data.moduleSale?.orderNumber || data.moduleSale?.orderId) {
        bits.push(
          `modules Order ${data.moduleSale.orderNumber || data.moduleSale.orderId}`
        );
      }
      if (data.addedSkus?.length) bits.push(`added ${data.addedSkus.join(", ")}`);
      amendStatus.textContent = `Complete — ${bits.join(" · ") || "ok"}`;
      selectedAddons.clear();
      await loadConsole({ accountId: state.account.id });
    } catch (err) {
      amendStatus.textContent = err.message || String(err);
      amendStatus.classList.add("error");
    } finally {
      btn.disabled = false;
    }
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
