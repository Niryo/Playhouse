export const initialState = { open: false };

export const actions = {
  toggle(state) {
    state.open = !state.open;
  },
  close(state) {
    state.open = false;
  }
};
