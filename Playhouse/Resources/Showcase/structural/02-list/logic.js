export const initialState = { items: [{ id: 1, title: "First item" }, { id: 2, title: "Second item" }], nextId: 3 };

export const actions = {
  add(state) {
    const id = state.nextId++;
    state.items.push({ id, title: "Item " + id });
  },
  removeFirst(state) {
    state.items.shift();
  }
};
