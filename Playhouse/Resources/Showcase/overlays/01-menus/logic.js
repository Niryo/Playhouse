export const initialState = { byName: true, byDate: false, last: "none" };

export const actions = {
  sort(state, payload) {
    state.byName = payload.by === "name";
    state.byDate = payload.by === "date";
    state.last = "Sorted by " + payload.by;
  },
  act(state, payload) {
    state.last = payload.what;
  }
};
