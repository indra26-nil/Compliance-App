/* Compliance register — talks to the D/E/F API. No build step. */
(function () {
  "use strict";
  var apiBaseInput = document.getElementById("apiBase");
  var sessionInfo = document.getElementById("sessionInfo");
  var loginBtn = document.getElementById("loginBtn");
  var logoutBtn = document.getElementById("logoutBtn");
  var loginPanel = document.getElementById("loginPanel");
  var registerView = document.getElementById("registerView");
  var loginForm = document.getElementById("loginForm");
  var loginError = document.getElementById("loginError");
  var violationsList = document.getElementById("violationsList");
  var filesBody = document.getElementById("filesBody");
  var searchInput = document.getElementById("searchInput");
  var verdictFilter = document.getElementById("verdictFilter");
  var categoryFilter = document.getElementById("categoryFilter");
  var csvBtn = document.getElementById("csvBtn");
  var prevPage = document.getElementById("prevPage");
  var nextPage = document.getElementById("nextPage");
  var pageInfo = document.getElementById("pageInfo");
  var drawer = document.getElementById("drawer");
  var scrim = document.getElementById("scrim");
  var drawerClose = document.getElementById("drawerClose");
  var drawerBody = document.getElementById("drawerBody");
  var drawerTitle = document.getElementById("drawerTitle");
  var drawerKicker = document.getElementById("drawerKicker");
  var pdfBtn = document.getElementById("pdfBtn");

  var state = { page: 1, total: 0, limit: 20, activeRule: "", detailId: "" };

  function defaultBase() {
    if (window.location.protocol.indexOf("http") === 0) {
      var origin = window.location.origin;
      // Same-origin deploy: API lives next to /dashboard.
      if (window.location.pathname.indexOf("/dashboard") === 0) return origin;
    }
    return "http://localhost:5000";
  }
  function base() {
    return (apiBaseInput.value || localStorage.getItem("apiBase") || defaultBase()).replace(/\/$/, "");
  }
  function token() { return localStorage.getItem("jwt") || ""; }
  function authHeaders() {
    var h = {};
    if (token()) h.Authorization = "Bearer " + token();
    return h;
  }
  async function api(path, opts) {
    opts = opts || {};
    opts.headers = Object.assign({}, authHeaders(), opts.headers || {});
    var res = await fetch(base() + path, opts);
    if (res.status === 401) { signOut("Session expired. Sign in again."); throw new Error("unauthorized"); }
    var data = null;
    try { data = await res.json(); } catch (e) { /* pdf/csv handled by callers */ }
    if (!res.ok) throw new Error((data && data.message) || ("Request failed (" + res.status + ")"));
    return data;
  }

  function verdictName(v) {
    if (v === "compliant") return "Compliant";
    if (v === "nonCompliant") return "Non-compliant";
    return "Needs review";
  }

  function refreshSession() {
    var t = token();
    var user = null;
    try { user = JSON.parse(localStorage.getItem("user") || "null"); } catch (e) {}
    if (t && user) {
      sessionInfo.textContent = user.name + " · " + user.role;
      loginBtn.classList.add("hidden");
      logoutBtn.classList.remove("hidden");
      loginPanel.classList.add("hidden");
      registerView.classList.remove("hidden");
    } else {
      sessionInfo.textContent = "Not signed in";
      loginBtn.classList.remove("hidden");
      logoutBtn.classList.add("hidden");
      loginPanel.classList.remove("hidden");
      registerView.classList.add("hidden");
    }
  }

  function signOut(msg) {
    localStorage.removeItem("jwt");
    localStorage.removeItem("user");
    refreshSession();
    if (msg) { loginError.textContent = msg; loginError.classList.remove("hidden"); }
  }

  async function loadSummary() {
    var s = await api("/api/dashboard/summary");
    document.getElementById("tallyCompliant").textContent = s.byVerdict.compliant;
    document.getElementById("tallyNonCompliant").textContent = s.byVerdict.nonCompliant;
    document.getElementById("tallyNeedsReview").textContent = s.byVerdict.needsReview;
    document.getElementById("tallyTotal").textContent = s.totalScans;
    document.getElementById("passRate").textContent = Math.round((s.passRate || 0) * 100) + "%";
    var max = 1;
    s.topViolations.forEach(function (v) { if (v.count > max) max = v.count; });
    violationsList.innerHTML = "";
    if (!s.topViolations.length) {
      var empty = document.createElement("li");
      empty.innerHTML = '<p class="hint">No failed rules yet. Sync a scan from the app.</p>';
      violationsList.appendChild(empty);
      return;
    }
    s.topViolations.forEach(function (v) {
      var li = document.createElement("li");
      var btn = document.createElement("button");
      btn.type = "button";
      btn.setAttribute("aria-pressed", state.activeRule === v.code ? "true" : "false");
      var pct = Math.round((v.count / max) * 100);
      btn.innerHTML = '<span class="code"></span><span class="bar"><i></i></span><span class="count"></span>';
      btn.querySelector(".code").textContent = v.code;
      btn.querySelector(".bar i").style.width = pct + "%";
      btn.querySelector(".count").textContent = v.count + (v.count === 1 ? " file" : " files") + " — select to filter";
      btn.addEventListener("click", function () {
        state.activeRule = state.activeRule === v.code ? "" : v.code;
        state.page = 1;
        loadSummary();
        loadFiles();
      });
      li.appendChild(btn);
      violationsList.appendChild(li);
    });
  }

  async function loadFiles() {
    var params = new URLSearchParams({
      page: String(state.page),
      limit: String(state.limit),
      q: searchInput.value || "",
      verdict: verdictFilter.value || "",
      category: categoryFilter.value || "",
    });
    var data = await api("/api/scans?" + params.toString());
    state.total = data.total;
    filesBody.innerHTML = "";
    if (!data.scans.length) {
      var tr = document.createElement("tr");
      var td = document.createElement("td");
      td.colSpan = 5;
      td.textContent = state.activeRule
        ? "No files match this filter yet."
        : "No files yet. Scan a product in the app and it appears here after sync.";
      tr.appendChild(td);
      filesBody.appendChild(tr);
    }
    var show = data.scans;
    if (state.activeRule) {
      // Violation filter needs report detail; fetch lazily per row is wasteful,
      // so filter client-side by re-checking detail on open instead. Here we
      // keep the server list and note the active filter in the hint.
      document.getElementById("filesHint").textContent =
        "Filtered to files citing " + state.activeRule + " — open a file to confirm. Select the rule again to clear.";
    }
    show.forEach(function (s) {
      var tr = document.createElement("tr");
      var filed = "";
      try { filed = new Date(s.createdAt).toLocaleDateString(); } catch (e) {}
      tr.innerHTML = "<td></td><td></td><td></td><td></td><td></td>";
      tr.children[0].textContent = s.productName;
      var v = document.createElement("span");
      v.className = "verdict " + s.verdict;
      v.textContent = verdictName(s.verdict);
      tr.children[1].appendChild(v);
      tr.children[2].textContent = s.score + "/100";
      tr.children[3].textContent = s.photoCount;
      tr.children[4].textContent = filed;
      tr.addEventListener("click", function () { openDetail(s.id); });
      tr.tabIndex = 0;
      tr.addEventListener("keydown", function (e) { if (e.key === "Enter") openDetail(s.id); });
      filesBody.appendChild(tr);
    });
    var pages = Math.max(1, Math.ceil(state.total / state.limit));
    pageInfo.textContent = "Page " + state.page + " of " + pages + " · " + state.total + " files";
    prevPage.disabled = state.page <= 1;
    nextPage.disabled = state.page >= pages;
  }

  async function openDetail(id) {
    state.detailId = id;
    var data = await api("/api/scans/" + encodeURIComponent(id));
    var s = data.scan;
    var r = s.reportJson || {};
    drawerKicker.textContent = "File · " + (s.category || "general") + " · filed " + new Date(s.createdAt).toLocaleString();
    drawerTitle.textContent = s.productName;
    var html = "";
    html += '<div><span class="stamp-line ' + s.verdict + '">' + verdictName(s.verdict) + " · " + s.score + "/100</span></div>";
    html += '<dl class="kv">' +
      "<dt>Officer</dt><dd>" + escapeHtml(s.officerName || (s.officer && s.officer.email) || "—") + "</dd>" +
      "<dt>Photos</dt><dd>" + s.photoCount + "</dd>" +
      "<dt>Capture quality</dt><dd>" + Math.round((r.meanConfidence || s.meanConfidence || 0) * 100) + "% mean confidence</dd>" +
      "</dl>";
    if (s.imageUrls && s.imageUrls.length) {
      html += '<div><h3>Evidence photos</h3><div class="evidence">';
      s.imageUrls.forEach(function (u, i) {
        html += '<a href="' + escapeAttr(u) + '" target="_blank" rel="noopener"><img src="' + escapeAttr(u) + '" alt="Evidence photo ' + (i + 1) + '" loading="lazy"></a>';
      });
      html += "</div></div>";
    }
    html += "<div><h3>Rule findings</h3><div>";
    (r.results || []).forEach(function (rule) {
      html += '<div class="rule"><span class="code">' + escapeHtml(rule.code || "") + "</span> · " +
        '<span class="status-' + escapeHtml(rule.status || "") + '">' + escapeHtml(String(rule.status || "").toUpperCase()) + "</span><br>" +
        escapeHtml(rule.message || "") +
        (rule.evidence ? "<br><span class='hint'>Evidence: " + escapeHtml(String(rule.evidence).slice(0, 220)) + "</span>" : "") +
        "</div>";
    });
    html += "</div></div>";
    if (s.ocrText) {
      html += "<div><h3>OCR text (audit)</h3><div class='ocr-text'>" + escapeHtml(s.ocrText) + "</div></div>";
    }
    drawerBody.innerHTML = html;
    drawer.classList.remove("hidden");
    scrim.classList.remove("hidden");
  }

  function closeDetail() {
    drawer.classList.add("hidden");
    scrim.classList.add("hidden");
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function escapeAttr(s) { return escapeHtml(s).replace(/"/g, "&quot;"); }

  // Events
  apiBaseInput.value = localStorage.getItem("apiBase") || defaultBase();
  apiBaseInput.addEventListener("change", function () {
    localStorage.setItem("apiBase", base());
  });
  loginBtn.addEventListener("click", function () {
    loginPanel.classList.remove("hidden");
    document.getElementById("email").focus();
  });
  logoutBtn.addEventListener("click", function () { signOut(); });
  loginForm.addEventListener("submit", async function (e) {
    e.preventDefault();
    loginError.classList.add("hidden");
    try {
      var res = await fetch(base() + "/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email: document.getElementById("email").value,
          password: document.getElementById("password").value,
        }),
      });
      var data = await res.json();
      if (!res.ok) throw new Error(data.message || "Sign in failed");
      localStorage.setItem("jwt", data.token);
      localStorage.setItem("user", JSON.stringify(data.user));
      localStorage.setItem("apiBase", base());
      refreshSession();
      await loadSummary();
      await loadFiles();
    } catch (err) {
      loginError.textContent = err.message + " — check the server address and account.";
      loginError.classList.remove("hidden");
    }
  });

  var debounce = null;
  searchInput.addEventListener("input", function () {
    clearTimeout(debounce);
    debounce = setTimeout(function () { state.page = 1; loadFiles().catch(function () {}); }, 300);
  });
  verdictFilter.addEventListener("change", function () { state.page = 1; loadFiles().catch(function () {}); });
  categoryFilter.addEventListener("change", function () { state.page = 1; loadFiles().catch(function () {}); });
  prevPage.addEventListener("click", function () { if (state.page > 1) { state.page -= 1; loadFiles().catch(function () {}); } });
  nextPage.addEventListener("click", function () { state.page += 1; loadFiles().catch(function () {}); });
  csvBtn.addEventListener("click", async function () {
    var res = await fetch(base() + "/api/reports.csv", { headers: authHeaders() });
    if (!res.ok) { alert("Sheet download failed (" + res.status + ")."); return; }
    var blob = await res.blob();
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "reports.csv";
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
  });
  pdfBtn.addEventListener("click", async function () {
    if (!state.detailId) return;
    var res = await fetch(base() + "/api/reports/" + encodeURIComponent(state.detailId) + ".pdf", { headers: authHeaders() });
    if (!res.ok) { alert("PDF download failed (" + res.status + ")."); return; }
    var blob = await res.blob();
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "compliance-" + state.detailId + ".pdf";
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
  });
  drawerClose.addEventListener("click", closeDetail);
  scrim.addEventListener("click", closeDetail);
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeDetail(); });

  refreshSession();
  if (token()) {
    loadSummary().catch(function () {});
    loadFiles().catch(function () {});
  }
})();
