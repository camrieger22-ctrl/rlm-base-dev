(() => {
  const form = document.getElementById("pricing-form");
  const status = document.getElementById("status");
  const submit = document.getElementById("submit");
  const country = document.getElementById("country");
  const planSku = document.getElementById("planSku");
  const headcount = document.getElementById("headcount");
  const hcRange = document.getElementById("hcRange");
  const addonHint = document.getElementById("addonHint");
  const flatHint = document.getElementById("flatHint");
  const addonCount = document.getElementById("addonCount");
  const volumePill = document.getElementById("volumePill");
  const bandGrid = document.getElementById("bandGrid");
  const planCards = [...document.querySelectorAll(".plan-card[data-plan]")];

  const FX = { US: 1, CA: 1.35, UK: 0.79 };
  const CUR = { US: "USD", CA: "CAD", UK: "GBP" };
  // Seeded demo lists (USD). Overwritten by GET /api/catalog with currency-native PBE prices.
  const PLAN_LIST = { "BAMBOO-CORE": 10, "BAMBOO-PRO": 17, "BAMBOO-ELITE": 25 };
  const PLAN_LABELS = {
    "BAMBOO-CORE": "Core",
    "BAMBOO-PRO": "Pro",
    "BAMBOO-ELITE": "Elite",
  };
  const ADDON_LIST = {
    "BAMBOO-ADD-PAYROLL": 8,
    "BAMBOO-ADD-BENEFITS": 6,
    "BAMBOO-ADD-TIME": 4,
    "BAMBOO-ADD-GLOBAL": 12,
  };
  const ADDON_LABELS = {
    "BAMBOO-ADD-PAYROLL": "Payroll",
    "BAMBOO-ADD-BENEFITS": "Benefits Administration",
    "BAMBOO-ADD-TIME": "Time & Attendance",
    "BAMBOO-ADD-GLOBAL": "Global Employment",
  };
  let useOrgList = false;
  let coreFlatList = 250;
  let catalogBadge = null;
  const VOLUME_BANDS = [
    { lo: 1, hi: 24, rate: 0, label: "1–24" },
    { lo: 25, hi: 75, rate: 0.05, label: "25–75" },
    { lo: 76, hi: 150, rate: 0.1, label: "76–150" },
    { lo: 151, hi: 300, rate: 0.15, label: "151–300" },
    { lo: 301, hi: 500, rate: 0.2, label: "301–500" },
    { lo: 501, hi: null, rate: 0.25, label: "501–∞" },
  ];

  let billPeriod = "annual";
  let wasSmallBiz = false;
  let planBeforeSmallBiz = planSku.value;
  /** Sticky Draft Quote id from /api/get-pricing-preview. */
  let stickyQuoteId = null;
  try {
    stickyQuoteId = sessionStorage.getItem("bhStickyQuoteId") || null;
  } catch (_) {
    stickyQuoteId = null;
  }
  let stickyCfg = null;
  let previewTimer = null;
  let previewSeq = 0;
  let previewInFlight = false;
  let previewNeedsRerun = false;
  let pricingBusy = false;
  let lastRcPricing = null;

  const persistStickyQuoteId = (qid) => {
    stickyQuoteId = qid || null;
    try {
      if (qid) sessionStorage.setItem("bhStickyQuoteId", qid);
      else sessionStorage.removeItem("bhStickyQuoteId");
    } catch (_) {
      /* ignore */
    }
  };

  const money = (n) =>
    n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  const fx = () => FX[country.value] || 1;
  const currency = () => CUR[country.value] || "USD";

  const volumeRate = (hc) => {
    for (const b of VOLUME_BANDS) {
      if (hc >= b.lo && (b.hi == null || hc <= b.hi)) return b.rate;
    }
    return 0;
  };

  const activeBand = (hc) =>
    VOLUME_BANDS.find((b) => hc >= b.lo && (b.hi == null || hc <= b.hi)) || VOLUME_BANDS[0];

  const usesFlat = () => planSku.value === "BAMBOO-CORE" && Number(headcount.value) <= 25;

  const selectedAddons = () =>
    [...form.querySelectorAll('input[name="addon"]:checked:not(:disabled)')].map((el) => el.value);

  const pathB = () => {
    const a = selectedAddons();
    return a.includes("BAMBOO-ADD-PAYROLL") && a.includes("BAMBOO-ADD-BENEFITS");
  };

  const round2 = (n) => Math.round(n * 100) / 100;
  const listPlan = (sku) =>
    useOrgList ? round2(PLAN_LIST[sku]) : round2(PLAN_LIST[sku] * fx());
  const listAddon = (sku) =>
    useOrgList ? round2(ADDON_LIST[sku]) : round2(ADDON_LIST[sku] * fx());
  const flatPrice = () =>
    useOrgList ? round2(coreFlatList) : round2(coreFlatList * fx());

  const netPlanPepm = (hc) => {
    if (usesFlat()) return null;
    const list = listPlan(planSku.value);
    return round2(list * (1 - volumeRate(hc)));
  };

  const netAddonPepm = (sku) => {
    // Order matches RC: Bundle & Save on ListPrice, then volume by headcount.
    let n = listAddon(sku);
    if (pathB() && (sku === "BAMBOO-ADD-PAYROLL" || sku === "BAMBOO-ADD-BENEFITS")) {
      n = round2(n * 0.85);
    }
    n = round2(n * (1 - volumeRate(Number(headcount.value) || 0)));
    return n;
  };

  const syncPlanFooters = () => {
    planCards.forEach((card) => {
      const on = card.getAttribute("aria-checked") === "true";
      const label = card.querySelector(".foot-label");
      if (label) label.textContent = on ? "Selected" : "Get Quote";
    });
  };

  const displayList = (n) => {
    const v = round2(n);
    return Number.isInteger(v) ? String(v) : money(v);
  };

  const selectPlan = (sku) => {
    if (!planSku || !sku) return;
    planSku.value = sku;
    planCards.forEach((card) => {
      const on = card.dataset.plan === sku;
      card.setAttribute("aria-checked", on ? "true" : "false");
    });
    syncPlanFooters();
    syncEstimate();
  };

  planCards.forEach((card) => {
    card.addEventListener("click", () => selectPlan(card.dataset.plan));
    card.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        selectPlan(card.dataset.plan);
      }
    });
  });

  document.querySelectorAll(".bill-opt").forEach((btn) => {
    btn.addEventListener("click", () => {
      billPeriod = btn.dataset.bill;
      document.querySelectorAll(".bill-opt").forEach((b) => {
        b.setAttribute("aria-pressed", b === btn ? "true" : "false");
      });
      syncEstimate();
    });
  });

  const syncCountryAddons = () => {
    const nonUs = country.value === "CA" || country.value === "UK";
    form.querySelectorAll('input[name="addon"][data-us-only]').forEach((el) => {
      const forceOff = nonUs || el.dataset.available === "false";
      el.disabled = forceOff;
      if (forceOff) el.checked = false;
      el.closest(".module-card")?.classList.toggle("disabled", forceOff);
    });
    if (addonHint) {
      if (nonUs) {
        addonHint.textContent =
          `${country.value === "CA" ? "Canada" : "United Kingdom"}: Payroll and Benefits unavailable. Time and Global remain selectable.`;
      } else {
        addonHint.textContent = "Accomplish even more with additional capabilities.";
      }
    }
    // Refresh displayed list prices for currency
    const cur = currency();
    document.querySelectorAll(".plan-card[data-list]").forEach((card) => {
      const el = card.querySelector("[data-price]");
      if (el) el.textContent = displayList(listPlan(card.dataset.plan));
      const curEl = card.querySelector(".price .cur");
      if (curEl) curEl.textContent = `${cur}*`;
      const nameEl = card.querySelector(".plan-name");
      if (nameEl && PLAN_LABELS[card.dataset.plan]) {
        nameEl.textContent = PLAN_LABELS[card.dataset.plan];
      }
      const flatNote = card.querySelector(".price-meta.flat-note");
      if (flatNote && card.dataset.plan === "BAMBOO-CORE") {
        flatNote.textContent = `${cur} ${displayList(flatPrice())}/mo flat for ≤25 employees`;
      }
    });
    form.querySelectorAll("input[name=addon][data-list]").forEach((input) => {
      const card = input.closest(".module-card");
      const el = card?.querySelector("[data-addon-price]");
      if (el) el.textContent = displayList(listAddon(input.value));
      const unit = card?.querySelector(".mod-price span");
      if (unit) unit.textContent = `${cur} /emp/mo`;
      const nameEl = card?.querySelector(".mod-name");
      if (nameEl && ADDON_LABELS[input.value]) {
        const sub = nameEl.querySelector(".mod-sub");
        nameEl.textContent = ADDON_LABELS[input.value];
        if (sub) nameEl.appendChild(sub);
      }
    });
    if (catalogBadge) {
      catalogBadge.textContent = useOrgList
        ? `List prices from Salesforce price book (${cur})`
        : `Demo list prices (${cur})`;
    }
  };

  const applyCatalog = (data) => {
    if (!data || !data.ok) return;
    (data.plans || []).forEach((p) => {
      if (p.sku in PLAN_LIST) PLAN_LIST[p.sku] = Number(p.listPepm);
      if (p.name) PLAN_LABELS[p.sku] = p.name;
      const card = document.querySelector(`.plan-card[data-plan="${p.sku}"]`);
      if (card) {
        card.dataset.list = String(p.listPepm);
        card.dataset.available = p.available ? "true" : "false";
        card.classList.toggle("disabled", !p.available);
        card.disabled = !p.available;
      }
    });
    (data.addons || []).forEach((a) => {
      if (a.sku in ADDON_LIST) ADDON_LIST[a.sku] = Number(a.listPepm);
      if (a.name) ADDON_LABELS[a.sku] = a.name;
      const input = form.querySelector(`input[name="addon"][value="${a.sku}"]`);
      if (input) {
        input.dataset.list = String(a.listPepm);
        input.dataset.available = a.available ? "true" : "false";
      }
    });
    if (data.coreFlat && data.coreFlat.listPrice != null) {
      coreFlatList = Number(data.coreFlat.listPrice);
    }
    useOrgList = data.source === "pricebook" || data.source === "mixed";
    syncCountryAddons();
    syncEstimate();
  };

  const loadCatalog = async () => {
    try {
      const resp = await fetch(`/api/catalog?country=${encodeURIComponent(country.value)}`);
      const data = await resp.json();
      if (!resp.ok || !data.ok) throw new Error(data.error || "catalog failed");
      applyCatalog(data);
    } catch (_) {
      useOrgList = false;
      syncCountryAddons();
      syncEstimate();
    }
  };

  const isSmallBizHeadcount = () => {
    const hc = Number(headcount.value);
    return Number.isFinite(hc) && hc >= 1 && hc <= 25;
  };

  const setHeadcount = (n, { fromSlider } = {}) => {
    let hc = Math.max(1, Math.min(100000, Number(n) || 1));
    headcount.value = String(hc);
    if (hcRange && !fromSlider) {
      hcRange.value = String(Math.min(600, hc));
    }
    document.querySelectorAll("#hcPresets button").forEach((b) => {
      b.classList.toggle("on", Number(b.dataset.hc) === hc);
    });
    const small = isSmallBizHeadcount();
    if (small && !wasSmallBiz) {
      planBeforeSmallBiz = planSku.value;
      selectPlan("BAMBOO-CORE");
    } else if (!small && wasSmallBiz && planSku.value === "BAMBOO-CORE") {
      selectPlan(planBeforeSmallBiz || "BAMBOO-PRO");
    }
    wasSmallBiz = small;
    syncEstimate();
  };

  const currentBuyer = () => {
    let buyer = {};
    try {
      buyer = JSON.parse(sessionStorage.getItem("bhHeroLead") || "{}") || {};
    } catch (_) {
      buyer = {};
    }
    const hf = document.getElementById("hero-lead-form");
    if (hf) {
      buyer = {
        firstName: hf.firstName?.value || buyer.firstName || "",
        lastName: hf.lastName?.value || buyer.lastName || "",
        email: hf.email?.value || buyer.email || "",
        company: hf.company?.value || buyer.company || "",
        phone: hf.phone?.value || buyer.phone || "",
        jobTitle: hf.jobTitle?.value || buyer.jobTitle || "",
      };
    }
    return buyer;
  };

  const cfgFingerprint = () => {
    const addons = selectedAddons().slice().sort().join(",");
    const trial = document.getElementById("freeTrial")?.checked ? "1" : "0";
    return `${planSku.value}|${Number(headcount.value) || 0}|${country.value}|${addons}|trial=${trial}`;
  };

  const setRailBusy = (busy, message) => {
    pricingBusy = busy;
    const rail = document.querySelector(".rail-card");
    rail?.classList.toggle("is-pricing", !!busy);
    const src = document.getElementById("railSource");
    if (src && message) src.textContent = message;
    if (submit) submit.disabled = !!busy;
  };

  const paintRailFromLines = ({
    lines,
    monthly,
    pepmDisplay,
    flat,
    cur,
    sourceNote,
  }) => {
    const annual = round2(monthly * 12);
    const total = billPeriod === "annual" ? annual : monthly;
    document.getElementById("railPepm").textContent = money(pepmDisplay);
    document.getElementById("railPepmUnit").textContent = flat
      ? `effective / emp · ${cur} flat package`
      : `per employee / month · ${cur}`;
    document.getElementById("railBill").textContent =
      billPeriod === "annual" ? "Billed annually" : "Billed monthly";
    document.getElementById("railSubLabel").textContent =
      billPeriod === "annual" ? "Subscription, per year" : "Subscription, per month";
    document.getElementById("railSub").textContent = `$${money(
      billPeriod === "annual" ? annual : monthly
    )}`;
    document.getElementById("railTotal").textContent = `$${money(total)}`;
    const railLines = document.getElementById("railLines");
    if (railLines) {
      railLines.innerHTML = lines
        .map(
          (l) => `<li>
            <span class="name">${l.name}</span>
            <span class="calc">${l.calc}${
            l.listAmt != null ? ` · <s>$${money(l.listAmt)}</s>` : ""
          }</span>
            <span class="amt">$${money(l.amt)}</span>
          </li>`
        )
        .join("");
    }
    const src = document.getElementById("railSource");
    if (src && sourceNote) src.textContent = sourceNote;
  };

  const scheduleRcPreview = () => {
    if (previewTimer) clearTimeout(previewTimer);
    // Longer debounce + single-flight below — RC System reprice is ~4–8s.
    previewTimer = setTimeout(() => fetchRcPreview(), 700);
  };

  const fetchRcPreview = async () => {
    // Coalesce: never queue multiple Salesforce previews behind the account lock.
    if (previewInFlight) {
      previewNeedsRerun = true;
      return;
    }
    previewInFlight = true;
    previewNeedsRerun = false;
    const seq = ++previewSeq;
    const cfg = cfgFingerprint();
    setRailBusy(true, "Pricing in Revenue Cloud…");
    try {
      const buyer = currentBuyer();
      const body = {
        headcount: Number(headcount.value) || 1,
        country: country.value,
        planSku: planSku.value,
        addonSkus: selectedAddons(),
        freeTrial: !!document.getElementById("freeTrial")?.checked,
        quoteId: stickyQuoteId || undefined,
      };
      if (buyer.company && buyer.email) body.buyer = buyer;
      const resp = await fetch("/api/get-pricing-preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (seq !== previewSeq) return;
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Preview failed");
      }
      stickyQuoteId = data.quoteId || stickyQuoteId;
      stickyCfg = data.cfg || cfg;
      lastRcPricing = data;
      persistStickyQuoteId(stickyQuoteId);
      const hc = Number(data.headcount) || Number(headcount.value) || 1;
      const cur = data.currency || currency();
      const flat = !!data.smallBizFlat;
      const trial = !!data.freeTrial;
      const lines = (data.lineItems || []).map((li) => {
        const qty = Number(li.quantity) || hc;
        const net = Number(li.netPepm) || 0;
        const list = li.listPepm != null ? Number(li.listPepm) : null;
        const amt = Number(li.monthly) || round2(net * qty);
        let calc;
        if (flat && li.isPlan) {
          calc = `${money(amt)} / mo flat · qty ${qty}`;
        } else {
          calc = `$${money(net)} × ${qty} employees`;
        }
        return {
          name: li.name || li.sku,
          calc,
          listAmt:
            list != null && list > net + 0.009 ? round2(list * qty) : null,
          amt,
        };
      });
      let monthly = Number(data.monthlyTotal) || 0;
      let pepmDisplay = hc > 0 ? round2(monthly / hc) : Number(data.netPepm) || 0;
      if (trial) {
        pepmDisplay = 0;
      }
      const qn = data.quoteNumber ? ` · ${data.quoteNumber}` : "";
      paintRailFromLines({
        lines,
        monthly,
        pepmDisplay,
        flat,
        cur,
        sourceNote: `Priced in Revenue Cloud (System reprice)${qn}`,
      });
    } catch (err) {
      if (seq !== previewSeq) return;
      const src = document.getElementById("railSource");
      if (src) {
        src.textContent = `RC preview unavailable — showing local estimate. ${
          err.message || ""
        }`;
      }
    } finally {
      previewInFlight = false;
      if (previewNeedsRerun) {
        previewNeedsRerun = false;
        // One more pass with the latest cart — keep spinner until then.
        fetchRcPreview();
      } else if (seq === previewSeq) {
        setRailBusy(false);
      }
    }
  };

  const syncEstimate = () => {
    const hc = Number(headcount.value) || 1;
    const rate = volumeRate(hc);
    const band = activeBand(hc);
    const addons = selectedAddons();
    const flat = usesFlat();
    const trial = !!document.getElementById("freeTrial")?.checked;
    const cur = currency();

    if (flatHint) flatHint.hidden = !flat;
    document.querySelectorAll(".price-meta.flat-note").forEach((el) => {
      el.classList.toggle("is-active", flat);
    });

    if (addonCount) addonCount.textContent = `${addons.length} OF 4 ON`;
    if (volumePill) {
      volumePill.textContent = flat
        ? "SMALL-BIZ FLAT"
        : `${Math.round(rate * 100)}% VOLUME BAND`;
    }

    // Volume band cards — plan net PEPM at each band (matches RC ladder)
    if (bandGrid) {
      const bands = VOLUME_BANDS.slice(1); // 25–∞
      bandGrid.innerHTML = bands
        .map((b) => {
          const list = listPlan(planSku.value);
          const net = round2(list * (1 - b.rate));
          const on = band.lo === b.lo ? " on" : "";
          const off =
            b.rate > 0 ? `${Math.round(b.rate * 100)}% off list` : "List price";
          return `<div class="band-card${on}" data-band-lo="${b.lo}">
            <span class="range">${b.label} employees</span>
            <span class="pepm">${money(net)}</span>
            <span class="off">${off}</span>
          </div>`;
        })
        .join("");
      bandGrid.querySelectorAll(".band-card").forEach((card) => {
        card.addEventListener("click", () => setHeadcount(Number(card.dataset.bandLo)));
      });
    }

    // Line items
    const lines = [];
    let monthly = 0;
    let pepmDisplay = 0;

    if (flat) {
      const fp = flatPrice();
      monthly = fp;
      pepmDisplay = round2(fp / hc);
      lines.push({
        name: `${PLAN_LABELS[planSku.value]} (flat · ≤25)`,
        calc: `${money(fp)} / mo flat · qty 1`,
        listAmt: null,
        amt: fp,
      });
    } else {
      const list = listPlan(planSku.value);
      const net = round2(list * (1 - rate));
      const lineMo = round2(net * hc);
      monthly = round2(monthly + lineMo);
      pepmDisplay = net;
      lines.push({
        name: PLAN_LABELS[planSku.value],
        calc: `$${money(net)} × ${hc} employees`,
        listAmt: rate > 0 ? round2(list * hc) : null,
        amt: lineMo,
      });
    }

    for (const sku of addons) {
      const list = listAddon(sku);
      const net = netAddonPepm(sku);
      const lineMo = round2(net * hc);
      monthly = round2(monthly + lineMo);
      lines.push({
        name: ADDON_LABELS[sku],
        calc: `$${money(net)} × ${hc} employees`,
        listAmt: net < list ? round2(list * hc) : null,
        amt: lineMo,
      });
    }

    // Blended PEPM across plan + modules (sidebar hero number)
    pepmDisplay = hc > 0 ? round2(monthly / hc) : 0;

    if (trial) {
      lines.forEach((l) => {
        l.listAmt = l.amt;
        l.amt = 0;
      });
      monthly = 0;
      pepmDisplay = 0;
    }

    // Local estimate immediately; Revenue Cloud preview replaces shortly.
    stickyCfg = null;
    paintRailFromLines({
      lines,
      monthly,
      pepmDisplay,
      flat,
      cur,
      sourceNote: "Local estimate — pricing in Revenue Cloud…",
    });
    scheduleRcPreview();
  };

  country.addEventListener("change", () => {
    loadCatalog();
  });
  headcount.addEventListener("input", () => setHeadcount(headcount.value));
  headcount.addEventListener("change", () => setHeadcount(headcount.value));
  hcRange?.addEventListener("input", () => setHeadcount(hcRange.value, { fromSlider: true }));
  document.getElementById("hcMinus")?.addEventListener("click", () =>
    setHeadcount(Number(headcount.value) - 1)
  );
  document.getElementById("hcPlus")?.addEventListener("click", () =>
    setHeadcount(Number(headcount.value) + 1)
  );
  document.querySelectorAll("#hcPresets button").forEach((b) => {
    b.addEventListener("click", () => setHeadcount(Number(b.dataset.hc)));
  });
  form.querySelectorAll('input[name="addon"]').forEach((el) => {
    el.addEventListener("change", syncEstimate);
  });
  document.getElementById("freeTrial")?.addEventListener("change", syncEstimate);

  catalogBadge = document.getElementById("catalogSource");
  syncCountryAddons();
  wasSmallBiz = isSmallBizHeadcount();
  selectPlan(planSku.value || "BAMBOO-PRO");
  loadCatalog();

  const heroForm = document.getElementById("hero-lead-form");
  const heroCountry = document.getElementById("heroCountry");
  const heroHeadcount = document.getElementById("heroHeadcount");

  const openSf = document.getElementById("openSalesforce");
  const openAcct = document.getElementById("openSfAccounts");
  openSf?.addEventListener("click", (event) => {
    if (!openSf.getAttribute("href") || openSf.getAttribute("href") === "#") {
      event.preventDefault();
      status.textContent = "Salesforce link not ready yet — wait a moment and try again.";
    }
  });
  fetch("/api/health")
    .then((r) => r.json())
    .then((data) => {
      if (!data.ok || !data.links) return;
      if (openSf && data.links.home) openSf.href = data.links.home;
      if (openAcct && data.links.accounts) {
        openAcct.href = data.links.accounts;
        openAcct.hidden = false;
      }
    })
    .catch(() => {});

  if (heroCountry) heroCountry.value = country.value;
  if (heroHeadcount) {
    const hc = Number(headcount.value) || 50;
    const opts = [...heroHeadcount.options].map((o) => Number(o.value));
    const nearest = opts.reduce((best, n) =>
      Math.abs(n - hc) < Math.abs(best - hc) ? n : best
    );
    heroHeadcount.value = String(nearest);
  }
  heroCountry?.addEventListener("change", () => {
    country.value = heroCountry.value;
    // country "change" already triggers loadCatalog
    country.dispatchEvent(new Event("change"));
  });
  country.addEventListener("change", () => {
    if (heroCountry && heroCountry.value !== country.value) {
      heroCountry.value = country.value;
    }
  });
  const readHeroLead = () => {
    try {
      return JSON.parse(sessionStorage.getItem("bhHeroLead") || "{}") || {};
    } catch (_) {
      return {};
    }
  };

  const saveHeroLead = (lead) => {
    try {
      sessionStorage.setItem("bhHeroLead", JSON.stringify(lead));
    } catch (_) {
      /* ignore quota / private mode */
    }
  };

  const fillDemoCustomer = () => {
    if (!heroForm) return null;
    const stamp = new Date()
      .toISOString()
      .slice(5, 16)
      .replace(/[-:T]/g, "");
    const lead = {
      firstName: "Casey",
      lastName: "Nguyen",
      email: `casey.nguyen+nw${stamp}@northwind.example`,
      company: "Northwind Robotics",
      phone: "415-555-0148",
      jobTitle: "Head of People",
    };
    if (heroForm.firstName) heroForm.firstName.value = lead.firstName;
    if (heroForm.lastName) heroForm.lastName.value = lead.lastName;
    if (heroForm.email) heroForm.email.value = lead.email;
    if (heroForm.company) heroForm.company.value = lead.company;
    if (heroForm.phone) heroForm.phone.value = lead.phone;
    if (heroForm.jobTitle) heroForm.jobTitle.value = lead.jobTitle;
    if (heroCountry) {
      heroCountry.value = "US";
      country.value = "US";
      country.dispatchEvent(new Event("change"));
    }
    if (heroHeadcount) {
      heroHeadcount.value = "50";
      setHeadcount(50);
    }
    saveHeroLead(lead);
    status.textContent =
      "Demo customer loaded: Northwind Robotics — open Salesforce beside this tab, then continue.";
    status.classList.remove("error");
    heroForm.scrollIntoView({ behavior: "smooth", block: "center" });
    return lead;
  };

  document.getElementById("loadDemoCustomer")?.addEventListener("click", fillDemoCustomer);

  heroForm?.addEventListener("submit", (event) => {
    event.preventDefault();
    if (heroCountry) {
      country.value = heroCountry.value;
      country.dispatchEvent(new Event("change"));
    }
    if (heroHeadcount) setHeadcount(heroHeadcount.value);
    const lead = {
      firstName: heroForm.firstName?.value || "",
      lastName: heroForm.lastName?.value || "",
      email: heroForm.email?.value || "",
      company: heroForm.company?.value || "",
      phone: heroForm.phone?.value || "",
      jobTitle: heroForm.jobTitle?.value || "",
    };
    if (!lead.company || !lead.email) {
      status.textContent =
        "Enter company name and work email so we can create your Salesforce Account.";
      status.classList.add("error");
      return;
    }
    status.textContent = "";
    status.classList.remove("error");
    saveHeroLead(lead);
    document.getElementById("plans")?.scrollIntoView({ behavior: "smooth", block: "start" });
    // Keep stickyQuoteId — server reuses/collapses by Account after lead resolve.
    syncEstimate();
  });

  // Prefill hero from a prior visit in this browser session.
  const existingLead = readHeroLead();
  if (heroForm && existingLead.email) {
    if (heroForm.firstName) heroForm.firstName.value = existingLead.firstName || "";
    if (heroForm.lastName) heroForm.lastName.value = existingLead.lastName || "";
    if (heroForm.email) heroForm.email.value = existingLead.email || "";
    if (heroForm.company) heroForm.company.value = existingLead.company || "";
    if (heroForm.phone) heroForm.phone.value = existingLead.phone || "";
    if (heroForm.jobTitle) heroForm.jobTitle.value = existingLead.jobTitle || "";
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    status.classList.remove("error");
    let buyer = readHeroLead();
    // Prefer live hero fields if the user is still on the page.
    if (heroForm) {
      buyer = {
        firstName: heroForm.firstName?.value || buyer.firstName || "",
        lastName: heroForm.lastName?.value || buyer.lastName || "",
        email: heroForm.email?.value || buyer.email || "",
        company: heroForm.company?.value || buyer.company || "",
        phone: heroForm.phone?.value || buyer.phone || "",
        jobTitle: heroForm.jobTitle?.value || buyer.jobTitle || "",
      };
      saveHeroLead(buyer);
    }
    if (!buyer.company || !buyer.email) {
      status.textContent =
        "New customer required: use Get Pricing above with company + work email, then get your quote.";
      status.classList.add("error");
      document.querySelector(".get-pricing-card")?.scrollIntoView({
        behavior: "smooth",
        block: "center",
      });
      return;
    }
    status.textContent = "Creating Account / Contact / Quote in Revenue Cloud…";
    submit.disabled = true;
    try {
      const body = {
        headcount: Number(headcount.value),
        country: country.value,
        planSku: planSku.value,
        addonSkus: selectedAddons(),
        placeQuote: true,
        freeTrial: !!document.getElementById("freeTrial")?.checked,
        buyer,
        previewQuoteId: stickyQuoteId || undefined,
      };
      // If sticky preview is still in-flight, wait for it once.
      if (pricingBusy) {
        status.textContent = "Waiting for Revenue Cloud price…";
        await fetchRcPreview();
        body.previewQuoteId = stickyQuoteId || undefined;
      }
      const resp = await fetch("/api/get-pricing", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Pricing request failed");
      }
      stickyQuoteId = data.quoteId || stickyQuoteId;
      persistStickyQuoteId(stickyQuoteId);
      if (data.quoteUrl) {
        window.location.href = data.quoteUrl;
        return;
      }
      status.textContent = `Net plan $${data.netPepm}/employee · $${data.monthlyTotal}/mo`;
    } catch (err) {
      status.classList.add("error");
      const msg = err && err.message ? String(err.message) : String(err);
      if (/failed to fetch|load failed|networkerror|connection/i.test(msg)) {
        status.textContent =
          "Cannot reach the pricing server. Use http://127.0.0.1:8765/ " +
          "(http, not https) and keep the BFF terminal running.";
      } else {
        status.textContent = msg;
      }
    } finally {
      submit.disabled = false;
    }
  });
})();
