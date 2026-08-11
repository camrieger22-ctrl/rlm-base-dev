/**
 * BambooHR self-service agent embed (Phase 1).
 *
 * Loads Salesforce Messaging for In-App and Web when /api/agent-config says
 * enabled + deployment ids are set. Otherwise optional preview shell so SE
 * demos can see the launcher before Phase 0 Messaging is wired.
 *
 * Money / Quote writes stay on BFF APIs (Phase 2+ actions) — this file only
 * surfaces chat + page context.
 */
(() => {
  const STICKY_KEY = "bhAmendSticky";
  const HERO_KEY = "bhHeroLead";
  const PIN_KEY = "bhAccountPin";

  const detectPage = () => {
    const p = location.pathname || "";
    if (p.startsWith("/amend-quote/")) return "amend-quote";
    if (p.startsWith("/quote/")) return "quote";
    if (p === "/account" || p.startsWith("/account") || p === "/licenses") {
      return "account";
    }
    if (p === "/" || p.startsWith("/index")) return "get-pricing";
    return "other";
  };

  const readJson = (store, key) => {
    try {
      const raw = store.getItem(key);
      if (!raw) return null;
      const v = JSON.parse(raw);
      return v && typeof v === "object" ? v : null;
    } catch (_) {
      return null;
    }
  };

  const pathId = (prefix) => {
    const m = location.pathname.match(new RegExp(`/${prefix}/([^/]+)`));
    return m ? decodeURIComponent(m[1]) : null;
  };

  const collectContext = () => {
    const params = new URLSearchParams(location.search);
    const sticky = readJson(sessionStorage, STICKY_KEY);
    const hero = readJson(sessionStorage, HERO_KEY);
    const pin =
      readJson(sessionStorage, PIN_KEY) || readJson(localStorage, PIN_KEY);
    const page = detectPage();
    const ctx = {
      page,
      accountId:
        params.get("accountId") ||
        sticky?.accountId ||
        pin?.accountId ||
        null,
      contactId: params.get("contactId") || null,
      quoteId: page === "quote" ? pathId("quote") : null,
      amendSummaryId: page === "amend-quote" ? pathId("amend-quote") : null,
      amendQuotes: sticky?.amendQuotes || [],
      moduleQuoteId: sticky?.moduleQuoteId || null,
      ecToken: params.get("ecToken") || null,
      country: document.getElementById("country")?.value || "US",
      currency: null,
      company: hero?.company || pin?.company || null,
      email: hero?.email || null,
      bffOrigin: location.origin,
    };
    return ctx;
  };

  const setHiddenInputs = (root, ctx) => {
    if (!root) return;
    const ensure = (name, value) => {
      let el = root.querySelector(`[data-agent-ctx="${name}"]`);
      if (!el) {
        el = document.createElement("input");
        el.type = "hidden";
        el.dataset.agentCtx = name;
        root.appendChild(el);
      }
      el.value = value == null ? "" : String(value);
    };
    ensure("page", ctx.page);
    ensure("accountId", ctx.accountId);
    ensure("quoteId", ctx.quoteId);
    ensure("amendSummaryId", ctx.amendSummaryId);
    ensure("ecToken", ctx.ecToken);
    ensure("company", ctx.company);
    ensure("email", ctx.email);
    ensure(
      "amendQuotes",
      ctx.amendQuotes?.length ? JSON.stringify(ctx.amendQuotes) : ""
    );
    ensure("moduleQuoteId", ctx.moduleQuoteId);
  };

  /** Expose for Messaging prechat / future action bridge. */
  const publishContext = (ctx) => {
    window.BH_AGENT_CONTEXT = ctx;
    try {
      sessionStorage.setItem("bhAgentContext", JSON.stringify(ctx));
    } catch (_) {
      /* ignore */
    }
    document.dispatchEvent(
      new CustomEvent("bh-agent-context", { detail: ctx })
    );
  };

  const mountPreviewShell = (cfg) => {
    if (document.getElementById("bhAgentPreviewRoot")) return;
    const root = document.createElement("div");
    root.id = "bhAgentPreviewRoot";
    root.className = "bh-agent-preview";
    root.innerHTML = `
      <button type="button" class="bh-agent-fab" id="bhAgentFab" aria-expanded="false" aria-controls="bhAgentPanel">
        <span class="bh-agent-fab-label">Ask assistant</span>
      </button>
      <div class="bh-agent-panel" id="bhAgentPanel" hidden>
        <header class="bh-agent-panel-head">
          <div>
            <p class="bh-agent-kicker">BambooHR assistant</p>
            <h2>Chat (preview)</h2>
          </div>
          <button type="button" class="bh-agent-close" id="bhAgentClose" aria-label="Close">×</button>
        </header>
        <p class="bh-agent-lede">
          Messaging for In-App and Web is not connected yet (Phase 0).
          This launcher is the Phase 1 embed shell — estimates stay on the
          Pricing API; quotes still require company + work email.
        </p>
        <ul class="bh-agent-hints">
          <li>“Price Pro + Payroll for 100 US employees”</li>
          <li>“Create a quote for my company” <span>(needs email)</span></li>
          <li>“Change seats to 260” <span>(Licenses sticky Draft)</span></li>
        </ul>
        <p class="bh-agent-meta muted" id="bhAgentMeta"></p>
        <p class="bh-agent-footnote muted">
          Place order stays on the summary CTA. Named Cloudflare tunnel recommended for live Messaging.
        </p>
      </div>`;
    document.body.appendChild(root);

    const fab = document.getElementById("bhAgentFab");
    const panel = document.getElementById("bhAgentPanel");
    const close = document.getElementById("bhAgentClose");
    const meta = document.getElementById("bhAgentMeta");

    const refreshMeta = () => {
      const ctx = collectContext();
      publishContext(ctx);
      setHiddenInputs(root, ctx);
      if (meta) {
        meta.textContent = [
          `page=${ctx.page}`,
          ctx.accountId ? `account=${ctx.accountId}` : null,
          ctx.quoteId ? `quote=${ctx.quoteId}` : null,
          ctx.amendQuotes?.length
            ? `stickyDrafts=${ctx.amendQuotes.length}`
            : null,
          cfg.orgLabel ? `org=${cfg.orgLabel}` : null,
        ]
          .filter(Boolean)
          .join(" · ");
      }
    };

    const open = () => {
      panel.hidden = false;
      fab.setAttribute("aria-expanded", "true");
      refreshMeta();
    };
    const hide = () => {
      panel.hidden = true;
      fab.setAttribute("aria-expanded", "false");
    };
    fab.addEventListener("click", () => {
      if (panel.hidden) open();
      else hide();
    });
    close?.addEventListener("click", hide);
    refreshMeta();
    // Keep context fresh when sticky amend / pin changes.
    window.addEventListener("storage", refreshMeta);
    document.addEventListener("bh-agent-context-refresh", refreshMeta);
  };

  const showMiawIssue = (message) => {
    console.error("[bh-agent]", message);
    if (document.getElementById("bhAgentMiawIssue")) return;
    const el = document.createElement("div");
    el.id = "bhAgentMiawIssue";
    el.setAttribute("role", "status");
    el.style.cssText =
      "position:fixed;right:16px;bottom:16px;z-index:2147483000;max-width:320px;" +
      "padding:12px 14px;background:#1b1b1b;color:#fff;font:13px/1.4 system-ui,sans-serif;" +
      "border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.25)";
    el.innerHTML =
      "<strong style=\"display:block;margin-bottom:6px\">Chat did not load</strong>" +
      "<span></span>";
    el.querySelector("span").textContent = message;
    document.body.appendChild(el);
  };

  const loadMiaw = (cfg) => {
    const {
      orgId,
      deploymentName,
      messagingUrl,
      scrtUrl,
      language = "en_US",
    } = cfg;
    if (!orgId || !deploymentName || !messagingUrl || !scrtUrl) {
      console.warn(
        "[bh-agent] enabled but missing orgId/deploymentName/messagingUrl/scrtUrl — falling back to preview"
      );
      mountPreviewShell({ ...cfg, preview: true });
      return;
    }

    let ready = false;
    window.addEventListener("onEmbeddedMessagingReady", () => {
      ready = true;
      const issue = document.getElementById("bhAgentMiawIssue");
      issue?.remove();
      const ctx = collectContext();
      publishContext(ctx);
      try {
        // Best-effort: set visible prechat / hidden fields when API exists.
        if (window.embeddedservice_bootstrap?.prechatAPI?.setHiddenFields) {
          window.embeddedservice_bootstrap.prechatAPI.setHiddenFields([
            { name: "page", value: ctx.page || "" },
            { name: "AccountId", value: ctx.accountId || "" },
            { name: "QuoteId", value: ctx.quoteId || "" },
            { name: "BffOrigin", value: ctx.bffOrigin || "" },
          ]);
        }
      } catch (err) {
        console.warn("[bh-agent] prechat context skipped", err);
      }
    });

    window.initBambooEmbeddedMessaging = function initBambooEmbeddedMessaging() {
      try {
        window.embeddedservice_bootstrap.settings.language = language;
        window.embeddedservice_bootstrap.init(orgId, deploymentName, messagingUrl, {
          scrt2URL: scrtUrl,
        });
      } catch (err) {
        console.error("[bh-agent] Messaging init failed", err);
        showMiawIssue(
          "Messaging init failed. Check CORS for http://127.0.0.1:8765 and the browser console."
        );
        mountPreviewShell({ ...cfg, preview: true });
      }
    };

    const bootstrapSrc = messagingUrl.replace(/\/?$/, "/") + "assets/js/bootstrap.min.js";
    const s = document.createElement("script");
    s.type = "text/javascript";
    s.src = bootstrapSrc;
    s.onload = () => window.initBambooEmbeddedMessaging?.();
    s.onerror = () => {
      console.error("[bh-agent] failed to load Messaging bootstrap", bootstrapSrc);
      showMiawIssue(
        "Could not load Salesforce bootstrap.js (blocked or network). Allow-list this origin in CORS."
      );
      mountPreviewShell({ ...cfg, preview: true });
    };
    document.body.appendChild(s);

    // SCRT/CORS failures often don't throw — surface after a short wait.
    window.setTimeout(() => {
      if (ready) return;
      const hasSfLauncher = Boolean(
        document.querySelector(
          ".embeddedMessagingFrame, .embeddedServiceHelpButton, [class*='embeddedMessaging']"
        )
      );
      if (!hasSfLauncher) {
        const origin = location.origin;
        showMiawIssue(
          `Allow-list ${origin} in Setup → CORS and the ESW site Trusted Domains for Inline Frames, then hard-refresh. HTTPS origins only.`
        );
      }
    }, 8000);
  };

  const boot = async () => {
    let cfg = { enabled: false, preview: false };
    try {
      const resp = await fetch("/api/agent-config");
      cfg = await resp.json();
    } catch (err) {
      console.warn("[bh-agent] /api/agent-config unavailable", err);
      return;
    }
    if (!cfg || cfg.ok === false) return;

    publishContext(collectContext());

    if (cfg.enabled) {
      loadMiaw(cfg);
      return;
    }
    if (cfg.preview) {
      mountPreviewShell(cfg);
    }
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
