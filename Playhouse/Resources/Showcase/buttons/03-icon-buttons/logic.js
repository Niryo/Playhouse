export const initialState = { last: "nothing yet" };

export const actions = {
  pressed(state, payload) {
    state.last = payload.which;
  }
};
