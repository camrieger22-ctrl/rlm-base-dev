(() => {
  const form = document.getElementById("pricing-form");
  const status = document.getElementById("status");
  const submit = document.getElementById("submit");
  const country = document.getElementById("country");
  const addonHint = document.getElementById("addonHint");

  const syncCountryAddons = () => {
    const isCA = country.value === "CA";
    form.querySelectorAll('input[name="addon"][data-us-only]').forEach((el) => {
      el.disabled = isCA;
      if (isCA) el.checked = false;
      el.closest("label")?.classList.toggle("disabled", isCA);
    });
    if (addonHint) {
      addonHint.textContent = isCA
        ? "Canada: Payroll and Benefits are unavailable (category disqualification). Time and Global remain selectable."
        : "Payroll + Benefits together unlock Path B Bundle & Save (15%). US-only for Payroll/Benefits.";
    }
  };
  country.addEventListener("change", syncCountryAddons);
  syncCountryAddons();

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
      status.textContent = err.message || String(err);
    } finally {
      submit.disabled = false;
    }
  });
})();
