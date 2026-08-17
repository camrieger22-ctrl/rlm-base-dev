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

  let billPeriod = "monthly";
  let wasSmallBiz = false;
  let planBeforeSmallBiz = planSku.value;

  const params = new URLSearchParams(window.location.search);
  const MICRO = params.get("fullCatalog") !== "1";
  const SALES_HANDOFF_URL =
    document.body.dataset.salesHandoffUrl ||
    "mailto:sales@example.com?subject=BambooHR%20self-serve%20handoff";
  const MICRO_MAX_HC = 24;
  const MICRO_PLANS = new Set(["BAMBOO-CORE", "BAMBOO-PRO"]);
  const UTM_KEYS = [
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_content",
    "utm_term",
    "gclid",
    "campaign",
  ];
  const readUtm = () => {
    const utm = {};
    UTM_KEYS.forEach((k) => {
      const v = params.get(k);
      if (v) utm[k] = v;
    });
    return utm;
  };
  let qualifyUtm = readUtm();
  const newQualifyId = () =>
    (window.crypto && crypto.randomUUID && crypto.randomUUID()) ||
    `qs-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  let qualifySessionId = params.get("resume") || "";
  try {
    if (!qualifySessionId) {
      qualifySessionId = sessionStorage.getItem("bhQualifySessionId") || "";
    }
    if (!qualifySessionId) qualifySessionId = newQualifyId();
    sessionStorage.setItem("bhQualifySessionId", qualifySessionId);
  } catch (_) {
    if (!qualifySessionId) qualifySessionId = newQualifyId();
  }
  // Assigned after the wizard DOM helpers exist; showSalesHandoff can call it.
  let persistQualifySession = (_extra) => {};
  let postQualifyHandoff = (_opts) => {};
  let lastBounceType = "";

  const PLAN_NAME = {
    "BAMBOO-CORE": "Core",
    "BAMBOO-PRO": "Pro",
    "BAMBOO-ELITE": "Elite",
  };
  const PLAN_RANK = { "BAMBOO-CORE": 1, "BAMBOO-PRO": 2, "BAMBOO-ELITE": 3 };
  const NEED_TO_PLAN = {
    records: "BAMBOO-CORE",
    hiring: "BAMBOO-CORE",
    onboarding: "BAMBOO-CORE",
    timeoff: "BAMBOO-CORE",
    timetracking: "BAMBOO-CORE",
    performance: "BAMBOO-PRO",
    reporting: "BAMBOO-PRO",
  };
  const NEED_TO_ADDON = {
    timetracking: "BAMBOO-ADD-TIME",
  };

  const recommendFromNeeds = (needs) => {
    let planSku = "BAMBOO-CORE";
    const addonSkus = [];
    for (const n of needs || []) {
      const plan = NEED_TO_PLAN[n];
      if (plan && (PLAN_RANK[plan] || 0) > (PLAN_RANK[planSku] || 0)) {
        planSku = plan;
      }
      if (!MICRO && NEED_TO_ADDON[n]) addonSkus.push(NEED_TO_ADDON[n]);
    }
    return { planSku, addonSkus: [...new Set(addonSkus)] };
  };

  const DEFAULT_HANDOFF_MUTED =
    "Self-serve today is limited to teams under 25 in the US or Canada choosing Core or Pro. Larger teams, other countries, Elite, and Payroll stay on an assisted path.";

  const applyOwnerToHandoff = (lookup = {}) => {
    const owner = (lookup.ownerName || "").trim();
    if (!owner) return;
    const titleEl = document.getElementById("salesHandoffTitle");
    const reasonEl = document.getElementById("salesHandoffReason");
    const mutedEl = document.getElementById("salesHandoffMuted");
    const cta = document.getElementById("salesHandoffCta");
    const brief = document.getElementById("salesHandoffBrief");
    const statusEl = document.getElementById("handoffCaptureStatus");
    if (titleEl) titleEl.textContent = `Connect with ${owner}`;
    if (lookup.reason && reasonEl) reasonEl.textContent = lookup.reason;
    else if (reasonEl && !reasonEl.textContent.includes(owner)) {
      reasonEl.textContent =
        `You’re already working with ${owner}. We’ll reconnect you instead of starting a new self-serve path.`;
    }
    if (mutedEl) {
      mutedEl.textContent =
        `Your work email is already on ${lookup.accountName || "an Account"} owned by ${owner}. We’ll route this to them.`;
    }
    if (cta && !cta.dataset.fixedHref) {
      if (lookup.ownerEmail) {
        cta.href = `mailto:${encodeURIComponent(lookup.ownerEmail)}?subject=${encodeURIComponent(
          "BambooHR — reconnecting from self-serve"
        )}`;
        cta.textContent = `Email ${owner}`;
      } else {
        cta.textContent = `Connect with ${owner}`;
      }
    }
    if (brief) {
      brief.hidden = false;
      brief.textContent = `Already with ${owner} — we’ll keep you on their plate.`;
    }
    if (statusEl && !statusEl.hidden) {
      statusEl.textContent = `Saved for ${owner}. They’ll follow up with your answers.`;
    }
  };

  const showSalesHandoff = (reason, opts = {}) => {
    const card = document.getElementById("qualifyCard");
    const handoff = document.getElementById("salesHandoff");
    const reasonEl = document.getElementById("salesHandoffReason");
    const titleEl = document.getElementById("salesHandoffTitle");
    const mutedEl = document.getElementById("salesHandoffMuted");
    const cta = document.getElementById("salesHandoffCta");
    if (titleEl) {
      titleEl.textContent = opts.title || "Let’s connect you with sales";
    }
    if (reasonEl) reasonEl.textContent = reason;
    if (mutedEl) mutedEl.textContent = opts.muted || DEFAULT_HANDOFF_MUTED;
    if (cta) {
      delete cta.dataset.fixedHref;
      if (opts.ctaHref) {
        cta.href = opts.ctaHref;
        cta.textContent = opts.ctaLabel || "Continue";
        cta.dataset.fixedHref = "1";
      } else {
        cta.href = SALES_HANDOFF_URL;
        cta.textContent = SALES_HANDOFF_URL.startsWith("mailto:")
          ? "Email sales"
          : "Talk to sales";
      }
    }
    if (opts.ownerName || opts.lookup) {
      applyOwnerToHandoff({
        ownerName: opts.ownerName,
        ownerEmail: opts.ownerEmail,
        accountName: opts.accountName,
        reason: opts.ownerReason || reason,
        ...(opts.lookup || {}),
      });
    }
    persistQualifySession({
      bounceReason: reason,
      bounceType: opts.bounceType || lastBounceType || "",
      step: qualifyResumeStep || opts.step || 1,
    });
    lastBounceType = opts.bounceType || lastBounceType || "";
    const ident = {
      email: document.getElementById("hero-lead-form")?.email?.value?.trim() || "",
      company: document.getElementById("hero-lead-form")?.company?.value?.trim() || "",
    };
    const emailEl = document.getElementById("handoffEmail");
    const companyEl = document.getElementById("handoffCompany");
    if (emailEl && !emailEl.value) emailEl.value = ident.email;
    if (companyEl && !companyEl.value) companyEl.value = ident.company;
    const capture = document.getElementById("salesHandoffCapture");
    if (capture) capture.hidden = !!opts.skipHandoff;
    const brief = document.getElementById("salesHandoffBrief");
    if (brief) {
      const hc = document.getElementById("heroHeadcount")?.value || "";
      const geo = document.getElementById("heroCountry")?.value || "";
      brief.hidden = false;
      brief.textContent = `We’ll pass this to a person: ${hc || "—"} employees · ${geo || "—"} · ${lastBounceType || "handoff"}.`;
    }
    if (card) card.hidden = true;
    if (handoff) handoff.hidden = false;
    syncQualifyAgentContext({
      bounceType: lastBounceType,
      bounceReason: reason,
    });
    if (!opts.skipHandoff) {
      const hasIdentity =
        (document.getElementById("handoffEmail")?.value || "").trim() &&
        (document.getElementById("handoffCompany")?.value || "").trim();
      if (hasIdentity) {
        postQualifyHandoff({ reason, bounceType: lastBounceType });
      }
    }
  };

  /** Slice 2b — keep Agent chat page context in sync with the 5-beat wizard. */
  const syncQualifyAgentContext = (extra = {}) => {
    const handoffVisible = !document.getElementById("salesHandoff")?.hidden;
    const bounceType =
      extra.bounceType ??
      (handoffVisible ? lastBounceType || document.body.dataset.bounceType || "" : "");
    const bounceReason =
      extra.bounceReason ??
      (handoffVisible
        ? document.getElementById("salesHandoffReason")?.textContent || ""
        : "");
    if (bounceType) document.body.dataset.bounceType = bounceType;
    else delete document.body.dataset.bounceType;
    if (bounceReason) document.body.dataset.bounceReason = bounceReason;
    else delete document.body.dataset.bounceReason;
    window.BH_QUALIFY_CONTEXT = {
      qualifyStep: Number(document.body.dataset.qualifyStep || 0) || null,
      bounceType: bounceType || null,
      bounceReason: bounceReason || null,
      sessionId: sessionStorage.getItem("bhQualifySessionId") || null,
      headcount: Number(document.getElementById("heroHeadcount")?.value || 0) || null,
    };
    try {
      document.dispatchEvent(new CustomEvent("bh-agent-context-refresh"));
    } catch (_) {
      /* ignore */
    }
  };

  const setQualifyStep = (step) => {
    const steps = [
      document.getElementById("qwStep1"),
      document.getElementById("qwStep2"),
      document.getElementById("qwStep3"),
      document.getElementById("qwStep4"),
      document.getElementById("qwStep5"),
    ];
    steps.forEach((el, i) => {
      if (el) el.hidden = i + 1 !== step;
    });
    document.querySelectorAll("[data-qw-progress]").forEach((el) => {
      const n = Number(el.dataset.qwProgress);
      el.classList.toggle("is-active", n === step);
      el.classList.toggle("is-done", n < step);
    });
    const heading = document.getElementById(`qwHeading${step}`);
    heading?.focus({ preventScroll: true });
    document.body.dataset.qualifyStep = String(step);
    syncQualifyAgentContext();
  };

  let qualifyResumeStep = 1;

  const hideSalesHandoff = () => {
    const step = qualifyResumeStep || 1;
    const heroHc = document.getElementById("heroHeadcount");
    if (step === 1 && heroHc && Number(heroHc.value) >= 25) {
      heroHc.value = "15";
      // Push the reset to the pricing rail too, or the rail keeps the old count
      // and quoted price, agent context, and wizard disagree.
      syncWizardHeadcountToRail();
    }
    if (step === 2) {
      const heroCtry = document.getElementById("heroCountry");
      if (heroCtry) heroCtry.value = "US";
      document.querySelectorAll('input[name="ctryBand"]').forEach((el) => {
        el.checked = el.value === "US";
      });
      if (country.value !== "US") {
        country.value = "US";
        country.dispatchEvent(new Event("change"));
      }
    }
    if (step === 3) {
      document
        .querySelectorAll('input[name="need"][value="payroll"], input[name="need"][value="elite"]')
        .forEach((el) => {
          el.checked = false;
        });
    }
    const card = document.getElementById("qualifyCard");
    const handoff = document.getElementById("salesHandoff");
    const titleEl = document.getElementById("salesHandoffTitle");
    const mutedEl = document.getElementById("salesHandoffMuted");
    if (titleEl) titleEl.textContent = "Let’s connect you with sales";
    if (mutedEl) mutedEl.textContent = DEFAULT_HANDOFF_MUTED;
    if (handoff) handoff.hidden = true;
    if (card) card.hidden = false;
    lastBounceType = "";
    setQualifyStep(qualifyResumeStep || 1);
    syncQualifyAgentContext({ bounceType: "", bounceReason: "" });
  };

  document.getElementById("salesHandoffBack")?.addEventListener("click", hideSalesHandoff);

  if (MICRO) {
    document.body.classList.add("micro-mode");
    document.querySelectorAll(".micro-only-hide").forEach((el) => {
      el.hidden = true;
    });
    // Drop UK from header country when micro (hero still lists it to trigger handoff).
    [...country.querySelectorAll('option[value="UK"]')].forEach((o) => o.remove());
    if (headcount) {
      headcount.max = String(MICRO_MAX_HC);
      if (Number(headcount.value) > MICRO_MAX_HC) headcount.value = "15";
    }
    if (hcRange) {
      hcRange.max = String(MICRO_MAX_HC);
      if (Number(hcRange.value) > MICRO_MAX_HC) hcRange.value = headcount.value;
    }
  }

  /** Clear legacy sticky-Quote session key from pre–Phase 1 previews. */
  try {
    sessionStorage.removeItem("bhStickyQuoteId");
  } catch (_) {
    /* ignore */
  }
  let estimateTimer = null;
  let estimateSeq = 0;
  let estimateInFlight = false;
  let estimateNeedsRerun = false;
  let pricingBusy = false;
  let lastRcPricing = null;

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

  // Self-serve models Core/Pro at standard list PEPM — no BAMBOO-CORE-FLAT-SM.
  const usesFlat = () => false;

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
    if (MICRO && !MICRO_PLANS.has(sku)) {
      status.textContent =
        "Elite isn’t available on self-serve — stay on Core or Pro, or talk to sales.";
      status.classList.add("error");
      return;
    }
    planSku.value = sku;
    planCards.forEach((card) => {
      const on = card.dataset.plan === sku;
      card.setAttribute("aria-checked", on ? "true" : "false");
    });
    syncPlanFooters();
    syncPlanLocks();
    syncEstimate();
  };

  const syncPlanLocks = () => {
    planCards.forEach((card) => {
      // Core + Pro always selectable on micro; full catalog unlocks Elite too.
      const lock = MICRO && !MICRO_PLANS.has(card.dataset.plan || "");
      card.classList.toggle("is-locked", lock);
      card.setAttribute("aria-disabled", lock ? "true" : "false");
      card.tabIndex = lock ? -1 : 0;
    });
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
      if (btn.disabled) return;
      setBillPeriod(btn.dataset.bill);
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

  const syncHeroHeadcountSelect = (hc) => {
    const heroHc = document.getElementById("heroHeadcount");
    if (!heroHc) return;
    const n = Math.max(1, Number(hc) || 1);
    if (heroHc.value !== String(n)) heroHc.value = String(n);
  };

  const setHeadcount = (n, { fromSlider, fromHero } = {}) => {
    const maxHc = MICRO ? MICRO_MAX_HC : 100000;
    let hc = Math.max(1, Math.min(maxHc, Number(n) || 1));
    headcount.value = String(hc);
    if (hcRange && !fromSlider) {
      hcRange.value = String(Math.min(Number(hcRange.max) || maxHc, hc));
    }
    document.querySelectorAll("#hcPresets button").forEach((b) => {
      b.classList.toggle("on", Number(b.dataset.hc) === hc);
    });
    // Keep the Get Pricing hero employee band in sync (unless it just drove this update).
    if (!fromHero) {
      syncHeroHeadcountSelect(hc);
    }
    // Core/Pro at list PEPM for any headcount; only clamp Elite off micro path.
    if (MICRO && planSku.value === "BAMBOO-ELITE") {
      selectPlan("BAMBOO-CORE");
      return;
    }
    syncPlanLocks();
    wasSmallBiz = isSmallBizHeadcount();
    syncEstimate();
  };

  const readStartDate = () => {
    const el = document.getElementById("startDateInput");
    const v = el?.value;
    if (v) return v;
    return new Date().toISOString().slice(0, 10);
  };

  const readTermMonths = () => {
    const el = document.getElementById("termMonths");
    const n = Number(el?.value || 1);
    return [1, 12, 24, 36].includes(n) ? n : 1;
  };

  const setBillPeriod = (period) => {
    billPeriod = period === "annual" ? "annual" : "monthly";
    document.querySelectorAll(".bill-opt").forEach((b) => {
      b.setAttribute(
        "aria-pressed",
        b.dataset.bill === billPeriod ? "true" : "false"
      );
    });
  };

  const updateTermHint = () => {
    const hint = document.getElementById("termHint");
    if (!hint) return;
    const trial = !!document.getElementById("freeTrial")?.checked;
    const start = readStartDate();
    const months = readTermMonths();
    const termEl = document.getElementById("termMonths");
    if (termEl) termEl.disabled = trial;
    // Month-to-month: rail shows monthly only. Committed terms can toggle monthly vs term total.
    document.querySelectorAll('.bill-opt[data-bill="annual"]').forEach((b) => {
      b.disabled = months === 1 || trial;
      if (months === 1 && billPeriod === "annual") setBillPeriod("monthly");
    });
    if (trial) {
      hint.textContent = `Starts ${start} · free trial ends 30 days later (term selection applies after convert).`;
    } else if (months === 1) {
      hint.textContent = `Starts ${start} · month-to-month (PEPM) · Quote lines use a 1-month Term Monthly window.`;
    } else {
      hint.textContent = `Starts ${start} · ${months}-month commitment (PEPM billed monthly) · Quote EndDate = start + ${months} months.`;
    }
  };

  const currentBuyer = () => {
    let buyer = {};
    try {
      buyer = JSON.parse(sessionStorage.getItem("bhHeroLead") || "{}") || {};
    } catch (_) {
      buyer = {};
    }
    const val = (id) => document.getElementById(id)?.value?.trim() || "";
    const hf = document.getElementById("hero-lead-form");
    const needs = [
      ...(hf?.querySelectorAll('input[name="need"]:checked') || []),
    ]
      .map((el) => el.value)
      .filter((n) => n && n !== "payroll" && n !== "elite");
    const dmRole =
      hf?.querySelector('input[name="dmRole"]:checked')?.value ||
      buyer.dmRole ||
      "";
    // Rail is the live editor after "See what we recommend"; wizard fields stay as fallback.
    return {
      firstName: val("buyerFirst") || hf?.firstName?.value?.trim() || buyer.firstName || "",
      lastName: val("buyerLast") || hf?.lastName?.value?.trim() || buyer.lastName || "",
      email: val("buyerEmail") || hf?.email?.value?.trim() || buyer.email || "",
      company: val("buyerCompany") || hf?.company?.value?.trim() || buyer.company || "",
      phone: buyer.phone || "",
      jobTitle: hf?.jobTitle?.value?.trim() || buyer.jobTitle || "",
      needs: needs.length ? needs : buyer.needs || [],
      dmRole,
      sessionId: qualifySessionId,
      utm: qualifyUtm,
    };
  };

  const syncRailBuyerToWizard = () => {
    const hf = document.getElementById("hero-lead-form");
    const copy = (railId, field) => {
      const railEl = document.getElementById(railId);
      if (!hf || !railEl || !hf[field]) return;
      hf[field].value = railEl.value;
    };
    copy("buyerCompany", "company");
    copy("buyerEmail", "email");
    copy("buyerFirst", "firstName");
    copy("buyerLast", "lastName");
    saveHeroLead({ ...readHeroLead(), ...currentBuyer() });
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
    termMonths,
  }) => {
    const months = Number(termMonths) || readTermMonths();
    const termTotal = round2(monthly * months);
    const annual = round2(monthly * 12);
    const total = billPeriod === "annual" ? termTotal : monthly;
    document.getElementById("railPepm").textContent = money(pepmDisplay);
    document.getElementById("railPepmUnit").textContent = flat
      ? `effective / emp · ${cur} flat package`
      : `per employee / month · ${cur}`;
    document.getElementById("railBill").textContent =
      billPeriod === "annual"
        ? `Billed · ${months}-month term`
        : "Billed monthly";
    document.getElementById("railSubLabel").textContent =
      billPeriod === "annual"
        ? `Subscription, ${months} mo`
        : "Subscription, per month";
    document.getElementById("railSub").textContent = `$${money(
      billPeriod === "annual" ? termTotal : monthly
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
    void annual;
  };

  const schedulePricingEstimate = () => {
    if (estimateTimer) clearTimeout(estimateTimer);
    // Pricing API is ~1–2s — shorter debounce than sticky Quote System reprice.
    estimateTimer = setTimeout(() => fetchPricingEstimate(), 350);
  };

  const fetchPricingEstimate = async () => {
    if (estimateInFlight) {
      estimateNeedsRerun = true;
      return;
    }
    estimateInFlight = true;
    estimateNeedsRerun = false;
    const seq = ++estimateSeq;
    setRailBusy(true, "Pricing with Salesforce Pricing API…");
    try {
      const body = {
        headcount: Number(headcount.value) || 1,
        country: country.value,
        planSku: planSku.value,
        addonSkus: selectedAddons(),
        freeTrial: !!document.getElementById("freeTrial")?.checked,
        startDate: readStartDate(),
        termMonths: readTermMonths(),
      };
      const resp = await fetch("/api/get-pricing-estimate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (seq !== estimateSeq) return;
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Estimate failed");
      }
      lastRcPricing = data;
      const hc = Number(data.headcount) || Number(headcount.value) || 1;
      const cur = data.currency || currency();
      let flat = !!data.smallBizFlat;
      const trial = !!data.freeTrial;
      // Prefer live usesFlat() so Core ≤25 never paints a $0 API glitch.
      if (usesFlat()) flat = true;
      let lines = (data.lineItems || []).map((li) => {
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
      // Catalog flat when Pricing API returns $0 for BAMBOO-CORE-FLAT-SM.
      if (flat && !trial && monthly < 0.01) {
        const fp = flatPrice();
        const planLine = lines.find((l) => /flat|core/i.test(l.name || ""));
        const addonTotal = lines
          .filter((l) => l !== planLine)
          .reduce((s, l) => s + (Number(l.amt) || 0), 0);
        monthly = round2(fp + addonTotal);
        pepmDisplay = hc > 0 ? round2(monthly / hc) : fp;
        lines = [
          {
            name: `${PLAN_LABELS[planSku.value] || "Core"} (flat · ≤25)`,
            calc: `${money(fp)} / mo flat · qty 1`,
            listAmt: null,
            amt: fp,
          },
          ...lines.filter((l) => l !== planLine),
        ];
      }
      if (trial) {
        pepmDisplay = 0;
      }
      const srcLabel =
        data.pricingSource === "localFallback"
          ? "Local estimate (Pricing API unavailable)"
          : "Priced with Salesforce Pricing API";
      paintRailFromLines({
        lines,
        monthly,
        pepmDisplay,
        flat,
        cur,
        sourceNote: srcLabel,
        termMonths: Number(data.termMonths) || readTermMonths(),
      });
    } catch (err) {
      if (seq !== estimateSeq) return;
      const src = document.getElementById("railSource");
      if (src) {
        src.textContent = `Pricing API unavailable — showing local estimate. ${
          err.message || ""
        }`;
      }
    } finally {
      estimateInFlight = false;
      if (estimateNeedsRerun) {
        estimateNeedsRerun = false;
        fetchPricingEstimate();
      } else if (seq === estimateSeq) {
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

    // Local estimate immediately; Pricing API replaces shortly (no Quote).
    paintRailFromLines({
      lines,
      monthly,
      pepmDisplay,
      flat,
      cur,
      sourceNote: "Local estimate — pricing with Salesforce…",
      termMonths: readTermMonths(),
    });
    updateTermHint();
    schedulePricingEstimate();
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
  document.getElementById("freeTrial")?.addEventListener("change", () => {
    updateTermHint();
    syncEstimate();
  });
  document.getElementById("startDateInput")?.addEventListener("change", () => {
    updateTermHint();
    syncEstimate();
  });
  document.getElementById("termMonths")?.addEventListener("change", () => {
    if (readTermMonths() === 1) setBillPeriod("monthly");
    updateTermHint();
    syncEstimate();
  });

  const startEl = document.getElementById("startDateInput");
  if (startEl && !startEl.value) {
    startEl.value = new Date().toISOString().slice(0, 10);
  }
  updateTermHint();

  catalogBadge = document.getElementById("catalogSource");
  syncCountryAddons();
  wasSmallBiz = isSmallBizHeadcount();
  // Default Core on micro; full catalog keeps current / Pro.
  if (MICRO) {
    selectPlan("BAMBOO-CORE");
  } else {
    selectPlan(planSku.value || "BAMBOO-PRO");
  }
  loadCatalog();

  const heroForm = document.getElementById("hero-lead-form");
  const heroCountry = document.getElementById("heroCountry");
  const heroHeadcount = document.getElementById("heroHeadcount");

  const visibleQualifyStep = () =>
    [1, 2, 3, 4, 5].find((n) => {
      const el = document.getElementById(`qwStep${n}`);
      return el && !el.hidden;
    }) || 1;

  const collectQualifyPayload = (extra = {}) => {
    const ident = {
      company: heroForm?.company?.value?.trim() || "",
      email: heroForm?.email?.value?.trim() || "",
      firstName: heroForm?.firstName?.value?.trim() || "",
      lastName: heroForm?.lastName?.value?.trim() || "",
    };
    const needs = [
      ...(heroForm?.querySelectorAll('input[name="need"]:checked') || []),
    ].map((el) => el.value);
    return {
      sessionId: qualifySessionId,
      step: extra.step != null ? extra.step : visibleQualifyStep(),
      headcount: Number(heroHeadcount?.value || headcount.value || 0) || null,
      country: heroCountry?.value || country.value || "",
      needs,
      dmRole: heroForm?.querySelector('input[name="dmRole"]:checked')?.value || "",
      email: ident.email,
      company: ident.company,
      firstName: ident.firstName,
      lastName: ident.lastName,
      utm: qualifyUtm,
      ...extra,
    };
  };

  persistQualifySession = (extra = {}) => {
    fetch("/api/qualify-session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(collectQualifyPayload(extra)),
    }).catch(() => {});
  };

  postQualifyHandoff = async (opts = {}) => {
    const email =
      document.getElementById("handoffEmail")?.value?.trim() ||
      heroForm?.email?.value?.trim() ||
      "";
    const company =
      document.getElementById("handoffCompany")?.value?.trim() ||
      heroForm?.company?.value?.trim() ||
      "";
    const statusEl = document.getElementById("handoffCaptureStatus");
    const errEl = document.getElementById("handoffCaptureError");
    if (!email || !company) {
      if (errEl) {
        errEl.hidden = false;
        errEl.textContent =
          "Add work email and company so we can connect you with a person — we won’t lose this.";
      }
      if (statusEl) statusEl.hidden = true;
      return false;
    }
    if (errEl) {
      errEl.hidden = true;
      errEl.textContent = "";
    }
    if (statusEl) {
      statusEl.hidden = false;
      statusEl.textContent = "Saving this for sales…";
    }
    try {
      const buyer = {
        ...collectQualifyPayload({ step: qualifyResumeStep || 1 }),
        email,
        company,
      };
      const resp = await fetch("/api/qualify-handoff", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          buyer,
          headcount: buyer.headcount,
          country: buyer.country,
          bounceReason: opts.reason || "",
          bounceType: opts.bounceType || lastBounceType || "",
        }),
      });
      const data = await resp.json();
      if (data.status === "existingCustomer" && applyQualifyOutcome(data)) {
        return true;
      }
      // Already sales-working before this bounce (open Quote / prior handoff) —
      // switch to the dual-motion panel. Fresh Payroll/size/geo bounces keep
      // the bounce panel + “saved for sales” copy (alreadyWorking=false).
      if (data.alreadyWorking && applyQualifyOutcome(data)) {
        return true;
      }
      if (!data.ok) {
        throw new Error(data.error || "Could not save this for sales.");
      }
      // Size/Payroll bounce + known AE: personalize after save.
      try {
        const looked = await lookupQualifyEmail(email);
        if (looked?.ownerName) applyOwnerToHandoff(looked);
      } catch (_) {
        /* ignore */
      }
      if (statusEl) {
        statusEl.hidden = false;
        const ownerEl = document.getElementById("salesHandoffTitle")?.textContent || "";
        const named = /^Connect with (.+)$/.exec(ownerEl);
        statusEl.textContent = data.taskId
          ? named
            ? `You’re with ${named[1]} — they have your answers.`
            : "You’re in the sales queue — a specialist has your answers."
          : named
            ? `Saved for ${named[1]}.`
            : "Saved for sales. A specialist will follow up.";
      }
      return true;
    } catch (err) {
      if (errEl) {
        errEl.hidden = false;
        errEl.textContent = err.message || String(err);
      }
      return false;
    }
  };

  document.getElementById("salesHandoffCaptureBtn")?.addEventListener("click", () => {
    postQualifyHandoff({
      reason: document.getElementById("salesHandoffReason")?.textContent || "",
      bounceType: lastBounceType,
    });
  });

  document.getElementById("handoffEmail")?.addEventListener("blur", async () => {
    const email = document.getElementById("handoffEmail")?.value?.trim() || "";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return;
    try {
      const looked = await lookupQualifyEmail(email);
      if (looked?.status === "existingCustomer") {
        applyQualifyOutcome(looked);
        return;
      }
      if (looked?.status === "salesWorking") {
        applyQualifyOutcome(looked);
        return;
      }
      if (looked?.ownerName) applyOwnerToHandoff(looked);
    } catch (_) {
      /* ignore */
    }
  });

  const lookupQualifyEmail = async (email) => {
    const resp = await fetch("/api/qualify-lookup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, sessionId: qualifySessionId }),
    });
    return resp.json();
  };

  const applyQualifyOutcome = (lookup) => {
    if (!lookup || lookup.status === "selfServe") {
      if (lookup?.ownerName && !document.getElementById("salesHandoff")?.hidden) {
        applyOwnerToHandoff(lookup);
      }
      return false;
    }
    if (lookup.status === "existingCustomer") {
      qualifyResumeStep = 5;
      showSalesHandoff(lookup.reason || "You already have BambooHR — sign in.", {
        title: "You already have BambooHR",
        ctaHref: lookup.signInUrl || "/account",
        ctaLabel: "Sign in to Licenses",
        muted:
          "This work email is on an Account with licenses. Sign in instead of starting a new self-serve Quote.",
        step: 5,
        skipHandoff: true,
      });
      return true;
    }
    if (lookup.status === "salesWorking") {
      qualifyResumeStep = 5;
      const owner = (lookup.ownerName || "").trim();
      showSalesHandoff(
        lookup.reason ||
          (owner
            ? `You’re already working with ${owner}.`
            : "Sales is already working this."),
        {
          title: owner ? `Connect with ${owner}` : "Sales is already working this",
          muted: owner
            ? `There’s already an open Quote with ${owner}. We will not start a competing self-serve Quote.`
            : "There’s already an open Quote in Salesforce for this Account. We will not start a competing self-serve Quote.",
          step: 5,
          bounceType: "salesWorking",
          lookup,
          ownerName: owner,
          ownerEmail: lookup.ownerEmail,
          accountName: lookup.accountName,
        }
      );
      return true;
    }
    return false;
  };
  const NEED_LABELS = {
    records: "Employee records",
    hiring: "Hiring",
    onboarding: "Onboarding",
    timeoff: "Time off",
    timetracking: "Time tracking",
    performance: "Performance",
    reporting: "Reporting",
  };
  const SALES_NEEDS = new Set(["payroll", "elite"]);
  const SIZE_HANDOFF =
    "Self-serve is for teams under 25 employees. With 25+, a specialist will help you choose the right plan.";
  const GEO_HANDOFF =
    "Self-serve is US and Canada only right now. We’ll connect you with sales for other countries.";
  const PAYROLL_HANDOFF =
    "Payroll isn’t on the unassisted path. You’re qualified to talk to a person — we’ll get Payroll set up with Core or Pro.";
  const ELITE_HANDOFF =
    "Elite (compensation and benchmarks) isn’t on self-serve acquisition. You’re qualified to talk to a person.";

  const productNeeds = (needs) => (needs || []).filter((n) => !SALES_NEEDS.has(n));

  const fillWizardBuyer = (lead) => {
    if (!heroForm) return;
    if (heroForm.company && lead.company) heroForm.company.value = lead.company;
    if (heroForm.email && lead.email) heroForm.email.value = lead.email;
    if (heroForm.firstName && lead.firstName) heroForm.firstName.value = lead.firstName;
    if (heroForm.lastName && lead.lastName) heroForm.lastName.value = lead.lastName;
  };

  const fillRailBuyer = (lead) => {
    const set = (id, v) => {
      const el = document.getElementById(id);
      if (el && v) el.value = v;
    };
    set("buyerCompany", lead.company);
    set("buyerEmail", lead.email);
    set("buyerFirst", lead.firstName);
    set("buyerLast", lead.lastName);
  };

  const readWizardIdentity = () => ({
    company: heroForm?.company?.value?.trim() || "",
    email: heroForm?.email?.value?.trim() || "",
    firstName: heroForm?.firstName?.value?.trim() || "",
    lastName: heroForm?.lastName?.value?.trim() || "",
  });

  const showFieldError = (id, msg) => {
    const el = document.getElementById(id);
    if (!el) return false;
    el.hidden = !msg;
    el.textContent = msg || "";
    return !msg;
  };

  const showIdentityError = (msg) => showFieldError("qwIdentityError", msg);

  const advanceFromIdentity = () => {
    const ident = readWizardIdentity();
    if (!ident.company || !ident.email) {
      showIdentityError("Company and work email are required to create your account.");
      (ident.company ? heroForm?.email : heroForm?.company)?.focus();
      return false;
    }
    if (ident.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(ident.email)) {
      showIdentityError("Enter a valid work email.");
      heroForm?.email?.focus();
      return false;
    }
    showIdentityError("");
    fillRailBuyer(ident);
    saveHeroLead({ ...readHeroLead(), ...ident });
    persistQualifySession({ step: 5 });
    return true;
  };

  const syncCountryTile = (code) => {
    if (!heroCountry) return;
    heroCountry.value = code;
    document.querySelectorAll('input[name="ctryBand"]').forEach((el) => {
      el.checked = el.value === code;
    });
  };

  const applyNeedRecommendation = (needs) => {
    const rec = recommendFromNeeds(productNeeds(needs));
    selectPlan(rec.planSku);
    markRecommended(rec.planSku);
    if (!MICRO) {
      form.querySelectorAll('input[name="addon"]').forEach((el) => {
        el.checked = rec.addonSkus.includes(el.value);
      });
    }
    return rec;
  };

  const updateRecommendHint = () => {
    const el = document.getElementById("qwRecommend");
    if (!heroForm) return;
    const needs = productNeeds(
      [...heroForm.querySelectorAll('input[name="need"]:checked')].map((i) => i.value)
    );
    const rec = applyNeedRecommendation(needs);
    const plan = PLAN_NAME[rec.planSku] || "Core";
    const needWords = needs.map((n) => NEED_LABELS[n] || n);
    if (el) {
      el.innerHTML = needWords.length
        ? `We’ll select <strong>${plan}</strong> from ${needWords.join(", ")}.`
        : `We’ll select <strong>Core</strong> — pick needs to change the plan.`;
    }
    const recap = document.getElementById("qualifyRecap");
    if (recap && !recap.hidden) {
      recap.textContent = needWords.length
        ? `Selected ${plan} from ${needWords.join(", ")}.`
        : `Selected Core.`;
    }
  };

  const markRecommended = (sku) => {
    planCards.forEach((card) => {
      const on = card.dataset.plan === sku;
      card.classList.toggle("is-recommended", on);
      const banner = card.querySelector("[data-plan-banner]");
      if (!banner) return;
      if (on) {
        banner.textContent = "Recommended for you";
        banner.classList.remove("plan-banner--spacer");
        banner.removeAttribute("aria-hidden");
      } else if (card.dataset.plan === "BAMBOO-PRO") {
        banner.textContent = "Most popular";
        banner.classList.remove("plan-banner--spacer");
        banner.removeAttribute("aria-hidden");
      } else {
        banner.textContent = "";
        banner.classList.add("plan-banner--spacer");
        banner.setAttribute("aria-hidden", "true");
      }
    });
  };

  const gateSize = () => {
    const hc = Number(heroHeadcount?.value || 0);
    if (MICRO && hc >= 25) return SIZE_HANDOFF;
    return null;
  };

  const sizeInvalid = () => {
    const hc = Number(heroHeadcount?.value);
    if (!Number.isFinite(hc) || hc < 1) {
      return "Enter how many employees you have.";
    }
    return null;
  };

  const gateCountry = () => {
    const ctry = heroCountry?.value || "US";
    if (MICRO && ctry === "UK") return GEO_HANDOFF;
    return null;
  };

  const gateNeeds = () => {
    const picked = [...(heroForm?.querySelectorAll('input[name="need"]:checked') || [])].map(
      (el) => el.value
    );
    if (MICRO && picked.includes("payroll")) return PAYROLL_HANDOFF;
    if (MICRO && picked.includes("elite")) return ELITE_HANDOFF;
    return null;
  };

  const needsBounceType = () => {
    const picked = [
      ...(heroForm?.querySelectorAll('input[name="need"]:checked') || []),
    ].map((el) => el.value);
    if (picked.includes("elite")) return "elite";
    if (picked.includes("payroll")) return "payroll";
    return "needs";
  };

  const bounceIf = (reason, resumeStep, bounceType) => {
    if (!reason) return false;
    qualifyResumeStep = resumeStep;
    lastBounceType = bounceType || lastBounceType || "";
    showSalesHandoff(reason, { step: resumeStep, bounceType: lastBounceType });
    return true;
  };

  const syncWizardHeadcountToRail = () => {
    const hc = Number(heroHeadcount?.value || 0);
    if (!Number.isFinite(hc) || hc < 1) return;
    if (MICRO && hc >= 25) return;
    setHeadcount(String(hc), { fromHero: true });
  };

  if (heroCountry) heroCountry.value = country.value === "UK" ? "US" : country.value;
  syncCountryTile(heroCountry?.value || "US");
  if (heroHeadcount) {
    syncHeroHeadcountSelect(Number(headcount.value) || 15);
  }

  document.getElementById("qwHcMinus")?.addEventListener("click", () => {
    const n = Math.max(1, Number(heroHeadcount?.value || 1) - 1);
    if (heroHeadcount) heroHeadcount.value = String(n);
    showFieldError("qwSizeError", "");
    syncWizardHeadcountToRail();
  });
  document.getElementById("qwHcPlus")?.addEventListener("click", () => {
    const cur = Number(heroHeadcount?.value || 1);
    const n = MICRO ? Math.min(MICRO_MAX_HC, cur + 1) : cur + 1;
    if (heroHeadcount) heroHeadcount.value = String(Math.max(1, n));
    showFieldError("qwSizeError", "");
    syncWizardHeadcountToRail();
  });
  heroHeadcount?.addEventListener("change", () => {
    showFieldError("qwSizeError", "");
    if (bounceIf(gateSize(), 1, "size")) return;
    syncWizardHeadcountToRail();
  });
  document.getElementById("qwHcSales")?.addEventListener("click", () => {
    bounceIf(SIZE_HANDOFF, 1, "size");
  });

  heroForm?.querySelectorAll('input[name="ctryBand"]').forEach((el) => {
    el.addEventListener("change", () => {
      if (!el.checked || !heroCountry) return;
      heroCountry.value = el.value;
      if (el.value === "US" || el.value === "CA") {
        country.value = el.value;
        country.dispatchEvent(new Event("change"));
      }
      bounceIf(gateCountry(), 2, "geo");
    });
  });
  heroForm?.querySelectorAll('input[name="need"]').forEach((el) => {
    el.addEventListener("change", () => {
      if (
        el.checked &&
        SALES_NEEDS.has(el.value) &&
        bounceIf(gateNeeds(), 3, el.value === "elite" ? "elite" : "payroll")
      )
        return;
      persistQualifySession({ step: 3 });
      updateRecommendHint();
    });
  });

  country.addEventListener("change", () => {
    if (country.value === "US" || country.value === "CA") {
      syncCountryTile(country.value);
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

  heroForm?.email?.addEventListener("blur", async () => {
    persistQualifySession({ step: 5 });
    const email = heroForm.email?.value?.trim() || "";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return;
    try {
      const looked = await lookupQualifyEmail(email);
      applyQualifyOutcome(looked);
    } catch (_) {
      /* Get your quote is the second gate. */
    }
  });
  ["firstName", "lastName", "company"].forEach((name) => {
    heroForm?.[name]?.addEventListener("blur", () => persistQualifySession({ step: 5 }));
  });

  ["buyerCompany", "buyerEmail", "buyerFirst", "buyerLast"].forEach((id) => {
    document.getElementById(id)?.addEventListener("change", syncRailBuyerToWizard);
    document.getElementById(id)?.addEventListener("blur", syncRailBuyerToWizard);
  });

  document.querySelectorAll("[data-qw-next]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const next = Number(btn.dataset.qwNext);
      if (next === 2) {
        const invalid = sizeInvalid();
        if (invalid) {
          showFieldError("qwSizeError", invalid);
          heroHeadcount?.focus();
          return;
        }
        if (bounceIf(gateSize(), 1, "size")) return;
        showFieldError("qwSizeError", "");
        syncWizardHeadcountToRail();
        qualifyResumeStep = 2;
        setQualifyStep(2);
        persistQualifySession({ step: 2 });
        return;
      }
      if (next === 3) {
        if (bounceIf(gateCountry(), 2, "geo")) return;
        qualifyResumeStep = 3;
        setQualifyStep(3);
        persistQualifySession({ step: 3 });
        updateRecommendHint();
        return;
      }
      if (next === 4) {
        if (bounceIf(gateNeeds(), 3, needsBounceType())) return;
        qualifyResumeStep = 4;
        setQualifyStep(4);
        persistQualifySession({ step: 4 });
        return;
      }
      if (next === 5) {
        const role = heroForm?.querySelector('input[name="dmRole"]:checked')?.value;
        if (!role) {
          showFieldError("qwRoleError", "Pick how you’re involved in the buying decision.");
          return;
        }
        showFieldError("qwRoleError", "");
        qualifyResumeStep = 5;
        setQualifyStep(5);
        persistQualifySession({ step: 5 });
      }
    });
  });

  document.querySelectorAll("[data-qw-goto]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const n = Number(btn.dataset.qwGoto);
      if (Number.isFinite(n)) setQualifyStep(n);
    });
  });

  heroForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const visible = visibleQualifyStep();
    if (visible && visible < 5) {
      document.querySelector(`#qwStep${visible} [data-qw-next]`)?.click();
      return;
    }
    if (!advanceFromIdentity()) {
      setQualifyStep(5);
      return;
    }
    persistQualifySession({ step: 5 });
    const ident = readWizardIdentity();
    const recBtn = heroForm.querySelector('button[type="submit"]');
    if (recBtn) recBtn.disabled = true;
    try {
      const looked = await lookupQualifyEmail(ident.email);
      if (applyQualifyOutcome(looked)) return;
      const committed = await fetch("/api/qualify-commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          headcount: Number(heroHeadcount?.value || headcount.value || 0),
          country: heroCountry?.value || country.value || "US",
          buyer: { ...collectQualifyPayload({ step: 5 }), ...ident },
        }),
      }).then((r) => r.json());
      if (applyQualifyOutcome(committed)) return;
    } catch (_) {
      /* Get your quote is the second gate if lookup/commit is down. */
    } finally {
      if (recBtn) recBtn.disabled = false;
    }
    if (bounceIf(gateSize(), 1, "size")) return;
    if (bounceIf(gateCountry(), 2, "geo")) return;
    if (bounceIf(gateNeeds(), 3, needsBounceType())) return;
    const hc = Number(heroHeadcount?.value || headcount.value || 0);
    const ctry = heroCountry?.value || country.value || "US";
    const needs = [...(heroForm.querySelectorAll('input[name="need"]:checked') || [])].map(
      (el) => el.value
    );
    const planNeeds = productNeeds(needs);
    const needPayroll = needs.includes("payroll");
    const dmRole = heroForm.querySelector('input[name="dmRole"]:checked')?.value || "own";
    const decisionMaker = dmRole === "own" || dmRole === "influence";

    if (heroCountry && (heroCountry.value === "US" || heroCountry.value === "CA")) {
      country.value = heroCountry.value;
      country.dispatchEvent(new Event("change"));
    }
    if (heroHeadcount) {
      const clamped = MICRO ? Math.min(hc, MICRO_MAX_HC) : hc;
      setHeadcount(String(clamped), { fromHero: true });
    }
    const prior = readHeroLead();
    const lead = {
      firstName: ident.firstName || prior.firstName || "",
      lastName: ident.lastName || prior.lastName || "",
      email: ident.email || prior.email || "",
      company: ident.company || prior.company || "",
      phone: prior.phone || "",
      jobTitle: prior.jobTitle || "",
      needs: planNeeds,
      needPayroll,
      decisionMaker,
      dmRole,
      headcount: hc,
      country: ctry,
      micro: MICRO,
    };
    status.textContent = "";
    status.classList.remove("error");
    saveHeroLead(lead);
    fillRailBuyer(lead);
    try {
      sessionStorage.setItem("bhQualify", JSON.stringify(lead));
    } catch (_) {
      /* ignore */
    }
    persistQualifySession({ step: 5 });
    const rec = applyNeedRecommendation(planNeeds);
    const recap = document.getElementById("qualifyRecap");
    const switchHint = document.getElementById("qualifySwitchHint");
    const recName = PLAN_NAME[rec.planSku] || "Core";
    const otherName = rec.planSku === "BAMBOO-PRO" ? "Core" : "Pro";
    if (recap) {
      const needWords = planNeeds.map((n) => NEED_LABELS[n] || n);
      recap.hidden = false;
      recap.textContent = needWords.length
        ? `We recommend ${recName} from ${needWords.join(", ")}.`
        : `We recommend ${recName}.`;
    }
    if (switchHint) {
      switchHint.hidden = false;
      switchHint.textContent = `Click ${otherName} if you’d rather start there — both plans stay on this page.`;
    }
    if (MICRO) {
      form.querySelectorAll('input[name="addon"]').forEach((el) => {
        el.checked = false;
      });
      const trial = document.getElementById("freeTrial");
      if (trial) trial.checked = false;
    }
    const recCard = document.querySelector(`.plan-card[data-plan="${rec.planSku}"]`);
    (recCard || document.getElementById("plans"))?.scrollIntoView({
      behavior: "smooth",
      block: "center",
    });
    syncEstimate();
  });

  const existingLead = readHeroLead();
  fillWizardBuyer(existingLead);
  fillRailBuyer(existingLead);
  if (heroForm && Array.isArray(existingLead.needs)) {
    heroForm.querySelectorAll('input[name="need"]').forEach((el) => {
      if (SALES_NEEDS.has(el.value)) {
        el.checked = false;
        return;
      }
      el.checked = existingLead.needs.includes(el.value);
    });
  }
  if (heroForm && ["own", "influence", "research"].includes(existingLead.dmRole)) {
    const roleEl = heroForm.querySelector(
      `input[name="dmRole"][value="${existingLead.dmRole}"]`
    );
    if (roleEl) roleEl.checked = true;
  }
  if (existingLead.headcount && heroHeadcount && Number(existingLead.headcount) < 25) {
    heroHeadcount.value = String(existingLead.headcount);
    setHeadcount(String(existingLead.headcount), { fromHero: true });
  }
  updateRecommendHint();
  if (!params.get("resume")) {
    persistQualifySession({ step: visibleQualifyStep() });
  }

  const applyQualifySession = (s) => {
    if (!s) return;
    if (s.sessionId) {
      qualifySessionId = s.sessionId;
      try {
        sessionStorage.setItem("bhQualifySessionId", qualifySessionId);
      } catch (_) {
        /* ignore */
      }
    }
    if (s.utm && typeof s.utm === "object") {
      qualifyUtm = { ...s.utm, ...qualifyUtm };
    }
    if (s.headcount && heroHeadcount) {
      heroHeadcount.value = String(s.headcount);
      if (Number(s.headcount) < 25) {
        setHeadcount(String(s.headcount), { fromHero: true });
      }
    }
    if (s.country) {
      if (heroCountry) heroCountry.value = s.country;
      syncCountryTile(s.country);
      if (s.country === "US" || s.country === "CA") {
        country.value = s.country;
        country.dispatchEvent(new Event("change"));
      }
    }
    if (Array.isArray(s.needs) && heroForm) {
      heroForm.querySelectorAll('input[name="need"]').forEach((el) => {
        el.checked = s.needs.includes(el.value);
      });
    }
    if (s.dmRole && heroForm) {
      const roleEl = heroForm.querySelector(
        `input[name="dmRole"][value="${s.dmRole}"]`
      );
      if (roleEl) roleEl.checked = true;
    }
    fillWizardBuyer(s);
    fillRailBuyer(s);
    const step = Number(s.step) || 1;
    qualifyResumeStep = step;
    setQualifyStep(step);
    updateRecommendHint();
  };

  const resumeId = params.get("resume");
  if (resumeId) {
    fetch(`/api/qualify-sessions?sessionId=${encodeURIComponent(resumeId)}`)
      .then((r) => r.json())
      .then((data) => {
        if (data.ok && data.session) {
          applyQualifySession(data.session);
          persistQualifySession({
            step: Number(data.session.step) || 1,
          });
        }
      })
      .catch(() => {});
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    status.classList.remove("error");
    const buyer = currentBuyer();
    saveHeroLead({ ...readHeroLead(), ...buyer });
    if (!buyer.company || !buyer.email) {
      status.textContent =
        "Create your account (company and work email) in the wizard, then get your quote.";
      status.classList.add("error");
      document.getElementById("qualifyCard")?.scrollIntoView({
        behavior: "smooth",
        block: "center",
      });
      setQualifyStep(5);
      heroForm?.company?.focus();
      return;
    }
    if (MICRO) {
      if (Number(headcount.value) > MICRO_MAX_HC) {
        status.textContent = "Self-serve supports up to 24 employees. Talk to sales for larger teams.";
        status.classList.add("error");
        return;
      }
      if (!MICRO_PLANS.has(planSku.value)) {
        status.textContent = "Self-serve quotes are Core or Pro only.";
        status.classList.add("error");
        return;
      }
      if (selectedAddons().length) {
        status.textContent = "Add-ons aren’t on the self-serve path — remove them or talk to sales.";
        status.classList.add("error");
        return;
      }
      if (document.getElementById("freeTrial")?.checked) {
        status.textContent = "Micro self-serve bills immediately — turn off free trial.";
        status.classList.add("error");
        return;
      }
    }
    status.textContent = "Creating Account / Contact / Quote in Revenue Cloud…";
    submit.disabled = true;
    try {
      // Opp + Quote only here — rail used Pricing API (no sticky preview Quote).
      const body = {
        headcount: Number(headcount.value),
        country: country.value,
        planSku: planSku.value,
        addonSkus: selectedAddons(),
        placeQuote: true,
        freeTrial: !!document.getElementById("freeTrial")?.checked,
        startDate: readStartDate(),
        termMonths: readTermMonths(),
        buyer,
      };
      const resp = await fetch("/api/get-pricing", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (resp.status === 409 && applyQualifyOutcome(data)) {
        status.textContent = data.reason || data.error || "";
        return;
      }
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || "Pricing request failed");
      }
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
