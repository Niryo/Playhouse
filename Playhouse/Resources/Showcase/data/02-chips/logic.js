export const initialState = {
  tags: [{ id: 1, text: "swift", selected: true }, { id: 2, text: "plugins", selected: false }],
  nextId: 3
};

export const actions = {
  toggle(state, payload) {
    const tag = state.tags.find(t => t.id === payload.id);
    if (tag) tag.selected = !tag.selected;
  },
  remove(state, payload) {
    state.tags = state.tags.filter(t => t.id !== payload.id);
  },
  add(state) {
    state.tags.push({ id: state.nextId, text: "tag " + state.nextId, selected: false });
    state.nextId += 1;
  }
};
