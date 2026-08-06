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

  const listPlan = (sku) => round2(PLAN_LIST[sku] * fx());
  const listAddon = (sku) => round2(ADDON_LIST[sku] * fx());
  const flatPrice = () => round2(250 * fx());
  const round2 = (n) => Math.round(n * 100) / 100;

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
      el.disabled = nonUs;
      if (nonUs) el.checked = false;
      el.closest(".module-card")?.classList.toggle("disabled", nonUs);
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
    });
    form.querySelectorAll("input[name=addon][data-list]").forEach((input) => {
      const card = input.closest(".module-card");
      const el = card?.querySelector("[data-addon-price]");
      if (el) el.textContent = displayList(listAddon(input.value));
      const unit = card?.querySelector(".mod-price span");
      if (unit) unit.textContent = `${cur} /emp/mo`;
    });
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
  };

  country.addEventListener("change", () => {
    syncCountryAddons();
    syncEstimate();
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

  syncCountryAddons();
  wasSmallBiz = isSmallBizHeadcount();
  selectPlan(planSku.value || "BAMBOO-PRO");

  const heroForm = document.getElementById("hero-lead-form");
  const heroCountry = document.getElementById("heroCountry");
  const heroHeadcount = document.getElementById("heroHeadcount");
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
    country.dispatchEvent(new Event("change"));
  });
  country.addEventListener("change", () => {
    if (heroCountry && heroCountry.value !== country.value) {
      heroCountry.value = country.value;
    }
  });
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
    };
    try {
      sessionStorage.setItem("bhHeroLead", JSON.stringify(lead));
    } catch (_) {
      /* ignore quota / private mode */
    }
    document.getElementById("plans")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    status.textContent = "Creating quote in Revenue Cloud…";
    status.classList.remove("error");
    submit.disabled = true;
    try {
      const body = {
        headcount: Number(headcount.value),
        country: country.value,
        planSku: planSku.value,
        addonSkus: selectedAddons(),
        placeQuote: true,
        freeTrial: !!document.getElementById("freeTrial")?.checked,
      };
      const resp = await fetch("/api/get-pricing", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
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
