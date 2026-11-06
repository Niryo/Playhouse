export const initialState = { open: false, toggleTitle: "Show details" };

export const actions = {
  toggle(state) {
    state.open = !state.open;
    state.toggleTitle = state.open ? "Hide details" : "Show details";
  }
};
