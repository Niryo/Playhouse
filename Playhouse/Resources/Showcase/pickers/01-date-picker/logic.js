const start = "2026-11-07T09:30:00Z";
export const initialState = { day: start, when: start, both: start };

export const actions = {
  set(state, payload) {
    state[payload.field] = payload.value;
  }
};
