// Phoenix LiveView hook for roving-tabindex keyboard navigation on
// role="tablist" widgets, matching the WAI-ARIA Authoring Practices
// tablist pattern.
//
// Attach with `phx-hook="TabList"` on the element that carries
// `role="tablist"`. Every direct or nested `role="tab"` descendant
// becomes a keyboard target.
//
// Keybindings:
//   ArrowLeft / ArrowUp   -> focus previous tab (wraps)
//   ArrowRight / ArrowDown -> focus next tab (wraps)
//   Home                  -> focus first tab
//   End                   -> focus last tab
//   Enter / Space         -> activate focused tab (forwards the
//                            existing phx-click so LiveView state
//                            updates and `aria-selected` rolls).
//
// The hook only manages focus and forwards activation; LiveView owns
// `aria-selected` and `tabindex` state on the server and rerenders
// after the phx-click round-trip.

const TabList = {
  mounted() {
    this.onKeyDown = (event) => this.handleKeyDown(event);
    this.el.addEventListener("keydown", this.onKeyDown);
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown);
  },

  tabs() {
    return Array.from(this.el.querySelectorAll('[role="tab"]'));
  },

  focusAt(index) {
    const tabs = this.tabs();
    if (tabs.length === 0) return;
    const target = tabs[(index + tabs.length) % tabs.length];
    target.focus();
  },

  currentIndex() {
    const tabs = this.tabs();
    const active = document.activeElement;
    const idx = tabs.indexOf(active);
    if (idx !== -1) return idx;
    // Fall back to the tab with tabindex=0 (the "selected" one).
    return tabs.findIndex((t) => t.getAttribute("tabindex") === "0");
  },

  handleKeyDown(event) {
    const tabs = this.tabs();
    if (tabs.length === 0) return;

    // Only react when the focused element is one of our tabs.
    if (!tabs.includes(event.target)) return;

    const key = event.key;
    const current = this.currentIndex();

    switch (key) {
      case "ArrowLeft":
      case "ArrowUp":
        event.preventDefault();
        this.focusAt(current - 1);
        break;

      case "ArrowRight":
      case "ArrowDown":
        event.preventDefault();
        this.focusAt(current + 1);
        break;

      case "Home":
        event.preventDefault();
        this.focusAt(0);
        break;

      case "End":
        event.preventDefault();
        this.focusAt(tabs.length - 1);
        break;

      case "Enter":
      case " ":
      case "Spacebar":
        // Let native button click fire; LiveView picks it up via
        // phx-click and rerenders aria-selected + tabindex.
        if (event.target.tagName === "BUTTON") return;
        event.preventDefault();
        event.target.click();
        break;

      default:
        return;
    }
  },
};

export default TabList;
