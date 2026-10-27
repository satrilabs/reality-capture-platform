// Runs the repository's Rego policies (compiled to policy.wasm at build
// time) against a change, and explains the verdict in plain words.
import opa from "./vendor/opa-wasm-browser.esm.js";

const $ = (sel) => document.querySelector(sel);
const changesList = $(".changes");
const narration = $(".narration");
const codeView = $(".code code");
const builder = $(".builder");
const goButton = $(".go");
const readout = $(".readout");
const result = $(".result");
const still = matchMedia("(prefers-reduced-motion: reduce)");
const sleep = (ms) => new Promise((r) => setTimeout(r, still.matches ? 0 : ms));

const REGION_NAMES = {
  westeurope: "West Europe",
  germanywestcentral: "Germany West Central",
  eastus: "East US",
  eastus2: "East US 2",
};
const ROLE_NAMES = {
  "Storage Blob Data Reader": "read-only access to files",
  Contributor: "the Contributor role (change anything)",
  Owner: "the Owner role (full control)",
};
const RENAME_STORE = {
  match: ["module.stamp_eu.azurerm_storage_account.scans"],
  icon: "swap",
  title: "Rename the main EU scan storage",
  detail: "Azure cannot rename storage. It deletes it and creates a new, empty one.",
};

const STORIES = {
  risky: {
    plan: "ai-risky-change",
    story: "The agent wrote this in seconds. At a glance it looks like a reasonable quick fix.",
    items: [
      { match: ["azurerm_storage_account.export"], icon: "storage", title: "Create an export bucket for the customer's download", detail: "In East US, reachable from the internet, with account keys on, copied to a second region." },
      { match: ["azurerm_role_assignment.export_writer"], icon: "key", title: "Give the export app the Contributor role", detail: "On the whole subscription, so the upload \"just works\"." },
      RENAME_STORE,
      { match: ["azurerm_subscription_policy_assignment.deny_public_storage"], icon: "shield", title: "Remove the rule \"deny public storage\"", detail: "It was blocking the public bucket above." },
    ],
  },
  safe: {
    plan: "ai-safe-change",
    story: "A small, careful change. This is what most agent work should look like.",
    items: [
      { match: ["module.stamp_eu.azurerm_storage_container.thumbnails"], icon: "image", title: "Add a private \"thumbnails\" folder", detail: "In the EU scan storage. Not public." },
      { match: ["module.stamp_eu.azurerm_role_assignment.viewer_read_thumbnails"], icon: "key", title: "Let the viewer read the thumbnails", detail: "Read-only access, nothing else." },
      { match: ["module.stamp_eu.azurerm_log_analytics_workspace.stamp"], icon: "gauge", title: "Raise the EU log limit to 8 GB a day", detail: "Room for the extra viewer logs, still capped." },
    ],
  },
  platform: {
    plan: "blueprint-prod",
    story: "A real Terraform plan of this whole project: both regions and the global entry point.",
    items: [
      { prefix: "module.stamp_eu.", icon: "layers", title: "EU region in West Europe", detail: "Private scan storage, upload queue, network, identities and audit logs" },
      { prefix: "module.stamp_us.", icon: "layers", title: "US region in East US 2", detail: "The same, fully separate from the EU" },
      { prefix: "module.edge.", icon: "globe", title: "Global entry point with a web firewall", detail: "Front Door sends each customer to their own region" },
      { prefix: "azurerm_resource_group.global", icon: "layers", title: "A home for the shared pieces", detail: "Holds no customer data" },
    ],
  },
};

// Plain-language explanations for each policy message.
const EXPLAIN = [
  [/cannot grant '([^']+)'/, (m) => [`Hands out "${m[1]}" rights`, "An AI agent may not give anyone broad access. With this role the app could change or delete anything in the subscription."]],
  [/location '([^']+)' is not allowed for data-region '([^']+)'/, (m) => ["Customer data in the wrong region", `This ${m[2].toUpperCase()} customer's data would be stored in ${REGION_NAMES[m[1]] || m[1]}. Data must stay in the customer's region, for GDPR and for the customer's contract.`]],
  [/missing required tags/, () => ["No owner or cost label", "Without owner, cost-center and data-region labels, nobody knows who owns it, who pays for it, or where its data may live."]],
  [/public_network_access_enabled/, () => ["Open to the internet", "Anyone on the internet could try to reach customer scans. Storage may only be reached through the platform's private network."]],
  [/shared_access_key_enabled/, () => ["Uses a shared master key", "Account keys work like one password for everything, and they leak. Only personal, logged sign-in is allowed."]],
  [/allow_nested_items_to_be_public/, () => ["Files could be made public", "Anonymous links to customer files must be impossible."]],
  [/min_tls_version/, () => ["Old, weak encryption allowed", "Connections must use TLS 1.2 or newer."]],
  [/cannot touch policies or audit logging/, () => ["Switches off a guardrail", "An AI agent may not change the rules that check it, or the audit logs. That needs a person."]],
  [/cannot delete or replace stateful/, () => ["Would destroy stored data", "Every scan in this storage would be lost. An AI agent may never delete or replace storage, databases or key vaults."]],
  [/plan changes (\d+) resources/, (m) => [`Too big to review: ${m[1]} resources`, "AI changes are limited to 25 resources, so a person can follow them. Split it into smaller steps."]],
  [/Spot VMs/, () => ["Build machines that never switch off", "Build machines must use cheap Spot capacity and scale to zero when nobody is building."]],
  [/geo-redundant/, () => ["Doubles the storage bill", "Keeping a second copy in another region doubles the cost. Allowed, but someone must record why."]],
  [/second approver/, () => ["Deletes stored data", "Allowed for an engineer, but a second person has to approve it."]],
];

const state = { story: "risky", author: "ai-agent" };
const plans = {};
let policy;
let renderId = 0;

function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "ico");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function resource(address, type, actions, after) {
  return { address, mode: "managed", type, name: address.split(".").pop(), change: { actions, after } };
}

function customStory() {
  const f = new FormData(builder);
  const tags = { owner: "team-scans", "data-region": f.get("dataRegion") };
  if (f.get("costTag")) tags["cost-center"] = "cc-4711";

  const resources = [
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
  const detail = [
    `In ${REGION_NAMES[f.get("location")]}`,
    f.get("publicAccess") ? "reachable from the internet" : "private",
    f.get("keys") ? "account keys on" : "personal sign-in only",
    f.get("replication") === "GZRS" ? "copied to a second region" : "3 copies in one region",
  ];
  if (!f.get("costTag")) detail.push("no cost-center label");
  const items = [{ match: ["azurerm_storage_account.customer_export"], icon: "storage", title: "Create an export bucket for the customer's download", detail: detail.join(", ") + "." }];

  if (f.get("role")) {
    resources.push(resource("azurerm_role_assignment.export_app", "azurerm_role_assignment", ["create"], { role_definition_name: f.get("role") }));
    items.push({ match: ["azurerm_role_assignment.export_app"], icon: "key", title: `Give the export app ${ROLE_NAMES[f.get("role")]}`, detail: "So it can write the export files." });
  }
  if (f.get("replace")) {
    resources.push(plans["ai-risky-change"].resource_changes.find((rc) => rc.address === RENAME_STORE.match[0]));
    items.push(RENAME_STORE);
  }
  return { plan: { resource_changes: resources }, items, story: "Your change. Flip the switches above and scan it again." };
}

function currentStory() {
  if (state.story === "custom") return customStory();
  const story = STORIES[state.story];
  return { plan: plans[story.plan], items: story.items, story: story.story };
}

function belongs(item, address) {
  return item.match ? item.match.includes(address) : address.startsWith(item.prefix);
}

function changeRow(item, index, plan) {
  const li = el("li", "change");
  li.append(el("span", "ref", `CHG-${String(index + 1).padStart(2, "0")}`), icon(item.icon));
  const body = el("div");
  body.append(el("p", "t", item.title));
  const count = item.prefix ? ` · ${plan.resource_changes.filter((rc) => belongs(item, rc.address)).length} resources` : "";
  body.append(el("p", "d", item.detail + count));
  li.append(body, el("span", "chip", "Not checked"));
  return li;
}

function setButton(label) {
  goButton.replaceChildren(document.createTextNode(label));
}

// Shows the change the way the story goes: the agent writes it line by line.
async function renderChanges({ animate = true } = {}) {
  const id = ++renderId;
  const { plan, items, story } = currentStory();
  const who = state.author === "ai-agent" ? "AI agent" : "Engineer";
  codeView.textContent = JSON.stringify(plan, null, 2);
  result.hidden = true;
  readout.classList.remove("on");
  readout.textContent = "10 rules loaded from policy/terraform";
  changesList.replaceChildren();
  goButton.disabled = true;

  for (const [i, item] of items.entries()) {
    if (animate) {
      narration.className = "narration typing";
      narration.textContent = `${who} is writing the change: ${i + 1} of ${items.length}`;
      await sleep(260);
      if (id !== renderId) return;
    }
    const row = changeRow(item, i, plan);
    if (animate) row.classList.add("enter");
    changesList.append(row);
  }

  narration.className = "narration";
  narration.replaceChildren(el("b", "", `${items.length} change${items.length === 1 ? "" : "s"} written. `), document.createTextNode(story));
  goButton.disabled = false;
  setButton("Scan this change");
}

function reasonNode(message, kind) {
  const found = EXPLAIN.find(([re]) => re.test(message));
  const [title, why] = found ? found[1](message.match(found[0])) : [message, ""];
  const li = el("li", kind === "warn" ? "reason warn" : "reason");
  li.append(el("b", "", (kind === "warn" ? "Warning: " : "") + title));
  if (why) li.append(el("span", "", why));
  li.append(el("code", "", message));
  return li;
}

const addressOf = (m) => (m.indexOf(": ") > 0 && !m.startsWith("plan ") ? m.slice(0, m.indexOf(": ")) : null);

// Moves the laser line down the list and stamps each row as it passes.
function sweep(rows, onRow) {
  return new Promise((resolve) => {
    const laser = el("li", "laser");
    laser.setAttribute("aria-hidden", "true");
    changesList.append(laser);
    const total = changesList.getBoundingClientRect().height;
    const marks = rows.map((r) => r.offsetTop + r.offsetHeight * 0.6);
    const duration = still.matches ? 0 : Math.min(2600, Math.max(1300, rows.length * 520));
    let next = 0;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      while (next < rows.length) onRow(next++);
      laser.remove();
      resolve();
    };
    const t0 = performance.now();
    const step = (now) => {
      if (done) return;
      const p = duration ? Math.min((now - t0) / duration, 1) : 1;
      const y = p * total;
      laser.style.transform = `translateY(${y}px)`;
      while (next < rows.length && marks[next] <= y) onRow(next++);
      if (p < 1) requestAnimationFrame(step);
      else finish();
    };
    requestAnimationFrame(step);
    // Background tabs pause animation frames; the verdict must still arrive.
    setTimeout(finish, duration + 800);
  });
}

async function run() {
  const id = renderId;
  goButton.disabled = true;
  setButton("Scanning…");
  result.hidden = true;
  const { plan, items } = currentStory();

  policy.setData({ change: { author_type: state.author } });
  const [{ result: decision }] = policy.evaluate(plan);
  const deny = [...decision.deny].sort();
  const warn = [...decision.warn].sort();

  const rows = [...changesList.querySelectorAll(".change")];
  for (const row of rows) {
    row.classList.remove("ok", "deny", "warn", "stamp");
    row.querySelector(".reasons")?.remove();
    row.querySelector(".chip").textContent = "Not checked";
  }
  readout.classList.add("on");
  readout.textContent = `Scanning ${plan.resource_changes.length} resources against 10 rules`;

  await sweep(rows, (i) => {
    const item = items[i];
    const mine = (list) => list.filter((m) => addressOf(m) && belongs(item, addressOf(m)));
    const d = mine(deny);
    const w = mine(warn);
    const row = rows[i];
    const kind = d.length ? "deny" : w.length ? "warn" : "ok";
    row.classList.add(kind, "stamp");
    row.querySelector(".chip").textContent = kind === "deny" ? "Blocked" : kind === "warn" ? "Warning" : "Pass";
    if (d.length || w.length) {
      const ul = el("ul", "reasons");
      ul.append(...d.map((m) => reasonNode(m, "deny")), ...w.map((m) => reasonNode(m, "warn")));
      row.append(ul);
    }
  });
  if (id !== renderId) return;

  $(".general").replaceChildren(
    ...deny.filter((m) => !addressOf(m)).map((m) => reasonNode(m, "deny")),
    ...warn.filter((m) => !addressOf(m)).map((m) => reasonNode(m, "warn")),
  );

  const n = plan.resource_changes.length;
  const kind = deny.length ? "deny" : warn.length ? "warn" : "allow";
  result.className = `result ${kind}`;
  const verdict = $(".verdict");
  verdict.replaceChildren(icon(kind === "deny" ? "cross" : kind === "warn" ? "alert" : "check"), verdict.querySelector("div"));
  $(".v-title").textContent = kind === "deny"
    ? `Blocked: ${deny.length} problem${deny.length === 1 ? "" : "s"} found`
    : kind === "warn" ? "Allowed, with a warning" : "Safe to approve";
  $(".v-sub").textContent = `${state.author === "ai-agent" ? "Written by an AI agent" : "Written by an engineer"} / ${n} resource${n === 1 ? "" : "s"} / 10 rules`;

  const next = $(".next");
  next.replaceChildren(
    el("strong", "", kind === "deny" ? "Nothing reached Azure. " : "Next, a platform engineer approves it. "),
    document.createTextNode(kind === "deny"
      ? "The change cannot be merged. The reasons go back to whoever wrote it, so they can fix it and try again."
      : "Then the pipeline applies exactly this change, and stops if anything changed after the approval."),
  );

  readout.textContent = `Done: ${deny.length} blocked, ${warn.length} warning${warn.length === 1 ? "" : "s"}`;
  result.hidden = false;
  goButton.disabled = false;
  setButton("Scan it again");
  result.scrollIntoView({ behavior: still.matches ? "auto" : "smooth", block: "nearest" });
}

function choose(groupSelector, attr, value) {
  for (const b of document.querySelectorAll(`${groupSelector} [${attr}]`)) {
    b.setAttribute("aria-checked", String(b.getAttribute(attr) === value));
  }
}

$(".stories").addEventListener("click", (e) => {
  const b = e.target.closest("[data-story]");
  if (!b || b.dataset.story === state.story) return;
  state.story = b.dataset.story;
  choose(".stories", "data-story", state.story);
  builder.hidden = state.story !== "custom";
  renderChanges();
});

$(".who").addEventListener("click", (e) => {
  const b = e.target.closest("[data-author]");
  if (!b || b.dataset.author === state.author) return;
  state.author = b.dataset.author;
  choose(".who", "data-author", state.author);
  renderChanges({ animate: false });
});

builder.addEventListener("input", () => renderChanges({ animate: false }));
builder.addEventListener("submit", (e) => e.preventDefault());
goButton.addEventListener("click", run);

// Sections arrive as they scroll into view. Content is visible without
// this; the class is only added when the browser can drive it, and a
// timer reveals everything in case the observer never reports.
const sections = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window && !still.matches) {
  document.documentElement.classList.add("motion");
  const reveal = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        reveal.unobserve(entry.target);
      }
    }
  }, { threshold: 0.12 });
  sections.forEach((node) => reveal.observe(node));
  setTimeout(() => sections.forEach((node) => node.classList.add("in")), 2500);
}

// The change list is filled at once; the first time it comes into view,
// the agent "writes" it again line by line.
let replayed = false;
const firstView = "IntersectionObserver" in window && new IntersectionObserver(([entry]) => {
  if (entry.isIntersecting && !replayed) {
    replayed = true;
    firstView.disconnect();
    renderChanges();
  }
}, { threshold: 0.35 });

try {
  const [wasm, ...loaded] = await Promise.all([
    fetch("policy.wasm").then((r) => r.arrayBuffer()),
    ...Object.values(STORIES).map(({ plan }) => fetch(`plans/${plan}.json`).then((r) => r.json()).then((p) => [plan, p])),
  ]);
  for (const [name, p] of loaded) plans[name] = p;
  policy = await opa.loadPolicy(wasm);
  await renderChanges({ animate: false });
  if (firstView && !still.matches) firstView.observe($(".changes").closest(".step"));
} catch (err) {
  setButton("The checker could not be loaded");
  console.error(err);
}
