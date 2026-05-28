const buttons = document.querySelectorAll("[data-copy]");

for (const button of buttons) {
  button.addEventListener("click", async () => {
    const value = button.getAttribute("data-copy");
    const state = button.querySelector(".copy-state");

    try {
      await navigator.clipboard.writeText(value);
      state.textContent = "copied";
    } catch (_error) {
      state.textContent = "select";
    }

    window.setTimeout(() => {
      state.textContent = "copy";
    }, 1600);
  });
}
