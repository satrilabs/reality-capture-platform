// Evaluates the repository's Rego policies (compiled to policy.wasm at
// build time) against example plans or a plan built from the form.
import opa from "./vendor/opa-wasm-browser.esm.js";

const verdict = document.querySelector(".verdict");
const findings = document.querySelector(".findings");
const planView = document.querySelector(".plan code");
const form = document.querySelector('[data-pane="build"]');

const state = { author: "ai-agent", tab: "examples", plan: "ai-risky-change" };
const plans = {};
let policy;

function goodScanStorage() {
  return {
    location: "westeurope",
    account_replication_type: "ZRS",
    min_tls_version: "TLS1_2",
    public_network_access_enabled: false,
    allow_nested_items_to_be_public: false,
    shared_access_key_enabled: false,
    tags: { owner: "platform-team", "cost-center": "cc-4711", "data-region": "eu", workload: "scan-data" },
  };
}

function resource(address, type, actions, after) {
  return { address, mode: "managed", type, name: address.split(".").pop(), change: { actions, after } };
}

function planFromForm() {
  const f = new FormData(form);
  const tags = { owner: "team-scans", "data-region": f.get("dataRegion") };
  if (f.get("costTag")) tags["cost-center"] = "cc-4711";

  const changes = [
    resource("azurerm_storage_account.customer_export", "azurerm_storage_account", ["create"], {
      location: f.get("location"),
      account_replication_type: f.get("replication"),
      min_tls_version: "TLS1_2",
      public_network_access_enabled: Boolean(f.get("publicAccess")),
      allow_nested_items_to_be_public: false,
      shared_access_key_enabled: Boolean(f.get("keys")),
      tags,
    }),
  ];
  if (f.get("role")) {
    changes.push(resource("azurerm_role_assignment.export_app", "azurerm_role_assignment", ["create"], {
      role_definition_name: f.get("role"),
    }));
  }
  if (f.get("replace")) {
    changes.push(resource("module.stamp_eu.azurerm_storage_account.scans", "azurerm_storage_account", ["delete", "create"], goodScanStorage()));
  }
  return { resource_changes: changes };
}

function currentPlan() {
  return state.tab === "build" ? planFromForm() : plans[state.plan];
}

function changedCount(plan) {
  return plan.resource_changes.filter((rc) => !["no-op", "read"].includes(rc.change.actions.join())).length;
}

function item(kind, text) {
  const li = document.createElement("li");
  li.className = kind;
  const split = text.indexOf(": ");
  const where = split > 0 ? text.slice(0, split) : "";
  const what = split > 0 ? text.slice(split + 2) : text;
  li.innerHTML = `<span class="tag">${kind === "deny" ? "Blocked" : "Warning"}</span>`;
  const body = document.createElement("span");
  body.className = "body";
  const strong = document.createElement("strong");
  strong.textContent = what;
  body.append(strong);
  if (where) {
    const code = document.createElement("code");
    code.textContent = where;
    body.append(code);
  }
  li.append(body);
  return li;
}

function render() {
  if (!policy) return;
  const plan = currentPlan();
  policy.setData({ change: { author_type: state.author } });
  const [{ result }] = policy.evaluate(plan);

  const who = state.author === "ai-agent" ? "an AI agent" : "an engineer";
  const n = changedCount(plan);
  verdict.dataset.state = result.allow ? "allow" : "deny";
  verdict.querySelector(".status").textContent = result.allow
    ? result.warn.length ? "Allowed, with a warning" : "Allowed"
    : `Blocked: ${result.deny.length} reason${result.deny.length === 1 ? "" : "s"}`;
  verdict.querySelector(".meta").textContent = `Change by ${who} · ${n} resource${n === 1 ? "" : "s"}`;

  findings.replaceChildren(
    ...[...result.deny].sort().map((m) => item("deny", m)),
    ...[...result.warn].sort().map((m) => item("warn", m)),
  );
  if (result.allow && !result.warn.length) {
    const li = document.createElement("li");
    li.className = "ok";
    li.textContent = state.author === "ai-agent"
      ? "Nothing risky found. It still goes to a platform engineer for approval."
      : "Nothing risky found. A second engineer approves before the pipeline applies it.";
    findings.replaceChildren(li);
  }
  planView.textContent = JSON.stringify(plan, null, 2);
}

function select(group, attr, value) {
  for (const b of document.querySelectorAll(`[${attr}]`)) {
    if (b.closest(group)) b.setAttribute(b.getAttribute("role") === "tab" ? "aria-selected" : "aria-checked", String(b.getAttribute(attr) === value));
  }
}

document.querySelector(".segmented").addEventListener("click", (e) => {
  const b = e.target.closest("[data-author]");
  if (!b) return;
  state.author = b.dataset.author;
  select(".segmented", "data-author", state.author);
  render();
});

document.querySelector(".tabs").addEventListener("click", (e) => {
  const b = e.target.closest("[data-tab]");
  if (!b) return;
  state.tab = b.dataset.tab;
  select(".tabs", "data-tab", state.tab);
  for (const pane of document.querySelectorAll("[data-pane]")) pane.hidden = pane.dataset.pane !== state.tab;
  render();
});

document.querySelector(".examples").addEventListener("click", (e) => {
  const b = e.target.closest("[data-plan]");
  if (!b) return;
  state.plan = b.dataset.plan;
  select(".examples", "data-plan", state.plan);
  render();
});

form.addEventListener("input", render);
form.addEventListener("submit", (e) => e.preventDefault());

try {
  const [wasm, ...loaded] = await Promise.all([
    fetch("policy.wasm").then((r) => r.arrayBuffer()),
    ...["ai-risky-change", "ai-safe-change", "blueprint-prod"].map((name) =>
      fetch(`plans/${name}.json`).then((r) => r.json()).then((p) => [name, p])),
  ]);
  for (const [name, p] of loaded) plans[name] = p;
  policy = await opa.loadPolicy(wasm);
  render();
} catch (err) {
  verdict.dataset.state = "error";
  verdict.querySelector(".status").textContent = "The policies could not be loaded.";
  verdict.querySelector(".meta").textContent = String(err);
}
