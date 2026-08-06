(() => {
  const form = document.getElementById("pricing-form");
  const status = document.getElementById("status");
  const submit = document.getElementById("submit");
  const country = document.getElementById("country");
  const planSku = document.getElementById("planSku");
  const headcount = document.getElementById("headcount");
  const addonHint = document.getElementById("addonHint");
  const flatHint = document.getElementById("flatHint");

  const syncCountryAddons = () => {
    const nonUs = country.value === "CA" || country.value === "UK";
    form.querySelectorAll('input[name="addon"][data-us-only]').forEach((el) => {
      el.disabled = nonUs;
      if (nonUs) el.checked = false;
      el.closest("label")?.classList.toggle("disabled", nonUs);
    });
    if (addonHint) {
      if (country.value === "CA") {
        addonHint.textContent =
          "Canada (CAD): Payroll and Benefits are unavailable (category disqualification). Time and Global remain selectable.";
      } else if (country.value === "UK") {
        addonHint.textContent =
          "United Kingdom (GBP): Payroll and Benefits are unavailable (category disqualification). Time and Global remain selectable.";
      } else {
        addonHint.textContent =
          "Payroll + Benefits together unlock Path B Bundle & Save (15%). US-only for Payroll/Benefits. Quotes in USD.";
      }
    }
  };

  // When headcount crosses into ≤25, default Plan → Core ($250 flat path).
  // Crossing back out restores the prior plan (usually Pro).
  let wasSmallBiz = false;
  let planBeforeSmallBiz = planSku.value;

  const isSmallBizHeadcount = () => {
    const hc = Number(headcount.value);
    return Number.isFinite(hc) && hc >= 1 && hc <= 25;
  };

  const syncFlatHint = () => {
    if (!flatHint) return;
    flatHint.hidden = !(planSku.value === "BAMBOO-CORE" && isSmallBizHeadcount());
  };

  const syncSmallBizPlanDefault = () => {
    const small = isSmallBizHeadcount();
    if (small && !wasSmallBiz) {
      planBeforeSmallBiz = planSku.value;
      planSku.value = "BAMBOO-CORE";
    } else if (!small && wasSmallBiz && planSku.value === "BAMBOO-CORE") {
      planSku.value = planBeforeSmallBiz || "BAMBOO-PRO";
    }
    wasSmallBiz = small;
    syncFlatHint();
  };

  country.addEventListener("change", syncCountryAddons);
  planSku.addEventListener("change", syncFlatHint);
  headcount.addEventListener("input", syncSmallBizPlanDefault);
  syncCountryAddons();
  wasSmallBiz = isSmallBizHeadcount();
  syncFlatHint();

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    status.textContent = "Calculating…";
    status.classList.remove("error");
    submit.disabled = true;
    try {
      const addonSkus = [...form.querySelectorAll('input[name="addon"]:checked:not(:disabled)')].map(
        (el) => el.value
      );
      const body = {
        headcount: Number(document.getElementById("headcount").value),
        country: country.value,
        planSku: document.getElementById("planSku").value,
        addonSkus,
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
      // fetch() network failures surface as TypeError ("Failed to fetch" /
      // "Load failed" / "Connection failed") — usually wrong URL (https) or BFF down.
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
