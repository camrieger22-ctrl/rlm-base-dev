(() => {
  const form = document.getElementById("pricing-form");
  const status = document.getElementById("status");
  const submit = document.getElementById("submit");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    status.textContent = "Calculating…";
    status.classList.remove("error");
    submit.disabled = true;
    try {
      const body = {
        headcount: Number(document.getElementById("headcount").value),
        country: document.getElementById("country").value,
        planSku: document.getElementById("planSku").value,
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
      status.textContent = `Net $${data.netPepm}/employee · $${data.monthlyTotal}/mo`;
    } catch (err) {
      status.classList.add("error");
      status.textContent = err.message || String(err);
    } finally {
      submit.disabled = false;
    }
  });
})();
