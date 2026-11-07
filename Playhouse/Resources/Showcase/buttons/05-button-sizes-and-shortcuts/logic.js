export const initialState = { presses: 0 };

export const actions = {
  press(state) {
    state.presses += 1;
  }
};
