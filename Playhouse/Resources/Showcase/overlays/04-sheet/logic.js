export const initialState = { open: false, draft: "", name: "Untitled" };

export const actions = {
  open(state) {
    state.draft = state.name;
    state.open = true;
  },
  close(state) {
    state.open = false;
  },
  edit(state, payload) {
    state.draft = payload.value;
  },
  save(state) {
    state.name = state.draft;
    state.open = false;
  }
};
