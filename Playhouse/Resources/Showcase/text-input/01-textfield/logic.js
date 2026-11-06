export const initialState = { draft: "", entries: [], nextId: 1 };

export const actions = {
  edit(state, payload) {
    state.draft = payload.value;
  },
  add(state) {
    if (!state.draft) return;
    state.entries.push({ id: state.nextId++, text: state.draft });
    state.draft = "";
  }
};
