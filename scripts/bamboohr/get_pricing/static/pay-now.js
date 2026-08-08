/**
 * Shared Pay Now card renderer for quote success + Licenses amend success.
 * Card entry stays on Salesforce Pay Now; this only drives BFF CTAs.
 */
(() => {
  const money = (n, cur = "USD") => {
    if (n == null || n === "") return "";
    const abs = Math.abs(Number(n));
    const formatted = abs.toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    const sign = Number(n) < 0 ? "−" : "";
    if (cur === "USD") return `${sign}$${formatted}`;
    return `${sign}${cur} ${formatted}`;
  };

  const isDemoMode = () => {
    try {
      return new URLSearchParams(window.location.search).has("demo");
    } catch {
      return false;
    }
  };

  const INCOGNITO_HINT =
    "If the pay page errors while you’re logged into Salesforce, open Pay now in a private / incognito window.";

  /**
   * @param {object} els
   * @param {HTMLElement|null} els.card
   * @param {HTMLElement|null} [els.title]
   * @param {HTMLElement|null} [els.lede]
   * @param {HTMLElement|null} [els.status]
   * @param {HTMLAnchorElement|null} [els.payBtn]
   * @param {HTMLButtonElement|null} [els.retryBtn]
   * @param {HTMLAnchorElement|null} [els.invoiceBtn]
   * @param {HTMLElement|null} [els.hint]
   * @param {object} payment — PaymentPrompt.as_dict() shape
   * @param {object} [opts]
   * @param {string} [opts.currency]
   * @param {string} [opts.payUrl] — override / links.payNow
   * @param {string} [opts.invoiceUrl] — override / links.invoice
   * @param {string} [opts.defaultTitle]
   * @param {string} [opts.defaultLede]
   * @param {boolean} [opts.showInvoiceLink] — force SE invoice link (default: ?demo=1)
   */
  const render = (els, payment, opts = {}) => {
    const card = els?.card;
    if (!card) return { shown: false };

    const pay = payment || {};
    const currency = opts.currency || "USD";
    const payUrl = opts.payUrl || pay.paymentUrl || "";
    const invoiceUrl = opts.invoiceUrl || pay.invoiceUrl || "";
    const hasInvoice = !!(pay.invoiceId || pay.invoiceNumber || invoiceUrl);
    const hasPayUrl = !!payUrl;
    const balance = pay.invoiceBalance;
    const zeroDue = balance != null && Number(balance) <= 0;
    const showInvoice =
      opts.showInvoiceLink === true ||
      (opts.showInvoiceLink !== false && isDemoMode());

    const show =
      hasInvoice || !!pay.blockedReason || hasPayUrl || zeroDue;
    if (!show) {
      card.hidden = true;
      return { shown: false };
    }
    card.hidden = false;

    if (els.title && opts.defaultTitle) {
      els.title.textContent = opts.defaultTitle;
    }

    if (els.lede) {
      if (pay.invoiceNumber) {
        const bal =
          balance != null
            ? ` · ${money(balance, currency)}${zeroDue ? "" : " due"}`
            : "";
        els.lede.textContent = `Invoice ${pay.invoiceNumber}${bal}.`;
      } else if (opts.defaultLede) {
        els.lede.textContent = opts.defaultLede;
      }
    }

    if (els.payBtn) {
      if (hasPayUrl) {
        els.payBtn.href = payUrl;
        els.payBtn.hidden = false;
      } else {
        els.payBtn.hidden = true;
        els.payBtn.removeAttribute("href");
      }
    }

    if (els.invoiceBtn) {
      if (showInvoice && invoiceUrl) {
        els.invoiceBtn.href = invoiceUrl;
        els.invoiceBtn.hidden = false;
      } else {
        els.invoiceBtn.hidden = true;
      }
    }

    if (els.hint) {
      els.hint.textContent = INCOGNITO_HINT;
      els.hint.hidden = !hasPayUrl;
    }

    const canRetry = !!(pay.invoiceId || pay.orderId) && !hasPayUrl && !zeroDue;
    if (els.retryBtn) {
      els.retryBtn.hidden = !canRetry;
      els.retryBtn.dataset.invoiceId = pay.invoiceId || "";
      els.retryBtn.dataset.orderId = pay.orderId || "";
    }

    if (els.emailBtn) {
      els.emailBtn.hidden = !(hasPayUrl && !zeroDue);
    }

    if (els.status) {
      els.status.classList.remove("error");
      if (hasPayUrl) {
        els.status.textContent =
          "Ready — open Pay now to complete payment.";
      } else if (zeroDue) {
        els.status.textContent = "No amount due.";
      } else if (pay.blockedReason) {
        els.status.textContent = pay.blockedReason;
        els.status.classList.add("error");
      } else if (canRetry) {
        els.status.textContent =
          "Payment link not ready — try Retry pay.";
        els.status.classList.add("error");
      } else {
        els.status.textContent = "";
      }
    }

    return { shown: true, hasPayUrl, canRetry };
  };

  /**
   * POST /api/collect-payment and re-render the card.
   * @returns {Promise<object>} payment payload
   */
  const retryCollect = async (els, payment, opts = {}) => {
    const pay = payment || {};
    const body = {};
    if (pay.invoiceId) body.invoiceId = pay.invoiceId;
    else if (pay.orderId) body.orderId = pay.orderId;
    else throw new Error("invoiceId or orderId required to retry");

    if (els.status) {
      els.status.textContent = "Creating Pay Now link…";
      els.status.classList.remove("error");
    }
    if (els.retryBtn) els.retryBtn.disabled = true;
    try {
      const resp = await fetch("/api/collect-payment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok && !data.paymentUrl) {
        throw new Error(
          data.blockedReason || data.error || "Could not create payment link"
        );
      }
      const next = { ...pay, ...data };
      render(els, next, opts);
      if (next.paymentUrl) {
        window.open(next.paymentUrl, "_blank", "noopener");
      }
      return next;
    } finally {
      if (els.retryBtn) els.retryBtn.disabled = false;
    }
  };

  /**
   * POST /api/payment-email for the current payment prompt.
   */
  const emailPayLink = async (els, payment, opts = {}) => {
    const pay = payment || {};
    if (!pay.paymentUrl && !(pay.invoiceId || pay.orderId)) {
      throw new Error("paymentUrl or invoiceId required to email");
    }
    if (els.status) {
      els.status.textContent = "Sending pay link email…";
      els.status.classList.remove("error");
    }
    if (els.emailBtn) els.emailBtn.disabled = true;
    try {
      const body = {};
      if (pay.paymentUrl) body.paymentUrl = pay.paymentUrl;
      if (pay.invoiceId) body.invoiceId = pay.invoiceId;
      if (pay.orderId) body.orderId = pay.orderId;
      if (pay.invoiceNumber) body.invoiceNumber = pay.invoiceNumber;
      if (pay.invoiceBalance != null) body.amountDue = pay.invoiceBalance;
      if (opts.accountId) body.accountId = opts.accountId;
      if (opts.toEmail) body.toEmail = opts.toEmail;
      const resp = await fetch("/api/payment-email", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok || !data.ok) {
        throw new Error(data.error || data.message || "Email failed");
      }
      if (els.status) {
        els.status.textContent =
          data.message || `Email sent${data.toAddress ? " to " + data.toAddress : ""}.`;
      }
      return data;
    } finally {
      if (els.emailBtn) els.emailBtn.disabled = false;
    }
  };

  /**
   * Wire Retry button once. Keeps latest payment on els._payment.
   */
  const bindRetry = (els, opts = {}) => {
    if (!els?.retryBtn || els.retryBtn.dataset.bound === "1") return;
    els.retryBtn.dataset.bound = "1";
    els.retryBtn.addEventListener("click", async () => {
      try {
        const next = await retryCollect(els, els._payment || {}, opts);
        els._payment = next;
        if (typeof opts.onUpdated === "function") opts.onUpdated(next);
      } catch (err) {
        if (els.status) {
          els.status.textContent = err.message || String(err);
          els.status.classList.add("error");
        }
      }
    });
  };

  const bindEmail = (els, opts = {}) => {
    if (!els?.emailBtn || els.emailBtn.dataset.bound === "1") return;
    els.emailBtn.dataset.bound = "1";
    els.emailBtn.addEventListener("click", async () => {
      try {
        await emailPayLink(els, els._payment || {}, opts);
      } catch (err) {
        if (els.status) {
          els.status.textContent = err.message || String(err);
          els.status.classList.add("error");
        }
      }
    });
  };

  window.BambooPayNow = {
    money,
    isDemoMode,
    INCOGNITO_HINT,
    render,
    retryCollect,
    emailPayLink,
    bindRetry,
    bindEmail,
  };
})();
