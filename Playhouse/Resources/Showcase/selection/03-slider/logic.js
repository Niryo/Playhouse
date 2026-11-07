export const initialState = { volume: 40, effort: 2 };

export const actions = {
  set(state, payload) {
    state[payload.field] = payload.value;
  }
};
