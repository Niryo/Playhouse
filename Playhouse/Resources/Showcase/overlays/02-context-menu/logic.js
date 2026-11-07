export const initialState = { last: "nothing" };

export const actions = {
  act(state, payload) {
    state.last = payload.what;
  }
};
