// Invoice Ninja's tabs on the chassis window: Business, Users, Mail, and the HTTPS part of Site address.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function inUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function money(amount, code) {
    try { return new Intl.NumberFormat(undefined, { style: "currency", currency: code || "USD" }).format(amount || 0); }
    catch (e) { return (code || "") + " " + (Math.round((amount || 0) * 100) / 100).toFixed(2); }
  }
  function totals(o) { var k = Object.keys(o || {}); return k.length ? k.map(function (c) { return money(o[c], c); }).join(" + ") : money(0, "USD").replace(/[0-9.,]+/, "0"); }
  function touched(id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; }); }); }
  function quiet(id, v) { if (!$(id).dataset.touched) $(id).value = v == null ? "" : v; }

  // ---------------------------------------------------------------- Business
  P.register("business", {
    render: function (st) {
      var a = st.app || {}, od = a.overdue || [], t = $("bz-tiles");
      document.querySelectorAll(".in-link").forEach(function (x) { x.href = inUrl(st) || "#"; });
      P.clear(t);
      P.tile(t, totals(a.outstanding), "owed to you (" + (a.open || 0) + " invoices)");
      P.tile(t, String(od.length), od.length === 1 ? "overdue invoice" : "overdue invoices");
      P.tile(t, totals(a.paid30), "paid in the last 30 days");
      P.tile(t, String(a.clients || 0), "clients");
      var s = $("bz-alert"), b = $("bz-alert-btn"); P.clear(s); P.clear(b);
      s.appendChild(a.alerts ? P.chip("on", "ok") : P.chip("off", ""));
      b.appendChild(P.btn(a.alerts ? "Turn off" : "Turn on", "", function () { P.act("overdue", { on: a.alerts ? 0 : 1 }); }));
      var tb = $("bz-overdue"), sig = JSON.stringify(od); if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!od.length) { var r0 = P.el("tr"), c0 = P.cell("Nothing overdue.", "empty"); c0.colSpan = 4; r0.appendChild(c0); tb.appendChild(r0); }
      od.forEach(function (i) {
        var late = i.due ? Math.max(1, Math.floor((Date.now() / 1000 - i.due) / 86400)) : 0;
        P.row(tb, [P.cell(P.el("b", i.number || "–")), i.client, P.cell(P.el("span", money(i.balance, i.currency), "money"), "n"), late ? late + " day" + (late === 1 ? "" : "s") + " late" : "–"]);
      });
    },
    tiles: function (t, st) { var a = st.app || {}; P.tile(t, String((a.overdue || []).length), "overdue invoices"); }
  });

  // ---------------------------------------------------------------- Users
  P.register("users", {
    render: function (st) {
      var a = st.app || {}, users = a.users || [], tb = $("users");
      var sig = JSON.stringify(users) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      users.forEach(function (u) {
        var who = P.el("div"), acts = P.el("span", null, "row");
        who.appendChild(P.el("b", u.name || u.email)); if (u.name) who.appendChild(P.el("div", u.email, "muted small"));
        acts.appendChild(P.btn("New password", "", function () { P.act("userpw", { email: u.email }, "Make a new password for " + u.email + "?"); }));
        if (u.mfa) acts.appendChild(P.btn("Two-step off", "", function () { P.act("usermfa", { email: u.email }, "Turn off two-step sign-in for " + u.email + "?"); }));
        P.row(tb, [P.cell(who), u.owner ? P.chip("owner", "ok") : u.admin ? P.chip("admin", "ok") : "user", u.mfa ? "on" : "–", u.last ? P.ago(u.last) : "never", P.cell(acts, "n")]);
      });
    }
  });
  P.register("secretNote", function () { return "Use it to sign in to Invoice Ninja, then keep it in a password manager."; });

  // ---------------------------------------------------------------- Mail
  ["ml-host", "ml-port", "ml-enc", "ml-user", "ml-from", "ml-name"].forEach(touched);
  P.register("mail", {
    render: function (st) {
      var m = (st.app || {}).mail || {};
      $("badge-mail").hidden = !!m.on;
      quiet("ml-host", m.on ? m.host : ""); quiet("ml-port", m.port || 587); quiet("ml-enc", m.enc || "tls"); quiet("ml-user", m.user); quiet("ml-from", m.from); quiet("ml-name", m.name);
    }
  });
  $("ml-save").onclick = function () {
    P.act("mailset", { host: $("ml-host").value.trim(), port: $("ml-port").value.trim(), enc: $("ml-enc").value, user: $("ml-user").value, pass: $("ml-pass").value, from: $("ml-from").value.trim(), name: $("ml-name").value.trim() })
      .then(function () { $("ml-pass").value = ""; ["ml-host", "ml-port", "ml-enc", "ml-user", "ml-from", "ml-name"].forEach(function (id) { $(id).dataset.touched = ""; }); });
  };
  $("ml-test").onclick = function () { P.act("mailtest", { email: $("ml-to").value.trim() }); };

  // ---------------------------------------------------------------- Site address: HTTPS
  P.register("site", {
    fill: function (st) { var t = (st.app && st.app.tls) || {}; $("set-tls").value = t.mode || "off"; },
    values: function () { return { tls: $("set-tls").value }; },
    render: function (st) {
      var t = (st.app && st.app.tls) || {}, c = t.cert, tb = $("tls-info"), note = $("tls-note"), acts = $("tls-actions"); P.clear(tb); P.clear(acts);
      $("tls-card").hidden = !t.mode || t.mode === "off";
      if (!t.mode || t.mode === "off") return;
      if (!c) { P.kv(tb, "Certificate", "none yet — it's made or read when Invoice Ninja starts"); note.textContent = ""; return; }
      P.kv(tb, "From", t.source === "dsm" ? "DSM (the system default certificate)" : "the package (self-signed)");
      P.kv(tb, "Issued to", c.subject || "–"); P.kv(tb, "Issued by", c.self_signed ? "itself (self-signed)" : (c.issuer || "–"));
      P.kv(tb, "Expires", (c.expires || "–") + (typeof c.days_left === "number" ? " (" + (c.days_left < 0 ? "expired" : c.days_left + " days") + ")" : ""));
      if (c.names) P.kv(tb, "Names", c.names.replace(/,/g, ", "));
      note.textContent = t.mode === "dsm" && t.source === "self" ? "DSM's certificate wasn't found on this system, so a self-signed one is in use."
        : c.self_signed ? "Self-signed: browsers warn — and so would your clients' browsers on invoice links. For clients, use a trusted certificate (Let's Encrypt in DSM, made the system default) or DSM's reverse proxy with a domain."
        : "Browsers trust this certificate as long as they reach Invoice Ninja by one of its names.";
      acts.appendChild(P.btn(t.mode === "dsm" ? "Read DSM's certificate again" : "Make a new self-signed certificate", "", function () { P.act("refreshcert", {}, t.mode === "dsm" ? null : "Make a new self-signed certificate?"); }));
    }
  });
  $("set-tls").addEventListener("change", function () { $("set-url").dataset.touched = "1"; var u = $("set-url").value.trim(); if ($("set-tls").value !== "off" && /^http:\/\//.test(u)) $("set-url").value = "https://" + u.slice(7); });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Invoice Ninja's files")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Uploads (logos, documents, PDFs)", app.app], ["Logs", app.logs], ["Caches", app.framework]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    box.appendChild(c);
  } });
})(window.Panel);
