(() => {
  const pending = new Map();

  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || event.defaultPrevented) return;
    if (form.getAttribute("aria-busy") === "true") {
      event.preventDefault();
      return;
    }
    const buttons = [...form.querySelectorAll("button[data-loading-text]")];
    if (!buttons.length) return;
    form.setAttribute("aria-busy", "true");
    buttons.forEach((button) => {
      pending.set(button, { text: button.textContent, disabled: button.disabled });
      button.textContent = button.dataset.loadingText;
      button.disabled = true;
    });
  });

  window.addEventListener("pageshow", () => {
    pending.forEach((state, button) => {
      button.textContent = state.text;
      button.disabled = state.disabled;
      button.form?.removeAttribute("aria-busy");
    });
    pending.clear();
    const rejected = document.querySelector('form [aria-invalid="true"]')?.form;
    rejected?.querySelector('button[type="submit"]')?.focus({ focusVisible: false });
  });
})();
