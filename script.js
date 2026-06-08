document.documentElement.classList.add("js-ready");

for (const detail of document.querySelectorAll("details")) {
  detail.addEventListener("toggle", () => {
    if (!detail.open) return;
    for (const other of document.querySelectorAll("details[open]")) {
      if (other !== detail && other.parentElement === detail.parentElement) {
        other.open = false;
      }
    }
  });
}
