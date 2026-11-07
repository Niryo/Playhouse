export const initialState = { layout: "list", size: "M", priority: "normal" };

export const actions = {
  set(state, payload) {
    state[payload.field] = payload.value;
  }
};
