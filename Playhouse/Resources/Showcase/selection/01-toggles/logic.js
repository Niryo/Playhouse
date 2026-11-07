export const initialState = { notify: true, autosave: false };

export const actions = {
  set(state, payload) {
    state[payload.field] = payload.value;
  }
};
