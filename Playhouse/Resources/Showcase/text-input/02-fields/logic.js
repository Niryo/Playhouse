export const initialState = { plain: "", secret: "", secretLength: 0, query: "", notes: "", submits: 0 };

export const actions = {
  set(state, payload) {
    state[payload.field] = payload.value;
    state.secretLength = state.secret.length;
  },
  submitted(state) {
    state.submits += 1;
  }
};
