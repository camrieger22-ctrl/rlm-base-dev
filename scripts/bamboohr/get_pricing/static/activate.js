(function () {
  const params = new URLSearchParams(location.search);
  const cleanAccountId = (raw) =>
    String(raw || "")
      .trim()
      .replace(/^['"]+|['"]+$/g, "")
      .replace(/[.,;:!?)'"\]]+$/g, "");
  const status = document.getElementById("activateStatus");
  const stepsEl = document.getElementById("activateSteps");
  const lede = document.getElementById("activateLede");
  const progress = document.getElementById("activateProgress");
  const bar = document.getElementById("activateProgressBar");
  const customerProof = document.getElementById("customerProof");
  const customerProofList = document.getElementById("customerProofList");
  const clockEl = document.getElementById("activateClock");
  const needsEl = document.getElementById("activateNeeds");
  const ahaTitle = document.getElementById("ahaTitle");
  const newEstimateLink = document.getElementById("newEstimateLink");
  const licensesCta = document.getElementById("licensesCta");
  const footerNote = document.getElementById("activateFooterNote");
  const cadenceEl = document.getElementById("activateCadence");
  const cadenceTitle = document.getElementById("cadenceTitle");
  const cadenceBody = document.getElementById("cadenceBody");
  const cadenceHint = document.getElementById("cadenceHint");
  const cadenceMarkBtn = document.getElementById("cadenceMarkBtn");
  const cadenceTaskLinks = document.getElementById("cadenceTaskLinks");

  const qs = new URLSearchParams();
  if (params.get("ecToken")) qs.set("ecToken", params.get("ecToken"));
  else if (params.get("accountId")) qs.set("accountId", cleanAccountId(params.get("accountId")));
  else if (params.get("company")) qs.set("company", params.get("company"));

  const identity = () => {
    const body = {};
    if (params.get("ecToken")) body.ecToken = params.get("ecToken");
    else if (params.get("accountId")) body.accountId = cleanAccountId(params.get("accountId"));
    else if (params.get("company")) body.company = params.get("company");
    return body;
  };

  const esc = (s) =>
    String(s || "").replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );

  const setBusy = (busy) => {
    stepsEl.querySelectorAll("button, input, select").forEach((el) => {
      el.disabled = busy;
    });
    if (cadenceMarkBtn) cadenceMarkBtn.disabled = busy;
  };

  const save = (payload) => {
    setBusy(true);
    status.textContent = "Saving…";
    status.classList.remove("error");
    return fetch("/api/activate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...identity(), ...payload }),
    })
      .then((r) => r.json().then((d) => ({ ok: r.ok, d })))
      .then(({ ok, d }) => {
        if (!ok || !d.ok) throw new Error(d.error || "Could not save");
        render(d);
      })
      .catch((err) => {
        status.textContent = err.message || String(err);
        status.classList.add("error");
        setBusy(false);
      });
  };

  const actionHtml = (s) => {
    if (!s.action) return "";
    if (s.done && s.action !== "employees") return "";
    if (s.action === "employees") {
      return (
        '<form class="activate-form activate-form-person" data-action="employees">' +
        '<label class="sr-only" for="ahaFirst">First name</label>' +
        '<input id="ahaFirst" name="firstName" type="text" maxlength="40" placeholder="First name" required />' +
        '<label class="sr-only" for="ahaLast">Last name</label>' +
        '<input id="ahaLast" name="lastName" type="text" maxlength="80" placeholder="Last name" required />' +
        '<label class="sr-only" for="ahaEmail">Work email</label>' +
        '<input id="ahaEmail" name="email" type="email" maxlength="80" placeholder="work@company.com" required />' +
        '<button type="submit">Add teammate</button>' +
        "</form>"
      );
    }
    if (s.action === "invite") {
      const prefill = s.value
        ? ' value="' + esc(s.value) + '"'
        : "";
      return (
        '<form class="activate-form" data-action="invite">' +
        '<label class="sr-only" for="ahaAdmin">Admin email</label>' +
        '<input id="ahaAdmin" name="adminEmail" type="email" maxlength="80" ' +
        'placeholder="alex@company.com"' +
        prefill +
        ' required />' +
        '<button type="submit">Send invite</button>' +
        "</form>" +
        '<p class="muted activate-invite-hint">Creates a Contact and Task in Salesforce — no email is sent in this demo.</p>'
      );
    }
    if (s.action === "timeoff") {
      const opts = (s.options || [])
        .map((o) => '<option value="' + esc(o) + '">' + esc(o) + "</option>")
        .join("");
      return (
        '<form class="activate-form" data-action="timeoff">' +
        '<label class="sr-only" for="ahaTimeOff">Time-off policy</label>' +
        '<select id="ahaTimeOff" name="timeOffPolicy" required>' +
        '<option value="">Choose a policy</option>' +
        opts +
        "</select>" +
        '<button type="submit">Save policy</button>' +
        "</form>" +
        '<p class="muted activate-invite-hint">Creates a Task in Salesforce — no PTO engine is started.</p>'
      );
    }
    return "";
  };

  const publishAgentContext = (data) => {
    const aha = data.ahaSteps || [];
    const open = aha.find((s) => !s.done && s.action) || aha.find((s) => !s.done);
    const cadence = data.cadence || {};
    window.BH_ACTIVATE_CONTEXT = {
      page: "activate",
      accountId: data.accountId,
      ahaComplete: !!data.ahaComplete,
      activateStep: open ? open.id : "done",
      needs: data.needs || [],
      needsLabel: data.needsLabel || "",
      setupDay: data.setup ? data.setup.day : null,
      setupDeadline: data.setup ? data.setup.deadline : null,
      setupLabel: data.setup ? data.setup.label : null,
      cadenceWhich: cadence.which || null,
      cadenceDue: !!cadence.due,
      cadenceLabel: cadence.label || null,
      cadenceOwner: cadence.owner || "Marketing",
      eliteIsSales: true,
      payrollIsSales: true,
    };
    document.dispatchEvent(new CustomEvent("bh-agent-context-refresh"));
  };

  const renderCadence = (data) => {
    if (!cadenceEl) return;
    const cadence = data.cadence || {};
    cadenceEl.hidden = false;
    cadenceEl.classList.toggle("is-due", !!cadence.due);
    if (cadenceTitle) {
      cadenceTitle.textContent = cadence.due
        ? cadence.title || cadence.label || "Marketing follow-up"
        : cadence.label || "Marketing follows up during the 14-day setup window";
    }
    if (cadenceBody) {
      cadenceBody.textContent = cadence.due
        ? cadence.body || ""
        : cadence.complete
          ? "Setup is done. Marketing cadence is complete — proof is the CRM Tasks on this Account."
          : "Day 3, 7, and 14 nudges are Marketing-owned. When the clock hits each day, a CRM Task is logged — no email, not Marketing Cloud.";
    }
    if (cadenceHint) {
      cadenceHint.textContent = cadence.due
        ? "Creates a CRM Task — we do not send email."
        : cadence.complete
          ? "Elite and Payroll stay with a person."
          : "Marketing owns follow-up. This demo does not send email.";
    }
    if (cadenceMarkBtn) {
      cadenceMarkBtn.hidden = !cadence.due;
      cadenceMarkBtn.dataset.which = cadence.which || "";
      cadenceMarkBtn.textContent = cadence.which
        ? "Mark " + cadence.which.replace("day", "day ") + " sent"
        : "Mark follow-up sent";
    }
    if (cadenceTaskLinks) {
      if (cadence.taskUrl) {
        cadenceTaskLinks.hidden = false;
        cadenceTaskLinks.innerHTML =
          '<a class="activate-person" href="' +
          esc(cadence.taskUrl) +
          '" target="_blank" rel="noopener">Open cadence Task</a>';
      } else if (cadence.taskId) {
        cadenceTaskLinks.hidden = false;
        cadenceTaskLinks.innerHTML =
          '<span class="muted">CRM Task ' + esc(cadence.taskId) + "</span>";
      } else {
        cadenceTaskLinks.hidden = true;
        cadenceTaskLinks.innerHTML = "";
      }
    }
  };

  const render = (data) => {
    if (lede && data.message) lede.textContent = data.message;
    if (licensesCta && data.licensesUrl) licensesCta.href = data.licensesUrl;
    if (licensesCta) {
      licensesCta.textContent = data.ahaComplete
        ? "Go to Licenses & billing"
        : "Skip to Licenses & billing";
    }
    if (newEstimateLink) newEstimateLink.hidden = !!data.paid;
    if (footerNote) {
      footerNote.textContent = data.ahaComplete
        ? "HR is out of the spreadsheet — saved on the Account in Salesforce"
        : "Each step writes to your Salesforce Account";
    }
    if (clockEl) {
      if (data.setup && data.setup.label) {
        clockEl.hidden = false;
        clockEl.textContent = data.setup.overdue
          ? data.setup.label
          : data.setup.label +
            " · complete setup by " +
            (data.setup.deadlineLabel || data.setup.deadline);
      } else {
        clockEl.hidden = true;
        clockEl.textContent = "";
      }
    }
    if (needsEl) {
      if (data.needsLabel) {
        needsEl.hidden = false;
        needsEl.textContent = "You told us you care about " + data.needsLabel + ".";
      } else {
        needsEl.hidden = true;
        needsEl.textContent = "";
      }
    }
    if (ahaTitle) {
      ahaTitle.textContent = data.ahaComplete
        ? "You're set up"
        : "Get value this week";
    }
    const customer = data.customerSteps || [];
    if (customerProof && customerProofList && customer.length) {
      customerProof.hidden = false;
      customerProofList.innerHTML = customer
        .map((s) => {
          const on = s.done ? " is-on" : "";
          return (
            '<li class="activate-proof-chip' +
            on +
            '"><span>' +
            (s.done ? "✓" : "○") +
            "</span> " +
            esc(s.label) +
            (s.detail ? '<em>' + esc(s.detail) + "</em>" : "") +
            "</li>"
          );
        })
        .join("");
    } else if (customerProof) {
      customerProof.hidden = true;
    }
    renderCadence(data);
    const steps = data.ahaSteps || data.steps || [];
    const done = (data.progress && data.progress.done) || 0;
    const total = (data.progress && data.progress.total) || steps.length || 1;
    if (progress && bar) {
      progress.hidden = false;
      bar.style.width = Math.round((done / total) * 100) + "%";
    }
    stepsEl.innerHTML = steps
      .map((s) => {
        const cls =
          s.done && !(s.action === "employees")
            ? "is-done"
            : s.action
              ? "is-open"
              : s.done
                ? "is-done"
                : "";
        const mark = s.done ? "✓" : s.action ? "→" : "○";
        const extra =
          s.href && s.done
            ? '<a class="activate-step-link" href="' +
              esc(s.href) +
              '">' +
              esc(s.detail || "Open") +
              "</a>"
            : s.href && !s.action
              ? '<a class="activate-step-link" href="' +
                esc(s.href) +
                '">' +
                esc(s.detail || "Open") +
                "</a>"
              : '<span class="muted">' + esc(s.detail || "") + "</span>";
        const people = (s.people || [])
          .map((p) => {
            const label = esc(p.name) + (p.email ? " · " + esc(p.email) : "");
            return p.url
              ? '<li><a class="activate-person" href="' +
                  esc(p.url) +
                  '" target="_blank" rel="noopener">' +
                  label +
                  "</a></li>"
              : "<li>" + label + "</li>";
          })
          .join("");
        const peopleBlock = people
          ? '<ul class="activate-people">' + people + "</ul>"
          : "";
        const inv = s.invite || {};
        const inviteLinks = [
          inv.contactUrl
            ? '<a class="activate-person" href="' +
              esc(inv.contactUrl) +
              '" target="_blank" rel="noopener">Open Contact</a>'
            : "",
          inv.taskUrl
            ? '<a class="activate-person" href="' +
              esc(inv.taskUrl) +
              '" target="_blank" rel="noopener">Open invite Task</a>'
            : "",
        ]
          .filter(Boolean)
          .join(" · ");
        const inviteBlock = inviteLinks
          ? '<p class="activate-invite-links">' + inviteLinks + "</p>"
          : "";
        const to = s.timeoff || {};
        const timeoffBlock =
          to.taskUrl
            ? '<p class="activate-invite-links"><a class="activate-person" href="' +
              esc(to.taskUrl) +
              '" target="_blank" rel="noopener">Open time-off Task</a></p>'
            : "";
        return (
          '<li class="' +
          cls +
          '" data-step="' +
          esc(s.id) +
          '"><span class="activate-mark" aria-hidden="true">' +
          mark +
          "</span><div><strong>" +
          esc(s.label || "") +
          "</strong>" +
          extra +
          peopleBlock +
          inviteBlock +
          timeoffBlock +
          actionHtml(s) +
          "</div></li>"
        );
      })
      .join("");
    status.textContent = done + " of " + total + " ready this week";
    status.classList.remove("error");
    publishAgentContext(data);
  };

  stepsEl.addEventListener("submit", (ev) => {
    const form = ev.target.closest("form.activate-form");
    if (!form) return;
    ev.preventDefault();
    const action = form.getAttribute("data-action");
    if (action === "employees") {
      save({
        firstName: form.firstName.value,
        lastName: form.lastName.value,
        email: form.email.value,
      });
    } else if (action === "invite") {
      save({ adminEmail: form.adminEmail.value });
    } else if (action === "timeoff") {
      save({ timeOffPolicy: form.timeOffPolicy.value });
    }
  });

  cadenceMarkBtn?.addEventListener("click", () => {
    const which = cadenceMarkBtn.dataset.which;
    if (!which) return;
    setBusy(true);
    status.textContent = "Logging Marketing follow-up…";
    status.classList.remove("error");
    fetch("/api/activate-cadence", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...identity(), which }),
    })
      .then((r) => r.json().then((d) => ({ ok: r.ok, d })))
      .then(({ ok, d }) => {
        if (!ok || !d.ok) throw new Error(d.error || "Could not mark cadence");
        render(d);
      })
      .catch((err) => {
        status.textContent = err.message || String(err);
        status.classList.add("error");
        setBusy(false);
      });
  });

  fetch("/api/activate?" + qs.toString())
    .then((r) => r.json().then((d) => ({ ok: r.ok, d })))
    .then(({ ok, d }) => {
      if (!ok || !d.ok) throw new Error(d.error || "Could not load activate checklist");
      render(d);
    })
    .catch((err) => {
      status.textContent = err.message || String(err);
      status.classList.add("error");
      stepsEl.innerHTML =
        "<li class='is-stub'><div><strong>Checklist unavailable</strong>" +
        "<span class='muted'>Open Licenses &amp; billing to continue.</span></div></li>";
    });
})();
