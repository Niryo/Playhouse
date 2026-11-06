export const initialState = { count: 0, atZero: true };

export const actions = {
  change(state, payload) {
    state.count = Math.max(0, state.count + payload.by);
    state.atZero = state.count === 0;
  },
  reset(state) {
    state.count = 0;
    state.atZero = true;
  }
};
