// track("d,d,n,-"): d done, n needs you, w working, x blocked, - not yet
function track(s, el) {
  const names = ["Plan", "Build", "Review", "Merge"], c = s.split(",");
  const col = { d: "var(--success)", n: "var(--warning)", w: "var(--working)", x: "var(--failure)", "-": "var(--tertiary)" };
  el.outerHTML = '<div class="track">' + names.map((n, i) =>
    `<span class="st" style="color:${col[c[i]]}"><i class="dot" style="background:${col[c[i]]}"></i>${n}</span>`).join('<i class="seg"></i>') + '</div>';
}
function bar(s, el) {
  const col = { d: "var(--success)", n: "var(--warning)", w: "var(--working)", x: "var(--failure)", "-": "var(--sep)" };
  el.outerHTML = '<span class="mb">' + s.split(",").map(k => `<i style="background:${col[k]}"></i>`).join("") + '</span>';
}
document.querySelectorAll("[data-track]").forEach(e => track(e.dataset.track, e));
document.querySelectorAll("[data-bar]").forEach(e => bar(e.dataset.bar, e));
