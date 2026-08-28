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
    if (p.startsWith("/activate")) return "activate";
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
    const q = window.BH_QUALIFY_CONTEXT || {};
    const activate = window.BH_ACTIVATE_CONTEXT || {};
    const acct = window.BH_ACCOUNT_CONTEXT || {};
    const quoteCtx = window.BH_QUOTE_CONTEXT || {};
    const onWizard = page === "get-pricing";
    const onQuote = page === "quote" || page === "amend-quote";
    const onLicenses = page === "account" || page === "activate";
    const ctx = {
      page,
      accountId:
        params.get("accountId") ||
        (onQuote ? quoteCtx.accountId || null : null) ||
        (onLicenses
          ? sticky?.accountId || pin?.accountId || acct.accountId || null
          : null),
      contactId: params.get("contactId") || null,
      quoteId: page === "quote" ? pathId("quote") : null,
      amendSummaryId: page === "amend-quote" ? pathId("amend-quote") : null,
      amendQuotes: sticky?.amendQuotes || [],
      moduleQuoteId: sticky?.moduleQuoteId || null,
      upgradeQuoteId: sticky?.upgradeQuoteId || null,
      ecToken: params.get("ecToken") || null,
      country:
        document.getElementById("heroCountry")?.value ||
        document.getElementById("country")?.value ||
        "US",
      currency: null,
      company: hero?.company || pin?.company || null,
      email: hero?.email || null,
      bffOrigin: location.origin,
      // Wizard leftovers must not stamp Quote / Licenses chats.
      qualifyStep: onWizard
        ? q.qualifyStep ||
          Number(document.body?.dataset?.qualifyStep || 0) ||
          null
        : null,
      bounceType: onWizard
        ? q.bounceType || document.body?.dataset?.bounceType || null
        : null,
      bounceReason: onWizard
        ? q.bounceReason || document.body?.dataset?.bounceReason || null
        : null,
      salesHandoffVisible: onWizard && !document.getElementById("salesHandoff")?.hidden,
      qualifySessionId: onWizard
        ? q.sessionId || sessionStorage.getItem("bhQualifySessionId") || null
        : null,
      headcount: onWizard
        ? q.headcount ||
          Number(document.getElementById("heroHeadcount")?.value || 0) ||
          null
        : quoteCtx.headcount || null,
      activateStep: activate.activateStep || null,
      ahaComplete: !!activate.ahaComplete,
      primaryNeeds: activate.needsLabel || (activate.needs || []).join(", ") || null,
      setupDay: activate.setupDay || null,
      setupDeadline: activate.setupDeadline || null,
      currentPlan: acct.currentPlan || null,
      currentPlanLabel: acct.currentPlanLabel || null,
      upgradeAvailable: !!acct.upgradeAvailable,
      upgradeTo: acct.upgradeTo || null,
      upgradeSelected: !!acct.upgradeSelected,
      nextModuleSku: acct.nextModuleSku || null,
      nextModuleCopy: acct.nextModuleCopy || null,
      nextModuleAvailable: !!acct.nextModuleAvailable,
      eliteIsSales: acct.eliteIsSales !== false,
      payrollIsSales: acct.payrollIsSales !== false,
      cadenceWhich: activate.cadenceWhich || null,
      cadenceDue: !!activate.cadenceDue,
      cadenceLabel: activate.cadenceLabel || null,
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
    ensure("qualifyStep", ctx.qualifyStep);
    ensure("bounceType", ctx.bounceType);
    ensure("bounceReason", ctx.bounceReason);
    ensure("salesHandoffVisible", ctx.salesHandoffVisible ? "1" : "");
    ensure("qualifySessionId", ctx.qualifySessionId);
    ensure("headcount", ctx.headcount);
    ensure("activateStep", ctx.activateStep);
    ensure("primaryNeeds", ctx.primaryNeeds);
    ensure("setupDay", ctx.setupDay);
    ensure("ahaComplete", ctx.ahaComplete ? "1" : "");
    ensure("currentPlan", ctx.currentPlan);
    ensure("upgradeTo", ctx.upgradeTo);
    ensure("upgradeSelected", ctx.upgradeSelected ? "1" : "");
    ensure("nextModuleSku", ctx.nextModuleSku);
    ensure("nextModuleCopy", ctx.nextModuleCopy);
    ensure("nextModuleAvailable", ctx.nextModuleAvailable ? "1" : "");
    ensure("eliteIsSales", ctx.eliteIsSales ? "1" : "");
    ensure("payrollIsSales", ctx.payrollIsSales ? "1" : "");
    ensure("cadenceWhich", ctx.cadenceWhich);
    ensure("cadenceDue", ctx.cadenceDue ? "1" : "");
    ensure("cadenceLabel", ctx.cadenceLabel);
    ensure(
      "amendQuotes",
      ctx.amendQuotes?.length ? JSON.stringify(ctx.amendQuotes) : ""
    );
    ensure("moduleQuoteId", ctx.moduleQuoteId);
    ensure("upgradeQuoteId", ctx.upgradeQuoteId);
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
          <li>“Where am I in the signup?” <span>(5-beat wizard)</span></li>
          <li>“What's the next module?” <span>(Time &amp; Attendance)</span></li>
          <li>“Can I upgrade to Elite?” <span>(talk to a person)</span></li>
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
          ctx.qualifyStep ? `qualifyStep=${ctx.qualifyStep}` : null,
          ctx.activateStep ? `activateStep=${ctx.activateStep}` : null,
          ctx.primaryNeeds ? `needs=${ctx.primaryNeeds}` : null,
          ctx.bounceType ? `bounce=${ctx.bounceType}` : null,
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
    // Console only — never paint a fixed “Chat did not load” banner on the
    // buyer page (distracting for demos when Messaging/CORS isn’t ready).
    console.error("[bh-agent]", message);
  };

  const pushMiawHiddenFields = (ctx) => {
    // Best-effort: MIAW custom attributes for Help-with-page (5-beat + bounce).
    // Field API names must exist on the Embedded Service deployment / Messaging
    // prechat form when configured in Setup — unknown names are usually ignored.
    const api = window.embeddedservice_bootstrap?.prechatAPI;
    if (!api) return;
    const str = (v) => (v == null || v === "" ? "" : String(v));
    const fields = {
      page: str(ctx.page),
      AccountId: str(ctx.accountId),
      QuoteId: str(ctx.quoteId),
      BffOrigin: str(ctx.bffOrigin),
      qualifyStep: str(ctx.qualifyStep),
      bounceType: str(ctx.bounceType),
      bounceReason: str(ctx.bounceReason),
      salesHandoffVisible: ctx.salesHandoffVisible ? "1" : "0",
      qualifySessionId: str(ctx.qualifySessionId),
      headcount: str(ctx.headcount),
      activateStep: str(ctx.activateStep),
      primaryNeeds: str(ctx.primaryNeeds),
      setupDay: str(ctx.setupDay),
      ahaComplete: ctx.ahaComplete ? "1" : "0",
      nextModuleSku: str(ctx.nextModuleSku),
      nextModuleCopy: str(ctx.nextModuleCopy),
      eliteIsSales: ctx.eliteIsSales ? "1" : "0",
      payrollIsSales: ctx.payrollIsSales ? "1" : "0",
      cadenceWhich: str(ctx.cadenceWhich),
      cadenceDue: ctx.cadenceDue ? "1" : "0",
    };
    // MIAW takes an object keyed by channel parameter name; legacy Embedded Chat
    // takes an array of {name, value}.
    if (typeof api.setHiddenPrechatFields === "function") {
      console.info("[bh-agent] prechat fields →", JSON.stringify(fields));
      api.setHiddenPrechatFields(fields);
      return;
    }
    if (typeof api.setHiddenFields === "function") {
      api.setHiddenFields(
        Object.entries(fields).map(([name, value]) => ({ name, value }))
      );
    }
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

    // Still consulted by the CORS-failure timeout below.
    let ready = false;
    const refreshMiawContext = () => {
      const ctx = collectContext();
      publishContext(ctx);
      try {
        pushMiawHiddenFields(ctx);
      } catch (err) {
        console.warn("[bh-agent] prechat context skipped", err);
      }
    };

    window.addEventListener("onEmbeddedMessagingReady", () => {
      ready = true;
      document.getElementById("bhAgentMiawIssue")?.remove();
      // Push the buyer's current beat before the conversation starts, then hand
      // off to the real widget and open it — the deferred bootstrap should still
      // feel like the single click the buyer made.
      refreshMiawContext();
      document.getElementById("bhAgentLazyRoot")?.remove();
      try {
        window.embeddedservice_bootstrap?.utilAPI?.launchChat?.();
      } catch (err) {
        console.warn("[bh-agent] auto-open skipped", err);
      }
    });
    // Wizard step / bounce changes (app.js → bh-agent-context-refresh).
    // Not gated on a ready flag: pushMiawHiddenFields no-ops until the prechat
    // API exists, and dropping early beats meant the page-load defaults were the
    // only values Salesforce ever saw.
    document.addEventListener("bh-agent-context-refresh", refreshMiawContext);
    // Last chance before the conversation begins — hidden pre-chat is only read
    // at conversation start, so re-push the buyer's current beat as they open chat.
    window.addEventListener("onEmbeddedMessagingButtonClicked", refreshMiawContext);
    window.addEventListener("onEmbeddedMessagingWindowMaximized", refreshMiawContext);

    window.initBambooEmbeddedMessaging = function initBambooEmbeddedMessaging() {
      try {
        window.embeddedservice_bootstrap.settings.language = language;
        window.embeddedservice_bootstrap.init(orgId, deploymentName, messagingUrl, {
          scrt2URL: scrtUrl,
        });
      } catch (err) {
        console.error("[bh-agent] Messaging init failed", err);
        showMiawIssue(
          "Messaging init failed. Check CORS for this origin and the browser console."
        );
        mountPreviewShell({ ...cfg, preview: true });
      }
    };

    // Deferred bootstrap. init() starts the conversation immediately, and MIAW
    // freezes hidden pre-chat at conversation start — so bootstrapping on page
    // load stamps the wizard's HTML defaults (headcount 15, no qualifyStep) and
    // burns a MessagingSession on every page view. Wait for the buyer to ask.
    let bootstrapStarted = false;
    const startMessaging = () => {
      if (bootstrapStarted) return;
      bootstrapStarted = true;
      const fabLabel = document.querySelector("#bhAgentLazyFab .bh-agent-fab-label");
      if (fabLabel) fabLabel.textContent = "Connecting…";

      const bootstrapSrc =
        messagingUrl.replace(/\/?$/, "/") + "assets/js/bootstrap.min.js";
      const s = document.createElement("script");
      s.type = "text/javascript";
      s.src = bootstrapSrc;
      s.onload = () => window.initBambooEmbeddedMessaging?.();
      s.onerror = () => {
        console.error("[bh-agent] failed to load Messaging bootstrap", bootstrapSrc);
        showMiawIssue(
          "Could not load Salesforce bootstrap.js (blocked or network). Allow-list this origin in CORS."
        );
        document.getElementById("bhAgentLazyRoot")?.remove();
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
          showMiawIssue(
            `Allow-list ${location.origin} in Setup → CORS and the ESW site Trusted Domains for Inline Frames, then hard-refresh. HTTPS origins only.`
          );
        }
      }, 8000);
    };

    const mountLazyLauncher = () => {
      if (document.getElementById("bhAgentLazyRoot")) return;
      const root = document.createElement("div");
      root.id = "bhAgentLazyRoot";
      root.className = "bh-agent-preview";
      root.innerHTML = `
        <button type="button" class="bh-agent-fab" id="bhAgentLazyFab">
          <span class="bh-agent-fab-label">Ask assistant</span>
        </button>`;
      document.body.appendChild(root);
      document
        .getElementById("bhAgentLazyFab")
        ?.addEventListener("click", startMessaging);
    };

    mountLazyLauncher();
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
